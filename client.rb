require 'socket'
require_relative './constants'

log_socket = UNIXSocket.new(DOMAIN_SOCKET)
loop do
  log_socket.puts "some data"
end
