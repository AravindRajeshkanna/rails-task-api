require "rails_helper"

RSpec.describe Analytics::ReportForm do
  def form(**attributes) = described_class.new(attributes)

  around { |example| travel_to(Time.utc(2026, 10, 29, 12)) { example.run } }

  it "defaults to the last 30 days in weekly buckets" do
    report = form

    expect(report).to be_valid
    expect([ report.from_date, report.to_date, report.interval ]).to eq([ Date.new(2026, 9, 30), Date.new(2026, 10, 29), "week" ])
  end

  it "counts 30 days back from `to` when only `to` is given" do
    expect(form(to: "2026-06-30").from_date).to eq(Date.new(2026, 6, 1))
  end

  it "accepts explicit ISO 8601 dates and a known interval" do
    report = form(from: "2026-01-01", to: "2026-03-31", interval: "month")

    expect(report).to be_valid
    expect(report.cache_key).to eq("2026-01-01:2026-03-31:month")
  end

  it "reads only the declared attributes from params" do
    params = ActionController::Parameters.new(from: "2026-10-01", interval: "day", admin: "true", id: "7")

    expect(described_class.from_params(params).interval).to eq("day")
  end

  describe "rejects" do
    it "an interval it does not know, saying which ones it does" do
      report = form(interval: "year")

      expect(report).not_to be_valid
      expect(report.errors[:interval].first).to eq("must be one of: day, week, month")
    end

    it "dates that are not ISO 8601 calendar days, including impossible ones" do
      report = form(from: "yesterday", to: "2026-02-30")

      expect(report).not_to be_valid
      expect(report.errors.attribute_names).to contain_exactly(:from, :to)
    end

    it "a range that ends before it starts" do
      expect(form(from: "2026-10-10", to: "2026-10-01")).not_to be_valid
    end

    it "a range that would produce too many buckets for the interval" do
      expect(form(from: "2026-01-01", to: "2026-10-29", interval: "day")).not_to be_valid
      expect(form(from: "2026-01-01", to: "2026-10-29", interval: "week")).to be_valid
    end
  end
end
