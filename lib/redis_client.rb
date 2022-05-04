# frozen_string_literal: true

require "redis_client/version"
require "redis_client/config"
require "redis_client/sentinel_config"
require "redis_client/connection"
require "redis_client/middlewares"

class RedisClient
  module Common
    attr_reader :config, :id
    attr_accessor :connect_timeout, :read_timeout, :write_timeout

    def initialize(
      config,
      id: config.id,
      connect_timeout: config.connect_timeout,
      read_timeout: config.read_timeout,
      write_timeout: config.write_timeout
    )
      @config = config
      @id = id
      @connect_timeout = connect_timeout
      @read_timeout = read_timeout
      @write_timeout = write_timeout
    end

    def timeout=(timeout)
      @connect_timeout = @read_timeout = @write_timeout = timeout
    end
  end

  Error = Class.new(StandardError)

  ConnectionError = Class.new(Error)

  FailoverError = Class.new(ConnectionError)

  TimeoutError = Class.new(ConnectionError)
  ReadTimeoutError = Class.new(TimeoutError)
  WriteTimeoutError = Class.new(TimeoutError)
  ConnectTimeoutError = Class.new(TimeoutError)
  CheckoutTimeoutError = Class.new(ConnectTimeoutError)

  class CommandError < Error
    class << self
      def parse(error_message)
        code = error_message.split(' ', 2).first
        klass = ERRORS.fetch(code, self)
        klass.new(error_message)
      end
    end
  end

  AuthenticationError = Class.new(CommandError)
  PermissionError = Class.new(CommandError)

  CommandError::ERRORS = {
    "WRONGPASS" => AuthenticationError,
    "NOPERM" => PermissionError,
  }.freeze

  class << self
    def config(**kwargs)
      Config.new(**kwargs)
    end

    def sentinel(**kwargs)
      SentinelConfig.new(**kwargs)
    end

    def new(arg = nil, **kwargs)
      if arg.is_a?(Config::Common)
        super
      else
        super(config(**(arg || {}), **kwargs))
      end
    end

    def register(middleware)
      Middlewares.extend(middleware)
    end
  end

  include Common

  def initialize(config, **)
    super
    @raw_connection = nil
    @disable_reconnection = false
  end

  def size
    1
  end

  def with(_options = nil)
    yield self
  end
  alias_method :then, :with

  def timeout=(timeout)
    super
    raw_connection.read_timeout = raw_connection.write_timeout = timeout if connected?
  end

  def read_timeout=(timeout)
    super
    raw_connection.read_timeout = timeout if connected?
  end

  def write_timeout=(timeout)
    super
    raw_connection.write_timeout = timeout if connected?
  end

  def pubsub
    sub = PubSub.new(ensure_connected)
    @raw_connection = nil
    sub
  end

  def call(*command)
    command = RESP3.coerce_command!(command)
    ensure_connected do |connection|
      Middlewares.call(command, config) do
        connection.call(command, nil)
      end
    end
  end

  def call_once(*command)
    command = RESP3.coerce_command!(command)
    ensure_connected(retryable: false) do |connection|
      Middlewares.call(command, config) do
        connection.call(command, nil)
      end
    end
  end

  def blocking_call(timeout, *command)
    command = RESP3.coerce_command!(command)
    ensure_connected do |connection|
      Middlewares.call(command, config) do
        connection.call(command, timeout)
      end
    end
  end

  def scan(*args, &block)
    unless block_given?
      return to_enum(__callee__, *args)
    end

    scan_list(1, ["SCAN", 0, *args], &block)
  end

  def sscan(key, *args, &block)
    unless block_given?
      return to_enum(__callee__, key, *args)
    end

    scan_list(2, ["SSCAN", key, 0, *args], &block)
  end

  def hscan(key, *args, &block)
    unless block_given?
      return to_enum(__callee__, key, *args)
    end

    scan_pairs(2, ["HSCAN", key, 0, *args], &block)
  end

  def zscan(key, *args, &block)
    unless block_given?
      return to_enum(__callee__, key, *args)
    end

    scan_pairs(2, ["ZSCAN", key, 0, *args], &block)
  end

  def connected?
    @raw_connection&.connected?
  end

  def close
    @raw_connection&.close
    @raw_connection = nil
    self
  end

  def pipelined
    pipeline = Pipeline.new
    yield pipeline

    if pipeline._size == 0
      []
    else
      ensure_connected(retryable: pipeline._retryable?) do |connection|
        commands = pipeline._commands
        Middlewares.call_pipelined(commands, config) do
          connection.call_pipelined(commands, pipeline._timeouts)
        end
      end
    end
  end

  def multi(watch: nil, &block)
    results = if watch
      # WATCH is stateful, so we can't reconnect if it's used, the whole transaction
      # has to be redone.
      ensure_connected(retryable: false) do |connection|
        call("WATCH", *watch)
        begin
          if transaction = build_transaction(&block)
            commands = transaction._commands
            Middlewares.call_pipelined(commands, config) do
              connection.call_pipelined(commands, nil)
            end.last
          else
            call("UNWATCH")
            []
          end
        rescue
          call("UNWATCH") if connected? && watch
          raise
        end
      end
    else
      transaction = build_transaction(&block)
      if transaction._empty?
        []
      else
        ensure_connected(retryable: transaction._retryable?) do |connection|
          commands = transaction._commands
          Middlewares.call_pipelined(commands, config) do
            connection.call_pipelined(commands, nil)
          end.last
        end
      end
    end

    results&.each do |result|
      if result.is_a?(CommandError)
        raise result
      end
    end

    results
  end

  class PubSub
    def initialize(raw_connection)
      @raw_connection = raw_connection
    end

    def call(*command)
      raw_connection.write(RESP3.coerce_command!(command))
      nil
    end

    def close
      raw_connection&.close
      @raw_connection = nil
      self
    end

    def next_event(timeout = nil)
      unless raw_connection
        raise ConnectionError, "Connection was closed or lost"
      end

      raw_connection.read(timeout)
    rescue ReadTimeoutError
      nil
    end

    private

    attr_reader :raw_connection
  end

  class Multi
    def initialize
      @size = 0
      @commands = []
      @retryable = true
    end

    def call(*command)
      @commands << RESP3.coerce_command!(command)
      nil
    end

    def call_once(*command)
      @retryable = false
      @commands << RESP3.coerce_command!(command)
      nil
    end

    def _commands
      @commands
    end

    def _size
      @commands.size
    end

    def _empty?
      @commands.size <= 2
    end

    def _timeouts
      nil
    end

    def _retryable?
      @retryable
    end
  end

  class Pipeline < Multi
    def initialize
      super
      @timeouts = nil
    end

    def blocking_call(timeout, *command)
      @timeouts ||= []
      @timeouts[@commands.size] = timeout
      @commands << RESP3.coerce_command!(command)
      nil
    end

    def _timeouts
      @timeouts
    end

    def _empty?
      @commands.empty?
    end
  end

  private

  def build_transaction
    transaction = Multi.new
    transaction.call("MULTI")
    yield transaction
    transaction.call("EXEC")
    transaction
  end

  def scan_list(cursor_index, command, &block)
    cursor = 0
    while cursor != "0"
      command[cursor_index] = cursor
      cursor, elements = call(*command)
      elements.each(&block)
    end
    nil
  end

  def scan_pairs(cursor_index, command)
    cursor = 0
    while cursor != "0"
      command[cursor_index] = cursor
      cursor, elements = call(*command)

      index = 0
      size = elements.size
      while index < size
        yield elements[index], elements[index + 1]
        index += 2
      end
    end
    nil
  end

  def ensure_connected(retryable: true)
    if @disable_reconnection
      yield @raw_connection
    elsif retryable
      tries = 0
      connection = nil
      begin
        connection = raw_connection
        if block_given?
          yield connection
        else
          connection
        end
      rescue ConnectionError => error
        connection&.close
        close

        if !@disable_reconnection && config.retry_connecting?(tries, error)
          tries += 1
          retry
        else
          raise
        end
      end
    else
      previous_disable_reconnection = @disable_reconnection
      connection = ensure_connected
      begin
        @disable_reconnection = true
        yield connection
      ensure
        @disable_reconnection = previous_disable_reconnection
      end
    end
  end

  def raw_connection
    @raw_connection ||= connect
  end

  def connect
    connection = config.driver.new(
      config,
      connect_timeout: connect_timeout,
      read_timeout: read_timeout,
      write_timeout: write_timeout,
    )

    prelude = config.connection_prelude.dup

    if id
      prelude << ["CLIENT", "SETNAME", id.to_s]
    end

    # The connection prelude is deliberately not sent to Middlewares
    if config.sentinel?
      prelude << ["ROLE"]
      role, = connection.call_pipelined(prelude, nil).last
      config.check_role!(role)
    else
      connection.call_pipelined(prelude, nil)
    end

    connection
  end
end

require "redis_client/resp3"
require "redis_client/pooled"
