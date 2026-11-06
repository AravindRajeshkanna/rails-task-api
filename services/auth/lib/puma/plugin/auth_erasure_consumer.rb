require "puma/plugin"

# Runs the erasure consumer in a thread of the Puma process (AUTH_ERASURE_CONSUMER=true), so the pod has one process whose /up and /metrics describe the
# real work. Stops cleanly on shutdown: the current batch finishes and unfinished messages simply become visible again.
Puma::Plugin.create do
  def start(launcher)
    consumer = nil
    thread = nil

    launcher.events.after_booted do
      consumer = AuthService::ErasureConsumer.new
      thread = Thread.new do
        Thread.current.name = "erasure-consumer"
        Rails.application.executor.wrap { consumer.run }
      rescue Exception => error # rubocop:disable Lint/RescueException
        AuthService::ErasureConsumer.report_crash(error)
        Process.kill("TERM", Process.pid) # let Kubernetes restart the pod
      end
    end

    launcher.events.after_stopped do
      consumer&.stop
      thread&.join(30)
    end
  end
end
