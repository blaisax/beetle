module Beetle
  # Provides the publishing logic implementation.
  class Publisher < Base

    attr_reader :dead_servers

    def initialize(client, options = {}) #:nodoc:
      super
      @exchanges_with_bound_queues = {}
      @dead_servers = {}
      @bunnies = {}
      @channels = {}
      at_exit { stop }
    end

    # list of exceptions potentially raised by bunny
    def bunny_exceptions
      [
        Bunny::Exception, Errno::EHOSTUNREACH, Errno::ECONNRESET, Timeout::Error
      ]
    end

    def publish(message_name, data, opts={}) #:nodoc:
      ActiveSupport::Notifications.instrument('publish.beetle') do
        opts = @client.messages[message_name].merge(opts.symbolize_keys)
        exchange_name = opts.delete(:exchange)
        opts.delete(:queue)
        recycle_dead_servers unless @dead_servers.empty?
        if opts[:redundant]
          publish_with_redundancy(exchange_name, message_name, data.to_s, opts)
        else
          publish_with_failover(exchange_name, message_name, data.to_s, opts)
        end
      end
    end

    def publish_with_failover(exchange_name, message_name, data, opts) #:nodoc:
      tries = @servers.size * 2
      logger.debug "Beetle: sending #{message_name}"
      published = 0
      opts = Message.publishing_options(opts)
      begin
        select_next_server if tries.even?
        bind_queues_for_exchange(exchange_name)
        logger.debug "Beetle: trying to send message #{message_name}:#{opts[:message_id]} to #{@server}"
        exchange(exchange_name).publish(data, opts)
        logger.debug "Beetle: message sent!"
        published = 1
      rescue *bunny_exceptions => e
        stop!(e)
        tries -= 1
        # retry same server on receiving the first exception for it (might have been a normal restart)
        # in this case you'll see either a broken pipe or a forced connection shutdown error
        retry if tries.odd?
        mark_server_dead
        retry if tries > 0
        logger.error "Beetle: message could not be delivered: #{message_name}"
        raise NoMessageSent.new
      end
      published
    end

    def publish_with_redundancy(exchange_name, message_name, data, opts) #:nodoc:
      if @servers.size < 2
        logger.warn "Beetle: at least two active servers are required for redundant publishing" if @dead_servers.size > 0
        return publish_with_failover(exchange_name, message_name, data, opts)
      end
      published = []
      opts = Message.publishing_options(opts)
      loop do
        break if published.size == 2 || @servers.empty? || published == @servers
        tries = 0
        select_next_server
        begin
          next if published.include? @server
          bind_queues_for_exchange(exchange_name)
          logger.debug "Beetle: trying to send #{message_name}:#{opts[:message_id]} to #{@server}"
          exchange(exchange_name).publish(data, opts)
          published << @server
          logger.debug "Beetle: message sent (#{published})!"
        rescue *bunny_exceptions => e
          stop!(e)
          retry if (tries += 1) == 1
          mark_server_dead
        end
      end
      case published.size
      when 0
        logger.error "Beetle: message could not be delivered: #{message_name}"
        raise NoMessageSent.new
      when 1
        logger.warn "Beetle: failed to send message redundantly"
      end

      published.size
    end

    RPC_DEFAULT_TIMEOUT = 10 #:nodoc:

    def rpc(message_name, data, opts={}) #:nodoc:
      opts = @client.messages[message_name].merge(opts.symbolize_keys)
      timeout = opts.delete(:timeout) || RPC_DEFAULT_TIMEOUT
      exchange_name = opts.delete(:exchange)
      opts.delete(:queue)
      recycle_dead_servers unless @dead_servers.empty?
      tries = @servers.size
      logger.debug "Beetle: performing rpc with message #{message_name}"
      result = nil
      status = "TIMEOUT"
      begin
        select_next_server
        bind_queues_for_exchange(exchange_name)
        # create non durable, autodeleted temporary queue with a server assigned name
        queue = channel.queue("", :durable => false, :auto_delete => true)
        opts = Message.publishing_options(opts.merge :reply_to => queue.name)
        logger.debug "Beetle: trying to send #{message_name}:#{opts[:message_id]} to #{@server}"
        exchange(exchange_name).publish(data, opts)
        logger.debug "Beetle: message sent!"
        q = Queue.new
        consumer = queue.subscribe do |info, properties, payload|
          logger.debug "Beetle: received reply!"
          result = payload
          q.push properties[:headers]["status"]
        end
        Timeout.timeout(timeout) do
          status = q.pop
        end
        consumer.cancel
        logger.debug "Beetle: rpc complete!"
      rescue *bunny_exceptions => e
        stop!(e)
        mark_server_dead
        tries -= 1
        retry if tries > 0
        logger.error "Beetle: message could not be delivered: #{message_name}"
      end
      [status, result]
    end

    def purge(queue_names) #:nodoc:
      each_server do
        queue_names.each do |name|
          queue(name).purge rescue nil
        end
      end
    end

    def stop #:nodoc:
      each_server { stop! }
    end

    private

    def bunny
      @bunnies[@server] ||= new_bunny
    end

    def bunny?
      !!@bunnies[@server]
    end

    def new_bunny
      b = Bunny.new(
        :host                  => current_host,
        :port                  => current_port,
        :logger                => @client.config.logger,
        :username              => @client.config.user,
        :password              => @client.config.password,
        :vhost                 => @client.config.vhost,
        :automatically_recover => false,
        :frame_max             => @client.config.frame_max,
        :channel_max           => @client.config.channel_max,
        :read_timeout          => @client.config.publishing_timeout,
        :write_timeout         => @client.config.publishing_timeout,
        :continuation_timeout  => @client.config.publishing_timeout,
        :connection_timeout    => @client.config.publisher_connect_timeout)
      b.start
      b
    end

    def channel
      @channels[@server] ||= bunny.create_channel
    end

    def channel?
      !!@channels[@server]
    end

    # retry dead servers after ignoring them for 10.seconds
    # if all servers are dead, retry the one which has been dead for the longest time
    def recycle_dead_servers
      recycle = []
      @dead_servers.each do |s, dead_since|
        recycle << s if dead_since < 10.seconds.ago
      end
      if recycle.empty? && @servers.empty?
        recycle << @dead_servers.keys.sort_by{|k| @dead_servers[k]}.first
      end
      @servers.concat recycle
      recycle.each {|s| @dead_servers.delete(s)}
    end

    def mark_server_dead
      logger.info "Beetle: server #{@server} down: #{$!}"
      @dead_servers[@server] = Time.now
      @servers.delete @server
      @server = @servers[rand @servers.size]
    end

    def select_next_server
      if @servers.empty?
        logger.error("Beetle: no server available")
      else
        set_current_server(@servers[((@servers.index(@server) || 0)+1) % @servers.size])
      end
    end

    def create_exchange!(name, opts)
      channel.exchange(name, opts)
    end

    def bind_queues_for_exchange(exchange_name)
      return if @exchanges_with_bound_queues.include?(exchange_name)
      @client.exchanges[exchange_name][:queues].each {|q| queue(q) }
      @exchanges_with_bound_queues[exchange_name] = true
    end

    # TODO: Refactor, fetch the keys and stuff itself
    def bind_queue!(queue_name, creation_keys, exchange_name, binding_keys)
      logger.debug("Beetle: creating queue with opts: #{creation_keys.inspect}")
      queue = channel.queue(queue_name, creation_keys)
      @dead_lettering.bind_dead_letter_queues!(channel, @client.servers, queue_name, creation_keys)
      logger.debug("Beetle: binding queue #{queue_name} to #{exchange_name} with opts: #{binding_keys.inspect}")
      queue.bind(exchange(exchange_name), binding_keys)
      queue
    end

    def stop!(exception=nil)
      return unless bunny?
      timeout = @client.config.publishing_timeout + @client.config.publisher_connect_timeout + 1
      Beetle::Timer.timeout(timeout) do
        logger.debug "Beetle: closing connection from publisher to #{server}"
        if exception
          puts exception.inspect
          bunny.__send__ :close_connection
        else
          channel.close if channel?
          bunny.stop
        end
      end
    rescue Exception => e
      logger.warn "Beetle: error closing down bunny: #{e}"
      Beetle::reraise_expectation_errors!
    ensure
      @bunnies[@server] = nil
      @channels[@server] = nil
      @exchanges[@server] = {}
      @queues[@server] = {}
    end
  end
end
