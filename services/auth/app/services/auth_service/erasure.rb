module AuthService
  # Deletes the identity of a person the Task API has erased (ADR 79): the account, with its password digest and address, and every refresh token, which are
  # all this service holds of them. Found by the subject the Task API had linked (the JWT `sub`, our uid) and by the Task API's own id, which is
  # `legacy_id` on an account that was imported at the cutover and has not signed in since, so that the subject was never linked.
  #
  # Idempotent: an event delivered twice, or for someone this service never knew, deletes nothing the second time.
  module Erasure
    module_function

    # Returns :erased, or :unknown when there was no such identity (already deleted, never imported, or an account of the Task API's own).
    def call(subject: nil, legacy_id: nil)
      found = []
      found << User.where(uid: subject) if subject.present?
      found << User.where(legacy_id: legacy_id) if legacy_id.present?
      return :unknown if found.empty?

      users = found.reduce(:or)
      User.transaction { users.lock.to_a.each(&:destroy!).any? } ? :erased : :unknown
    end
  end
end
