require 'socket'
require_relative './constants'

log_socket = UNIXSocket.new(DOMAIN_SOCKET)
sleep 1
5000.times do
  begin
    log_socket.puts "some data"
  rescue StandardError => e
    STDERR.puts "Client writing error: #{e}"
  end
end
