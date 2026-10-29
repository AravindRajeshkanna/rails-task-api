class User < ApplicationRecord
  has_secure_password

  has_one_attached :avatar

  has_many :sessions, dependent: :destroy
  has_many :memberships, dependent: :destroy
  has_many :projects, through: :memberships
  has_many :owned_projects, class_name: "Project", foreign_key: :owner_id, inverse_of: :owner, dependent: :restrict_with_error
  has_many :assigned_tasks, class_name: "Task", foreign_key: :assignee_id, inverse_of: :assignee, dependent: :nullify
  has_many :comments, dependent: :destroy

  normalizes :email_address, with: ->(email) { email.strip.downcase }
  normalizes :name, with: ->(name) { name.squish }

  validates :name, presence: true, length: { maximum: 100 }
  validates :email_address, presence: true, uniqueness: true, format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :password, length: { minimum: 8 }, allow_nil: true

  validate :avatar_is_a_small_image

  AVATAR_TYPES = %w[image/png image/jpeg image/webp].freeze
  AVATAR_MAX_SIZE = 2.megabytes

  private
    def avatar_is_a_small_image
      return unless avatar.attached?

      errors.add(:avatar, "must be a PNG, JPEG or WebP image") unless avatar.content_type.in?(AVATAR_TYPES)
      errors.add(:avatar, "must be smaller than #{AVATAR_MAX_SIZE / 1.megabyte} MB") if avatar.byte_size > AVATAR_MAX_SIZE
    end
end
