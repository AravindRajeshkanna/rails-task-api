module Api
  module V1
    class MembershipsController < BaseController
      rate_limit to: 60, within: 1.hour, only: :create, by: -> { current_user.id },
                 with: -> { render_error :too_many_requests, "rate_limited", "Too many requests. Try again later." }

      before_action :set_project, only: %i[index create]
      before_action :set_membership, only: %i[update destroy]

      def index
        authorize @project, :show?
        memberships = policy_scope(@project.memberships).includes(:user).order(:created_at, :id)
        records, meta = paginate(memberships)
        render_resource MembershipResource, records, meta: meta
      end

      # Adds an existing user to the project by email address. In an organization's project the person
      # must already be in the organization, and an unknown address gets the same answer as a user who
      # is not (so this cannot be used to find out who is registered); to bring someone new in, invite
      # them to the organization. A project without an organization still answers 404 for an unknown address.
      def create
        membership = @project.memberships.build(role: params[:role] || "member")
        authorize membership
        membership.user = User.find_by(email_address: params[:email_address].to_s.strip.downcase)
        if membership.user.nil?
          raise ActiveRecord::RecordNotFound unless @project.organization_id

          membership.errors.add(:user, Membership::NOT_IN_ORGANIZATION)
          raise ActiveRecord::RecordInvalid, membership
        end
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
