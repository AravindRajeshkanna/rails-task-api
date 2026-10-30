# Opt-in routing of read actions to the read replica (ReplicaRouting, ADR 60):
#
#   replica_reads :index, :show        # the actions whose answer may be a moment behind
#
# The candidates are the heavy reads that tolerate a little staleness: lists, dashboards, search, the audit log. A person who has just written is served
# by the primary, so the app never shows someone a stale version of their own change. Authentication has already happened (on the primary) when this runs,
# so sessions and their usage stamp are never read from, or written to, a replica.
module ReplicaReads
  extend ActiveSupport::Concern

  included do
    # Any write by this person starts their read-your-writes window.
    after_action :note_write_for_replica_routing, unless: -> { request.get? || request.head? }
  end

  class_methods do
    def replica_reads(*actions) = around_action(:read_from_replica, only: actions)
  end

  private
    def read_from_replica(&) = ReplicaRouting.route(request, Current.user&.id, &)

    def note_write_for_replica_routing
      ReplicaRouting.note_write(Current.user.id) if ReplicaRouting.enabled? && Current.user
    end
end
