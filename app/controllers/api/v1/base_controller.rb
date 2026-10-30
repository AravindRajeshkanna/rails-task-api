module Api
  module V1
    # Every v1 action must authorize (and every index must scope), or the
    # request fails loudly in development and test instead of leaking data.
    class BaseController < ApplicationController
      include ApiVersioning
      include Idempotency
      include SparseFieldsets
      include ReplicaReads

      api_version "v1"

      after_action :verify_authorized

      # What the request is about, for the logs and for fairness between tenants (ADR 62): once a record is authorized, its organization is known, and a
      # write is charged to that organization's budget. Authorization comes first, so a person cannot spend another organization's budget.
      def authorize(record, query = nil, policy_class: nil)
        super.tap do
          organization_id = Tenant.organization_id_for(record)
          Current.organization_id = organization_id if organization_id
          OrganizationBudget.charge!(organization_id) if organization_id && !(request.get? || request.head?)
        end
      end
      # `if:` rather than `only: :index`, so controllers without an index action don't trip
      # Rails' raise_on_missing_callback_actions check.
      after_action :verify_policy_scoped, if: -> { action_name == "index" }
    end
  end
end
