# One hit of GET /search: enough to show a result and link to it. «» mark the matched words.
class SearchResultResource < ApplicationResource
  attributes :id, :project_id, :title, :status, :priority, :due_on, :updated_at

  attribute(:project) { |task| { id: task.project_id, name: task.project.name } }
  attribute(:rank) { |task| task.search_rank.to_f.round(4) }
  attribute :highlights do |task|
    { title: task.title_highlight.presence, description: task.description_highlight.presence }
  end
end
