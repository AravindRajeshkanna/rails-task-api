# The delivery log names who was sent what by address, which cannot be found again once a person asks to be forgotten: the address is the one thing the
# Task API's erasure no longer has (ADR 79). The id the event carries for its recipient (`data.recipient.id`: the Task API's user id for a task event, the
# Auth service's uid for a password reset) is kept next to it, and `user.erased` deletes by that. Rows written before this migration have none and age out
# under the 90-day retention. A string, because the two services' ids are different kinds. The index is built without blocking writes.
class AddRecipientIdToDeliveries < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_column :deliveries, :recipient_id, :string
    add_index :deliveries, :recipient_id, algorithm: :concurrently, where: "recipient_id IS NOT NULL"
  end
end
