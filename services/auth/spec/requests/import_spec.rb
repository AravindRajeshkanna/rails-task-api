require "rails_helper"
require "rake"

RSpec.describe "users:import", type: :request do
  before(:all) { Rails.application.load_tasks }

  def run_import(rows)
    file = Tempfile.new([ "users", ".jsonl" ])
    rows.each { |row| file.puts(row.to_json) }
    file.close
    ENV["IN"] = file.path
    Rake::Task["users:import"].reenable
    expect { Rake::Task["users:import"].invoke }.to output(/Imported/).to_stdout
  ensure
    ENV.delete("IN")
    file&.unlink
  end

  let(:digest) { BCrypt::Password.create("old-password-123", cost: 4).to_s }
  let(:row) { { legacy_id: 41, name: "Old Timer", email_address: "old@example.com", password_digest: digest, created_at: "2025-01-02T03:04:05Z" } }

  it "carries users over with their password hash and legacy id, so they sign in as before" do
    run_import([ row ])

    user = User.sole
    expect(user).to have_attributes(legacy_id: 41, email_address: "old@example.com", created_at: Time.utc(2025, 1, 2, 3, 4, 5))
    claims = verifier.verify!(sign_in(user, password: "old-password-123")["token"])
    expect(claims["legacy_id"]).to eq(41)
  end

  it "is safe to repeat" do
    run_import([ row ])
    run_import([ row.merge(name: "Renamed") ])

    expect(User.count).to eq(1)
    expect(User.sole.name).to eq("Renamed")
  end
end
