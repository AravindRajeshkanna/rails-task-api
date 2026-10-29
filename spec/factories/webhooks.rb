FactoryBot.define do
  factory :webhook do
    project
    url { "https://hooks.example.com/receive" }
    events { [] }

    trait :inactive do
      active { false }
    end
  end

  factory :webhook_delivery do
    webhook
    event { "task.created" }
    payload { { "event" => "task.created", "data" => { "id" => 1 } } }
  end
end
