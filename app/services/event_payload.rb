# Builds the JSON body shared by webhooks and Action Cable broadcasts:
#
#   { "event": "task.updated", "occurred_at": "2026-10-29T10:00:00.000Z", "data": { ...resource... } }
class EventPayload
  RESOURCES = {
    "Task" => TaskResource,
    "Project" => ProjectResource,
    "Comment" => CommentResource
  }.freeze

  # +event+ is the hash a Rails.event subscriber receives. Returns nil when the
  # subject has been deleted since the event was emitted.
  def self.build(event)
    subject = GlobalID::Locator.locate(event.dig(:payload, :subject))
    return unless subject

    {
      event: event[:name],
      occurred_at: Time.at(0, event[:timestamp], :nsec).utc.iso8601(3),
      data: RESOURCES.fetch(subject.class.name).new(subject).serializable_hash
    }
  end
end
