module Events
  # One log line per event. In JSON mode the event is a structured entry (its payload and context become
  # top-level fields, e.g. {"event":"task.completed","subject":"gid://...","request_id":"..."}); otherwise
  # a greppable key=value line:
  #   event=task.completed subject=gid://task-api/Task/7 project_id=3 actor_id=5
  class LogSubscriber < Subscriber
    LOGGED = /\A(task|project|comment|membership|webhook|ai|read_only)\.|\Aaction_controller\.(request_completed|rescue_from_handled)\z|\Aactive_job\.(completed|failed|discarded|retry_stopped)\z/

    private
      def handle(event)
        fields = event[:payload].merge(event[:context] || {})

        if Rails.configuration.x.json_logs
          Rails.logger.info({ event: event[:name] }.merge(fields))
        else
          Rails.logger.info("event=#{event[:name]} #{fields.map { |key, value| "#{key}=#{value}" }.join(" ")}")
        end
      end
  end
end
