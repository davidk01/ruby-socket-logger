#!/usr/bin/env ruby
require 'socket'
require 'fileutils'
require_relative './constants'

# Where we synchronize the state of the various clients
class LoggerState
  # A mutex and the state of the initial file
  def initialize
    @mutex, @line_count = Mutex.new, 0
    @log_file = open(LOG_PREFIX + Time.now.to_s.tr(' ', '_').tr(':', '_'), 'a')
  end

  # Re-open the file and reset the counter. Make sure to acquire the mutex
  def reset!
    return unless reset?
    @log_file.reopen(LOG_PREFIX + Time.now.to_s.tr(' ', '_').tr(':', '_'), 'a')
    @line_count = 0
  end

  # Do we need to reset?
  def reset?
    @line_count > LINE_COUNT_LIMIT
  end

  # Write the line and reset if we are over the line limit
  def write!(line)
    @mutex.synchronize do
      @log_file.write(line)
      @line_count += 1
      reset!
    end
  end

  # Fire a thread to handle the client
  def handle_client(client)
    Thread.new do
      while (log_line = client.readline)
        write!(log_line)
      end
    end
  end
end

begin
  # Daemonize
  Process.daemon(true)
  # If the socket file exists then we assume another server is running
  if File.exist?(DOMAIN_SOCKET)
    raise StandardError, "Socket file exists so assuming another server is running"
  end
  # Initial state
  state = LoggerState.new
  # Write the PID to a file
  open(PID_FILE, 'w') { |f| f.write Process.pid.to_s }
  # Start the server to accept clients
  UNIXServer.open(DOMAIN_SOCKET) do |s|
    # Trap termination signal and shutdown the socket
    Signal.trap("TERM") {
      s.shutdown(SHUTDOWN_MODE)
      FileUtils.rm_f(DOMAIN_SOCKET)
    }
    # This should throw an exception and terminate the loop when we get TERM signal
    loop { state.handle_client(s.accept) }
  end
rescue StandardError => e
  # If there are any exceptions then write them to a file
  open(ERROR_FILE, 'w') { |f| f.puts "#{e.class}: #{e}" }
end
