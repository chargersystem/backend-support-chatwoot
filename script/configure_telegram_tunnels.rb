# frozen_string_literal: true

# Run with Rails so the script can read the encrypted Telegram bot token from
# the configured inbox without printing it:
#
# docker compose exec -T \
#   -e TELEGRAM_INBOX_ID=1 \
#   -e CHATWOOT_AGENT_BOT_ID=1 \
#   -e CHATWOOT_PUBLIC_URL=https://chatwoot.example.trycloudflare.com \
#   -e GATEWAY_PUBLIC_URL=https://gateway.example.trycloudflare.com \
#   rails bundle exec rails runner - -- --check < script/configure_telegram_tunnels.rb
#
# Replace --check with --apply to update the AgentBot callback, the Telegram
# webhook, and the default Telegram Mini App menu button. Update the host .env
# separately, then recreate Rails and Sidekiq before running --check.

require 'json'
require 'uri'

def origin!(name)
  value = ENV.fetch(name)
  uri = URI.parse(value)
  valid = uri.is_a?(URI::HTTPS) && uri.host.present? && uri.userinfo.blank? &&
          uri.path.in?(['', '/']) && uri.query.blank? && uri.fragment.blank?
  raise "#{name} must be an HTTPS origin without a path" unless valid

  uri.origin
rescue URI::InvalidURIError
  raise "#{name} must be an HTTPS origin without a path"
end

def telegram_result!(response, action)
  return response.parsed_response.fetch('result') if response.success? && response.parsed_response['ok']

  raise "Telegram #{action} failed"
end

mode = ARGV.last
raise 'Use exactly one of --check or --apply' unless %w[--check --apply].include?(mode)

inbox_id = Integer(ENV.fetch('TELEGRAM_INBOX_ID'))
agent_bot_id = Integer(ENV.fetch('CHATWOOT_AGENT_BOT_ID'))
chatwoot_public_url = origin!('CHATWOOT_PUBLIC_URL')
gateway_public_url = origin!('GATEWAY_PUBLIC_URL')
button_text = ENV.fetch('TELEGRAM_MINI_APP_BUTTON_TEXT', 'Підключити ChargerSystem')
raise 'TELEGRAM_MINI_APP_BUTTON_TEXT must not be empty' if button_text.blank?

inbox = Inbox.find(inbox_id)
channel = inbox.channel
raise "Inbox #{inbox_id} is not a Telegram inbox" unless channel.is_a?(Channel::Telegram)

agent_bot = inbox.account.agent_bots.find(agent_bot_id)
webhook_url = "#{chatwoot_public_url}/webhooks/telegram/#{channel.bot_token}"
callback_url = "#{gateway_public_url}/webhooks/chatwoot"
mini_app_url = "#{gateway_public_url}/api/telegram/connect"
menu_button = {
  type: 'web_app',
  text: button_text,
  web_app: { url: mini_app_url }
}

webhook_info = telegram_result!(HTTParty.get("#{channel.telegram_api_url}/getWebhookInfo"), 'getWebhookInfo')
button_info = telegram_result!(HTTParty.get("#{channel.telegram_api_url}/getChatMenuButton"), 'getChatMenuButton')
frontend_matches = ENV['FRONTEND_URL'] == chatwoot_public_url
checks = {
  'frontend_url' => frontend_matches,
  'agent_bot_callback' => agent_bot.outgoing_url == callback_url,
  'telegram_webhook' => webhook_info['url'] == webhook_url,
  'mini_app_button' => button_info == menu_button.deep_stringify_keys
}

if mode == '--check'
  checks.each { |name, matches| puts "#{name}=#{matches ? 'ok' : 'mismatch'}" }
  exit(checks.values.all? ? 0 : 2)
end

agent_bot.update!(outgoing_url: callback_url)
telegram_result!(HTTParty.post("#{channel.telegram_api_url}/setWebhook", body: { url: webhook_url }), 'setWebhook')
telegram_result!(
  HTTParty.post("#{channel.telegram_api_url}/setChatMenuButton", body: { menu_button: JSON.generate(menu_button) }),
  'setChatMenuButton'
)

puts 'Tunnel configuration applied.'
