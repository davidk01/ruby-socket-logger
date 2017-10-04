#!/usr/bin/env ruby
%w[socket fileutils time].each { |r| require r }
require_relative './constants'

# Where we synchronize the state of the various clients
class LoggerState
  # A mutex, a pipe, a monitoring thread, and the state of the initial file
  def initialize
    # When we write to the file we need to lock and unlock to prevent overlap
    @mutex = Mutex.new
    # We keep track of the counter in another thread with this pipe.
    # As clients write lines we ship '0' to this pipe and then read
    # them in the monitoring thread and increment the line counter accordingly
    @r, @w = IO.pipe
    # Initial log file
    @log_file = open(LOG_PREFIX + DateTime.now.strftime('%Y-%j-%H-%M-%S-%N'), 'a')
    # Thread for counting the lines and rotating the log file
    @monitoring_thread = Thread.new do
      # We start with 0 lines
      line_count = 0
      # An infinite loop for reading from the in-process pipe
      loop do
        # If :stop thread local variable is set then we terminate the loop. This
        # is used for somewhat graceful termination of the server
        return if Thread.current[:stop]
        begin
          # We read in a non-blocking manner
          bytes = @r.read_nonblock(1_000)
          # However many bytes we read that's how many lines we add to the counter
          line_count += bytes.length
          # We are over the limit so acquire the mutex and rotate the log file
          if line_count > LINE_COUNT_LIMIT
            @mutex.synchronize do
              rotate
              # Reset the counter
              line_count = 0
            end
          end
        rescue IO::WaitReadable
          # Wait for the pipe to be readable again
          IO.select([@r])
        end
      end
    end
  end

  # Rotate the log file. We flush and close just to make sure everything gets
  # written to disk
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

  # Re-open the file with a new timestamp. Note that if we write quickly enough
  # it is possible we will re-open the same file but in practice this is not
  # such a big deal
  def reopen
    @log_file.reopen(LOG_PREFIX + DateTime.now.strftime('%Y-%j-%H-%M-%S-%N'), 'a')
  end

  # Write the line or bytes and then send the count of the number of newline
  # characters to the pipe so that the monitoring thread can rotate the log
  # if necessary
  def write!(log_bytes)
    # Acquire the mutex and write some bytes to the log file
    @mutex.synchronize do
      @log_file.write(log_bytes)
    end
    # This needs to be outside the mutex because we can get into a deadlock if
    # the write is inside the synchronized block. Hint: think about what
    # happens when '@w.write' blocks while we still have the lock
    line_count = log_bytes.scan("\n").length
    # If we had any newline characters then we ship that many '0' bytes to the
    # monitoring thread so that it can increment its internal counter and decide
    # when to rotate the log
    @w.write(LINE_COUNTER_INDICATOR * line_count) if line_count > 0
  end

  # Fire a thread to handle the client that wants to log some lines
  def handle_client(client)
    Thread.new do
      begin
        # Keep trying to read a line from the client until it goes away
        loop do
          # If :stop thread local variable is set then that means we are shutting
          # down so tell the client to go away. We raise an exception and let
          # the exception handling logic do its thing
          raise StandardError, "Shutting down" if Thread.current[:stop]
          # Get a line
          log_bytes = client.readline
          # Write it to the log
          write!(log_bytes)
        end
      rescue StandardError => e
        # Something bad happend or client just went away
        open(ERROR_FILE, 'a') { |f| f.puts "Client error: #{e}" }
        # Just flush and tell the client to go away. This is not very
        # graceful but good enough for now
        flush
        client.close
      end
    end
  end
end

# Main server loop
begin
  # Daemonize. We will run in the background
  Process.daemon(true)
  # If the socket file exists then we assume another server is running and bail
  if File.exist?(DOMAIN_SOCKET)
    raise StandardError, "Socket file exists so assuming another server is running"
  end
  # Initialize the logger
  state = LoggerState.new
  # Write our PID to a file so someone can send us a TERM signal
  open(PID_FILE, 'w') { |f| f.write Process.pid.to_s }
  # Start the unix domain socket server to accept clients
  UNIXServer.open(DOMAIN_SOCKET) do |s|
    # Trap TERM signal and shut down the server. If there are clients that
    # are still trying to write then we try to nicely to tell them to go away
    # by sending the shutdown signal to the client handlers
    Signal.trap("TERM") {
      s.shutdown(SHUTDOWN_MODE)
      FileUtils.rm_f(DOMAIN_SOCKET)
    }
    # This is the acceptance and client processing loop but when we get a TERM
    # signal we terminate the server so 's.accept' will throw an exception and
    # terminate the loop
    loop { state.handle_client(s.accept) }
  end
rescue StandardError => e
  # If there are any exceptions then write it to a file. This also includes
  # getting TERM signal and shutting down the unix domain socket server
  open(ERROR_FILE, 'a') { |f| f.puts "#{e.class}: #{e}" }
  # Assuming we are no longer acception any client connections so send the client
  # termination signal
  Thread.list.each { |t| t[:stop] = true }
  # See if we have any live threads and sleep some amount of time to give the
  # termination signal time to propagate
  sleep 1 if Thread.list.any?(&:alive?)
  # At this point we should not have any more clients so we can flush and close
  # the log file
  state.flush
  state.close
end
