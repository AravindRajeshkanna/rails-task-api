class User < ApplicationRecord
  # With AUTH_MODE=jwt the Auth service owns credentials and a local user has no password; see
  # User.provision_from_claims!. The password rules below still apply to every locally set password.
  has_secure_password validations: false

  has_one_attached :avatar

  has_many :sessions, dependent: :destroy
  has_many :memberships, dependent: :destroy
  has_many :organization_memberships, dependent: :destroy
  has_many :organizations, through: :organization_memberships
  has_many :team_memberships, dependent: :destroy
  has_many :teams, through: :team_memberships
  has_many :projects, through: :memberships
  has_many :owned_projects, class_name: "Project", foreign_key: :owner_id, inverse_of: :owner, dependent: :restrict_with_error
  has_many :assigned_tasks, class_name: "Task", foreign_key: :assignee_id, inverse_of: :assignee, dependent: :nullify
  has_many :comments, dependent: :destroy
  has_one :notification_setting, dependent: :delete # the foreign keys cascade too; this keeps the association honest
  has_many :notification_mutes, dependent: :delete_all
  has_many :ai_usages, dependent: :nullify

  # The address is what people sign in with, so it must be findable: deterministic encryption (the same address, the same ciphertext), under a key that
  # KMS protects. Names are not encrypted: they are shown in every list and a ciphertext cannot be sorted or searched. See docs/data-protection.md.
  encrypts_with_kms :email_address, deterministic: true

  normalizes :email_address, with: ->(email) { email.strip.downcase }
  normalizes :name, with: ->(name) { name.squish }

  validates :name, presence: true, length: { maximum: 100 }
  validates :email_address, presence: true, uniqueness: true, format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :password, length: { minimum: 8, maximum: 72 }, allow_nil: true
  validates :password, confirmation: true, allow_blank: true
  validate :password_present_unless_externally_authenticated

  validate :avatar_is_a_small_image

  AVATAR_TYPES = %w[image/png image/jpeg image/webp].freeze
  AVATAR_MAX_SIZE = 2.megabytes

  # The local record for an identity the Auth service has vouched for (claims of a verified JWT).
  #
  #   1. A user already linked to this subject.
  #   2. A pre-migration user, linked once via the legacy_id claim that the Auth service's import task sets.
  #      Never matched by email: an unverified email must not be able to claim an existing account.
  #   3. A new user.
  #
  # Name and email follow the Auth service. An email already used by an unlinked local user raises
  # ActiveRecord::RecordInvalid, which the caller reports as an account conflict.
  def self.provision_from_claims!(claims)
    subject = claims.fetch("sub")
    user = find_by(auth_subject: subject) || link_legacy_user(subject, claims["legacy_id"]) || new(auth_subject: subject)
    user.assign_attributes(name: claims["name"].presence || user.name || claims["email"], email_address: claims["email"])
    user.save! if user.changed?
    user
  rescue ActiveRecord::RecordNotUnique
    find_by!(auth_subject: subject) # a concurrent first request created it
  end

  def self.link_legacy_user(subject, legacy_id)
    return if legacy_id.blank?

    where(id: legacy_id, auth_subject: nil).first&.tap { |user| user.update_columns(auth_subject: subject) } # rubocop:disable Rails/SkipsModelValidations -- a link, not an edit
  end

  def externally_authenticated? = auth_subject.present?

  def erased? = erased_at.present?

  private
    def password_present_unless_externally_authenticated
      errors.add(:password, :blank) unless password_digest.present? || externally_authenticated?
    end

    def avatar_is_a_small_image
      return unless avatar.attached?

      errors.add(:avatar, "must be a PNG, JPEG or WebP image") unless avatar.content_type.in?(AVATAR_TYPES)
      errors.add(:avatar, "must be smaller than #{AVATAR_MAX_SIZE / 1.megabyte} MB") if avatar.byte_size > AVATAR_MAX_SIZE
    end
end
