#!/bin/bash -euo pipefail
set -x
# Kill any active clients
(ps aux | grep client.rb | awk '{print $2}' | xargs kill -9) || true
# Kill the logging server
(kill -TERM $(cat ruby-logger.pid)) || true
# Clean up any written logs
rm -f ruby-log2017* &> /dev/null
# Start the server
ruby -r ./logger -e 'LoggerServer.start_server_loop(daemonize: true)'
# Start some concurrent clients in the background
clients="5"
rm -f client.log* &> /dev/null
for i in $(seq 1 "${clients}"); do (ruby client.rb &> "client.log.${i}" &); done
# Sleep some amount of time and then send the termination signal
sleep 4
(kill -TERM $(cat ruby-logger.pid))
# Wait for background jobs to finish
for j in $(jobs -p); do
  wait $j
done
