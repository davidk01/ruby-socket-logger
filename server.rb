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
    @log_file = open(log_string, 'a')
    # We are not initially stopped and can process client requests
    @stop = false
    # The symbol we use to mark threads belonging to the logging server. This
    # is unique per instance so we can in theory have multiple logger instances
    # and shut down each one without messing with the threads of the other
    @marker = object_id.to_s.to_sym
    # Name for the monitoring thread
    @monitoring_name = "monitor-#{@marker}".to_sym
    # Name for the client handlers
    @handler_name = "handler-#{@marker}".to_sym
    # Thread for counting the lines and rotating the log file
    @monitoring_thread = Thread.new { monitoring_loop }
  end

  # Find all the threads belonging to this instance of the logging server
  def logging_threads
    Thread.list.select { |t| t[@marker] }
  end

  # Mark the current thread as a logging thread so that when we are shutting
  # down the server we can try to do it gracefully by finding the threads we
  # spawned and then asking them to shut down or killing them if they take
  # a long time
  def mark(name: nil)
    Thread.current[@marker] = true
    # We can name the threads as well for easier debugging
    Thread.current[:name] = name if name
  end

  # When the server is shutting down we set this variable to true so that
  # threads belonging to this logger can check it and start their shutdown
  # sequence
  def stopped?
    @stop
  end

  # We are shutting down so we set '@stop'. Active threads will check
  # and start their own shut down process
  def stop!
    @stop = true
  end

  # What we execute in the monitoring thread to rotate log files
  def monitoring_loop
    # Mark this thread as a monitoring thread
    mark(name: @monitoring_name)
    # We start with 0 lines
    line_count = 0
    # An infinite loop for reading from the in-process pipe
    loop do
      # Stop counting things if we are shutting down
      return if stopped?
      begin
        # We read in a non-blocking manner but not for any particular reason.
        # We could also read in a blocking manner without any issues (I think)
        bytes = @r.read_nonblock(1_000)
        # However many bytes we read that's how many lines we add to the counter
        line_count += bytes.length
        # We are over the limit so acquire the mutex and rotate the log file
        if line_count > LINE_COUNT_LIMIT
          @mutex.synchronize do
            rotate
            line_count = 0
          end
        end
      rescue IO::WaitReadable
        # Wait for the pipe to be readable again but time out after 1 second
        # so that we can go back to the top of the loop and terminate if we
        # are stopping. Otherwise we get stuck in a sleep here and have to
        # wait 10 seconds to get killed
        IO.select([@r], [], [], 1)
      end
    end
  end

  # The current time formatted as we expect
  def time_string
    DateTime.now.strftime(TIME_FORMAT_STRING)
  end

  # When we open or rotate log segments we need a properly formatted
  # file path string. This gives us that string
  def log_string
    LOG_PREFIX + time_string
  end

  # Rotate the log file. We flush and close just to make sure everything gets
  # written to disk. This is not safe to do without acquiring a lock so make
  # sure to acquire a lock before calling rotate
  def rotate
    flush
    close
    reopen
  end

  # Flush everything to disk. Not safe if the lock is not acquired
  def flush
    @log_file.flush
  end

  # Close the log file. Same as above, not safe without lock
  def close
    @log_file.close
  end

  # Re-open the file with a new timestamp. Note that if we write quickly enough
  # it is possible we will re-open the same file but in practice this is not
  # such a big deal. Not safe if done without acquiring the lock
  def reopen
    @log_file.reopen(log_string, 'a')
  end

  # Logs errors to an error file
  def log_error(error)
    open(ERROR_FILE, 'a') { |f| f.puts error.to_s }
  end

  # Write the line or bytes and then send the count of the number of newline
  # characters to the pipe so that the monitoring thread can rotate the log
  # if necessary
  def write!(log_bytes)
    # Acquire the mutex and write some bytes to the log file
    @mutex.synchronize { @log_file.write(log_bytes) }
    # This needs to be outside the mutex because we can get into a deadlock if
    # the write is inside the synchronized block. Hint: think about what
    # happens when '@w.write' blocks while we still have the lock
    line_count = log_bytes.scan("\n").length
    # If we had any newline characters then we ship that many '0' bytes to the
    # monitoring thread so that it can increment its internal counter and decide
    # when to rotate the log
    @w.write(LINE_COUNTER_INDICATOR * line_count) if line_count > 0
  end

  # Start a thread to handle the client that wants to log some lines
  def handle_client(client)
    Thread.new do
      # Mark it as a monitoring thread so we can iterate through the active
      # threads and shut down the ones that belong to the logging server
      mark(name: @handler_name)
      begin
        # Keep trying to read a line from the client until it goes away
        loop do
          # If :stop thread local variable is set then that means we are shutting
          # down so tell the client to go away. We raise an exception and let
          # the exception handling logic do its thing
          raise StandardError, "Shutting down" if stopped?
          # Get a line
          log_bytes = client.readline
          # Write it to the log
          write!(log_bytes)
        end
      rescue StandardError => e
        # Something bad happend or client just went away
        log_error("Client error: #{e}")
        # Just flush and tell the client to go away. This is not very nice
        # from the clients perspective but good enough for now
        flush
        client.close
      end
    end
  end

  # The logging server loop
  def self.start_server_loop(daemonize: false)
    # We will run in the background if requested. Otherwise foreground
    Process.daemon(true) if daemonize
    # If the socket file exists then we assume another server is running and bail
    if File.exist?(DOMAIN_SOCKET)
      raise StandardError, "Socket file exists so assuming another server is running"
    end
    # Initialize the logger
    state = new
    # Write our PID to a file so others can send us signals
    open(PID_FILE, 'w') { |f| f.write Process.pid.to_s }
    # Start the domain socket server to accept clients
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
    # getting TERM signal and shutting down the server
    state.log_error("#{e.class}: #{e}")
    # We are no longer accepting any client connections so set the stop criterion
    # to tell any logging threads belong to this logger to terminate
    state.stop!
    # Give the logging threads belonging to this instance some time to terminate
    logging_threads = state.logging_threads
    # Wait for up to 10 seconds for termination
    10.times do |i|
      break unless logging_threads.any?(&:alive?)
      state.log_error("There are still active logging threads: #{i}-th try")
      sleep 1
    end
    # We waited 10 seconds so now try to stop them ungracefully. In theory this
    # should be a no-op
    logging_threads.each(&:kill)
    # At this point we should not have any more clients so we can flush and close
    # the log file. We probably should acquire a mutex but everything should be
    # stopped at this point
    state.flush
    state.close
  end
end

# Main server loop
LoggerState.start_server_loop(daemonize: true)
