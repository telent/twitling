# -*- coding: utf-8 -*-
require 'json'
require 'pp'
require 'twitter'
require 'patron'
require 'nokogiri'
require 'erb'
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
  @patron = Patron::Session.new
  @patron.timeout=2
  def initialize(args={})
    @url=args[:url]
    unless Encoding.compatible?(@url,"hello") then
      @url=URI::encode(@url)
    end
    @status=args[:status]
    @summary=args[:summary]
    @body=args[:body]
    @dom=Nokogiri::HTML(@body)
  end

  def title
    @dom.css('title').text.encode("UTF-8")
  end
  def meta_description
    d=@dom.css('meta[name=description]')
    if d.first then d.attr('content').value.encode("UTF-8") end
  end
  def first_para
    paras=@dom.css('p')
    d=paras.select {|p| p.text.count(" ") >10 }.first ||
      paras.first
    if d then d.text end
  end
  def summary
    f=first_para
    m=meta_description
    if f && (f.start_with? m) then f
    elsif m && (m.start_with? f) then m
    else [m,f].compact.join("<br>")
    end
  end

  def image_url
    i=@dom.css('img').first
    s=i && i.attr('src')
    begin 
      ((URI.parse self.url).merge s).to_s.encode("UTF-8")
    rescue ArgumentError,Encoding::CompatibilityError,URI::InvalidURIError
      warn [:bad_url,self.url,s]
    end
  end

  def self.resolve(url)
    begin
      response=@patron.get(url)
      new(status: response.status, url: response.url, body: response.body)
    rescue Patron::Error
      return new(status: 500, url: url)
    rescue URI::InvalidURIError => e
      # URI::extract is impossibly optimistic about what it thinks a
      # URL is - anything with a colon will make it happy
      # warn "bad URI #{url}"
      nil
    end
  end
end

class Page
  attr_reader :stories
  def initialize(args={})
    @username=args[:username]
    @stories=[]
    stories=[]
    page_template=ERB.new(File.read("index.html.erb"))
    story_template=ERB.new(File.read("_story.html.erb"))

    p={count: args[:count]}; if s=args[:since_id] then p[:since_id]=s end
    Twitter.home_timeline(p).each do |tweet|
      text=tweet.text
      links=URI.extract(text).map {|l| Link.resolve(l) }.compact
      if links[0] then
        s=Story.new(text: text, links: links, poster: tweet.user,
                    timestamp: tweet.created_at, tweet_id: tweet.id)
        warn s.links.map(&:url).join("\n");
        @stories << story_template.result(s.get_binding)
    end
    end
    @string=page_template.result(binding)
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
  use Rack::Session::Cookie
  use OmniAuth::Builder do
    provider :twitter, Keys['twitter']['consumer_key'],Keys['twitter']['consumer_secret']
  end
  
  get '/' do
    warn "hello"
    %Q[
    <a href='/auth/twitter'>Sign in with Twitter</a>
    
    <form action='/auth/open_id' method='post'>
      <input type='text' name='identifier'/>
      <input type='submit' value='Sign in with OpenID'/>
    </form>
    ]
  end

  get '/auth/twitter/callback' do
    auth = request.env['omniauth.auth']
    c=auth.credentials
    PP.pp auth
    session[:token]=c.token
    session[:secret]=c.secret
    redirect '/timeline'
  end

  get '/timeline' do
    expires 60
    t,c= [session[:token],session[:secret]]
    warn [t,c]
    Twitter.configure do |config|
      config.consumer_key = Keys['twitter']['consumer_key']
      config.consumer_secret = Keys['twitter']['consumer_secret']
      config.oauth_token =t; 
      config.oauth_token_secret=c
    end
    p=Page.new :username=>Twitter.current_user.screen_name,:count=>2, :since_id=> nil
    p.to_html
  end

end


Twitling.run! 
