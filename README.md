## What is this?
Single file (`logger.rb`), socket based logging server and client.

## Why is this not a gem?
Single file libraries don't need to be gems.

## How do I use it?
To start the server

```bash
cd "${log_directory} && \
    ruby -r ./logger -e 'LoggerServer.start_server_loop(daemonize: true)'
```

To use the bare bones client

```ruby
require_relative './logger'

logger = LoggerClient.new(server: path_to_server_socket)
logger.write_line('log line')
```

## How do I configure it?
There is basically only 1 configuration parameter `LINE_COUNT_LIMIT` so you
can change it with

```bash
sed -i '' 's/LINE_COUNT_LIMIT = 10_000/LINE_COUNT_LIMIT = 20_000/' logger.rb
```

To change any of the other parameters use the same trick as above. The other
parameters are

```ruby
PID_FILE = File.join(starting_dir = Dir.pwd, 'ruby-logger.pid').freeze
ERROR_FILE = File.join(starting_dir, 'ruby-logger.error').freeze
DOMAIN_SOCKET = File.join(starting_dir, 'ruby-logger.sock').freeze
LOG_PREFIX = File.join(starting_dir, 'ruby-log').freeze
LINE_COUNT_LIMIT = 10_000
SHUTDOWN_MODE = :RDWR
LINE_COUNTER_INDICATOR = '0'.freeze
TIME_FORMAT_STRING = '%Y-%j-%H-%M-%S-%N'.freeze
CLIENT_LIMIT = 50
```

## Is it production ready?
When was the last time you looked at production logs?
