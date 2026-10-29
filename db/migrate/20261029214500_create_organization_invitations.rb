# An invitation is how someone joins an organization: an administrator names an email address, the
# address receives a link, and whoever signs in as that address and presents the link becomes a member.
# The API never says whether the address belongs to a registered user.
#
# There is no token column: the link carries a signed, expiring token derived from the row
# (OrganizationInvitation.generates_token_for), so nothing secret is stored or queued.
class CreateOrganizationInvitations < ActiveRecord::Migration[8.1]
  def change
    create_table :organization_invitations do |t|
      t.references :organization, null: false, foreign_key: true
      # Whoever sent it; the invitation outlives their account.
      t.references :invited_by, foreign_key: { to_table: :users, on_delete: :nullify }
      t.string :email_address, null: false
      t.string :role, null: false, default: "member"
      t.datetime :expires_at, null: false
      t.datetime :accepted_at
      t.datetime :revoked_at

      t.timestamps
    end
    # One open invitation per address and organization; sending again refreshes it.
    add_index :organization_invitations, %i[organization_id email_address], unique: true,
      where: "accepted_at IS NULL AND revoked_at IS NULL", name: "index_organization_invitations_pending"
    add_index :organization_invitations, :email_address
    add_check_constraint :organization_invitations, "role IN ('member', 'admin', 'owner')", name: "organization_invitations_role_valid"
    add_check_constraint :organization_invitations, "char_length(btrim(email_address)) > 0", name: "organization_invitations_email_present"
  end
end
