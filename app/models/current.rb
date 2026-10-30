class Current < ActiveSupport::CurrentAttributes
  attribute :session
  # The organization of the record the request is about, set when it is authorized (Api::V1::BaseController): what logs, traces and the
  # per-organization write budget are keyed by.
  attribute :organization_id
  delegate :user, to: :session, allow_nil: true
end
