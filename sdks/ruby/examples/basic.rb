# frozen_string_literal: true

# Yerel toplayıcıya tek olay gönderir:
#   FERALIN_PROJECT_KEY=pk_... FERALIN_COLLECT_URL=http://127.0.0.1:8081 ruby -Ilib examples/basic.rb
require "feralin"

client = Feralin::Client.new(
  ENV.fetch("FERALIN_PROJECT_KEY"),
  ENV.fetch("FERALIN_COLLECT_URL"),
  consent: Feralin::Consent.new(analytics: true),
  flush_interval: 0
)
client.track("order_completed", { order_id: "ord_1", amount: 249.9 }, user_id: "user_42")
result = client.close
puts "status=#{result.status} accepted=#{result.accepted} batch_id=#{result.batch_id} error=#{result.error&.message}"
exit(result.ok? ? 0 : 1)
