namespace :auth do
  desc "Write users as JSON lines for the Auth service's import task (OUT=users.jsonl). Contains password hashes: treat as a secret."
  task export_users: :environment do
    path = ENV.fetch("OUT", "users.jsonl")
    count = 0
    File.open(path, "w", 0o600) do |file|
      User.where(auth_subject: nil).where.not(password_digest: nil).find_each do |user|
        file.puts({
          legacy_id: user.id, name: user.name, email_address: user.email_address,
          password_digest: user.password_digest, created_at: user.created_at.iso8601
        }.to_json)
        count += 1
      end
    end
    puts "Wrote #{count} users to #{path} (mode 0600). Import with: bin/rails auth:import_users IN=#{path} (in services/auth), then delete the file."
  end

  desc "Users not yet linked to the Auth service (they link themselves on first login via legacy_id)"
  task status: :environment do
    puts "linked: #{User.where.not(auth_subject: nil).count}, waiting to link: #{User.where(auth_subject: nil).count}"
  end
end
