module Api
  module V1
    class OrganizationsController < BaseController
      idempotent :create # a retried POST with the same Idempotency-Key answers the first one's response (Idempotency)
      before_action :set_organization, only: %i[show update destroy]

      # GET /organizations: the ones the caller belongs to.
      def index
        authorize Organization
        records, meta = paginate(policy_scope(Organization).order(:name, :id))
        render_resource OrganizationResource, records, meta: meta
      end

      def show
        authorize @organization
        render_resource OrganizationResource, @organization
      end

      # The caller becomes the first owner.
      def create
        authorize Organization
        organization = Organizations::Create.call(user: current_user, attributes: organization_params)
        render_resource OrganizationResource, policy_scope(Organization).find(organization.id), status: :created
      end

      def update
        authorize @organization
        @organization.update!(organization_params)
        render_resource OrganizationResource, @organization
      end

      # Refused (422) while the organization still has projects.
      def destroy
        authorize @organization
        @organization.destroy!
        head :no_content
      end

      private
        def set_organization
          @organization = policy_scope(Organization).find(params[:id])
        end

        def organization_params
          params.permit(:name)
        end
    end
  end
end
