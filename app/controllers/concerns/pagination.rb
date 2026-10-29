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
