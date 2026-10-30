# Wipes and reloads the public demo's data every night (Demo::Dataset). Does nothing unless DEMO_MODE is on, so it is
# safe to leave in the schedule of every environment.
class ResetDemoJob < ApplicationJob
  queue_as :low

  def perform
    Demo::Dataset.reset! if Rails.configuration.x.demo_mode
  end
end
