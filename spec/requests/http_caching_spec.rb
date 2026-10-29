require "rails_helper"

RSpec.describe "HTTP caching" do
  let(:owner) { create(:user) }
  let!(:project) { create(:project, owner: owner) }
  let(:path) { "/api/v1/projects/#{project.id}" }

  it "lets clients keep a private copy but forces revalidation" do
    api :get, path, as: owner

    expect(response.headers["Cache-Control"]).to eq("no-cache, private")
    expect(response.headers["Vary"]).to include("Authorization")
    expect(response.headers["ETag"]).to be_present
  end

  it "answers 304 with no body when nothing changed" do
    api :get, path, as: owner
    etag = response.headers["ETag"]

    api :get, path, as: owner, headers: { "If-None-Match" => etag }

    expect(response).to have_http_status(:not_modified)
    expect(response.body).to be_empty
  end

  it "answers 200 with a new ETag once the resource changes" do
    api :get, path, as: owner
    etag = response.headers["ETag"]

    api :patch, path, { name: "Renamed" }, as: owner
    api :get, path, as: owner, headers: { "If-None-Match" => etag }

    expect(response).to have_http_status(:ok)
    expect(response.headers["ETag"]).not_to eq(etag)
  end

  it "does not share a representation between users" do
    stranger = create(:user)
    api :get, path, as: owner
    etag = response.headers["ETag"]

    api :get, path, as: stranger, headers: { "If-None-Match" => etag }

    expect(response).to have_http_status(:not_found)
  end

  it "forbids storing anything that carries a credential" do
    create(:user, email_address: "pat@example.com", password: "correct-horse-battery")

    api :post, "/api/v1/session", { email_address: "pat@example.com", password: "correct-horse-battery" }
    expect(response.headers["Cache-Control"]).to eq("private, no-store")

    api :post, "/api/v1/registrations", { name: "New", email_address: "new@example.com", password: "correct-horse-battery" }
    expect(response.headers["Cache-Control"]).to eq("private, no-store")
  end
end
