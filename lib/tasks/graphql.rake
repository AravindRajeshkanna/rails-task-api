namespace :graphql do
  namespace :schema do
    desc "Write the GraphQL schema (SDL) to docs/graphql/schema.graphql; CI fails if the committed copy is stale"
    task dump: :environment do
      path = Rails.root.join("docs/graphql/schema.graphql")
      File.write(path, TaskApiSchema.to_definition)
      puts "Wrote #{path.relative_path_from(Rails.root)}"
    end
  end
end
