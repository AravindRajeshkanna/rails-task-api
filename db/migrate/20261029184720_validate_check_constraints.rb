# Second half of AddCheckConstraintsNotValid. VALIDATE CONSTRAINT scans the table but only takes a
# lock that lets reads and writes continue, which is why it is a separate step.
class ValidateCheckConstraints < ActiveRecord::Migration[8.1]
  def change
    AddCheckConstraintsNotValid::CHECKS.each do |table, constraints|
      constraints.each_key { |name| validate_check_constraint table, name: name }
    end
  end
end
