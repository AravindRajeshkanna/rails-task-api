require "rails_helper"
require "open3"
require "tmpdir"

# The dump and restore-rehearsal scripts (deploy/scripts), run for real against the test database. They need pg_dump, pg_restore, createdb
# and dropdb at least as new as the server (pg_dump refuses an older client), which a CI runner with an older client lacks: the examples skip then.
RSpec.describe "deploy/scripts/db_dump.sh and db_restore_check.sh" do
  let(:config) { ActiveRecord::Base.connection_db_config.configuration_hash }
  let(:server_major) { ActiveRecord::Base.connection.select_value("show server_version_num").to_i / 10_000 }
  let(:dump_script) { Rails.root.join("deploy/scripts/db_dump.sh").to_s }
  let(:restore_script) { Rails.root.join("deploy/scripts/db_restore_check.sh").to_s }
  let(:dir) { Dir.mktmpdir("db-backup-spec") }

  after { FileUtils.remove_entry(dir) }

  before do
    client_major = `pg_dump --version 2>/dev/null`[/(\d+)(\.\d+)?/, 1].to_i
    skip "pg_dump (#{client_major}) is missing or older than the server (#{server_major})" if client_major.zero? || client_major < server_major
    skip "createdb or pg_restore is missing" unless system("command -v createdb pg_restore dropdb psql > /dev/null 2>&1")
  end

  def pg_env(extra = {})
    { "PGDATABASE" => config[:database], "PGHOST" => config[:host], "PGPORT" => config[:port]&.to_s, "PGUSER" => config[:username],
      "PGPASSWORD" => config[:password], "DUMP_DIR" => dir }.compact.merge(extra)
  end

  def run(script, *args, env: {})
    Open3.capture3(pg_env(env), script, *args)
  end

  it "writes a checked dump with its checksum, and the rehearsal restores it into a scratch database it then removes" do
    out, err, status = run(dump_script)

    expect(status).to be_success, err
    dump = out[/dump=(\S+)/, 1]
    expect(File.size(dump)).to eq(out[/bytes=(\d+)/, 1].to_i).and(be > 0)
    expect(File.read("#{dump}.sha256")).to eq("#{out[/sha256=(\h{64})/, 1]}  #{File.basename(dump)}\n")

    scratch = "db_backup_spec_#{Process.pid}"
    out, err, status = run(restore_script, dump, env: { "SCRATCH_DB" => scratch })

    expect(status).to be_success, err
    expect(out).to match(/restored in \d+s: users=\d+ projects=\d+ tasks=\d+/).and include("pgvector extension: present")
    expect(ActiveRecord::Base.connection.select_value("select count(*) from pg_database where datname = '#{scratch}'")).to eq(0)
  end

  it "refuses a dump of a database without the expected table, and keeps nothing" do
    _out, err, status = run(dump_script, env: { "EXPECT_TABLE" => "no_such_table" })

    expect(status).not_to be_success
    expect(err).to include("no table no_such_table")
    expect(Dir.children(dir).grep(/\.dump/)).to be_empty
  end

  it "keeps a verified dump when the upload fails, because it is the only copy" do
    bin = File.join(dir, "bin")
    FileUtils.mkdir_p(bin)
    File.write(File.join(bin, "aws"), "#!/bin/sh\necho refused >&2\nexit 1\n")
    FileUtils.chmod(0o755, File.join(bin, "aws"))

    _out, err, status = run(dump_script, "--upload", "s3://bucket/dumps/", env: { "PATH" => "#{bin}:#{ENV.fetch('PATH')}" })

    expect(status).not_to be_success
    expect(err).to include("the dump is kept at")
    expect(Dir.children(dir).grep(/\.dump\z/).size).to eq(1)
  end

  it "fails the rehearsal on a damaged dump and still removes its scratch database" do
    damaged = File.join(dir, "damaged.dump")
    File.binwrite(damaged, "PGDMP\x01\x0e\x00not a dump")
    scratch = "db_backup_spec_bad_#{Process.pid}"

    _out, _err, status = run(restore_script, damaged, env: { "SCRATCH_DB" => scratch })

    expect(status).not_to be_success
    expect(ActiveRecord::Base.connection.select_value("select count(*) from pg_database where datname = '#{scratch}'")).to eq(0)
  end
end
