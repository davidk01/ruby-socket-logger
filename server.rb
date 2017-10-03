#!/usr/bin/env ruby
require 'socket'
require 'fileutils'
require 'time'
require_relative './constants'

# Where we synchronize the state of the various clients
class LoggerState
  # A mutex and the state of the initial file
  def initialize
    # When we write to the file we need to lock and unlock to prevent overlap
    @mutex = Mutex.new
    # We keep track of the counter in another thread with this pipe
    @r, @w = IO.pipe
    # Initial log file
    @log_file = open(LOG_PREFIX + DateTime.now.strftime('%Y-%j-%H-%M-%S-%N'), 'a')
    # Thread for counting the lines and rotating the log file
    @monitoring_thread = Thread.new do
      line_count = 0
      loop do
        begin
          bytes = @r.read_nonblock(1_000)
          line_count += bytes.length
          if line_count > LINE_COUNT_LIMIT
            @mutex.synchronize do
              rotate
              line_count = 0
            end
          end
        rescue IO::WaitReadable
          IO.select([@r])
        end
      end
    end
  end

  # Rotate the log file
  def rotate
    flush
    close
    reopen
  end

  # Flush everything to disk
  def flush
    @log_file.flush
  end

  # Close the log file
  def close
    @log_file.close
  end

  # Re-open the file with a new timestamp
  def reopen
    @log_file.reopen(LOG_PREFIX + DateTime.now.strftime('%Y-%j-%H-%M-%S-%N'), 'a')
  end

  # Write the line or bytes and then send the count of the number of newline
  # characters to the pipe so that the monitoring thread can rotate the log
  # if necessary
  def write!(log_bytes)
    @mutex.synchronize do
      @log_file.write(log_bytes)
    end
    # This needs to be outside because we can get into a deadlock if
    # the write is inside the synchronized block. Hint: think about what
    # happens when '@w.write' blocks while we still have the lock
    line_count = log_bytes.scan("\n").length
    @w.write(LINE_COUNTER_INDICATOR * line_count) if line_count > 0
  end

  # Fire a thread to handle the client
  def handle_client(client)
    Thread.new do
      begin
        counter = 0
        loop do
          log_bytes = client.readline
          counter += 1
          begin
            write!(log_bytes)
          rescue StandardError => e
            open(ERROR_FILE, 'a') { |f| f.puts "Could not write to log file: #{e}" }
          end
        end
      rescue StandardError => e
        open(ERROR_FILE, 'a') { |f| f.puts "Client error: #{e}" }
        # Give up on the client if we get an error
        flush
        client.close
      end
    end
  end
end

begin
  # Daemonize
  # Process.daemon(true)
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
  open(ERROR_FILE, 'a') { |f| f.puts "#{e.class}: #{e}" }
  # Flush and close the log file when we get a TERM signal.
  # Note that we can have clients in flight and we don't gracefully
  #  handle shutting them down and flushing their results to disk
  state.flush
  state.close
end
