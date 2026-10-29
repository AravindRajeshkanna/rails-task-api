module Notifications
  # Decides what an event means and makes sure each event is acted on once.
  #
  # SNS and SQS deliver at least once, so the same event id can arrive twice. The id is recorded in the
  # same transaction as the handlers' work: if a handler fails the record rolls back and the event is
  # retried; if it succeeds a later duplicate is recognised and dropped.
  class Router
    HANDLERS = {
      "task.assigned" => [ Handlers::TaskAssigned ],
      "task.due_soon" => [ Handlers::TaskDueSoon ],
      "user.password_reset_requested" => [ Handlers::PasswordReset ],
      "task.completed" => [ Handlers::SlackAnnouncement ]
    }.freeze

    # Returns :handled, :duplicate or :ignored (an event type nobody here cares about).
    def dispatch(envelope)
      validate!(envelope)
      handlers = HANDLERS[envelope["type"]]
      return :ignored unless handlers

      ProcessedEvent.transaction do
        ProcessedEvent.create!(event_id: envelope["id"], event_type: envelope["type"])
        handlers.each { |handler| handler.new(envelope).call }
      end
      :handled
    rescue ActiveRecord::RecordNotUnique
      :duplicate
    end

    private
      def validate!(envelope)
        raise InvalidEvent, "not a JSON object" unless envelope.is_a?(Hash)
        raise InvalidEvent, "unsupported specversion #{envelope['specversion'].inspect}" unless envelope["specversion"] == "1.0"

        %w[id type].each { |field| raise InvalidEvent, "missing #{field}" if envelope[field].to_s.empty? }
        raise InvalidEvent, "missing data" unless envelope["data"].is_a?(Hash)
      end
  end
end
