module Events
  # Pushes events to clients subscribed to ProjectChannel.
  class BroadcastSubscriber < Subscriber
    private
      def handle(event)
        project_id = event.dig(:payload, :project_id)
        body = EventPayload.build(event)
        return unless project_id && body

        ActionCable.server.broadcast(ProjectChannel.stream_name(project_id), body)
      end
  end
end
