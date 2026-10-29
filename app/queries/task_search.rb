# Full-text search over the tasks a user can see, best match first: the engine behind GET /search.
#
#   TaskSearch.new(policy_scope(Task), "billing invoice", project_id: 3).call
#
# Pass a policy-scoped relation: that is what limits the search to projects the user can see.
#
# The text is parsed as a web search query (words are stemmed, "quoted phrases", `or`, and `-excluded`),
# and whatever the user types is safe: it cannot raise a syntax error. Title matches outrank description
# matches. Each row carries +search_rank+ and the highlighted +title_highlight+ and +description_highlight+;
# A description with no match is shown from its start, without marks. PostgreSQL only computes the highlights
# for the rows of the page it returns.
class TaskSearch
  MAX_LENGTH = 200

  # Marks around matched words in the highlights. Plain text, never HTML, so there is nothing to inject.
  # A title is shown whole; a description as the one fragment around the best match.
  TITLE_OPTIONS = "StartSel=«, StopSel=», HighlightAll=true".freeze
  DESCRIPTION_OPTIONS = "StartSel=«, StopSel=», MaxFragments=1, MaxWords=24, MinWords=10, ShortWord=2".freeze

  def initialize(scope, term, project_id: nil)
    @scope = scope
    @term = term.to_s.squish
    @project_id = project_id
  end

  def call
    raise InvalidParameterError.new("q", "q must be at most #{MAX_LENGTH} characters") if @term.length > MAX_LENGTH

    relation = @scope.kept.full_text(@term)
    relation = relation.where(project_id: @project_id) if @project_id.present?
    relation.select("tasks.*", Task.search_rank(@term).as("search_rank"), highlight(:title, TITLE_OPTIONS), highlight(:description, DESCRIPTION_OPTIONS))
            .reorder(Task.search_rank(@term).desc, Task.arel_table[:id].desc)
  end

  private

    def highlight(column, options)
      Task.sanitize_sql_array([
        "ts_headline('english', coalesce(tasks.#{column}, ''), websearch_to_tsquery('english', ?), ?) AS #{column}_highlight", @term, options
      ])
    end
end
