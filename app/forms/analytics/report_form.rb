module Analytics
  # GET /projects/:id/analytics?from=2026-10-01&to=2026-10-31&interval=week
  #
  # Dates are ISO 8601 calendar days in UTC. Without `to` the range ends today; without `from` it
  # starts 29 days before `to`. The bounds exist so one request cannot ask for years of daily buckets.
  class ReportForm < ApplicationForm
    INTERVALS = %w[day week month].freeze
    MAX_PERIODS = 120
    # Days one bucket spans, for the size check only (months are measured as 28 days, the shortest).
    PERIOD_DAYS = { "day" => 1, "week" => 7, "month" => 28 }.freeze

    attribute :from, :string
    attribute :to, :string
    attribute :interval, :string, default: "week"

    validates :interval, inclusion: { in: INTERVALS, message: "must be one of: #{INTERVALS.join(', ')}" }
    validate :dates_are_iso8601
    validate :range_is_sane

    def to_date = @to_date ||= parse(to) || Date.current
    def from_date = @from_date ||= parse(from) || (to_date - 29)

    # Identifies this report for caching.
    def cache_key = [ from_date, to_date, interval ].join(":")

    private
      def parse(value)
        Date.iso8601(value) if value.present?
      rescue Date::Error
        nil
      end

      def dates_are_iso8601
        { from: from, to: to }.each do |name, value|
          errors.add(name, "must be an ISO 8601 date (YYYY-MM-DD)") if value.present? && parse(value).nil?
        end
      end

      def range_is_sane
        return if errors.any? || interval.blank?

        if from_date > to_date
          errors.add(:from, "must not be after `to`")
        elsif (to_date - from_date).to_i / PERIOD_DAYS.fetch(interval) >= MAX_PERIODS
          errors.add(:base, "a range of that length would produce more than #{MAX_PERIODS} #{interval} buckets; use a wider interval or a shorter range")
        end
      end
  end
end
