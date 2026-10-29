class ApplicationController < ActionController::API
  include Authentication
  include ErrorHandling
  include Pagination
  include Pundit::Authorization

  # The API takes flat JSON bodies ({"title": "..."}), not Rails' nested form params.
  wrap_parameters false

  before_action :annotate_request

  private
    def pundit_user = Current.user

    # Ties this request's events (and its trace) to the signed-in user: IDs only, never names or emails.
    def annotate_request
      user_id = Current.user&.id
      Rails.event.set_context(user_id: user_id) if user_id
      Observability::Tracing.annotate_request(user_id: user_id)
    end

    # Serializes with Alba inside a {"data": ..., "meta": ...} envelope.
    def render_resource(resource_class, object, status: :ok, meta: nil, params: {})
      resource = resource_class.new(object, params: { base_url: request.base_url }.merge(params))
      render json: resource.serialize(**{ root_key: :data, meta: meta }.compact), status: status
    end
end
