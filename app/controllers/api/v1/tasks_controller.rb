module Api
  module V1
    class TasksController < BaseController
      replica_reads :index, :show # a moment of staleness is fine here (ReplicaRouting)
      idempotent :create # a retried POST with the same Idempotency-Key answers the first one's response (Idempotency)
      before_action :set_project, only: %i[index create]
      before_action :set_task, only: %i[show update destroy]

      # GET /projects/:project_id/tasks
      def index
        authorize @project, :show?

        query = TaskQuery.new(policy_scope(@project.tasks).kept, params, current_user: current_user)
        query.ensure_keyset_sort! if params.key?(:cursor)
        fields = requested_fields(TaskResource) # ?fields=id,title: only those, and only the associations they need are loaded
        tasks = preload_for(query.call, TaskResource, fields)
        # ?cursor= (even empty) pages by keyset: constant cost at any depth, no total. Otherwise ?page=.
        records, meta = params.key?(:cursor) ? paginate_by_cursor(tasks, params[:cursor]) : paginate(tasks)
        render_resource TaskResource, records, meta: meta, params: { fields: fields }
      end

      def show
        authorize @task
        render_resource TaskResource, @task, params: { fields: requested_fields(TaskResource) }
      end

      def create
        task = @project.tasks.build(creator: current_user)
        authorize task
        # Attributes are assigned after the project is set: tag_names= needs it.
        task.assign_attributes(task_params)
        task.save!
        render_resource TaskResource, task, status: :created
      end

      def update
        authorize @task
        @task.update!(task_params)
        render_resource TaskResource, @task
      end

      def destroy
        authorize @task
        @task.discard
        head :no_content
      end

      # POST /tasks/:id/restore
      def restore
        task = policy_scope(Task).discarded.find(params[:id])
        authorize task
        task.undiscard
        render_resource TaskResource, task
      end

      private
        def set_project
          @project = policy_scope(Project).kept.find(params[:project_id])
        end

        def set_task
          @task = policy_scope(Task).kept.find(params[:id])
        end

        # lock_version enables optimistic locking: a stale value yields 409.
        def task_params
          params.permit(:title, :description, :status, :priority, :due_on, :assignee_id, :lock_version, tag_names: [])
        end
    end
  end
end
