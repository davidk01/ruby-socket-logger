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
# Remove the error log
rm -f ruby-logger.error
# Remove the server socket so we can start another server
rm -f ruby-logger.sock
# Start the server
ruby -r ./server.rb -e 'LoggerState.start_server_loop(daemonize: true)'
# Start some concurrent clients in the background
clients="40"
for i in $(seq 1 "${clients}"); do (ruby client.rb &> /dev/null &); done
# Sleep some amount of time and then send the termination signal
sleep 4
(kill -TERM $(cat ruby-logger.pid))
