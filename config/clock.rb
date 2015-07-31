# https://github.com/tomykaira/clockwork

ENV['NEW_RELIC_DISPATCHER'] ||= 'clockwork'

require 'newrelic_rpm'
require 'clockwork'
require_relative '../lib/server_env'

puts "Clockwork loaded."

if ServerEnv.instance_index == 0
  require_relative 'boot'
  require_relative 'environment'

  puts NewRelic::Agent.config[:dispatcher]

  module Clockwork
    # TODO feature-flag this (more important when we have multiple tasks that we want run in all environments)
    # TODO do at a certain time
    every(30.seconds, 'report_mailer.budget', thread: true) do
      puts "SENDING TEST REPORT..."
      ReportMailer.budget_status.deliver_now
      puts "...DONE"
    end
  end
end
