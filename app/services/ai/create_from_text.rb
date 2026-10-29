module Ai
  # "Remind me to review the PR next Tuesday" -> a task. The caller authorizes creation first; this
  # class only turns text into attributes (validated by ai_core) and, unless it is a dry run, saves.
  class CreateFromText
    Outcome = Struct.new(:task, :proposal, :usage, keyword_init: true)

    def initialize(user:, project:, timezone: "UTC")
      @user = user
      @project = project
      @timezone = timezone
    end

    def call(text, persist: true)
      result = Runner.new(user: @user, project: @project).run("parse_task", input_for(text))
      proposal = result.output

      task = @project.tasks.build(creator: @user)
      task.assign_attributes(proposal.slice(:title, :description, :due_on, :priority, :assignee_id).compact)
      task.tag_names = proposal[:tag_names] if proposal[:tag_names].present?
      task.save! if persist

      Outcome.new(task: task, proposal: proposal, usage: result.usage)
    end

    private
      def input_for(text)
        {
          text: Context.clip(text, 1_000),
          today: Context.today(@timezone).iso8601,
          timezone: Context.zone(@timezone).tzinfo.name,
          members: Context.members(@project),
          tags: Context.tag_names(@project)
        }
      end
  end
end
