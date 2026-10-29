module V1
  # POST /v1/features/:name  { "input": { ... } }  ->  { "output": { ... }, "usage": { ... } }
  # The features (parse_task, suggest_priority, suggest_tags, summarize_project) and their input shapes
  # are defined in gems/ai_core and documented in docs/architecture/service-contracts.md.
  class FeaturesController < ApplicationController
    def create
      name = params[:name].to_s
      return render_error(:not_found, "unknown_feature", "Unknown feature #{name.inspect}") unless AiCore::Features::ALL.key?(name)

      result = AiService::Inference.call(name) { AiCore.client.run(name, json_object(:input)) }
      render json: { output: result.output, usage: result.usage.to_h }
    end
  end
end
