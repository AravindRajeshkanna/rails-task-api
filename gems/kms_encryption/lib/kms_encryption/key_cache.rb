module KmsEncryption
  # Unwrapped data keys, kept in memory for a short time so that reading many rows (or saving a record whose attribute was read) does not ask KMS
  # again for a key it just returned. Bounded in size (least recently used goes first) and in age: an access change in KMS takes effect for keys already
  # cached only after `ttl`. Failures are never cached.
  class KeyCache
    Entry = Struct.new(:value, :expires_at)

    def initialize(ttl:, size:, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
      @ttl = ttl
      @size = size
      @clock = clock
      @entries = {}
      @mutex = Mutex.new
    end

    def fetch(key)
      now = @clock.call
      cached = @mutex.synchronize do
        entry = @entries.delete(key)
        if entry && entry.expires_at > now
          @entries[key] = entry # reinserted last: most recently used
          entry.value
        end
      end
      return cached unless cached.nil?

      value = yield
      @mutex.synchronize do
        @entries[key] = Entry.new(value, now + @ttl)
        @entries.shift while @entries.size > @size
      end
      value
    end

    # Remember a value we already hold, without asking for it.
    def store(key, value)
      @mutex.synchronize do
        @entries.delete(key)
        @entries[key] = Entry.new(value, @clock.call + @ttl)
        @entries.shift while @entries.size > @size
      end
      value
    end

    def clear = @mutex.synchronize { @entries.clear }

    def size = @mutex.synchronize { @entries.size }
  end
end
