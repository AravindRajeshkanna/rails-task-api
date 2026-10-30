# Sparse fieldsets: `?fields=id,title,status` asks for only those attributes (ADR 56). A list view that shows a title and a status does not need
# the description, the tags, the creator and the attachments, and a client on a phone should not pay to download or the server to load them.
#
#   GET /projects/3/tasks?fields=id,title,status       -> [{ "id": 1, "title": "...", "status": "todo" }, ...]
#
# The resource decides what can be asked for (its sparse_fields declaration), `id` is always included, an unknown name is a 400 that lists the valid
# ones, and no `fields` means everything, as before. Associations nobody asked for are not loaded (the resource knows which preload each needs).
module SparseFieldsets
  extend ActiveSupport::Concern

  private
    # +relation+ with the associations the given fields need (none, for `?fields=id`).
    def preload_for(relation, resource_class, fields)
      preloads = resource_class.preloads_for(fields)
      preloads.empty? ? relation : relation.includes(*preloads)
    end

    # The validated list of fields asked for (strings), or nil for "all of them".
    def requested_fields(resource_class)
      raw = params[:fields]
      return if raw.blank?
      raise InvalidParameterError.new("fields", "fields must be a comma-separated list of field names") unless raw.is_a?(String)

      names = raw.split(",").map(&:strip).compact_blank.uniq
      unknown = names - resource_class.field_names
      raise InvalidParameterError.new("fields", "unknown field#{'s' if unknown.size > 1}: #{unknown.join(', ')}. Available: #{resource_class.field_names.join(', ')}") if unknown.any?

      names
    end
end
