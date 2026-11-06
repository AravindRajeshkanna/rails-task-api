class ValidateWebhooksRotationConsistent < ActiveRecord::Migration[8.1]
  def change
    validate_check_constraint :webhooks, name: "webhooks_rotation_consistent"
  end
end
