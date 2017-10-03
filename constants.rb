PID_FILE = File.join(__dir__, 'ruby-logger.pid')
ERROR_FILE = File.join(__dir__, 'ruby-logger.error')
DOMAIN_SOCKET = File.join(__dir__, 'ruby-logger.sock')
LOG_PREFIX = File.join(__dir__, 'ruby-log')
LINE_COUNT_LIMIT = 10_000
SHUTDOWN_MODE = :RDWR
LINE_COUNTER_INDICATOR = '0'.freeze
