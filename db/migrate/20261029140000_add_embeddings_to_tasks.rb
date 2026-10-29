class AddEmbeddingsToTasks < ActiveRecord::Migration[8.1]
  # pgvector ships with Aurora/RDS PostgreSQL 15+ (CREATE EXTENSION vector); locally: brew install pgvector.
  # The dimension must match AI_EMBEDDING_DIMENSIONS (Titan Text Embeddings v2 default: 1024).
  def change
    enable_extension "vector"

    add_column :tasks, :embedding, :vector, limit: 1024
    add_column :tasks, :embedding_digest, :string # SHA-256 of the embedded text; unchanged text is not re-embedded
    add_column :tasks, :embedded_at, :datetime

    add_index :tasks, :embedding, using: :hnsw, opclass: :vector_cosine_ops
  end
end
