require "rails_helper"

RSpec.describe "API documentation" do
  it "serves the generated OpenAPI document" do
    get "/api-docs/v1/swagger.yaml"

    expect(response).to have_http_status(:ok)
    document = YAML.safe_load(response.body, permitted_classes: [ Symbol ])
    expect(document).to include("openapi" => "3.0.3")
    expect(document.dig("info", "title")).to eq("Task API")
    expect(document["paths"]).to have_key("/api/v1/projects/{project_id}/tasks")
    expect(document.dig("components", "securitySchemes", "bearer_auth", "scheme")).to eq("bearer")
  end

  it "serves Swagger UI" do
    get "/api-docs/index.html"

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("swagger-ui")
  end

  # The document is generated (bin/rails rswag:specs:swaggerize) and committed. This fails when a
  # route is added or changed without documenting it, so the docs cannot silently drift.
  it "documents every public API route" do
    document = YAML.safe_load_file(Rails.root.join("swagger/v1/swagger.yaml"), permitted_classes: [ Symbol ])

    # Rails routes update actions for both PUT and PATCH; either one documents the pair.
    normalize = ->(verb) { verb.upcase == "PUT" ? "PATCH" : verb.upcase }

    documented = document["paths"].flat_map { |path, operations|
      operations.keys.grep(/\A(get|post|put|patch|delete)\z/).map { |verb| "#{normalize.(verb)} #{path}" }
    }.uniq

    actual = Rails.application.routes.routes.filter_map { |route|
      path = route.path.spec.to_s.sub("(.:format)", "")
      "#{normalize.(route.verb)} #{path.gsub(/:(\w+)/, '{\1}')}" if path.start_with?("/api/v1")
    }.uniq

    expect(actual - documented).to be_empty, "undocumented routes: #{(actual - documented).join(', ')}"
    expect(documented - actual).to be_empty, "documented but nonexistent: #{(documented - actual).join(', ')}"
  end
end
