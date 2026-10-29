FactoryBot.define do
  factory :tag do
    project
    sequence(:name) { |n| "tag-#{n}" }
  end
end
