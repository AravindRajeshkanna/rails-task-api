module Analyzers
  # A request may carry one mutation. The API's rate limit counts requests, and over REST one request is one write; without this, a single
  # GraphQL request could do as many writes as its complexity budget allows (`mutation { a: createTask(...) b: createTask(...) ... }`).
  class OneWritePerRequest < GraphQL::Analysis::Analyzer
    def initialize(query)
      super
      @root_fields = 0
    end

    def analyze? = query.mutation?

    def on_enter_field(_node, _parent, visitor)
      @root_fields += 1 if visitor.parent_type_definition == query.schema.mutation
    end

    def result
      return if @root_fields <= 1

      GraphQL::AnalysisError.new("A request can carry one mutation (it has #{@root_fields}); send them as separate requests")
    end
  end
end
