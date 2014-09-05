#!/usr/bin/env ruby
require 'socket'

# Global variables (mostly because I'm lazy and it makes the code easier)
$line_count_limit, $line_count_mutex, $log_file_mutex = 1000, Mutex.new, Mutex.new
$log_file, $line_count = open('/tmp/log' + Time.now.to_s.gsub(' ', '_'), 'a'), 0

# Reset the line count and re-open the file
$reset = ->(n = '/tmp/log' + Time.now.to_s.gsub(' ', '_')) do
  $log_file_mutex.synchronize {$line_count = 0; $log_file.reopen(n, 'a')}
end

# Read if the client is still sending data and write it to the log file.
# When we reach the line count re-open the log file and reset the counters.
$client_handler = ->(client) do
  Thread.new do
    while (log_line = client.readline)
      $log_file_mutex.synchronize { $log_file.write log_line }
      $line_count_mutex.synchronize { ($line_count += 1) > $line_count_limit ? $reset.call : nil }
    end
  end
end

# Start the server
UNIXServer.open('/tmp/logger') {|s| loop {$client_handler.call(s.accept)}}
