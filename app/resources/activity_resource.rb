# An audit event as an item of the activity feed: the same facts, plus the project it happened in,
# because the feed spans projects.
class ActivityResource < AuditEventResource
  attributes :project_id
end
