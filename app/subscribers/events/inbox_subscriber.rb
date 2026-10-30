module Events
  # Puts the events people should hear about in their in-app inbox (Notification). These are the events the
  # Notification service turns into email and Slack, plus comments; email and the inbox are independent, and
  # the inbox works whichever NOTIFICATIONS_MODE is set, because it is stored here with the data it points at.
  #
  # Who hears: the person themselves is never told about their own action, nobody is told about a
  # project they cannot (any longer) see, and nobody is told about what they muted (NotificationMute).
  class InboxSubscriber < Subscriber
    HANDLED = %w[task.assigned task.due_soon task.completed comment.created].freeze
    EXCERPT = 140

    private
      def handle(event)
        subject = GlobalID::Locator.locate(event.dig(:payload, :subject))
        actor_id = event.dig(:payload, :actor_id)
        task, comment = subject.is_a?(Comment) ? [ subject.task, subject ] : [ subject, nil ]
        return unless task&.kept? && task.project.kept?

        user_ids = recipients(event[:name], task, comment).excluding(actor_id)
        preferences = NotificationPreferences.new(user_ids)
        user_ids.each do |user_id|
          deliver(user_id, event[:name], task, comment, actor_id) if preferences.inbox?(user_id, event[:name], task.project_id)
        end
      rescue ActiveRecord::RecordNotFound
        nil # deleted since the event was emitted
      end

      def recipients(name, task, comment)
        case name
        when "task.assigned", "task.due_soon" then [ task.assignee_id ]
        when "task.completed" then [ task.creator_id ]
        when "comment.created" then [ task.assignee_id, task.creator_id ] - [ comment.user_id ]
        end.compact.uniq
      end

      def deliver(user_id, name, task, comment, actor_id)
        user = User.find_by(id: user_id)
        return unless user && ProjectPolicy.new(user, task.project).show?

        Notification.create!(
          user: user, project: task.project, task: task, actor_id: actor_id, kind: name,
          data: data_for(task, comment), dedupe_key: (name == "task.due_soon" ? "due_soon:#{task.id}:#{task.due_on}" : nil)
        )
      rescue ActiveRecord::RecordNotUnique
        nil # this reminder was already delivered
      end

      def data_for(task, comment)
        { task_title: task.title, project_name: task.project.name, due_on: task.due_on&.iso8601,
          comment_excerpt: comment&.body&.squish&.truncate(EXCERPT) }.compact
      end
  end
end
