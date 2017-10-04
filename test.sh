#!/bin/bash -euo pipefail
set -x
# Kill any active clients
(ps aux | grep client.rb | awk '{print $2}' | xargs kill -9) || true
# Kill the logging server
(kill -TERM $(cat ruby-logger.pid)) || true
# Clean up any written logs
rm -f ruby-log2017* &> /dev/null
# Remove the PID file
rm -f ruby-logger.pid
# Dump any errors so we can see if anything interesting happened
cat ruby-logger.error || true
# Remove the error log
rm -f ruby-logger.error
# Remove the server socket so we can start another server
rm -f ruby-logger.sock
# Start the server
./server.rb
# Start some concurrent clients in the background
clients="40"
for i in $(seq 1 "${clients}"); do (ruby client.rb &); done
sleep 1
(kill -TERM $(cat ruby-logger.pid))
