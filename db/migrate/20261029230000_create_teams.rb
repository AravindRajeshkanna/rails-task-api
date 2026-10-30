# Teams: named groups of an organization's members that a project can grant access to as a unit.
#
#   teams              belong to an organization; names are unique within it, ignoring case
#   team_memberships   a user in a team (the user must be in the team's organization; the models and
#                      OrganizationMembership keep that true)
#   project_teams      a team's access to a project, with a role (member or admin); only projects of
#                      the team's own organization can be granted (checked by the model)
class CreateTeams < ActiveRecord::Migration[8.1]
  def change
    create_table :teams do |t|
      t.references :organization, null: false, foreign_key: true
      t.string :name, null: false

      t.timestamps
    end
    add_index :teams, "organization_id, lower(name)", unique: true, name: "index_teams_on_organization_id_and_lower_name"
    add_check_constraint :teams, "char_length(btrim(name)) > 0", name: "teams_name_present"

    create_table :team_memberships do |t|
      t.references :team, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true

      t.timestamps
    end
    add_index :team_memberships, %i[team_id user_id], unique: true

    create_table :project_teams do |t|
      t.references :project, null: false, foreign_key: true
      t.references :team, null: false, foreign_key: true
      t.string :role, null: false, default: "member"

      t.timestamps
    end
    add_index :project_teams, %i[project_id team_id], unique: true
    add_check_constraint :project_teams, "role IN ('member', 'admin')", name: "project_teams_role_valid"
  end
end
