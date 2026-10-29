require "rails_helper"

RSpec.describe "Demo mode" do
  let(:user) { create(:user) }
  let!(:project) { create(:project, owner: user) }

  def demo_mode(on)
    original = Rails.configuration.x.demo_mode
    Rails.configuration.x.demo_mode = on
    yield
  ensure
    Rails.configuration.x.demo_mode = original
  end

  it "refuses what sends mail, stores files, calls out, spends AI budget or creates accounts, in the usual envelope" do
    demo_mode(true) do
      task = create(:task, project: project)
      refused = [
        [ :post, "/api/v1/registrations", { name: "A", email_address: "a@example.com", password: "long-enough-pw" } ],
        [ :post, "/api/v1/passwords", { email_address: user.email_address } ],
        [ :patch, "/api/v1/me", { name: "Vandal" } ],
        [ :post, "/api/v1/projects/#{project.id}/webhooks", { url: "https://hooks.example.com/x" } ],
        [ :post, "/api/v1/tasks/#{task.id}/attachments", {} ],
        [ :post, "/api/v1/ai/suggest_priority", { project_id: project.id, title: "x" } ],
        [ :post, "/api/v1/ai/chat", { project_id: project.id, message: "hi" } ]
      ]

      refused.each do |verb, path, body|
        api verb, path, body, as: user
        expect(response).to have_http_status(:forbidden), "#{verb.upcase} #{path} returned #{response.status}"
        expect(error).to include("code" => "demo_mode", "status" => 403)
      end
    end
  end

  it "leaves the rest of the API working, and says it is a demo on every response" do
    demo_mode(true) do
      api :post, "/api/v1/projects/#{project.id}/tasks", { title: "Still works" }, as: user
      expect(response).to have_http_status(:created)
      expect(response.headers["X-Demo-Mode"]).to eq("true")

      api :get, "/api/v1/projects", as: user
      expect(response).to have_http_status(:ok)
      api :post, "/api/v1/session", { email_address: user.email_address, password: "password123" }
      expect(response.headers["X-Demo-Mode"]).to eq("true")
    end
  end

  it "asks for sign-in before it explains itself" do
    demo_mode(true) do
      api :patch, "/api/v1/me", { name: "x" }

      expect(response).to have_http_status(:unauthorized)
    end
  end

  it "changes nothing when it is off" do
    demo_mode(false) do
      api :post, "/api/v1/registrations", { name: "Ada", email_address: "ada@example.com", password: "long-enough-pw" }
      expect(response).to have_http_status(:created)
      expect(response.headers).not_to have_key("X-Demo-Mode")
    end
  end

  it "only names routes that exist, so a typo cannot silently leave one open" do
    routed = Rails.application.routes.routes.filter_map { |route| "#{route.defaults[:controller]}##{route.defaults[:action]}" if route.defaults[:controller] }

    expect(DemoMode::REFUSED - routed).to be_empty
  end
end
