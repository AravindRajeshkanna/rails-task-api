module Types
  # The signed-in person, who may see their own email address.
  class ViewerType < UserType
    graphql_name "Viewer"
    field :email_address, String, null: false
  end
end
