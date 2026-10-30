class ApplicationController < ActionController::API
  include Authentication
  include ErrorHandling
  include Pagination
  include Pundit::Authorization
  include DemoMode

  # The API takes flat JSON bodies ({"title": "..."}), not Rails' nested form params.
  wrap_parameters false

  before_action :annotate_request
  before_action :set_cache_headers

  private
    def pundit_user = Current.user

    # Responses are per-user, so they must never sit in a shared cache; `no-cache` still
    # lets a client keep a copy and revalidate it with If-None-Match (Rack::ETag answers 304).
    # Vary tells any cache between us and the client that the token is part of the key.
    # Actions that hand out credentials call `prevent_storage` to forbid even a private copy.
    def set_cache_headers
      response.cache_control.merge!(no_cache: true, extras: %w[private])
      response.headers["Vary"] = "Authorization, Accept"
    end

    def prevent_storage
      response.cache_control.replace(no_store: true, private: true)
    end

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
