require 'active_record'
require 'activerecord-import'

require_relative 'worker'
require_relative 'models/item'
require_relative 'models/document'
require_relative 'models/collection'
require_relative 'new_postgres_helper'

class PostgresWorker < Worker

  def initialize(options)
    rabbitmq_options = options[:rabbitmq]
    super(rabbitmq_options)
    @activerecord_options = options[:activerecord]
    @batch_options = options[:batch].freeze
    if @batch_options[:enabled]
      @batch = []
      @batch_mutex = Mutex.new
    end
  end

  def start_batch_monitor
    @batch_monitor = Thread.new {
      loop {
        sleep @batch_options[:timeout]
        commit_batch
      }
    }
  end

  def start
    super
    if @batch_options[:enabled]
      start_batch_monitor
    end
  end

  def stop
    super
    if @batch_options[:enabled]
      @batch_monitor.kill
      commit_batch
    end
  end

  def connect
    super
    # TODO: change this to a connection pool perhaps
    ActiveRecord::Base.establish_connection(@activerecord_options)
  end

  def close
    super
    ActiveRecord::Base.connection.close
  end

  def commit_batch
    @batch_mutex.synchronize {
      Item.import(@batch)
      @batch.clear
    }
  end

  def process_message(headers, message)
    if headers['action'] == 'create'
      if @batch_options[:enabled]
        batch_create(message)
      else
        create_item(message)
      end
    end
  end

  def batch_create(message)
    # TODO: Cache collection IDs to minimize lookups
    collection = Collection.find_by_name(payload['collection'])
    item = Item.new(payload['item'])
    item.collection = collection
    item.documents.build(payload['documents'])
    @batch << item
    if (@batch.size >= @batch_options[:size])
      commit_batch
    end
  end

  def create_item(payload)
    item = Item.new(payload['item'])
    item.documents.build(payload['documents'])
    item.save!
  end

end