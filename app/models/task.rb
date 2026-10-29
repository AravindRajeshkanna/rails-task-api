class Task < ApplicationRecord
  include Discardable
  include Auditable
  include EventEmitting

  ATTACHMENT_TYPES = %w[
    image/png image/jpeg image/webp image/gif application/pdf text/plain text/csv
  ].freeze
  MAX_ATTACHMENTS = 10
  MAX_ATTACHMENT_SIZE = 10.megabytes

  belongs_to :project, touch: true
  belongs_to :creator, class_name: "User"
  belongs_to :assignee, class_name: "User", optional: true

  has_many :comments, dependent: :destroy
  has_many :taggings, dependent: :destroy
  has_many :tags, through: :taggings
  has_many_attached :attachments

  # pgvector column (see Ai::Embedder); powers similar-task search and assignee suggestions.
  has_neighbors :embedding

  enum :status, { todo: 0, in_progress: 1, done: 2 }, default: :todo, validate: true
  enum :priority, { low: 0, medium: 1, high: 2, urgent: 3 }, default: :medium, validate: true

  normalizes :title, with: ->(title) { title.squish }

  validates :title, presence: true, length: { maximum: 200 }
  validates :description, length: { maximum: 10_000 }
  validate :assignee_is_project_member
  validate :attachments_are_acceptable

  before_save :track_completion
  after_create { queue_event("created") }
  after_update :queue_update_events
  after_commit :notify_new_assignee, on: %i[create update]
  after_commit :schedule_embedding, on: %i[create update]

  scope :overdue, -> { where.not(status: :done).where(due_on: ...Date.current) }
  scope :with_tag_names, ->(names) {
    where(id: Tagging.joins(:tag).where(tags: { name: names }).select(:task_id))
  }
  scope :search, ->(term) {
    pattern = "%#{sanitize_sql_like(term)}%"
    where("tasks.title ILIKE :pattern OR tasks.description ILIKE :pattern", pattern: pattern)
  }

  def overdue? = due_on.present? && !done? && due_on < Date.current

  # Assigning names finds-or-builds the project's tags, so clients never deal
  # with tag ids: `{ "tag_names": ["bug", "api"] }`.
  def tag_names=(names)
    self.tags = Array(names).filter_map { |name|
      name = name.to_s.squish.downcase
      project.tags.find_or_initialize_by(name: name) if name.present?
    }.uniq(&:name)
  end

  def audit_project_id = project_id
  def event_project_id = project_id

  private
    def track_completion
      return unless status_changed?

      self.completed_at = done? ? Time.current : nil
    end

    def assignee_is_project_member
      return if assignee_id.blank? || project.blank?

      errors.add(:assignee, "must be a member of the project") unless project.participant?(assignee_id)
    end

    def attachments_are_acceptable
      return unless attachments.attached?

      errors.add(:attachments, "cannot exceed #{MAX_ATTACHMENTS} files") if attachments.size > MAX_ATTACHMENTS
      attachments.each do |attachment|
        errors.add(:attachments, "#{attachment.filename} has an unsupported type") unless attachment.content_type.in?(ATTACHMENT_TYPES)
        if attachment.byte_size > MAX_ATTACHMENT_SIZE
          errors.add(:attachments, "#{attachment.filename} exceeds #{MAX_ATTACHMENT_SIZE / 1.megabyte} MB")
        end
      end
    end

    def notify_new_assignee
      return unless saved_change_to_assignee_id? && assignee_id.present?
      return if assignee_id == Current.user&.id # assigning yourself needs no email

      Rails.event.notify("task.assigned", subject: to_global_id.to_s, project_id: project_id, actor_id: Current.user&.id)
      TaskMailer.assigned(self).deliver_later if Rails.configuration.x.notifications.mode == "local"
    end

    def schedule_embedding
      return unless Ai.embeddings?
      return unless previously_new_record? || saved_change_to_title? || saved_change_to_description?

      EmbedTaskJob.perform_later(self)
    end

    def queue_update_events
      return if saved_changes.except("updated_at", "lock_version").empty?

      if saved_change_to_discarded_at?
        queue_event(discarded_at.present? ? "discarded" : "restored")
      else
        queue_event("updated")
        queue_event("completed") if saved_change_to_status? && done?
      end
    end
end
