FactoryBot.define do
  factory :comment do
    task
    user { task.project.owner }
    body { Faker::Lorem.sentence }
  end
end
