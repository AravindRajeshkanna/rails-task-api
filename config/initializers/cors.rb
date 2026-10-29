# Browsers may only call this API from the origins listed in CORS_ORIGINS
# (comma-separated). Nothing is allowed by default in production.
allowed_origins = ENV.fetch("CORS_ORIGINS") {
  Rails.env.production? ? "" : "http://localhost:5173,http://localhost:3001"
}.split(",").map(&:strip).compact_blank

if allowed_origins.any?
  Rails.application.config.middleware.insert_before 0, Rack::Cors do
    allow do
      origins(*allowed_origins)

      resource "/api/*",
        headers: :any,
        methods: %i[get post put patch delete options head],
        expose: %w[Link Current-Page Page-Limit Total-Count Total-Pages Retry-After X-Request-Id],
        max_age: 600
    end
  end
end
