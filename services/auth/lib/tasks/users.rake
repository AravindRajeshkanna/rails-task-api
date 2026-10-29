namespace :users do
  desc "Import users exported by the monolith (rake auth:export_users there): IN=users.jsonl. Safe to repeat."
  task import: :environment do
    path = ENV.fetch("IN") { abort "Usage: bin/rails users:import IN=users.jsonl" }
    created = updated = 0

    File.foreach(path) do |line|
      row = JSON.parse(line)
      user = User.find_by(legacy_id: row["legacy_id"]) || User.find_by(email_address: row["email_address"].to_s.strip.downcase) || User.new
      new_record = user.new_record?
      user.assign_attributes(legacy_id: row["legacy_id"], name: row["name"], email_address: row["email_address"])
      user.password_digest = row["password_digest"] # a bcrypt hash: users keep their password
      user.created_at = Time.iso8601(row["created_at"]) if new_record && row["created_at"]
      user.save!(validate: false)
      new_record ? created += 1 : updated += 1
    end

    puts "Imported #{created + updated} users (#{created} new, #{updated} updated). Delete #{path} now: it holds password hashes."
  end
end
