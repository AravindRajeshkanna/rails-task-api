# A team has plain members and maintainers. A maintainer can add and remove the plain members of their own team (TeamMembershipPolicy); the
# role gives no access to any project, which comes only from the team's grants. NOT VALID first, validated in the next migration, so the
# constraint is added without a long lock on a table that could be large.
class AddRoleToTeamMemberships < ActiveRecord::Migration[8.1]
  def change
    add_column :team_memberships, :role, :string, null: false, default: "member"
    add_check_constraint :team_memberships, "role IN ('member', 'maintainer')", name: "team_memberships_role_valid", validate: false
  end
end
