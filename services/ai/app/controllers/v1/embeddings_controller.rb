module V1
  # POST /v1/embeddings  { "text": "..." }  ->  { "vector": [...], "usage": { ... } }
  class EmbeddingsController < ApplicationController
    def create
      embedding = AiService::Inference.call("embedding") { AiCore.client.embed(params.require(:text).to_s) }
      render json: { vector: embedding.vector, usage: embedding.usage.to_h }
    end
  end
end
