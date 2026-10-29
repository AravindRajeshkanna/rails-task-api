module Ai
  # Every model call goes through here: budget check, gateway call, ledger row, structured event.
  # The ledger also records failures (zero tokens) so error rates show up next to spend.
  class Runner
    def initialize(user: nil, project: nil, gateway: Gateway.current)
      @user = user
      @project = project
      @gateway = gateway
    end

    def run(feature, input) = call(feature) { @gateway.run(feature, input) }

    def converse(system:, messages:, tools: [], feature: "chat")
      call(feature) { @gateway.converse(system: system, messages: messages, tools: tools) }
    end

    def embed(text, feature: "embedding") = call(feature) { @gateway.embed(text) }

    private
      def call(feature)
        raise Disabled, "AI is not configured" unless @gateway.enabled?

        check_budget!

        Observability::Tracing.in_span("ai.#{feature}", attributes: { "gen_ai.operation.name" => feature, "gen_ai.system" => "aws.bedrock" }) do |span|
          result = begin
            yield
          rescue Error
            record(feature, nil, "error")
            raise
          end
          usage = result.usage
          span.add_attributes(
            "gen_ai.request.model" => usage.model_id.to_s, "gen_ai.usage.input_tokens" => usage.input_tokens.to_i,
            "gen_ai.usage.output_tokens" => usage.output_tokens.to_i
          )
          record(feature, usage, "ok")
          result
        end
      end

      def check_budget!
        Budget.new(user: @user, project: @project).check!
      rescue BudgetExceeded
        Rails.event.notify("ai.budget_exceeded", user_id: @user&.id, project_id: @project&.id)
        raise
      end

      def record(feature, usage, outcome)
        usage ||= AiCore::Usage.zero
        attributes = {
          user: @user, project: @project, feature: feature, outcome: outcome, model_id: usage.model_id,
          input_tokens: usage.input_tokens.to_i, output_tokens: usage.output_tokens.to_i,
          cost_micros: usage.cost_micros, latency_ms: usage.latency_ms
        }
        AiUsage.create!(attributes)

        Rails.event.notify("ai.completed", feature: feature, outcome: outcome, model_id: usage.model_id,
          input_tokens: attributes[:input_tokens], output_tokens: attributes[:output_tokens],
          cost_micros: attributes[:cost_micros], latency_ms: usage.latency_ms, user_id: @user&.id, project_id: @project&.id)
      end
  end
end
