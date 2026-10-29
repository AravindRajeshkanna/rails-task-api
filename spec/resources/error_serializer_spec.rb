require "rails_helper"

RSpec.describe ErrorSerializer do
  it "renders the envelope, leaving out what it has nothing to say about" do
    error = described_class.new(status: :not_found, code: "not_found", message: "Resource not found")

    expect(error.as_json).to eq(error: { status: 404, code: "not_found", message: "Resource not found" })
  end

  it "includes details and the request id when present" do
    error = described_class.new(status: 422, code: "validation_failed", message: "Validation failed",
                                details: { title: [ "can't be blank" ] }, request_id: "req-1")

    expect(error.as_json[:error]).to include(details: { title: [ "can't be blank" ] }, request_id: "req-1")
  end

  it "derives the code from the reason phrase for a bare HTTP status" do
    expect(described_class.for_status(404).as_json[:error]).to include(status: 404, code: "not_found", message: "Not Found")
    expect(described_class.for_status(503).as_json[:error]).to include(code: "service_unavailable")
  end

  it "is what render json: serializes" do
    expect(described_class.new(status: 429, code: "rate_limited", message: "Slow down").to_json)
      .to eq('{"error":{"status":429,"code":"rate_limited","message":"Slow down"}}')
  end
end
