FactoryBot.define do
  factory :membership do
    project
    user
    role { "member" }

    trait :admin do
      role { "admin" }
    end
  end
end
