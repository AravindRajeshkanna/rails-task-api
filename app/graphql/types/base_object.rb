module Types
  class BaseObject < GraphQL::Schema::Object
    include Scoping
  end
end
