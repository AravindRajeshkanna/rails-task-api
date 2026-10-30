# Writes an AuditEvent for every create/update/discard/restore, in the same
# transaction as the change, attributed to Current.user.
#
# Models include this and implement +audit_project_id+ (events listed per project) and/or
# +audit_organization_id+ (events listed per organization); both default to nil.
#
# Deletions are not recorded unless the model asks with +audit_destruction+, and then only a
# deliberate delete: records destroyed along with their parent (a cascade) leave nothing behind,
# because the parent's own trail is going away with it.
module Auditable
  extend ActiveSupport::Concern

  IGNORED_ATTRIBUTES = %w[created_at updated_at lock_version comments_count].freeze

  included do
    # No `dependent:`: the trail deliberately outlives the record it describes.
    has_many :audit_trail, as: :auditable, class_name: "AuditEvent", inverse_of: :auditable # rubocop:disable Rails/HasManyOrHasOneDependent

    after_create { record_audit("create") }
    after_update { record_audit(audit_action_for_update) }
  end

  class_methods do
    # Records a "destroy" event whose changes are every attribute going from its value to nil.
    def audit_destruction
      after_destroy do
        record_audit("destroy", changes: attributes.transform_values { |value| [ value, nil ] }) unless destroyed_by_association
      end
    end
  end

  def audit_project_id = nil
  def audit_organization_id = nil

  private
    def audit_action_for_update
      if respond_to?(:saved_change_to_discarded_at?) && saved_change_to_discarded_at?
        discarded_at.present? ? "discard" : "restore"
      else
        "update"
      end
    end

    def record_audit(action, changes: saved_changes)
      changes = changes.except(*IGNORED_ATTRIBUTES)
      return if changes.empty?

      AuditEvent.create!(
        project_id: audit_project_id,
        organization_id: audit_organization_id,
        actor_id: Current.user&.id,
        auditable: self,
        action: action,
        audit_changes: changes
      )
    end
end
