module Types
  # A person as other people see them: id and name, never the email address (like UserSummaryResource).
  class UserType < BaseObject
    graphql_name "User"
    field :id, ID, null: false
    field :name, String, null: false
  end
end
