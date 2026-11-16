# frozen_string_literal: true

# Idempotent provisioning of the Telegram support AI setup on an empty or
# existing installation. Every step finds its record first and only writes when
# the record is missing or differs from the desired state. Secrets are read from
# ENV and are never printed.
class Chargersystem::SupportAiSetup
  BOT_LABEL = 'ai-bot-active'
  MARKER = '[managed-by:cs-ai-gateway;key:%s]'

  Result = Struct.new(:step, :status, :detail) do
    def ok? = %w[ok created applied].include?(status)
    def to_s = detail.present? ? "#{step}=#{status}(#{detail})" : "#{step}=#{status}"
  end

  def initialize(env: ENV, apply: false)
    @env = env
    @apply = apply
    @results = []
  end

  attr_reader :results, :account, :inbox, :agent_bot

  def run
    ensure_account
    ensure_admin
    ensure_inbox
    ensure_agent_bot
    ensure_bot_inbox
    ensure_label_and_rules
    ensure_telegram_webhook
    verify_ids
    results.all?(&:ok?)
  end

  private

  attr_reader :env

  def apply? = @apply

  def ensure_account
    name = required('CHATWOOT_ACCOUNT_NAME')
    @account = Account.find_by(name: name)
    return record('account', 'ok') if account
    return record('account', 'missing') unless apply?

    @account = Account.create!(name: name)
    record('account', 'created')
  end

  def ensure_admin
    return record('admin', 'missing', 'account') unless account

    email = required('CHATWOOT_ADMIN_EMAIL').downcase
    user = User.from_email(email)
    membership = user && account.account_users.find_by(user: user)
    onboarding = ::Redis::Alfred.get(::Redis::Alfred::CHATWOOT_INSTALLATION_ONBOARDING).present?
    return record('admin', 'ok') if membership&.administrator? && !onboarding
    return record('admin', user ? 'mismatch' : 'missing', admin_detail(membership, onboarding)) unless apply?

    user ||= create_admin_user(email)
    membership ||= account.account_users.new(user: user)
    membership.update!(role: :administrator) unless membership.persisted? && membership.administrator?
    ::Redis::Alfred.delete(::Redis::Alfred::CHATWOOT_INSTALLATION_ONBOARDING)
    record('admin', 'applied')
  end

  def admin_detail(membership, onboarding)
    [('role' unless membership&.administrator?), ('onboarding' if onboarding)].compact.join(',')
  end

  def create_admin_user(email)
    user = SuperAdmin.new(
      name: env.fetch('CHATWOOT_ADMIN_NAME', 'Administrator'),
      email: email,
      password: required('CHATWOOT_ADMIN_PASSWORD')
    )
    user.skip_confirmation!
    user.save!
    user
  end

  def ensure_inbox
    return record('inbox', 'missing', 'account') unless account

    token = required('TELEGRAM_BOT_TOKEN')
    name = required('TELEGRAM_INBOX_NAME')
    channel = Channel::Telegram.find_by(bot_token: token)
    raise 'TELEGRAM_BOT_TOKEN belongs to another account' if channel && channel.account_id != account.id

    @inbox = channel&.inbox
    return record('inbox', 'ok') if inbox
    return record('inbox', 'missing') unless apply?

    channel ||= Channel::Telegram.create!(account: account, bot_token: token)
    @inbox = account.inboxes.create!(name: name, channel: channel)
    record('inbox', 'created')
  end

  def ensure_agent_bot
    return record('agent_bot', 'missing', 'account') unless account

    name = required('CHATWOOT_AGENT_BOT_NAME')
    desired = {
      outgoing_url: "#{origin('GATEWAY_PUBLIC_URL')}/webhooks/chatwoot",
      secret: required('CHATWOOT_WEBHOOK_SECRET')
    }
    token = required('CHATWOOT_BOT_TOKEN')
    @agent_bot = account.agent_bots.find_by(name: name)
    changed = agent_bot_changes(desired, token)
    return record('agent_bot', 'ok') if agent_bot && changed.empty?
    return record('agent_bot', agent_bot ? 'mismatch' : 'missing', changed.join(',')) unless apply?

    write_agent_bot(name, desired, token)
    record('agent_bot', 'applied', changed.join(','))
  end

  def agent_bot_changes(desired, token)
    return [] unless agent_bot

    changed = desired.keys.reject { |field| agent_bot.public_send(field) == desired[field] }.map(&:to_s)
    changed << 'access_token' unless agent_bot.access_token&.token == token
    changed
  end

  def write_agent_bot(name, desired, token)
    owner = AccessToken.find_by(token: token)&.owner
    raise 'CHATWOOT_BOT_TOKEN is already used by another owner' if owner && owner != agent_bot

    AgentBot.transaction do
      @agent_bot ||= account.agent_bots.new(name: name)
      agent_bot.update!(desired)
      access_token = agent_bot.access_token || agent_bot.create_access_token
      access_token.update!(token: token) unless access_token.token == token
    end
  end

  def ensure_bot_inbox
    return record('bot_inbox', 'missing', 'inbox or agent_bot') unless inbox && agent_bot

    binding = AgentBotInbox.find_by(inbox: inbox)
    return record('bot_inbox', 'ok') if binding&.agent_bot_id == agent_bot.id && binding.active?
    return record('bot_inbox', binding ? 'mismatch' : 'missing') unless apply?

    binding ||= AgentBotInbox.new(inbox: inbox)
    binding.update!(agent_bot: agent_bot, status: :active)
    record('bot_inbox', 'applied')
  end

  def ensure_label_and_rules
    return record('automation', 'missing', 'inbox') unless inbox

    label_missing = !account.labels.exists?(title: BOT_LABEL)
    plan = automation_rules.map { |key, attributes| rule_plan(key, attributes) }
    pending = plan.reject { |item| item[:changed]&.empty? }
    return record('automation', 'ok') if !label_missing && pending.empty?

    detail = [('label' if label_missing), *pending.map { |item| item[:key] }].compact.join(',')
    return record('automation', 'mismatch', detail) unless apply?

    ActiveRecord::Base.transaction do
      account.labels.create!(title: BOT_LABEL) if label_missing
      pending.each { |item| item[:rule].update!(item[:desired]) }
    end
    record('automation', 'applied', detail)
  end

  def rule_plan(key, attributes)
    marker = format(MARKER, key)
    desired = attributes.merge('description' => marker, 'active' => true)
    managed = account.automation_rules.where(description: marker).to_a
    raise "Duplicate managed rules: #{key}" if managed.many?

    rule = managed.first
    if rule.nil? && account.automation_rules.exists?(name: desired['name'])
      raise "Unmanaged rule named '#{desired['name']}' exists; delete it or set its description to #{marker}"
    end

    changed = rule && desired.keys.reject { |field| rule.public_send(field) == desired[field] }
    { key: key, rule: rule || account.automation_rules.new, desired: desired, changed: changed }
  end

  def automation_rules
    inbox_condition = { 'attribute_key' => 'inbox_id', 'filter_operator' => 'equal_to', 'values' => [inbox.id.to_s], 'query_operator' => 'AND' }
    pending_condition = { 'attribute_key' => 'status', 'filter_operator' => 'equal_to', 'values' => ['pending'], 'query_operator' => nil }
    add_bot_label = [{ 'action_name' => 'add_label', 'action_params' => [BOT_LABEL] }]
    reply_note = env.fetch('AI_REPLY_NOTE_TEXT', '🤖 Відповідь AI')
    raise 'AI_REPLY_NOTE_TEXT must not be empty' if reply_note.blank?

    {
      'bot-created' => {
        'name' => 'AI: new conversation',
        'event_name' => 'conversation_created',
        'conditions' => [inbox_condition, pending_condition],
        'actions' => add_bot_label
      },
      'bot-returned' => {
        'name' => 'AI: returned to bot',
        'event_name' => 'conversation_updated',
        'conditions' => [inbox_condition, pending_condition],
        'actions' => add_bot_label
      },
      'handoff-notice' => {
        'name' => 'AI: handoff notice',
        'event_name' => 'conversation_updated',
        'conditions' => [
          inbox_condition,
          { 'attribute_key' => 'status', 'filter_operator' => 'equal_to', 'values' => ['open'], 'query_operator' => 'AND' },
          { 'attribute_key' => 'labels', 'filter_operator' => 'equal_to', 'values' => [BOT_LABEL], 'query_operator' => nil }
        ],
        'actions' => [{ 'action_name' => 'remove_label', 'action_params' => [BOT_LABEL] }]
      },
      # Chatwoot cannot filter by sender, so an outgoing public message while the
      # conversation is Pending (owned by the bot) is treated as an AI reply.
      'ai-reply-note' => {
        'name' => 'AI: mark reply',
        'event_name' => 'message_created',
        'conditions' => [
          inbox_condition,
          { 'attribute_key' => 'message_type', 'filter_operator' => 'equal_to', 'values' => ['outgoing'], 'query_operator' => 'AND' },
          { 'attribute_key' => 'private_note', 'filter_operator' => 'equal_to', 'values' => [false], 'query_operator' => 'AND' },
          pending_condition
        ],
        'actions' => [{ 'action_name' => 'add_private_note', 'action_params' => [reply_note] }]
      }
    }
  end

  def ensure_telegram_webhook
    return record('telegram_webhook', 'missing', 'inbox') unless inbox

    channel = inbox.channel
    expected = "#{origin('FRONTEND_URL')}/webhooks/telegram/#{channel.bot_token}"
    current = telegram!(HTTParty.get("#{channel.telegram_api_url}/getWebhookInfo"), 'getWebhookInfo')['url']
    return record('telegram_webhook', 'ok') if current == expected
    return record('telegram_webhook', 'mismatch') unless apply?

    telegram!(HTTParty.post("#{channel.telegram_api_url}/setWebhook", body: { url: expected }), 'setWebhook')
    record('telegram_webhook', 'applied')
  end

  def telegram!(response, action)
    return response.parsed_response['result'] if response.success? && response.parsed_response['ok']

    raise "Telegram #{action} failed with HTTP #{response.code}"
  end

  def verify_ids
    actual = { 'CHATWOOT_ACCOUNT_ID' => account&.id, 'CHATWOOT_INBOX_ID' => inbox&.id, 'CHATWOOT_BOT_ID' => agent_bot&.id }
    wrong = actual.select { |name, id| env[name].present? && env[name].to_i != id }
    return record('ids', 'ok') if wrong.empty?

    record('ids', 'mismatch', wrong.map { |name, id| "#{name} expected #{env[name]} actual #{id.inspect}" }.join(', '))
  end

  def required(name)
    value = env[name]
    raise "#{name} is required" if value.blank?

    value
  end

  def origin(name)
    uri = URI.parse(required(name))
    valid = uri.is_a?(URI::HTTP) && uri.host.present? && uri.userinfo.blank? && uri.path.in?(['', '/']) &&
            uri.query.blank? && uri.fragment.blank?
    raise "#{name} must be an http(s) origin without a path" unless valid

    uri.origin
  rescue URI::InvalidURIError
    raise "#{name} must be an http(s) origin without a path"
  end

  def record(step, status, detail = nil)
    results << Result.new(step, status, detail.presence)
  end
end
