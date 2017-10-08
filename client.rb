require 'socket'
require_relative './logger'

client = LoggerClient.new(server: LoggerServer::DOMAIN_SOCKET)
socket = UNIXSocket.new(LoggerServer::DOMAIN_SOCKET)
5000.times do
  begin
    # socket.puts "some data"
    client.write_line "some data"
  rescue StandardError => e
    STDERR.puts "Server error: #{e.class}: #{e}"
    break
  end
end
client.done!
