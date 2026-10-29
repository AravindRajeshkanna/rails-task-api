class ApplicationController < ActionController::API
  include Authentication
  include ErrorHandling
  include Pagination
  include Pundit::Authorization

  # The API takes flat JSON bodies ({"title": "..."}), not Rails' nested form params.
  wrap_parameters false

  private
    def pundit_user = Current.user

    # Serializes with Alba inside a {"data": ..., "meta": ...} envelope.
    def render_resource(resource_class, object, status: :ok, meta: nil, params: {})
      resource = resource_class.new(object, params: { base_url: request.base_url }.merge(params))
      render json: resource.serialize(**{ root_key: :data, meta: meta }.compact), status: status
    end
end
