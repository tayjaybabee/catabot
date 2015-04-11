#!/usr/bin/env ruby

require 'json'
require 'yaml'

require 'cinch'
require 'cinch/logger/formatted_logger'
require 'dm-core'
require 'eldr'
require 'rack'
require 'thin'

module CataBot
  VERSION = '0.0.4'

  class Error < StandardError; end

  @@config = Hash.new
  def self.config; @@config; end
  def self.config=(obj); @@config = obj; end
  def self.log(level, msg); @@config[:logger].send(level, msg) if @@config[:logger]; end

  @@threads = Hash.new
  def self.add_thread(id, &blk)
    raise Error, "Thread '#{id}' already defined." if @@threads.has_key? id
    raise Error, 'No block given.' if blk.nil?
    @@threads[id] = {block: blk, thread: nil}
  end

  module IRC
    @@cmds = Hash.new
    def self.cmds; @@cmds; end
    def self.cmd(name, desc)
      raise Error, "IRC Command '#{name}' already defined." if @@cmds.has_key? name
      @@cmds[name] = desc
    end
  end

  module Web
    @@mounts = Hash.new
    def self.mounts; @@mounts; end
    def self.mount(root, app)
      raise Error, "Web app already mounted at '#{root}'." if @@mounts.has_key? root
      @@mounts[root] = app
    end

    class Logging
      def initialize(app)
        @app = app
      end

      def call(env)
        start = Time.now
        status, header, body = @app.call(env)
        log(env, status, header, start)
        [status, header, body]
      end

      private
      def log(env, status, header, start)
        msg = 'Web: %s %s %s%s %s %s %s %0.4f' % [
          env['HTTP_X_FORWARDED_FOR'] || env["REMOTE_ADDR"] || "-",
          env['REQUEST_METHOD'],
          env['PATH_INFO'],
          env['QUERY_STRING'].empty? ? '' : '?'+env['QUERY_STRING'],
          env['HTTP_VERSION'],
          status.to_s[0..3],
          header['Content-Length'] || '-',
          Time.now - start]
        CataBot.log :info, msg
      end
    end

    class App < Eldr::App
      use Logging
      use Rack::ContentLength

      def reply_ok(data); reply({success: true, data: data}.to_json); end
      def reply_err(msg); reply({success: false, error: msg}.to_json); end
      def reply(data, status = 200, header)
        Rack::Response.new(data, status, {'Content-Type' => 'application/json'}.merge(header))
      end
    end
  end

  def self.fire!
    c = @@config

    lf = c['runtime']['logging']['file']
    lt = if lf == 'stdout'
           STDERR.reopen(STDOUT)
           STDOUT
         else
           File.open(File.expand_path(lf), 'a')
         end
    lt.sync = true
    lg = Cinch::Logger::FormattedLogger.new(lt)
    lg.level = c['runtime']['logging']['level'].to_sym
    @@config[:logger] = lg

    self.log :info, 'Setting up database...'
    DataMapper.finalize
    DataMapper.setup(:default, c['database'])
    if m = c['database'].match(/sqlite:\/\/(.*?)/) # TODO: broken?
      p = m.captures.first
      unless File.exists? p
        require 'dm-migrations'
        DataMapper.auto_migrate!
      end
    end

    self.log :debug, 'Loading IRC code...'
    c['plugins'].each do |p|
      fname = "#{p.downcase}.rb"
      self.log :debug, "Loading '#{fname}'..."
      require_relative File.join('plugins', fname)
    end

    self.log :info, 'Configuring web backend...'
    app = Rack::Builder.new do
      CataBot::Web.mounts.each_pair do |r, a|
        map r do run a.new end
      end
    end.to_app

    self.log :info, 'Configuring IRC bot...'
    bot = Cinch::Bot.new do
      configure do |b|
        b.nick      = c['irc']['nick']
        b.user      = c['irc']['user']
        b.realname  = c['irc']['realname']
        b.server    = c['irc']['server']
        b.channels  = c['irc']['channels']

        b.plugins.plugins = c['plugins'].map {|p| CataBot::Plugin.const_get(p).const_get('IRC') }
      end
    end
    bot.loggers.clear
    bot.loggers << lg

    self.log :info, 'Starting Web backend...'
    web = Thread.new do
      host = c['web']['host'] || '127.0.0.1'
      port = c['web']['port'] || 8080
      c['web']['url'] = "http://#{host}:#{port}"
      Rack::Handler::Thin.run(app, {:Host => host, :Port => port})
    end

    self.log :info, 'Starting IRC bot...'
    irc = Thread.new { bot.start }

    if @@threads.any?
      self.log :info, 'Starting auxillary threads...'
      @@threads.each_pair do |k, v|
        self.log :debug, "Starting '#{k}'..."
        v[:thread] = Thread.new { v[:block].call }
      end
    end

    web.join
    self.log :debug, 'Web thread ended...'

    if @@threads.any?
      self.log :info, 'Stopping auxillary threads...'
      @@threads.each_pair do |k, v|
        self.log :debug, "Stopping '#{k}'..."
        Thread.kill(v[:thread])
      end
    end
  end
end

unless ARGV.length == 1
  STDERR.puts "Usage: #{$PROGRAM_NAME} cofig.yaml"
  exit(2)
end

begin
  c = CataBot.config = File.open(ARGV.first) {|f| YAML.load(f.read) }
  if c['runtime']['daemon']
    pid = fork { CataBot.fire! }
    if pf = c['runtime']['pid_file']
      pid_path = File.expand_path(pf)
      File.open(pid_path, 'w') {|f| f.puts pid }
    end
    Process.detach(pid)
  else
    CataBot.fire!
  end
rescue StandardError => e
  msg = "Runtime error: #{e.to_s} at #{e.backtrace.first}."
  CataBot.log :error, msg 
  CataBot.log :exception, e
  STDERR.puts msg
  exit(3)
end