require 'bunny'
require 'json'

class Worker

  def initialize(options)
    bunny_client_class = Module.const_get(options[:client_class])
    # TODO: clean the options
    bunny_client = bunny_client_class.new(options)
    bunny_client.start
    channel = bunny_client.create_channel
    @exchange = channel.default_exchange
    @work_queue = channel.queue(options[:work_queue])
    @work_queue.bind(@exchange)
    @error_queue = options[:error_queue]
  end

  def get_exchange
    @exchange
  end

  def subscribe
    @work_queue.subscribe do |delivery_info, metadata, payload|
      on_message(payload)
    end
  end

  # TODO
  # - add explicit acknowledgements
  # - add 'prefect' (batch) setting
  def on_message(payload)
    begin
      message = JSON.parse(payload)
      process_message(message)
    rescue Exception => exception
      send_error_message(exception)
    end
  end

  def process_message(message)
    raise 'Method must be implemented by subclasses'
  end

  def send_error_message(exception)
    error_message = {error: exception.class, message: exception.to_s}.to_json
    @exchange.publish(error_message, routing_key: @error_queue)
  end

end