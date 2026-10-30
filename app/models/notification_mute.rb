# Silences notifications for one person: a kind everywhere (project nil), a project entirely (kind nil), or one kind in one project.
# A muted notification is not written to the inbox, is not emailed, and so is not in the digest either.
class NotificationMute < ApplicationRecord
  belongs_to :user
  belongs_to :project, optional: true

  validates :kind, inclusion: { in: Notification::KINDS }, allow_nil: true
  validates :kind, uniqueness: { scope: %i[user_id project_id], message: "is already muted" }
  validate :mutes_something

  def covers?(kind, project_id)
    (self.kind.nil? || self.kind == kind) && (self.project_id.nil? || self.project_id == project_id)
  end

  private
    def mutes_something
      errors.add(:base, "give a kind, a project, or both") if kind.nil? && project_id.nil?
    end
end
