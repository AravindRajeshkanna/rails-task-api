# Captures Rails.event notifications emitted inside a block.
module EventHelpers
  class Recorder
    attr_reader :events

    def initialize = @events = []
    def emit(event) = @events << event
    def names = events.map { |event| event[:name] }
    def payloads(name) = events.select { |event| event[:name] == name }.map { |event| event[:payload] }
  end

  def record_events
    recorder = Recorder.new
    Rails.event.subscribe(recorder)
    yield
    recorder
  ensure
    Rails.event.unsubscribe(recorder)
  end
end

RSpec.configure { |config| config.include EventHelpers }
