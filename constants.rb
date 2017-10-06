# Where do we drop the pid file for the server
PID_FILE = File.join(__dir__, 'ruby-logger.pid').freeze
# Where do write errors
ERROR_FILE = File.join(__dir__, 'ruby-logger.error').freeze
# Where should clients connect to
DOMAIN_SOCKET = File.join(__dir__, 'ruby-logger.sock').freeze
# Folder plus the initial part of the log file
LOG_PREFIX = File.join(__dir__, 'ruby-log').freeze
# How many lines (approximately) in a log file before we rotate it
LINE_COUNT_LIMIT = 10_000
# When we shut down the unix domain server we need a mode of shutdown
SHUTDOWN_MODE = :RDWR
# Mostly an implementaiton detail and can be ignored
LINE_COUNTER_INDICATOR = '0'.freeze
# The time stamp we add to the log files the server writes to
TIME_FORMAT_STRING = '%Y-%j-%H-%M-%S-%N'.freeze
