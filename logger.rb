#!/usr/bin/env ruby
%w[socket fileutils time].each { |r| require r }

# All the code for the logging server
class LoggerServer
  # Where do we drop the pid file for the server
  PID_FILE = File.join(starting_dir = Dir.pwd, 'ruby-logger.pid').freeze
  # Where do we write errors. Must be careful and rotate this as well
  ERROR_FILE = File.join(starting_dir, 'ruby-logger.error').freeze
  # Where should clients connect to
  DOMAIN_SOCKET = File.join(starting_dir, 'ruby-logger.sock').freeze
  # Folder plus the initial part of the log file
  LOG_PREFIX = File.join(starting_dir, 'ruby-log').freeze
  # How many lines (approximately) in a log file before we rotate it
  LINE_COUNT_LIMIT = 10_000
  # When we shut down the unix domain server we need a mode of shutdown
  SHUTDOWN_MODE = :RDWR
  # Mostly an implementaiton detail and can be ignored
  LINE_COUNTER_INDICATOR = '0'.freeze
  # The time stamp we add to the log files the server writes to
  TIME_FORMAT_STRING = '%Y-%j-%H-%M-%S-%N'.freeze
  # Number of active clients we are willing to deal with before we turn
  # away new clients
  CLIENT_LIMIT = 50

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
    Thread.list.select { |t| t[@marker] }.select(&:alive?)
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
  def self.time_string
    DateTime.now.strftime(TIME_FORMAT_STRING)
  end

  # Delegate to class method
  def time_string
    self.class.time_string
  end

  # When we open or rotate log segments we need a properly formatted
  # file path string. This gives us that string
  def self.log_string
    LOG_PREFIX + time_string
  end

  # Delegate to class method
  def log_string
    self.class.log_string
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

  # Logs errors to an error file. We truncate the file when we go over
  # the block size limit. Errors should be rare and so the truncation should
  # not be a problem. This keeps the error file bounded.
  def self.log_error(error)
    line = "#{time_string}: #{error}"
    open(ERROR_FILE, 'a') { |l| l.puts line }
    stats = File.stat(ERROR_FILE)
    if stats.size > 2 * stats.blksize # rubocop:disable Style/GuardClause
      f = open(ERROR_FILE, 'w')
      f.truncate(0)
      f.close
      # We lose the last write when we truncate so we have to do it again
      open(ERROR_FILE, 'a') { |l| l.puts line }
    end
  end

  # Instance method that delegates to class method
  def log_error(error)
    self.class.log_error(error)
  end

  # Write the line or bytes and then send the count of the number of newline
  # characters to the pipe so that the monitoring thread can rotate the log
  # if necessary
  def write!(log_bytes)
    # Acquire the mutex and write some bytes to the log file
    @mutex.synchronize {
      @log_file.write(log_bytes)
    }
    # This needs to be outside the mutex because we can get into a deadlock if
    # the write is inside the synchronized block. Hint: think about what
    # happens when '@w.write' blocks while we still have the lock. But this
    # means due to vagaries of thread scheduling we might get into a situation
    # where we don't increment the counter quickly enough and overflow
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
          # There is an interesting failure mode here. What happens if the clients
          # are slow and start stacking up? At some point we will just come to a
          # screeching halt. One way out of this conundrum is to limit how many
          # clients we can deal with at a time and turn away new ones when we
          # reach a certain number of active clients. This is the solution we
          # implement in the server loop. We turn away clients when they go
          # over a limit
          log_bytes = client.readline
          write!(log_bytes)
        end
      rescue StandardError => e
        # Something bad happend or client just went away
        log_error("Client error: #{e.class}: #{e}")
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
    # Track the number of active clients
    client_count = 0
    # Start the domain socket server to accept clients
    UNIXServer.open(DOMAIN_SOCKET) do |s|
      # Trap TERM signal and shut down the server. If there are clients that
      # are still trying to write then we try to nicely to tell them to go away
      Signal.trap("TERM") {
        state.stop!
        s.shutdown(SHUTDOWN_MODE)
      }
      # This is the acceptance and client processing loop but when we get a TERM
      # signal we terminate the server so 's.accept' will throw an exception and
      # terminate the loop. We also keep track of the number of clients and terminate
      # new clients when we are over the limit of the number of threads we are
      # willing to handle.
      loop {
        state.handle_client(client = s.accept)
        client_count += 1
        next unless client_count > CLIENT_LIMIT
        # This count is inaccurate because there is a race condition between
        # starting the threads and when they get marked. So if enough clients
        # connect quickly enough then we can overflow our limit and erroneously
        # accept more clients. Only way I can think of to keep a true count is to use
        # atomic counter to increment and decrement the counter when threads start
        # and when they finish
        client_count = state.logging_threads.length
        if client_count > CLIENT_LIMIT
          client.close
          state.log_error("Throttling clients: #{client_count} > #{CLIENT_LIMIT}")
        end
      }
    end
  rescue StandardError => e
    # We are no longer accepting any client connections so set the stop criterion
    # to tell any logging threads that belong to this logger to terminate. We also
    # set this when handling TERM signal
    state.stop!
    # Log the exception to a file so we can know what happened
    state.log_error("#{e.class}: #{e}")
    # Give the logging threads belonging to this instance some time to terminate
    logging_threads = state.logging_threads
    # Wait for up to 10 seconds for termination
    10.times do |i|
      break unless logging_threads.any?
      state.log_error("There are still active logging threads: #{i}-th try")
      sleep 1
    end
    # We waited 10 seconds so now try to stop them ungracefully. In theory this
    # should be a no-op
    logging_threads.each(&:kill)
  ensure
    # At this point we should not have any more clients so we can flush and close
    # the log file. We probably should acquire a mutex but everything should be
    # stopped at this point so we are willing to let any active clients to disconnect
    # ungracefully
    state.flush
    state.close
    FileUtils.rm_f(DOMAIN_SOCKET)
  end
end

# All the code for the logging client
class LoggerClient
  # We need to know what socket we will connect to
  def initialize(server:)
    # Connect to server
    @socket = UNIXSocket.new(server)
    # In case we are used in a multi-threaded context we need to only have
    # one instnace of a given logger writing to the socket
    @mutex = Mutex.new
  end

  # Write a line to the logging server. Newline will be appended
  def write_line(bytes)
    @mutex.synchronize { @socket.puts bytes }
  rescue StandardError => e
    STDERR.puts "#{LoggerServer.time_string}: ERROR: Could not write to server: #{e.class}: #{e}"
  end

  # When we are done with the logger we wait for writes to finish and close
  # the server socket
  def done!
    @mutex.synchronize {
      @socket.flush
      @socket.close
    }
  end
end
