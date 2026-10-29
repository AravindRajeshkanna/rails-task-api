module Ai
  class Chat
    # What the chatbot may do, and nothing else. Every tool runs as the signed-in user through Pundit,
    # so the model can never reach beyond what that person could do in the API. There is deliberately
    # no delete tool. Task text is attacker-controlled, so tools return data and never instructions.
    class Tools
      class ToolError < StandardError; end

      SPECS = [
        {
          name: "list_projects", description: "List the projects the user belongs to, with open task counts.",
          input_schema: { type: "object", properties: {} }
        },
        {
          name: "list_tasks",
          description: "Search the user's tasks. All filters are optional; returns at most 20.",
          input_schema: {
            type: "object",
            properties: {
              project_id: { type: "integer" }, status: { type: "string", enum: %w[todo in_progress done] },
              priority: { type: "string", enum: %w[low medium high urgent] }, overdue: { type: "boolean" },
              assigned_to_me: { type: "boolean" }, query: { type: "string", description: "Text in the title or description" }
            }
          }
        },
        {
          name: "create_task", description: "Create a task in a project.",
          input_schema: {
            type: "object",
            properties: {
              project_id: { type: "integer" }, title: { type: "string" }, description: { type: "string" },
              due_on: { type: "string", description: "YYYY-MM-DD" }, priority: { type: "string", enum: %w[low medium high urgent] },
              tag_names: { type: "array", items: { type: "string" } }
            },
            required: [ "title" ]
          }
        },
        {
          name: "update_task_status", description: "Move a task to todo, in_progress or done.",
          input_schema: {
            type: "object",
            properties: { task_id: { type: "integer" }, status: { type: "string", enum: %w[todo in_progress done] } },
            required: %w[task_id status]
          }
        },
        {
          name: "project_stats", description: "Task counts by status, and how many are overdue, for one project.",
          input_schema: { type: "object", properties: { project_id: { type: "integer" } }, required: [ "project_id" ] }
        }
      ].freeze
      MUTATING = %w[create_task update_task_status].freeze

      def initialize(user:, default_project: nil)
        @user = user
        @default_project = default_project
      end

      def specs = SPECS
      def mutating?(name) = MUTATING.include?(name)

      # Returns a JSON-able value, or raises ToolError with a message the model may relay.
      def call(name, input)
        raise ToolError, "unknown tool #{name}" unless SPECS.any? { |spec| spec[:name] == name }

        send(name, input.to_h.with_indifferent_access)
      rescue Pundit::NotAuthorizedError
        raise ToolError, "you are not allowed to do that"
      rescue ActiveRecord::RecordNotFound
        raise ToolError, "not found"
      rescue ActiveRecord::RecordInvalid => error
        raise ToolError, error.record.errors.full_messages.to_sentence
      end

      private
        def list_projects(_input)
          projects = Pundit.policy_scope!(@user, Project).kept.order(:name).limit(50).to_a
          open = Task.kept.where(project_id: projects.map(&:id)).where.not(status: :done).group(:project_id).count
          projects.map { |project| { id: project.id, name: project.name, role: project.current_role, open_tasks: open.fetch(project.id, 0) } }
        end

        def list_tasks(input)
          scope = Pundit.policy_scope!(@user, Task).kept
          scope = scope.where(project_id: input[:project_id] || @default_project&.id) if input[:project_id] || @default_project
          scope = scope.where(status: input[:status]) if input[:status].present? && Task.statuses.key?(input[:status])
          scope = scope.where(priority: input[:priority]) if input[:priority].present? && Task.priorities.key?(input[:priority])
          scope = scope.overdue if input[:overdue]
          scope = scope.where(assignee_id: @user.id) if input[:assigned_to_me]
          scope = scope.search(input[:query].to_s.truncate(100)) if input[:query].present?

          scope.includes(:assignee).order(Arel.sql("tasks.due_on ASC NULLS LAST"), :id).limit(20).map { |task|
            { id: task.id, project_id: task.project_id, title: task.title, status: task.status, priority: task.priority,
              due_on: task.due_on&.iso8601, assignee: task.assignee&.name }
          }
        end

        def create_task(input)
          project = find_project(input[:project_id])
          task = project.tasks.build(creator: @user)
          Pundit.authorize(@user, task, :create?)
          task.assign_attributes(input.slice(:title, :description, :due_on).compact_blank)
          task.priority = input[:priority] if Task.priorities.key?(input[:priority])
          task.tag_names = input[:tag_names] if input[:tag_names].present?
          task.save!
          { id: task.id, project_id: task.project_id, title: task.title, due_on: task.due_on&.iso8601 }
        end

        def update_task_status(input)
          raise ToolError, "status must be one of #{Task.statuses.keys.join(', ')}" unless Task.statuses.key?(input[:status])

          task = Pundit.policy_scope!(@user, Task).kept.find(input[:task_id])
          Pundit.authorize(@user, task, :update?)
          task.update!(status: input[:status])
          { id: task.id, title: task.title, status: task.status }
        end

        def project_stats(input)
          project = find_project(input[:project_id])
          Pundit.authorize(@user, project, :show?)
          project.stats
        end

        def find_project(id)
          id ||= @default_project&.id
          raise ToolError, "project_id is required" unless id

          Pundit.policy_scope!(@user, Project).kept.find(id)
        end
    end
  end
end
