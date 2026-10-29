module Events
  # One greppable key=value line per domain event.
  #   event=task.completed subject=gid://task-api/Task/7 project_id=3 actor_id=5
  class LogSubscriber < Subscriber
    private
      def handle(event)
        fields = event[:payload].map { |key, value| "#{key}=#{value}" }.join(" ")
        Rails.logger.info("event=#{event[:name]} #{fields}")
      end
  end
end
