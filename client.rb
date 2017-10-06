require 'socket'
require_relative './server'

log_socket = UNIXSocket.new(LoggerState::DOMAIN_SOCKET)
sleep 1
5000.times do
  begin
    log_socket.puts "some data"
  rescue StandardError => e
    STDERR.puts "Client writing error: #{e}"
  end
end
