# Writes an AuditEvent for every create/update/discard/restore, in the same
# transaction as the change, attributed to Current.user.
#
# Models include this and implement +audit_project_id+ so events can be listed per project.
module Auditable
  extend ActiveSupport::Concern

  IGNORED_ATTRIBUTES = %w[created_at updated_at lock_version comments_count].freeze

  included do
    # No `dependent:`: the trail deliberately outlives the record it describes.
    has_many :audit_trail, as: :auditable, class_name: "AuditEvent", inverse_of: :auditable # rubocop:disable Rails/HasManyOrHasOneDependent

    after_create { record_audit("create") }
    after_update { record_audit(audit_action_for_update) }
  end

  private
    def audit_action_for_update
      if respond_to?(:saved_change_to_discarded_at?) && saved_change_to_discarded_at?
        discarded_at.present? ? "discard" : "restore"
      else
        "update"
      end
    end

    def record_audit(action)
      changes = saved_changes.except(*IGNORED_ATTRIBUTES)
      return if changes.empty?

      AuditEvent.create!(
        project_id: audit_project_id,
        actor_id: Current.user&.id,
        auditable: self,
        action: action,
        audit_changes: changes
      )
    end
end
