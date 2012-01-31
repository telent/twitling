# -*- coding: utf-8 -*-
require 'json'
require 'pp'
require 'twitter'
require 'patron'
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
    @dom=@body && Nokogiri::HTML(@body)
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
        Encoding.compatible?(p.text," ") && p.text.count(" ") >10 
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
      ((URI.parse self.url).merge s).to_s.encode("UTF-8")
    rescue ArgumentError,Encoding::CompatibilityError,URI::InvalidURIError
      warn [:bad_url,self.url,s]
    end
  end

  def self.resolve(url)
    begin
      response=@patron.get(url)
      ct=([response.headers["Content-Type"]].flatten.first.split /;/).first
      if ct=="text/html" then
        new(status: response.status, url: response.url, body: response.body)
      else
        new(status: response.status, url: response.url, body: nil)
      end
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
    @title="Link Digest for "+@username 
    @page=args[:page].to_i
    story_template=ERB.new(File.read("_story.html.erb"))

    Twitter.home_timeline(page: @page,count: 20).each do |tweet|
      text=tweet.text
      links=URI.extract(text).map {|l| Link.resolve(l) }.compact
      if links[0] then
        s=Story.new(text: text, links: links, poster: tweet.user,
                    timestamp: tweet.created_at, tweet_id: tweet.id)
        @stories << story_template.result(s.get_binding)
      end
    end
    @string=Tilt.new("layout.html.erb").render(self) do
      Tilt.new("index.html.erb").render(self)
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
    template=Tilt.new('layout.html.erb')
    template.render(:@title=>"Sign in") do
      %Q[
<header><h1>Sign in with Twitter</h1></header>
<article>
<p>Twitling presents a summary of all the links posted by people you 
follow on Twitter.  To do this, it needs you to sign into Twitter

<p>
<a href="/auth/twitter">
  <img src="/sign-in-with-twitter-l.png" alt="sign in with twitter">
</a>
</article>
]
    end
  end

  get '/auth/twitter/callback' do
    auth = request.env['omniauth.auth']
    c=auth.credentials
    session[:token]=c.token
    session[:secret]=c.secret
    redirect '/timeline'
  end

  def auth_twitter(token,secret)
    Twitter.configure do |config|
      config.consumer_key = Keys['twitter']['consumer_key']
      config.consumer_secret = Keys['twitter']['consumer_secret']
      config.oauth_token =token; 
      config.oauth_token_secret=secret
    end
  end

  get '/timeline' do
    auth_twitter session[:token],session[:secret]
    expires 60
    auth_twitter session[:token],session[:secret]
    p=Page.new :username=>Twitter.current_user.screen_name,:page=>(params[:page] || 1)
    p.to_html
  end

end

Twitling.run! 
