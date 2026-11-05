# frozen_string_literal: true

# Creates or updates the Telegram AI bot automation rules directly through the
# models, so no admin API token is needed. Run after the account, the Telegram
# inbox and the AgentBot exist:
#
# docker compose exec -T \
#   -e TELEGRAM_INBOX_ID=1 \
#   rails bundle exec rails runner - -- --check < script/configure_ai_automation.rb
#
# Replace --check with --apply to create the `ai-bot-active` label and create or
# update the managed rules. Rules are matched by the description marker shared
# with the gateway's chatwoot-config.cjs, so rules it created are updated in place.
# Unrelated rules are never touched or deleted.

BOT_LABEL = 'ai-bot-active'

mode = ARGV.last
raise 'Use exactly one of --check or --apply' unless %w[--check --apply].include?(mode)

inbox = Inbox.find(Integer(ENV.fetch('TELEGRAM_INBOX_ID')))
raise "Inbox #{inbox.id} is not a Telegram inbox" unless inbox.channel.is_a?(Channel::Telegram)

account = inbox.account
reply_note = ENV.fetch('AI_REPLY_NOTE_TEXT', '🤖 Відповідь AI')
raise 'AI_REPLY_NOTE_TEXT must not be empty' if reply_note.blank?

inbox_condition = { 'attribute_key' => 'inbox_id', 'filter_operator' => 'equal_to', 'values' => [inbox.id.to_s], 'query_operator' => 'AND' }
pending_condition = { 'attribute_key' => 'status', 'filter_operator' => 'equal_to', 'values' => ['pending'], 'query_operator' => nil }
add_bot_label = [{ 'action_name' => 'add_label', 'action_params' => [BOT_LABEL] }]

rules = {
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

plan = rules.map do |key, attributes|
  marker = "[managed-by:cs-ai-gateway;key:#{key}]"
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

label_exists = account.labels.exists?(title: BOT_LABEL)

if mode == '--check'
  puts "label=#{label_exists ? 'ok' : 'missing'}"
  plan.each do |item|
    status = if item[:changed].nil? then 'missing'
             elsif item[:changed].any? then "mismatch(#{item[:changed].join(',')})"
             else 'ok'
             end
    puts "#{item[:key]}=#{status}"
  end
  exit(label_exists && plan.all? { |item| item[:changed]&.none? } ? 0 : 2)
end

ActiveRecord::Base.transaction do
  account.labels.create!(title: BOT_LABEL) unless label_exists
  plan.each { |item| item[:rule].update!(item[:desired]) }
end

puts 'AI automation configuration applied.'
