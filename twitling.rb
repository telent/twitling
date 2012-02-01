# -*- coding: utf-8 -*-
require 'json'
require 'pp'
require 'twitter'
require 'typhoeus'
require 'nokogiri'
require 'erb'
require 'tilt'
require 'ostruct'
require 'omniauth'
require 'omniauth-twitter'

Keys=YAML::load_file("keys.yml")

class Story
  attr_reader :text,:links,:poster,:tweet_id
  def initialize(args={})
    @text=args[:text]
    @links=args[:links]
    @poster=args[:poster]
    @timestamp=args[:timestamp]
    @tweet_id=args[:tweet_id]
  end
  def get_binding
    return binding()
  end
end

class Link
  attr_reader :url,:status,:summary,:body,:dom
  def initialize(args={})
    @url=args[:url]
    unless Encoding.compatible?(@url,"hello") then
      @url=URI::encode(@url)
    end
    @status=args[:status]
    @summary=args[:summary]
    @body=args[:body]
  end
  
  def title
    @dom &&     @dom.css('title').text.encode("UTF-8")
  end
  def meta_description
    if @dom then
      d=@dom.css('meta[name=description]')
      if d.first then d.attr('content').value.encode("UTF-8") end
    end
  end
  def first_para
    return unless @dom
    begin 
      paras=@dom.css('p')
      d=paras.select {|p|
        Encoding.compatible?(p.text," ") && p.text.scan(/\w+/).size >10 
      }.first ||
        paras.first
    rescue Exception
      warn [@url,paras]
    end
    if d then d.text end
  end
  def summary
    return unless @dom
    f=first_para
    m=meta_description
    if f && (f.start_with? m) then f
    elsif m && (m.start_with? f) then m
    else [m,f].compact.join("<br>")
    end
  end
  
  def image_url
    return unless @dom
    i=@dom.css('img').first
    s=i && i.attr('src')
    begin 
      s && ((URI.parse self.url).merge s).to_s.encode("UTF-8")
    rescue ArgumentError,Encoding::CompatibilityError,URI::InvalidURIError
      warn [:bad_url,self.url,s]
    end
  end
  
  def fetch(hydra)
    valid_ct=%w(text/html application/xhtml+xml application/xml)
    if [80,443].member?(URI.parse(url).port) 
      req=Typhoeus::Request.new(@url,
                                :follow_location => false,
                                :timeout  =>  2000,
                                :headers =>{:Accept=>valid_ct.join(",")})
      req.on_complete do |resp|
        if resp.code/100 == 3 then
          # we have to do redirects by hand so that we can check we're
          # not being redirected to ports or places we don't want to go
          @url=resp.headers_hash[:Location]
          self.fetch(hydra)
        else
          @url=resp.effective_url
          @status=resp.code
          type=resp.headers_hash[:content_type]
          if type.is_a?(String) then
            # Typhoeus returns {} when asked for the value of a 
            # non-existent header.  I don't know why, you tell *me* why
            type=type.split(/;/).first 
            if valid_ct.member? type
              @body=resp.body
              @dom=@body && Nokogiri::HTML(@body)
              @dom.css('script').unlink # 
            end
          end
        end
      end
      hydra.queue(req)
    else
      @status=500
      @body="<h1>This address is restricted</h1><p>This page uses a network port which is normally used for purposes other than Web browsing.  It has not been fetched</p>"
    end
    self
  end
end

class Page
  attr_reader :stories
  def initialize(args={})
    @username=args[:username]
    @stories=[]
    @title="Link Digest for "+@username 
    @page=args[:page].to_i
    story_template=ERB.new(File.read("_story.html.erb"))

    hydra = Typhoeus::Hydra.new
    Twitter.home_timeline(page: @page,count: 20).each do |tweet|
      text=tweet.text
      reqs=[]
      links=[]
      URI.extract(text).grep(/http(s)?:\/\/.+\..+/).each do |l|
        links << Link.new(:url=>l).fetch(hydra)
      end
      if links[0] then
        s=Story.new(text: text, links: links, poster: tweet.user,
                    timestamp: tweet.created_at, tweet_id: tweet.id)
        @stories << s
      end
    end
    hydra.run
    @stories= @stories.map{|s| story_template.result(s.get_binding)}
    @string=Tilt.new("layout.html.erb").render(self) do
      Tilt.new("timeline.html.erb").render(self)
    end
  end
  def to_html
    @string
  end
end

require 'sinatra/base'

Twitter.configure do |config|
  config.consumer_key = Keys['twitter']['consumer_key']
  config.consumer_secret = Keys['twitter']['consumer_secret']
end

class Twitling < Sinatra::Base
  set :root, File.expand_path("#{File.dirname(__FILE__)}/")
  set :run, false
  set :static,true
  set :public_folder,"public"
  set :sessions, true
  set :port, (ENV['RACK_PORT'] || 4567)
  use Rack::Session::Cookie
  use OmniAuth::Builder do
    provider :twitter, Keys['twitter']['consumer_key'],Keys['twitter']['consumer_secret']
  end
  
  get '/' do
    @title="Sign in"
    Tilt.new('layout.html.erb').render(self) do
      Tilt.new("signin.html.erb").render(self)
    end
  end

  get '/auth/twitter/callback' do
    auth = request.env['omniauth.auth']
    c=auth.credentials
    session[:token]=c.token
    session[:secret]=c.secret
    redirect '/timeline/'+auth["info"]["nickname"]
  end

  def auth_twitter(token,secret)
    Twitter.configure do |config|
      config.consumer_key = Keys['twitter']['consumer_key']
      config.consumer_secret = Keys['twitter']['consumer_secret']
      config.oauth_token =token; 
      config.oauth_token_secret=secret
    end
  end

  # we put the twitter screen name into the URL to make caching easier:
  # don't want one users' timeline wiping out the cache entry for another
  # (or worse, being shown to another)
  get '/timeline/:name' do
    expires 60
    auth_twitter session[:token],session[:secret]
    halt 401 unless params[:name]==Twitter.current_user.screen_name
    p=Page.new :username=>Twitter.current_user.screen_name,:page=>(params[:page] || 1)
    p.to_html
  end

end

if $0 == __FILE__
  Twitling.run! 
end
