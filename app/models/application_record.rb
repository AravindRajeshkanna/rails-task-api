class ApplicationRecord < ActiveRecord::Base
  primary_abstract_class

  # Where a replica is configured (production with DB_REPLICA_HOST; development and test always, pointing at the same database) there is a reading role
  # that ReplicaRouting can switch a request to. Without one, none of that exists and every read goes to the primary.
  connects_to database: { writing: :primary, reading: :primary_replica } if ActiveRecord::Base.configurations.configs_for(env_name: Rails.env, name: "primary_replica", include_hidden: true)
end
