FactoryBot.define do
  # The owner automatically becomes an admin member (see Project#add_owner_as_admin).
  factory :project do
    association :owner, factory: :user
    sequence(:name) { |n| "Project #{n}" }
    description { Faker::Lorem.sentence }

    trait :discarded do
      discarded_at { 1.day.ago }
    end
  end
end
