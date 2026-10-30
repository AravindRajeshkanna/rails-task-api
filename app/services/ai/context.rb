module Ai
  # Turns records into the small, bounded, plain-data inputs the AI features take. Everything the
  # model sees is clipped here, so prompts stay cheap and one huge task cannot blow the budget.
  module Context
    module_function

    def today(timezone) = zone(timezone).today
    def zone(timezone) = ActiveSupport::TimeZone[timezone.to_s] || ActiveSupport::TimeZone["UTC"]

    def clip(text, max) = text.to_s.squish.truncate(max, omission: "…")

    def members(project)
      project.participants.order(:id).limit(100).map { |user| { id: user.id, name: user.name } }
    end

    def tag_names(project) = project.tags.order(:name).limit(200).pluck(:name)

    def task(task)
      { title: clip(task.title, 200), description: clip(task.description, 1_000), due_on: task.due_on&.iso8601, status: task.status }
    end
  end
end
