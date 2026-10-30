# An offer to join an organization, addressed to an email address rather than to a user, so it
# works the same whether or not the address is registered (nothing in the API reveals which).
#
# Redeeming needs two things: the token mailed to the address, and being signed in as that
# address. The token is signed and expires with the invitation; it changes meaning (becomes
# invalid) the moment the invitation is accepted or revoked. Nothing secret is stored.
class OrganizationInvitation < ApplicationRecord
  include Auditable

  VALID_FOR = 7.days

  belongs_to :organization
  belongs_to :invited_by, class_name: "User", optional: true

  enum :role, { member: "member", admin: "admin", owner: "owner" }, default: :member, validate: true

  normalizes :email_address, with: ->(email) { email.strip.downcase }

  validates :email_address, presence: true, length: { maximum: 254 }, format: { with: URI::MailTo::EMAIL_REGEXP }
  validate :not_already_a_member, on: :create

  scope :outstanding, -> { where(accepted_at: nil, revoked_at: nil) }
  scope :pending, -> { outstanding.where("expires_at > ?", Time.current) }

  generates_token_for(:acceptance, expires_in: VALID_FOR) { [ accepted_at.present?, revoked_at.present? ] }

  def pending? = accepted_at.nil? && revoked_at.nil? && expires_at.future?

  def status
    if accepted_at then "accepted"
    elsif revoked_at then "revoked"
    elsif expires_at.past? then "expired"
    else "pending"
    end
  end

  def revoke! = update!(revoked_at: Time.current)

  def audit_organization_id = organization_id

  private
    def audit_action_for_update
      if saved_change_to_accepted_at? then "accept"
      elsif saved_change_to_revoked_at? then "revoke"
      else "update"
      end
    end

    def not_already_a_member
      return unless organization && email_address.present?

      errors.add(:email_address, "already belongs to a member of this organization") if organization.members.exists?(email_address: email_address)
    end
end
