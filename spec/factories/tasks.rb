FactoryBot.define do
  factory :task do
    project
    creator { project.owner }
    sequence(:title) { |n| "Task #{n}" }
    description { Faker::Lorem.paragraph }

    trait :in_progress do
      status { :in_progress }
    end

    trait :done do
      status { :done }
    end

    trait :urgent do
      priority { :urgent }
    end

    trait :discarded do
      discarded_at { 1.day.ago }
    end
  end
end
