class Tag < ApplicationRecord
  belongs_to :project

  has_many :taggings, dependent: :destroy
  has_many :tasks, through: :taggings

  normalizes :name, with: ->(name) { name.squish.downcase }

  validates :name, presence: true, length: { maximum: 40 }, uniqueness: { scope: :project_id }
end
