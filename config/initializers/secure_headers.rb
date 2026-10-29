# Security headers for a JSON API. Nothing here is ever rendered by a browser, so the
# policy is "deny everything": a response that somehow ends up in a tab can't run
# scripts, load subresources, be framed or have its type guessed.
#
# The gem inserts its middleware at the very top of the stack, so these also cover
# answers produced before Rails routes the request (Rack::Attack's 429, Host
# Authorization). Cookies are not used, so the cookie flags are opted out.
#
# HSTS is left to Rails: config.force_ssl (production.rb) already sends it.
# CSP source keywords include their own quotes, which %w[] would mangle.
NONE = [ "'none'" ].freeze
SELF = "'self'".freeze
UNSAFE_INLINE = "'unsafe-inline'".freeze

SecureHeaders::Configuration.default do |config|
  config.cookies = SecureHeaders::OPT_OUT
  config.hsts = SecureHeaders::OPT_OUT

  config.x_frame_options = "DENY"
  config.x_content_type_options = "nosniff"
  config.x_xss_protection = "0" # the legacy XSS auditor created holes; modern guidance is to turn it off
  config.x_permitted_cross_domain_policies = "none"
  config.x_download_options = "noopen"
  config.referrer_policy = "no-referrer"

  # Directives that do not fall back to default-src have to be listed (the gem insists on script_src).
  config.csp = {
    default_src: NONE,
    script_src: NONE,
    object_src: NONE,
    base_uri: NONE,
    form_action: NONE,
    frame_ancestors: NONE
  }
end

# Swagger UI (/api-docs) is the one HTML page. This mirrors the policy rswag-ui sets
# itself, which the gem would otherwise replace with the deny-all one above.
SecureHeaders::Configuration.override(:swagger_ui) do |config|
  config.csp = {
    default_src: [ SELF ],
    img_src: [ SELF, "data:", "https://validator.swagger.io" ],
    font_src: [ SELF, "https://fonts.gstatic.com" ],
    style_src: [ SELF, UNSAFE_INLINE, "https://fonts.googleapis.com" ],
    script_src: [ SELF, UNSAFE_INLINE ],
    base_uri: NONE,
    form_action: NONE,
    frame_ancestors: NONE
  }
end

# Picks the :swagger_ui override for /api-docs. SecureHeaders::Middleware reads the choice
# from the request env after the inner app has run, so this can sit anywhere below it.
class SwaggerUiSecureHeaders
  def initialize(app)
    @app = app
  end

  def call(env)
    request = Rack::Request.new(env)
    SecureHeaders.use_secure_headers_override(request, :swagger_ui) if request.path.start_with?("/api-docs")
    @app.call(env)
  end
end

Rails.application.config.middleware.insert_after SecureHeaders::Middleware, SwaggerUiSecureHeaders
