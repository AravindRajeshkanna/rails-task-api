module Types
  class CommentType < BaseObject
    graphql_name "Comment"
    field :id, ID, null: false
    field :body, String, null: false
    field :created_at, GraphQL::Types::ISO8601DateTime, null: false
    field :user, UserType, null: false

    def user = dataload_association(:user)
  end
end
