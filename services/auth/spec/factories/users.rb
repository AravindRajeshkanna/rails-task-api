FactoryBot.define do
  factory :user do
    name { "Pat Person" }
    sequence(:email_address) { |n| "user#{n}@example.com" }
    password { "correct-horse-battery" }
  end
end
