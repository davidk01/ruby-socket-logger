#!/usr/bin/env ruby
require 'socket'

$line_count_limit, $line_count_mutex, $log_file_mutex = 1000, Mutex.new, Mutex.new
$log_file, $line_count = open('/tmp/log' + Time.now.to_s.gsub(' ', '_'), 'a'), 0

# Reset the line count and re-open the file.
$reset = ->(n = '/tmp/log' + Time.now.to_s.gsub(' ', '_')) do
  $log_file_mutex.synchronize {$line_count = 0; $log_file.reopen(n, 'a')}
end

# When we reach the line count limit re-open the log file and reset the counter.
$client_handler = ->(client) do
  Thread.new do
    while (log_line = client.readline)
      $log_file_mutex.synchronize {$log_file.write log_line}
      $line_count_mutex.synchronize {($line_count += 1) > $line_count_limit ? $reset.call : nil}
    end
  end
end

# Daemonize, drop a pidfile, and start the server.
Process.daemon(true)
open('ruby-logger.pid', 'w') {|f| f.puts Process.pid}
UNIXServer.open('/var/run/logger.sock') {|s| loop {$client_handler[s.accept]}}
