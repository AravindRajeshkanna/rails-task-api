class Delivery < ApplicationRecord
  CHANNELS = %w[email slack].freeze
  validates :channel, inclusion: { in: CHANNELS }
end
