class WebhookPolicy < ApplicationPolicy
  class Scope < Scope
    def resolve
      scope.where(project_id: member_project_ids(role: "admin"))
    end
  end

  def index? = admin_of?(record.project)
  def show? = admin_of?(record.project)
  def create? = admin_of?(record.project)
  def update? = admin_of?(record.project)
  def destroy? = admin_of?(record.project)

  # Replacing the signing secret (ADR 78) is what an admin does about a leaked one: the same people who may change the webhook.
  def rotate_secret? = update?
  def promote_secret? = update?
  def cancel_rotation? = update?
end
