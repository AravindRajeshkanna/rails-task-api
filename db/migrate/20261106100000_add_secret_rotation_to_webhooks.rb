# A webhook's signing secret can be replaced without a moment when the receiver rejects the events (ADR 78). `next_secret` is the secret being rotated in: it
# signs every delivery next to the current one until the project's admin promotes it (then it becomes `secret`) or cancels. `rotation_started_at` says there
# is one without reading, and so decrypting, it: the list of webhooks and every serializer ask `rotating`, and none of them should call KMS for that. The two
# are set and cleared together; NOT VALID first, validated in the next migration, as for any constraint on a table that could be large.
class AddSecretRotationToWebhooks < ActiveRecord::Migration[8.1]
  def change
    add_column :webhooks, :next_secret, :text
    add_column :webhooks, :rotation_started_at, :datetime
    add_check_constraint :webhooks, "(next_secret IS NULL) = (rotation_started_at IS NULL)", name: "webhooks_rotation_consistent", validate: false
  end
end
