module Ai
  # Stores a task's embedding. update_columns on purpose: re-embedding is bookkeeping, not an edit, so
  # it must not touch the project, bump lock_version, write an audit row or emit task.updated.
  module Embedder
    MAX_CHARS = 2_000

    module_function

    def text_for(task) = [ task.title, task.description ].compact_blank.join("\n").truncate(MAX_CHARS, omission: "")

    # Returns true when a new embedding was stored, false when the text had not changed.
    def call(task)
      text = text_for(task)
      digest = Digest::SHA256.hexdigest(text)
      return false if task.embedding_digest == digest && task.embedding.present?

      embedding = Runner.new(project: task.project).embed(text)
      # update_columns on purpose: saving would touch the project and re-enqueue this very job.
      task.update_columns(embedding: embedding.vector, embedding_digest: digest, embedded_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
      true
    end
  end
end
