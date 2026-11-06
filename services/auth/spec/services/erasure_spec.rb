require "rails_helper"

# What the Auth service holds of a person, and that it is all gone (ADR 79).
RSpec.describe AuthService::Erasure do
  let!(:ada) { create(:user, email_address: "ada@example.com", name: "Ada Lovelace") }
  let!(:grace) { create(:user, email_address: "grace@example.com") }

  before do
    RefreshToken.issue!(ada, ip_address: "203.0.113.7", user_agent: "RSpec")
    RefreshToken.issue!(ada)
    RefreshToken.issue!(grace)
  end

  it "deletes the identity found by its subject, with every refresh token, and leaves everyone else" do
    expect(described_class.call(subject: ada.uid)).to eq(:erased)

    expect(User.where(id: ada.id)).to be_empty
    expect(RefreshToken.where(user_id: ada.id)).to be_empty
    expect(User.find(grace.id).refresh_tokens.count).to eq(1)
    expect(User.where(email_address: "ada@example.com")).to be_empty
  end

  it "deletes by the Task API's own id when the subject was never linked: an account imported at the cutover that has not signed in since" do
    ada.update_columns(legacy_id: 41)

    expect(described_class.call(subject: nil, legacy_id: 41)).to eq(:erased)

    expect(User.where(id: ada.id)).to be_empty
    expect(User.exists?(grace.id)).to be(true)
  end

  it "deletes the identity once when both ways find it, and each of two when they find different ones" do
    ada.update_columns(legacy_id: 41)
    expect(described_class.call(subject: ada.uid, legacy_id: 41)).to eq(:erased)

    grace.update_columns(legacy_id: 42)
    other = create(:user)
    expect(described_class.call(subject: other.uid, legacy_id: 42)).to eq(:erased)
    expect(User.exists?(other.id)).to be(false)
    expect(User.exists?(grace.id)).to be(false)
  end

  it "does nothing the second time, or for somebody it never knew" do
    described_class.call(subject: ada.uid)

    expect(described_class.call(subject: ada.uid)).to eq(:unknown)
    expect(described_class.call(subject: SecureRandom.uuid)).to eq(:unknown)
    expect(described_class.call(legacy_id: 9999)).to eq(:unknown)
    expect(User.count).to eq(1)
  end

  it "does nothing without a subject or an id, rather than everything" do
    expect(described_class.call).to eq(:unknown)
    expect(described_class.call(subject: "", legacy_id: nil)).to eq(:unknown)
    expect(User.count).to eq(2)
  end

  it "leaves a person nothing to sign in with: the address and the refresh tokens are gone" do
    token = RefreshToken.issue!(ada).last

    described_class.call(subject: ada.uid)

    expect(User.authenticate_by(email_address: "ada@example.com", password: "correct-horse-battery")).to be_nil
    expect { RefreshToken.rotate!(token) }.to raise_error(RefreshToken::Invalid)
  end

  it "lets the address register again" do
    described_class.call(subject: ada.uid)

    expect(build(:user, email_address: "ada@example.com")).to be_valid
  end
end
