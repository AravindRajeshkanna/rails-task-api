module Api
  module V1
    class CommentsController < BaseController
      before_action :set_task, only: %i[index create]
      before_action :set_comment, only: %i[update destroy]

      def index
        authorize @task, :show?
        comments = policy_scope(@task.comments).includes(:user).order(:created_at, :id)
        records, meta = paginate(comments)
        render_resource CommentResource, records, meta: meta
      end

      def create
        comment = @task.comments.build(user: current_user)
        authorize comment
        comment.update!(comment_params)
        render_resource CommentResource, comment, status: :created
      end

      def update
        authorize @comment
        @comment.update!(comment_params)
        render_resource CommentResource, @comment
      end

      def destroy
        authorize @comment
        @comment.destroy!
        head :no_content
      end

      private
        def set_task
          @task = policy_scope(Task).kept.find(params[:task_id])
        end

        def set_comment
          @comment = policy_scope(Comment).find(params[:id])
        end

        def comment_params
          params.permit(:body)
        end
    end
  end
end
