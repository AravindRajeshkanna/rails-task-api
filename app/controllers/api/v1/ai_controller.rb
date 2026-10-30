module Api
  module V1
    # AI helpers. Every endpoint checks project membership exactly like the rest of the API; the model
    # only ever sees data the caller may read. Calls are rate limited per user and metered against the
    # daily token budget (see Ai::Budget).
    class AiController < BaseController
      idempotent :create_from_text # it creates tasks and spends model budget: a retry must do neither twice
      rate_limit to: Ai.config.requests_per_minute, within: 1.minute, by: -> { current_user.id },
        except: :usage, with: -> { render_error :too_many_requests, "rate_limited", "Too many AI requests. Slow down." }

      # POST /ai/suggest_priority  { task_id } or { project_id, title, description?, due_on? }
      def suggest_priority
        task, project = subject
        suggestion = Ai::SuggestPriority.new(user: current_user, project: project, timezone: timezone).call(
          task: task, title: (params.require(:title) unless task), description: params[:description], due_on: params[:due_on]
        )
        render json: { data: suggestion.to_h.except(:usage), meta: { usage: suggestion.usage.to_h } }
      end

      # POST /ai/suggest_tags  { task_id } or { project_id, title, description? }
      def suggest_tags
        task, project = subject
        suggestion = Ai::SuggestTags.new(user: current_user, project: project, timezone: timezone).call(
          title: task&.title || params.require(:title), description: task ? task.description : params[:description],
          allow_new: params.fetch(:allow_new, true).to_s != "false"
        )
        render json: { data: suggestion.tags, meta: { usage: suggestion.usage.to_h } }
      end

      # POST /ai/suggest_assignee  { task_id } or { project_id, title, description? }
      def suggest_assignee
        task, project = subject
        candidates = Ai::SuggestAssignee.new(user: current_user, project: project).call(
          title: task&.title || params.require(:title), description: task ? task.description : params[:description], task: task
        )
        render json: { data: candidates.map(&:to_h) }
      end

      # POST /ai/create_from_text  { project_id, text, timezone?, dry_run? }
      def create_from_text
        project = policy_scope(Project).kept.find(params.require(:project_id))
        authorize project.tasks.build(creator: current_user), :create?
        dry_run = ActiveModel::Type::Boolean.new.cast(params[:dry_run])

        outcome = Ai::CreateFromText.new(user: current_user, project: project, timezone: timezone).call(params.require(:text), persist: !dry_run)
        meta = { usage: outcome.usage.to_h, interpreted: outcome.proposal }
        if dry_run
          render json: { data: outcome.proposal, meta: meta }
        else
          render_resource TaskResource, outcome.task, status: :created, meta: meta
        end
      end

      # POST /ai/chat  { message, project_id?, history?: [{ role, text }] }
      def chat
        authorize :ai, :chat?
        project = (policy_scope(Project).kept.find(params[:project_id]).tap { |found| authorize found, :show? } if params[:project_id].present?)

        reply = Ai::Chat.new(user: current_user, project: project, timezone: timezone)
          .call(params.require(:message), history: Array(params[:history]).map { |turn| turn.respond_to?(:to_unsafe_h) ? turn.to_unsafe_h : turn })
        render json: { data: { reply: reply.reply, actions: reply.actions }, meta: { usage: reply.usage.to_h } }
      end

      # GET /ai/usage
      def usage
        authorize :ai, :usage?
        render json: { data: Ai::Budget.new(user: current_user).summary }
      end

      private
        # [task or nil, project]: either an existing task (id) or a project plus free text.
        def subject
          if params[:task_id].present?
            task = policy_scope(Task).kept.find(params[:task_id])
            authorize task, :show?
            [ task, task.project ]
          else
            project = policy_scope(Project).kept.find(params.require(:project_id))
            authorize project, :show?
            [ nil, project ]
          end
        end

        def timezone = params[:timezone].presence || "UTC"
    end
  end
end
