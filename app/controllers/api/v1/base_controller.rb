module Api
  module V1
    # Every v1 action must authorize (and every index must scope), or the
    # request fails loudly in development and test instead of leaking data.
    class BaseController < ApplicationController
      include ApiVersioning
      include Idempotency
      include SparseFieldsets

      api_version "v1"

      after_action :verify_authorized
      # `if:` rather than `only: :index`, so controllers without an index action don't trip
      # Rails' raise_on_missing_callback_actions check.
      after_action :verify_policy_scoped, if: -> { action_name == "index" }
    end
  end
end
