# The model validates all of this, but validations only guard the paths that go through
# the model: insert_all, update_columns, a console session and any future service writing
# to the same database skip them. These constraints make the database the last line of defense.
#
# Added NOT VALID: PostgreSQL enforces them for new writes immediately but does not scan the
# table (and hold a lock) to check old rows. The next migration validates them.
class AddCheckConstraintsNotValid < ActiveRecord::Migration[8.1]
  CHECKS = {
    tasks: {
      tasks_status_valid: "status IN (0, 1, 2)",
      tasks_priority_valid: "priority IN (0, 1, 2, 3)",
      tasks_title_present: "char_length(btrim(title)) > 0",
      tasks_counters_non_negative: "comments_count >= 0 AND lock_version >= 0"
    },
    projects: { projects_name_present: "char_length(btrim(name)) > 0" },
    tags: { tags_name_present: "char_length(btrim(name)) > 0" },
    comments: { comments_body_present: "char_length(btrim(body)) > 0" },
    users: {
      users_name_present: "char_length(btrim(name)) > 0",
      users_email_present: "char_length(btrim(email_address)) > 0"
    },
    memberships: { memberships_role_valid: "role IN ('member', 'admin')" },
    ai_usages: { ai_usages_counts_non_negative: "input_tokens >= 0 AND output_tokens >= 0 AND cost_micros >= 0" }
  }.freeze

  def change
    CHECKS.each do |table, constraints|
      constraints.each do |name, expression|
        add_check_constraint table, expression, name: name, validate: false
      end
    end
  end
end
