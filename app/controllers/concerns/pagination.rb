# Offset pagination with Pagy: `?page=2&limit=50` (default 25, max 100).
# Sets RFC 8288 `Link` plus `Current-Page`, `Page-Limit`, `Total-Count` and
# `Total-Pages` headers and returns the page of records with a meta hash.
module Pagination
  extend ActiveSupport::Concern
  include Pagy::Method

  DEFAULT_LIMIT = 25
  MAX_LIMIT = 100

  private
    def paginate(relation)
      pagy, records = pagy(:offset, relation, limit: DEFAULT_LIMIT, client_limit: MAX_LIMIT)
      response.headers.merge!(pagy.headers_hash)

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
