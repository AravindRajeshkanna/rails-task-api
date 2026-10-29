Rswag::Api.configure do |c|
  # Directory holding the generated OpenAPI documents (see `rake rswag:specs:swaggerize`).
  c.openapi_root = Rails.root.join("swagger").to_s
end
