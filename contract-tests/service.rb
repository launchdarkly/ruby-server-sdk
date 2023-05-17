require 'launchdarkly-server-sdk'
require 'json'
require 'logger'
require 'net/http'
require 'sinatra'

require './client_entity'

configure :development do
  disable :show_exceptions
end

$log = Logger.new(STDOUT)
$log.formatter = proc {|severity, datetime, progname, msg|
  "[GLOBAL] #{datetime.strftime('%Y-%m-%d %H:%M:%S.%3N')} #{severity} #{progname} #{msg}\n"
}

set :port, 9000
set :logging, false

clients = {}
clientCounter = 0

get '/' do
  {
    capabilities: [
      'server-side',
      'server-side-polling',
      'big-segments',
      'all-flags-with-reasons',
      'all-flags-client-side-only',
      'all-flags-details-only-for-tracked-flags',
      'filtering',
      'secure-mode-hash',
      'user-type',
      'tags',
    ],
  }.to_json
end

delete '/' do
  $log.info("Test service has told us to exit")
  Thread.new { sleep 1; exit }
  return 204
end

post '/' do
  opts = JSON.parse(request.body.read, :symbolize_names => true)
  tag = "[#{opts[:tag]}]"

  clientCounter += 1
  clientId = clientCounter.to_s

  log = Logger.new(STDOUT)
  log.formatter = proc {|severity, datetime, progname, msg|
    "#{tag} #{datetime.strftime('%Y-%m-%d %H:%M:%S.%3N')} #{severity} #{progname} #{msg}\n"
  }

  log.info("Starting client")
  log.debug("Parameters: #{opts}")

  client = ClientEntity.new(log, opts[:configuration])

  if !client.initialized? && opts[:configuration][:initCanFail] == false
    client.close()
    return [500, nil, "Failed to initialize"]
  end

  clientResourceUrl = "/clients/#{clientId}"
  clients[clientId] = client
  return [201, {'Location' => clientResourceUrl}, nil]
end

post '/clients/:id' do |clientId|
  client = clients[clientId]
  return 404 if client.nil?

  params = JSON.parse(request.body.read, :symbolize_names => true)

  client.log.info("Processing request for client #{clientId}")
  client.log.debug("Parameters: #{params}")

  case params[:command]
  when "evaluate"
    response = client.evaluate(params[:evaluate])
    return [200, nil, response.to_json]
  when "evaluateAll"
    response = {:state => client.evaluate_all(params[:evaluateAll])}
    return [200, nil, response.to_json]
  when "secureModeHash"
    response = {:result => client.secure_mode_hash(params[:secureModeHash])}
    return [200, nil, response.to_json]
  when "customEvent"
    client.track(params[:customEvent])
    return 201
  when "identifyEvent"
    client.identify(params[:identifyEvent])
    return 201
  when "flushEvents"
    client.flush_events
    return 201
  when "getBigSegmentStoreStatus"
    status = client.get_big_segment_store_status
    return [200, nil, status.to_json]
  end

  return [400, nil, {:error => "Unknown command requested"}.to_json]
end

delete '/clients/:id' do |clientId|
  client = clients[clientId]
  return 404 if client.nil?
  clients.delete(clientId)
  client.close

  return 204
end

error do
  env['sinatra.error'].message
end
