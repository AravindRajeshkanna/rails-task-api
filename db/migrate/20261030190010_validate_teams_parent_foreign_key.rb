class ValidateTeamsParentForeignKey < ActiveRecord::Migration[8.1]
  def change
    validate_foreign_key :teams, :teams, column: :parent_id
  end
end
