FactoryBot.define do
  factory :user do
    name { Faker::Name.name }
    sequence(:email_address) { |n| "user#{n}@example.com" }
    password { "correct-horse-battery" }
  end
end
