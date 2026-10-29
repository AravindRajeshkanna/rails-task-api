require "rails_helper"

RSpec.describe User do
  subject(:user) { build(:user) }

  describe "validations" do
    it { is_expected.to validate_presence_of(:name) }
    it { is_expected.to validate_length_of(:name).is_at_most(100) }
    it { is_expected.to validate_presence_of(:email_address) }
    it { is_expected.to validate_uniqueness_of(:email_address).case_insensitive }
    it { is_expected.to allow_value("a@b.co").for(:email_address) }
    it { is_expected.not_to allow_value("not-an-email").for(:email_address) }
    it { is_expected.not_to allow_value("short").for(:password) }
  end

  describe "associations" do
    it { is_expected.to have_many(:sessions).dependent(:destroy) }
    it { is_expected.to have_many(:memberships).dependent(:destroy) }
    it { is_expected.to have_many(:projects).through(:memberships) }
    it { is_expected.to have_many(:comments).dependent(:destroy) }
  end

  it "normalizes email addresses and names" do
    user = create(:user, email_address: "  Mixed.Case@Example.COM ", name: "  Ada   Lovelace ")

    expect(user.email_address).to eq("mixed.case@example.com")
    expect(user.name).to eq("Ada Lovelace")
  end

  describe ".authenticate_by" do
    let!(:user) { create(:user, email_address: "ada@example.com", password: "analytical-engine") }

    it "returns the user for correct credentials" do
      expect(User.authenticate_by(email_address: "ada@example.com", password: "analytical-engine")).to eq(user)
    end

    it "returns nil for a wrong password or unknown email" do
      expect(User.authenticate_by(email_address: "ada@example.com", password: "nope")).to be_nil
      expect(User.authenticate_by(email_address: "who@example.com", password: "analytical-engine")).to be_nil
    end
  end

  describe "avatar" do
    it "accepts a small image" do
      user = create(:user)
      user.avatar.attach(io: file_fixture("pixel.png").open, filename: "pixel.png", content_type: "image/png")

      expect(user).to be_valid
    end

    it "rejects other file types" do
      user = create(:user)
      user.avatar.attach(io: file_fixture("notes.txt").open, filename: "notes.txt", content_type: "text/plain")

      expect(user).not_to be_valid
      expect(user.errors[:avatar]).to include("must be a PNG, JPEG or WebP image")
    end
  end

  describe "password reset token" do
    it "round-trips and expires" do
      user = create(:user)
      token = user.password_reset_token

      expect(User.find_by_password_reset_token!(token)).to eq(user)
      travel_to(1.hour.from_now) do
        expect { User.find_by_password_reset_token!(token) }.to raise_error(ActiveSupport::MessageVerifier::InvalidSignature)
      end
    end
  end
end
