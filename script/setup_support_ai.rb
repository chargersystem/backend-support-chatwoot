# frozen_string_literal: true

# Provisions the Telegram support AI setup (account, first admin, Telegram
# inbox, AgentBot and its binding, label, automation rules, Telegram webhook).
# Safe to run on every deploy after migrations; an unchanged installation is a
# no-op. See deployment/helm/README.md for the variables.
#
#   bundle exec rails runner script/setup_support_ai.rb --check
#   bundle exec rails runner script/setup_support_ai.rb --apply
#
# --check writes nothing and exits 2 when anything differs.

mode = ARGV.last
raise 'Use exactly one of --check or --apply' unless %w[--check --apply].include?(mode)

setup = Chargersystem::SupportAiSetup.new(apply: mode == '--apply')
ok = setup.run
setup.results.each { |result| puts result }

ids = "account #{setup.account&.id.inspect}; inbox #{setup.inbox&.id.inspect}; bot #{setup.agent_bot&.id.inspect}"
if ok
  puts "Support AI setup #{mode == '--apply' ? 'applied' : 'checked'}; #{ids}"
else
  warn "Support AI setup incomplete; #{ids}"
  exit 2
end
