# Rails request logging uses filtered_path; query/parameter filtering alone does
# not redact Telegram's bot token embedded in the URL path. Routing keeps path unchanged.
module FilterTelegramWebhookPath
  def filtered_path
    super.sub(%r{(/webhooks/telegram/)[^/?]+}, '\1[FILTERED]')
  end
end

ActionDispatch::Request.prepend(FilterTelegramWebhookPath)
