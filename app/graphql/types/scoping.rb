module Types
  # What every type and field needs: the signed-in user, and the policies' scopes.
  module Scoping
    def current_user = context.fetch(:current_user)

    # The records of +relation+ the current user may see: the same scope REST uses.
    def policy_scope(relation) = Pundit.policy_scope!(current_user, relation)
  end
end
