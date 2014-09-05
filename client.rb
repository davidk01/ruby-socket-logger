require 'socket'

log_socket = UNIXSocket.new('/tmp/logger')
while true
  log_socket.puts "some data"
end
