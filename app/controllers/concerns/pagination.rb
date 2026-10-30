# Offset pagination with Pagy: `?page=2&limit=50` (default 25, max 100).
# Sets RFC 8288 `Link` plus `Current-Page`, `Page-Limit`, `Total-Count` and
# `Total-Pages` headers and returns the page of records with a meta hash.
#
# Lists that can be very long also offer keyset pagination (`paginate_by_cursor`): `?cursor=` for the
# first page, then `?cursor=<meta.next_cursor>`. It costs the same at any depth, has no total, and does not
# skip or repeat rows when rows are added meanwhile.
module Pagination
  extend ActiveSupport::Concern
  include Pagy::Method

  DEFAULT_LIMIT = 25
  MAX_LIMIT = 100

  # Cursor values as they appear in the relation's ORDER BY, and what each must look like.
  CURSOR_VALUE_CHECKS = {
    "created_at" => ->(value) { value.is_a?(String) && Time.iso8601(value) },
    "updated_at" => ->(value) { value.is_a?(String) && Time.iso8601(value) },
    "title" => ->(value) { value.is_a?(String) },
    "id" => ->(value) { value.is_a?(Integer) }
  }.freeze

  private
    # Keyset pagination for a relation ordered by created_at, updated_at or title plus id (a unique
    # tie-breaker, last). +cursor+ is blank for the first page. Answers meta { limit, next_cursor, has_more }
    # and a Link header with rel="next". A cursor that was not issued by this endpoint is a 400.
    #
    # +relation+ may also be a lambda taking the decoded cutoff ([created_at, id], or nil on the first page) and returning the relation, for
    # a list whose query must be told where to start to stay cheap (ActivityFeed); it is called after the cursor has been checked.
    def paginate_by_cursor(relation, cursor)
      builder = relation.respond_to?(:call) ? relation : nil
      keys = (builder ? builder.call(nil) : relation).order_values.map { |node| node.value.name.to_s }
      raise InvalidParameterError.new("cursor", "cursor is not valid; use meta.next_cursor from a previous response") unless valid_cursor?(cursor, keys)

      relation = builder.call(cursor.blank? ? nil : cutoff_from(cursor)) if builder

      pagy, records = pagy(:keyset, relation, page: cursor.to_s, limit: DEFAULT_LIMIT, client_limit: MAX_LIMIT,
                                              tuple_comparison: true, pre_serialize: method(:serialize_cursor_values))
      add_next_link(pagy.next) if pagy.next

      [ records, { limit: pagy.limit, next_cursor: pagy.next, has_more: pagy.next.present? } ]
    end

    # Microsecond precision, because the default JSON encoding of a Time keeps only milliseconds, and a
    # cutoff rounded down would skip the rows that fall between it and the real one.
    def serialize_cursor_values(attributes)
      attributes.transform_values! { |value| value.respond_to?(:iso8601) ? value.utc.iso8601(6) : value }
    end

    # The [created_at (a Time), id] a created_at/id cursor points after.
    def cutoff_from(cursor)
      created_at, id = Pagy::Keyset.decode(cursor)
      [ Time.iso8601(created_at), id ]
    end

    def valid_cursor?(cursor, keys)
      return true if cursor.blank?

      cutoff = Pagy::Keyset.decode(cursor)
      cutoff.is_a?(Array) && cutoff.size == keys.size &&
        keys.zip(cutoff).all? { |key, value| CURSOR_VALUE_CHECKS.fetch(key).call(value) }
    rescue ArgumentError, KeyError
      false # not a time, or a key we do not issue cursors for
    end

    def add_next_link(next_cursor)
      url = "#{request.base_url}#{request.path}?#{request.query_parameters.merge('cursor' => next_cursor).to_query}"
      existing = response.headers["Link"].presence
      response.headers["Link"] = [ existing, "<#{url}>; rel=\"next\"" ].compact_blank.join(", ")
    end

    def paginate(relation)
      pagy, records = pagy(:offset, relation, limit: DEFAULT_LIMIT, client_limit: MAX_LIMIT)
      headers = pagy.headers_hash
      # Keep any Link already on the response (e.g. ApiVersioning's successor-version).
      existing_link = response.headers["Link"].presence
      headers["link"] = [ existing_link, headers["link"] ].compact_blank.join(", ") if existing_link
      response.headers.merge!(headers)

      [ records, {
        page: pagy.page,
        limit: pagy.limit,
        count: pagy.count,
        pages: pagy.last,
        next: pagy.next,
        previous: pagy.previous
      } ]
    end
end
