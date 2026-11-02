require "socket"

# Speaks just enough SMTP to take one message. It never advertises AUTH or STARTTLS.
class NoLoginRelay
  attr_reader :port, :received

  def initialize
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.addr[1]
    @received = Queue.new
    @thread = Thread.new { serve }
  end

  def stop
    @server.close
    @thread.kill
  end

  private
    def serve
      loop { handle(@server.accept) }
    rescue IOError, Errno::EBADF
      nil
    end

    def handle(client)
      client.print "220 relay ready\r\n"
      body = nil
      while (line = client.gets)
        if body
          next body << line unless line == ".\r\n"

          @received << body
          body = nil
          client.print "250 queued\r\n"
        elsif line.match?(/\A(EHLO|HELO)/i)
          client.print "250 relay\r\n"
        elsif line.match?(/\A(MAIL FROM|RCPT TO)/i)
          client.print "250 ok\r\n"
        elsif line.match?(/\ADATA/i)
          client.print "354 go\r\n"
          body = +""
        elsif line.match?(/\AQUIT/i)
          client.print "221 bye\r\n"
          break
        else
          client.print "502 not here\r\n"
        end
      end
    ensure
      client.close
    end
end
