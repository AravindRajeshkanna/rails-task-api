module Types
  # A task that matched a full-text search; the matched words in the highlights are wrapped in « ».
  class SearchResultType < BaseObject
    graphql_name "SearchResult"

    field :task, TaskType, null: false
    field :rank, Float, null: false, description: "Higher is better; title matches count for more"
    field :title_highlight, String
    field :description_highlight, String, description: "One fragment around the best match"

    def task = object
    def rank = object.search_rank.to_f.round(4)
    def title_highlight = object.title_highlight.presence
    def description_highlight = object.description_highlight.presence
  end
end
