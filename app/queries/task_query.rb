# Applies the public filtering / sorting contract of GET /projects/:id/tasks:
#
#   status=todo,in_progress   priority=high,urgent   assignee=me|unassigned|<user id>
#   tag=bug,api               due_from=2026-11-01    due_to=2026-11-30
#   overdue=true              q=substring (title or description)
#   search=billing+invoice    full-text, stemmed ("quoted phrase", or, -excluded); best match first
#                             unless sort is given
#   sort=-priority,due_on     (prefix with - for descending; default -created_at)
#
# Everything is validated against allow-lists, so user input never reaches SQL
# as a column name, and bad values raise InvalidParameterError (HTTP 400).
class TaskQuery
  SORT_COLUMNS = %w[created_at updated_at due_on priority status title].freeze
  DEFAULT_SORT = "-created_at".freeze
  NULLS_LAST_COLUMNS = %w[due_on].freeze

  def initialize(scope, params, current_user:)
    @scope = scope
    @params = params
    @current_user = current_user
  end

  def call
    relation = @scope
    relation = filter_enum(relation, :status, Task.statuses)
    relation = filter_enum(relation, :priority, Task.priorities)
    relation = filter_assignee(relation)
    relation = relation.with_tag_names(list(:tag)) if @params[:tag].present?
    relation = relation.where(due_on: date(:due_from)..) if @params[:due_from].present?
    relation = relation.where(due_on: ..date(:due_to)) if @params[:due_to].present?
    relation = relation.overdue if boolean(:overdue)
    sort(search(relation))
  end

  private
    def search(relation)
      relation = relation.search(@params[:q].to_s.strip) if @params[:q].present?
      search_term ? relation.full_text(search_term) : relation
    end

    def search_term
      return @search_term if defined?(@search_term)

      term = @params[:search].to_s.squish.presence
      raise InvalidParameterError.new("search", "search must be at most #{TaskSearch::MAX_LENGTH} characters") if term && term.length > TaskSearch::MAX_LENGTH

      @search_term = term
    end

    def list(key) = @params[key].to_s.split(",").map(&:strip).compact_blank.uniq

    def filter_enum(relation, key, mapping)
      return relation if @params[key].blank?

      values = list(key)
      unknown = values - mapping.keys
      if unknown.any?
        raise InvalidParameterError.new(key.to_s, "#{key} must be one of: #{mapping.keys.join(', ')}")
      end

      relation.where(key => values)
    end

    def filter_assignee(relation)
      case (value = @params[:assignee].to_s)
      when "" then relation
      when "me" then relation.where(assignee_id: @current_user.id)
      when "unassigned" then relation.where(assignee_id: nil)
      when /\A\d+\z/ then relation.where(assignee_id: value.to_i)
      else raise InvalidParameterError.new("assignee", "assignee must be 'me', 'unassigned' or a user id")
      end
    end

    def date(key)
      Date.iso8601(@params[key].to_s)
    rescue Date::Error
      raise InvalidParameterError.new(key.to_s, "#{key} must be an ISO 8601 date (YYYY-MM-DD)")
    end

    def boolean(key)
      return false if @params[key].blank?

      ActiveModel::Type::Boolean.new.cast(@params[key]) || false
    end

    def sort(relation)
      return relation.reorder(Task.search_rank(search_term).desc, Task.arel_table[:id].desc) if search_term && list(:sort).empty?

      fields = list(:sort).presence || [ DEFAULT_SORT ]
      # The id tie-breaker keeps pagination stable when sort values collide.
      tie_breaker = Task.arel_table[:id].public_send(fields.first.start_with?("-") ? :desc : :asc)
      relation.reorder(*fields.map { |field| order_for(field) }, tie_breaker)
    end

    def order_for(field)
      direction = field.start_with?("-") ? :desc : :asc
      column = field.delete_prefix("-").delete_prefix("+")
      unless column.in?(SORT_COLUMNS)
        raise InvalidParameterError.new("sort", "sort must be one or more of: #{SORT_COLUMNS.join(', ')} (prefix with - for descending)")
      end

      order = Task.arel_table[column].public_send(direction)
      column.in?(NULLS_LAST_COLUMNS) ? order.nulls_last : order
    end
end
