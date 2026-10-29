# Pagy 43 global options. Controllers read ?page= and ?limit=.
# See app/controllers/concerns/pagination.rb for the per-request default (25) and cap (100).
Pagy::OPTIONS[:limit] = 25
Pagy::OPTIONS[:client_limit] = 100
Pagy::OPTIONS.freeze
