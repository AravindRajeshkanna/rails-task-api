threads_count = ENV.fetch("RAILS_MAX_THREADS", 3)
threads threads_count, threads_count
port ENV.fetch("PORT", 3000)
plugin :tmp_restart

# Run the SQS consumer inside the Puma process, so /up, /healthz and /metrics describe the real worker.
plugin :notifications_consumer if ENV["NOTIFICATIONS_CONSUMER"] == "true"

pidfile ENV["PIDFILE"] if ENV["PIDFILE"]
