module Events
  # Base class for Rails.event subscribers. A failing subscriber must never fail
  # the request that triggered the event: the database change has already been
  # committed, so errors are reported instead of raised (but raised in tests).
  class Subscriber
    def emit(event)
      handle(event)
    rescue => error
      raise if Rails.env.test?

      Rails.error.report(error, handled: true, context: { subscriber: self.class.name, event: event[:name] })
    end

    private
      def handle(event)
        raise NotImplementedError, "#{self.class} must implement #handle"
      end
  end
end
