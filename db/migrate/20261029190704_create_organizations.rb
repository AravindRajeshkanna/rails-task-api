# An organization groups people and projects. Its members have a role in it (owner, admin, member);
# owners and admins automatically administer every project of the organization (see ProjectPolicy).
class CreateOrganizations < ActiveRecord::Migration[8.1]
  def change
    create_table :organizations do |t|
      t.string :name, null: false

      t.timestamps
    end
    add_check_constraint :organizations, "char_length(btrim(name)) > 0", name: "organizations_name_present"

    create_table :organization_memberships do |t|
      t.references :organization, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.string :role, null: false, default: "member"

      t.timestamps
    end
    add_index :organization_memberships, %i[organization_id user_id], unique: true
    add_check_constraint :organization_memberships, "role IN ('member', 'admin', 'owner')", name: "organization_memberships_role_valid"
  end
end
