require 'rubygems'
require 'bundler/setup'
require 'sinatra/base'
require 'sinatra/reloader' if Sinatra::Base.development?
require 'sass'
require 'xively-rb'
require 'dalli'
require 'memcachier'
require 'json'


class AirQualityEgg < Sinatra::Base

  configure do
    enable :sessions
    enable :logging
    $product_id = ENV['PRODUCT_ID']
    $api_key = ENV['API_KEY']
    $api_url = ENV['API_URL'] || Xively::Client.base_uri

    raise "PRODUCT_ID not set" if $product_id.nil?
    raise "API_KEY not set" if $api_key.nil?
    raise "API_URL not set" if $api_url.nil?
    puts "WARN: You should set a SESSION_SECRET" unless ENV['SESSION_SECRET']

    set :session_secret, ENV['SESSION_SECRET'] || 'airqualityegg_session_secret'
    set :cache, Dalli::Client.new
  end

  configure :production do
    require 'newrelic_rpm'
    set :cache_time, 3600*12 # 12 hours
  end

  configure :development do
    register Sinatra::Reloader
    set :cache_time, 300 # five minutes
  end

  helpers do
    def string_to_time(timestamp)
      Time.parse(timestamp).strftime("%d %b %Y %H:%M:%S")
    rescue
      ''
    end
  end

  # Render css from scss
  get '/style.css' do
    scss :style
  end

  # Home page
  get '/' do
    @error = session.delete(:error)
    erb :home
  end

  # Endpoint used by home page
  get '/all_feeds.json' do
    content_type :json
    cache_key = "all_feeds"
    cached_data = settings.cache.fetch(cache_key) do
      all_feeds = fetch_all_feeds
      # store in cache and return
      settings.cache.set(cache_key, all_feeds, settings.cache_time)
      all_feeds
    end
    return cached_data
  end

  get '/recently_:order.json' do
    content_type :json
    cache_key = "recently_#{params[:order]}"
    cached_data = settings.cache.fetch(cache_key) do
      # fetch feeds based on input
      recently_response = fetch_xively_url("https://api.xively.com/v2/feeds.json?tag=device%3Atype%3Dairqualityegg&mapped=true&content=summary&per_page=10&order=#{params[:order]}")
      recently_results = Xively::SearchResult.new(recently_response.body).results.map(&:attributes)
      # store in cache and return
      settings.cache.set(cache_key, recently_results, settings.cache_time)
      recently_results
    end
    return cached_data.to_json
  end

  # Edit egg metadata
  get '/egg/:id/edit' do
    feed_id, api_key = extract_feed_id_and_api_key_from_session
    redirect_with_error('Not your egg') if feed_id.to_s != params[:id]
    response = Xively::Client.get(feed_url(feed_id), :headers => {'Content-Type' => 'application/json', "X-ApiKey" => api_key})
    @feed = Xively::Feed.new(response.body)
    erb :edit
  end

  # Register your egg
  post '/register' do
    begin
      logger.info("GET: #{product_url}")
      response = Xively::Client.get(product_url, :headers => {'Content-Type' => 'application/json', "X-ApiKey" => $api_key})
      json = MultiJson.load(response.body)
      session['response_json'] = json
      feed_id, api_key = extract_feed_id_and_api_key_from_session
      redirect_with_error("Egg not found") unless feed_id
      redirect "/egg/#{feed_id}/edit"
    rescue
      redirect_with_error "Egg not found"
    end
  end

  # Update egg metadata
  post '/egg/:id/update' do
    feed_id, api_key = extract_feed_id_and_api_key_from_session
    redirect_with_error('Not your egg') if feed_id.to_s != params[:id]
    new_tags = [params[:existing_tags], "device:type=airqualityegg"].compact.delete_if {|tag| tag.empty?}
    feed = Xively::Feed.new({
      :title => params[:title],
      :description => params[:description],
      :id => feed_id,
      :private => false,
      :location_ele => params[:location_ele],
      :location_lat => params[:location_lat],
      :location_lon => params[:location_lon],
      :location_exposure => params[:location_exposure],
      :tags => new_tags.join(',')
    })
    response = Xively::Client.put(feed_url(feed_id), :headers => {'Content-Type' => 'application/json', "X-ApiKey" => api_key}, :body => feed.to_json)
    redirect "/egg/#{feed_id}"
  end

  # View egg dashboard
  get '/egg/:id' do
    response = Xively::Client.get(feed_url(params[:id]), :headers => {"X-ApiKey" => $api_key})
    @feed = Xively::Feed.new(response.body)
    @no2 = @feed.datastreams.detect{|d| !d.tags.nil? && d.tags.match(/computed/) && d.tags.match(/sensor_type=NO2/)}
    @co = @feed.datastreams.detect{|d| !d.tags.nil? && d.tags.match(/computed/) && d.tags.match(/sensor_type=CO/)}
    @temperature = @feed.datastreams.detect{|d| !d.tags.nil? && d.tags.match(/computed/) && d.tags.match(/sensor_type=Temperature/)}
    @humidity = @feed.datastreams.detect{|d| !d.tags.nil? && d.tags.match(/computed/) && d.tags.match(/sensor_type=Humidity/)}
    @feeds = find_egg_feeds_near(@feed)
    @map_markers = collect_map_markers(@feeds)
    erb :show
  end

  get '/cache/flush' do
    return settings.cache.flush.to_s
  end

  private

  def extract_feed_id_and_api_key_from_session
    [session['response_json']['feed_id'], session['response_json']['apikey']]
  rescue
    redirect_with_error('Egg not found')
  end

  def find_egg_feeds_near(feed)
    find_egg_feeds(feed)
  end

  def find_egg_feeds(feed = nil)
    url = feeds_url(feed)
    logger.info("GET: #{url} - geosearch")
    response = Xively::Client.get(url, :headers => {'Content-Type' => 'application/json', 'X-ApiKey' => $api_key})
    @feeds = Xively::SearchResult.new(response.body).results
  rescue
    @feeds = Xively::SearchResult.new().results
  end

  def feed_url(feed_id)
    "#{$api_url}/v2/feeds/#{feed_id}.json"
  end

  def collect_map_markers(feeds)
    MultiJson.dump(
      feeds.collect do |feed|
        {:feed_id => feed.id, :lat => feed.location_lat, :lng => feed.location_lon, :title => feed.title}.delete_if {|_,v| v.blank?}
      end
    )
  end

  def feeds_url(feed)
    feeds_near = (feed && feed.location_lat && feed.location_lon) ? "&lat=#{feed.location_lat}&lon=#{feed.location_lon}&distance=400" : ''
    "#{$api_url}/v2/feeds.json?tag=device%3Atype%3Dairqualityegg&mapped=true#{feeds_near}"
  end

  def fetch_all_feeds
    page = 1
    all_feeds = []
    base_url = "https://api.xively.com/v2/feeds.json?tag=device%3Atype%3Dairqualityegg&mapped=true&content=summary&per_page=100"
    page_response = fetch_xively_url("#{base_url}&page=#{page}")
    while page_response.code == 200 # Unfortunately, Xively API seems to 500 when there are no more results
      logger.info("fetched page #{page} of 100 feeds") if Sinatra::Base.development?
      page_results = Xively::SearchResult.new(page_response.body).results
      all_feeds = all_feeds + page_results
      page += 1
      page_response = fetch_xively_url("#{base_url}&page=#{page}")
    end
    all_feeds = collect_map_markers(all_feeds)
  end

  def fetch_xively_url(url)
    Xively::Client.get(url, :headers => {'Content-Type' => 'application/json', 'X-ApiKey' => $api_key})
  end

  def product_url
    redirect_with_error('Please enter a serial number') if params[:serial].blank?
    "#{$api_url}/v2/products/#{$product_id}/devices/#{params[:serial].downcase}/activate"
  end

  def redirect_with_error(message)
    session['error'] = message
    redirect '/'
  end
end
