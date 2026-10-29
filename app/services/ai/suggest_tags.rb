module Ai
  class SuggestTags
    Suggestion = Struct.new(:tags, :usage, keyword_init: true)

    def initialize(user:, project:, timezone: "UTC")
      @user = user
      @project = project
      @timezone = timezone
    end

    def call(title:, description: nil, allow_new: true)
      result = Runner.new(user: @user, project: @project).run("suggest_tags", {
        task: { title: Context.clip(title, 200), description: Context.clip(description, 1_000) },
        existing_tags: Context.tag_names(@project),
        allow_new: allow_new,
        today: Context.today(@timezone).iso8601
      })

      Suggestion.new(tags: result.output, usage: result.usage)
    end
  end
end
