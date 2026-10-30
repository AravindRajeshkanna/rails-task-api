# The activity feed (GET /activity) for a set of projects, newest first, in a form a cursor can page through at constant cost.
#
# The obvious query, `WHERE project_id IN (the caller's projects) ORDER BY created_at DESC, id DESC LIMIT 26`, has to read and sort every
# event of every one of those projects before it can answer: 110 ms for the first page of someone in 8 projects holding 1.1 million events, 83 ms
# at any depth, and it grows with the history. This asks each project for its own newest 101 events, in index order
# (index_audit_events_on_project_id_and_created_at), and merges them: no event is read that is not at the head of some project's list, so a page
# costs about one index probe per project (0.25 ms for the same person, at any depth). A page of at most 100 can never need more than 101 from any one project.
#
#   ActivityFeed.new(projects, types: %w[Task], after: [ time, id ]).call   # an AuditEvent relation, ordered
class ActivityFeed
  PER_PROJECT = Pagination::MAX_LIMIT + 1

  # +projects+ is a relation of the projects to read (already scoped to what the caller may see); +after+ is the [created_at, id] of the
  # last event of the previous page, or nil for the first.
  def initialize(projects, types:, after: nil)
    @projects = projects
    @types = types
    @after = after
  end

  def call
    AuditEvent.from("(#{@projects.reselect('projects.id').to_sql}) AS projects CROSS JOIN LATERAL (#{newest_per_project.to_sql}) AS audit_events")
              .order(created_at: :desc, id: :desc)
  end

  private
    def newest_per_project
      events = AuditEvent.where("audit_events.project_id = projects.id").where(auditable_type: @types)
      events = events.where("(audit_events.created_at, audit_events.id) < (?, ?)", *@after) if @after
      events.order(created_at: :desc, id: :desc).limit(PER_PROJECT)
    end
end
