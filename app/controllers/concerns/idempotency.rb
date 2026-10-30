# Idempotency keys for the actions that create things (ADR 55). A client that times out cannot know whether its POST happened; if it retries
# it may create the thing twice, send the invitation email twice, or charge twice. With an Idempotency-Key it can retry safely:
#
#   POST /api/v1/projects/3/tasks   Idempotency-Key: 6f1c...   -> 201, the task is created
#   (the connection drops; the client retries the same request with the same key)
#                                                              -> 201, the SAME response, `Idempotent-Replayed: true`, no second task
#
#   * Opt in per action (`idempotent :create`): explicit over implicit, and never for sign-in, registration or password reset, whose responses hold
#     credentials that must not be stored.
#   * The key is the caller's own (unique per user), at most 255 visible ASCII characters; the header is optional.
#   * The same key with a different method, path, query or body is refused (422 idempotency_key_reused): it would otherwise replay an answer to a
#     different question.
#   * A request that arrives while the first is still running is refused (409 idempotency_in_progress, with Retry-After): replaying would answer
#     before there is an answer. A claim that has been in progress for a minute is taken over (the worker died).
#   * Only a success (2xx) is remembered, and it is recorded in the same transaction as the write, so there is never a stored answer for a write that
#     rolled back, nor a committed write with no stored answer. A failure (validation, authorization, a 500) releases the key so the retry runs again.
module Idempotency
  extend ActiveSupport::Concern

  HEADER = "Idempotency-Key".freeze

  class_methods do
    def idempotent(*actions) = around_action(:with_idempotency, only: actions)
  end

  private
    def with_idempotency(&)
      key = request.headers[HEADER].presence
      return yield unless key

      raise InvalidParameterError.new(HEADER, "#{HEADER} must be 1-#{IdempotencyKey::MAX_KEY_LENGTH} visible ASCII characters, without spaces") unless IdempotencyKey.valid_key?(key)

      outcome, record = IdempotencyKey.claim(user_id: current_user.id, key: key, fingerprint: request_fingerprint)
      case outcome
      when :replay then replay(record)
      when :mismatch then refuse_idempotent("idempotency_key_reused", :unprocessable_content, "This #{HEADER} was used for a different request. Use a new key for a new request.")
      when :in_progress then refuse_idempotent("idempotency_in_progress", :conflict, "A request with this #{HEADER} is still being processed. Retry shortly.", retry_after: 1)
      else run_once(record, &)
      end
    end

    # The write and the record of its answer commit or roll back together. Anything but a 2xx releases the key.
    def run_once(record)
      stored = false
      ActiveRecord::Base.transaction do
        yield
        raise ActiveRecord::Rollback unless response.successful?

        record.complete!(status: response.status, body: response.body)
        stored = true
      end
      stored ? Rails.event.notify("idempotency.stored", source: "request") : release(record)
    rescue StandardError
      release(record)
      raise
    end

    def release(record) = IdempotencyKey.where(id: record.id).delete_all

    # No policy runs for a replay or a refusal, deliberately: nothing is read or changed. A replay is the caller's own earlier answer to the identical
    # request (the key is theirs and the fingerprint matches), so it shows them nothing they were not already sent, even if their access has since gone.
    def replay(record)
      skip_authorization
      Rails.event.notify("idempotency.replayed", source: "request")
      response.headers["Idempotent-Replayed"] = "true"
      render json: record.response_body.presence || "", status: record.response_status
    end

    def refuse_idempotent(code, status, message, retry_after: nil)
      skip_authorization
      Rails.event.notify("idempotency.refused", source: code)
      response.headers["Retry-After"] = retry_after.to_s if retry_after
      render_error status, code, message
    end

    # What the request asked, byte for byte: the method, the path and query, and the body.
    def request_fingerprint
      OpenSSL::Digest::SHA256.hexdigest([ request.request_method, request.fullpath, request.raw_post ].join("\n"))
    end
end
