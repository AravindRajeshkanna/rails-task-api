module Events
  # Wraps a domain event in a CloudEvents 1.0 envelope (structured JSON), the contract other services
  # consume. See docs/architecture/service-contracts.md.
  #
  #   { "specversion": "1.0", "id": "...", "source": "task-api", "type": "task.assigned",
  #     "time": "...", "subject": "gid://task-api/Task/7", "projectid": 3, "data": { ... } }
  module CloudEvent
    SOURCE = "task-api"
    ENRICHED = %w[task.assigned task.due_soon].freeze

    module_function

    # +event+ is the hash a Rails.event subscriber receives. nil when the subject no longer exists.
    def build(event, id: SecureRandom.uuid)
      subject = locate(event.dig(:payload, :subject))
      return unless subject

      {
        specversion: "1.0",
        id: id,
        source: SOURCE,
        type: event[:name],
        time: Time.at(0, event[:timestamp], :nsec).utc.iso8601(3),
        datacontenttype: "application/json",
        subject: event.dig(:payload, :subject),
        projectid: event.dig(:payload, :project_id),
        data: ENRICHED.include?(event[:name]) ? enriched(subject, event) : EventPayload.build(event).fetch(:data)
      }.compact
    end

    def locate(global_id)
      GlobalID::Locator.locate(global_id)
    rescue ActiveRecord::RecordNotFound
      nil # deleted since the event was emitted
    end

    # Notification events carry everything a consumer needs to act (who, what, where to link), so the
    # Notification service never has to call back into this one.
    def enriched(task, event)
      assignee = task.assignee
      actor = User.find_by(id: event.dig(:payload, :actor_id))
      {
        task: TaskResource.new(task).serializable_hash,
        project: { id: task.project_id, name: task.project.name },
        recipient: { id: assignee.id, name: assignee.name, email_address: assignee.email_address,
                     email_enabled: NotificationPreferences.new(assignee.id).email?(assignee.id, event[:name], task.project_id) },
        actor: (actor && { id: actor.id, name: actor.name }),
        url: "#{Rails.configuration.x.frontend_url}/projects/#{task.project_id}/tasks/#{task.id}"
      }
    end
  end
end
