module Api
  module V1
    class MembershipsController < BaseController
      before_action :set_project, only: %i[index create]
      before_action :set_membership, only: %i[update destroy]

      def index
        authorize @project, :show?
        memberships = policy_scope(@project.memberships).includes(:user).order(:created_at, :id)
        records, meta = paginate(memberships)
        render_resource MembershipResource, records, meta: meta
      end

      # Adds an existing user to the project by email address.
      def create
        membership = @project.memberships.build(role: params[:role] || "member")
        authorize membership
        membership.user = User.find_by!(email_address: params[:email_address].to_s.strip.downcase)
        membership.save!
        render_resource MembershipResource, membership, status: :created
      end

      def update
        authorize @membership
        @membership.update!(role: params.require(:role))
        render_resource MembershipResource, @membership
      end

      def destroy
        authorize @membership
        @membership.destroy!
        head :no_content
      rescue ActiveRecord::RecordNotDestroyed
        raise ActiveRecord::RecordInvalid.new(@membership)
      end

      private
        def set_project
          @project = policy_scope(Project).kept.find(params[:project_id])
        end

        def set_membership
          @membership = policy_scope(Membership).find(params[:id])
        end
    end
  end
end
