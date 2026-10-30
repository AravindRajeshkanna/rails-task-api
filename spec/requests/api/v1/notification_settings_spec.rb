require "rails_helper"

RSpec.describe "Notification settings and mutes" do
  let(:ada) { create(:user) }
  let(:grace) { create(:user) }
  let!(:project) { create(:project, owner: ada) }
  let!(:others_project) { create(:project, owner: grace) }

  describe "GET and PATCH /notification_settings" do
    it "answers the defaults until something is changed, without storing anything" do
      expect { api :get, "/api/v1/notification_settings", as: ada }.not_to change(NotificationSetting, :count)

      expect(response).to have_http_status(:ok)
      expect(data).to include("digest" => "off", "digest_hour" => 8, "time_zone" => "UTC", "last_digest_at" => nil)
    end

    it "changes the digest, the hour and the zone, and remembers them" do
      api :patch, "/api/v1/notification_settings", { digest: "daily", digest_hour: 17, time_zone: "Asia/Kolkata" }, as: ada

      expect(response).to have_http_status(:ok)
      expect(data).to include("digest" => "daily", "digest_hour" => 17, "time_zone" => "Asia/Kolkata")

      api :get, "/api/v1/notification_settings", as: ada
      expect(data).to include("digest" => "daily", "digest_hour" => 17)
      expect(NotificationSetting.where(user: ada).count).to eq(1)
    end

    it "changes one thing without resetting the others" do
      api :patch, "/api/v1/notification_settings", { digest: "daily", digest_hour: 17 }, as: ada
      api :patch, "/api/v1/notification_settings", { time_zone: "Europe/Paris" }, as: ada

      expect(data).to include("digest" => "daily", "digest_hour" => 17, "time_zone" => "Europe/Paris")
    end

    it "refuses nonsense in the usual envelope, with the field named" do
      api :patch, "/api/v1/notification_settings", { digest: "hourly", digest_hour: 25, time_zone: "Nowhere" }, as: ada

      expect(response).to have_http_status(:unprocessable_content)
      expect(error["details"].keys).to contain_exactly("digest", "digest_hour", "time_zone")
    end

    it "never touches anyone else's settings: it is always the caller's" do
      create(:notification_setting, :daily, user: grace)

      api :patch, "/api/v1/notification_settings", { digest: "off", user_id: grace.id }, as: ada

      expect(NotificationSetting.find_by!(user: grace).digest).to eq("daily")
    end

    it "needs a signed-in caller" do
      api :get, "/api/v1/notification_settings"

      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "mutes" do
    it "mutes a kind everywhere, a project entirely, or a kind in a project" do
      api :post, "/api/v1/notification_mutes", { kind: "comment.created" }, as: ada
      expect(response).to have_http_status(:created)
      expect(data).to include("kind" => "comment.created", "project_id" => nil)

      api :post, "/api/v1/notification_mutes", { project_id: project.id }, as: ada
      expect(data).to include("kind" => nil, "project_id" => project.id)

      api :post, "/api/v1/notification_mutes", { project_id: project.id, kind: "task.due_soon" }, as: ada
      expect(data).to include("kind" => "task.due_soon", "project_id" => project.id)

      api :get, "/api/v1/notification_mutes", as: ada
      expect(data.size).to eq(3)
    end

    it "refuses an unknown kind, an empty mute and a duplicate with 422" do
      api :post, "/api/v1/notification_mutes", { kind: "task.exploded" }, as: ada
      expect(response).to have_http_status(:unprocessable_content)
      expect(error["details"]).to include("kind")

      api :post, "/api/v1/notification_mutes", {}, as: ada
      expect(response).to have_http_status(:unprocessable_content)

      2.times { api :post, "/api/v1/notification_mutes", { kind: "comment.created" }, as: ada }
      expect(response).to have_http_status(:unprocessable_content)
      expect(NotificationMute.where(user: ada).count).to eq(1)
    end

    it "answers 404 for a project the caller cannot see, as for one that does not exist" do
      api :post, "/api/v1/notification_mutes", { project_id: others_project.id }, as: ada
      stranger = response.status
      api :post, "/api/v1/notification_mutes", { project_id: 0 }, as: ada

      expect([ stranger, response.status ]).to eq([ 404, 404 ])
      expect(NotificationMute.count).to eq(0)
    end

    it "lists and removes only the caller's own" do
      mine = create(:notification_mute, user: ada, kind: "task.completed")
      theirs = create(:notification_mute, user: grace, kind: "task.completed")

      api :get, "/api/v1/notification_mutes", as: ada
      expect(data.pluck("id")).to eq([ mine.id ])

      api :delete, "/api/v1/notification_mutes/#{theirs.id}", as: ada
      expect(response).to have_http_status(:not_found)
      expect(theirs.reload).to be_persisted

      api :delete, "/api/v1/notification_mutes/#{mine.id}", as: ada
      expect(response).to have_http_status(:no_content)
      expect(NotificationMute.exists?(mine.id)).to be(false)
    end
  end

  describe "in the public demo" do
    it "refuses the digest, which sends mail, and allows the harmless mutes" do
      original = Rails.configuration.x.demo_mode
      Rails.configuration.x.demo_mode = true

      api :patch, "/api/v1/notification_settings", { digest: "daily" }, as: ada
      expect(response).to have_http_status(:forbidden)
      expect(error["code"]).to eq("demo_mode")

      api :post, "/api/v1/notification_mutes", { kind: "comment.created" }, as: ada
      expect(response).to have_http_status(:created)
    ensure
      Rails.configuration.x.demo_mode = original
    end
  end
end
