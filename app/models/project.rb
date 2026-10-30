class Project < ApplicationRecord
  include Discardable
  include Auditable
  include EventEmitting

  belongs_to :owner, class_name: "User"
  # Optional: a personal project has none. Set when the project is created and never changed, so a
  # project cannot leave (or enter) a tenant with its members and data.
  belongs_to :organization, optional: true

  has_many :memberships, dependent: :destroy
  has_many :members, through: :memberships, source: :user
  has_many :project_teams, dependent: :destroy
  has_many :tasks, dependent: :destroy
  has_many :tags, dependent: :destroy
  has_many :webhooks, dependent: :destroy
  has_many :audit_events, dependent: :nullify
  has_many :ai_usages, dependent: :nullify

  validates :name, presence: true, length: { maximum: 120 }
  validates :description, length: { maximum: 5_000 }
  validate :organization_is_fixed, on: :update

  after_create :add_owner_as_admin
  after_create { queue_event("created") }
  after_update :queue_update_event

  # Task counts by status, cached in Solid Cache. Tasks `touch` their project,
  # which changes the cache key, so no explicit expiry is needed.
  def stats
    Rails.cache.fetch([ cache_key_with_version, "stats" ]) do
      counts = tasks.kept.group(:status).count
      Task.statuses.keys.index_with { |status| counts.fetch(status, 0) }.merge(
        "overdue" => tasks.kept.overdue.count
      )
    end
  end

  # Everyone who can be given work here: direct members and the members of teams with access (and of their sub-teams).
  def participants
    User.where(id: memberships.select(:user_id))
        .or(User.where(id: TeamMembership.where(team_id: Team.with_sub_teams(project_teams.select(:team_id)).select(:id)).select(:user_id)))
  end

  def participant?(user_id) = participants.exists?(id: user_id)

  def audit_project_id = id
  def event_project_id = id

  private
    def organization_is_fixed
      errors.add(:organization_id, "cannot be changed once the project exists") if organization_id_changed?
    end

    def add_owner_as_admin
      memberships.create!(user: owner, role: :admin)
    end

    def queue_update_event
      return if saved_changes.except("updated_at").empty?

      if saved_change_to_discarded_at?
        queue_event(discarded_at.present? ? "discarded" : "restored")
      else
        queue_event("updated")
      end
    end
end
