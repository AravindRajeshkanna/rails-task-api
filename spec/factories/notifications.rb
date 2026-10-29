FactoryBot.define do
  factory :notification do
    user
    project { association :project, owner: user }
    task { association :task, project: project, creator: project.owner }
    actor { nil }
    kind { "task.assigned" }
    data { { task_title: task.title, project_name: project.name } }

    trait(:read) { read_at { 1.hour.ago } }
    trait(:due_soon) { kind { "task.due_soon" } }
  end
end
