module Api
  module V1
    # File uploads on a task: POST /tasks/:task_id/attachments (multipart, field "files[]").
    class AttachmentsController < BaseController
      before_action :set_task, only: :create

      def create
        authorize @task, :update?

        files = Array(params[:files]).grep(ActionDispatch::Http::UploadedFile)
        raise ActionController::ParameterMissing.new(:files) if files.empty?

        # On a persisted record `attach` validates and saves; nothing is uploaded when it fails.
        @task.attachments.attach(files)
        raise ActiveRecord::RecordInvalid.new(@task) if @task.errors.any?

        render_resource TaskResource, @task, status: :created
      end

      # DELETE /attachments/:id (shallow route). The attachment's task is looked up through the
      # caller's visible tasks, so attachments of other projects are a 404.
      def destroy
        attachment = ActiveStorage::Attachment.where(record_type: "Task", name: "attachments").find(params[:id])
        task = policy_scope(Task).kept.find(attachment.record_id)
        authorize task, :update?

        attachment.purge_later
        head :no_content
      end

      private
        def set_task
          @task = policy_scope(Task).kept.find(params[:task_id])
        end
    end
  end
end
