class Project < ApplicationRecord
  include Discardable
  include Auditable
  include EventEmitting

  belongs_to :owner, class_name: "User"

  has_many :memberships, dependent: :destroy
  has_many :members, through: :memberships, source: :user
  has_many :tasks, dependent: :destroy
  has_many :tags, dependent: :destroy
  has_many :webhooks, dependent: :destroy
  has_many :audit_events, dependent: :nullify

  validates :name, presence: true, length: { maximum: 120 }
  validates :description, length: { maximum: 5_000 }

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

  def audit_project_id = id
  def event_project_id = id

  private
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
