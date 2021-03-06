require 'chronic'
require 'haml'

module CataBot
  module Plugin
    module Jq
      DATADIR = File.expand_path(CataBot.config['params']['jq']['data'])
      VERSION = CataBot.config['params']['jq']['version']
      JQ = CataBot.config['params']['jq']['jq_bin']
      LIMIT = CataBot.config['params']['jq']['limit']
      EXPIRE = CataBot.config['params']['jq']['expire']
      TEMPLATE = Haml::Engine.new(File.read('data/jq/result.haml'))
      GROUPS = %w{null [] {} true false 0}

      def self.data_version
        return VERSION if VERSION
        `cd #{DATADIR}; git describe --tags --always --dirty`.chop
      end

      class App < Web::App
        @@results = Hash.new
        @@queries = Hash.new
        @@id = 0
        @@mutex = Mutex.new

        def self.can_query?(user)
          @@mutex.synchronize do
            if @@queries.length >= LIMIT
              [false, 'Sorry, I\'m too busy now. Ask later maybe?']
            else
              if @@queries.has_key? user.mask
                [false, 'I\'m still working on your last query.']
              else
                true
              end
            end
          end
        end

        def self.query(m, query)
          started = Time.now

          id = @@mutex.synchronize do
            @@id += 1
            @@queries[m.user.mask] = true
            @@id.to_s
          end

          exceptions = Array.new
          results = {'main' => Hash.new}
          Dir.chdir(DATADIR)
          Dir.glob('**/*.json') do |p|
            begin
              io = IO.popen([JQ, query, p, :err=>[:child,:out]])
              output = io.read
              unless output.empty?
                head = output.lines.first.chop
                if GROUPS.member? head
                  results[head] ||= Array.new
                  results[head].push(p)
                else
                  results['main'][p] = output
                end
              end
            rescue StandardError => e
              CataBot.log :error, "Something went wrong with jq query '#{query}' for #{p} from '#{m.user.mask}'"
              CataBot.log :exception, e
              exceptions.push(p)
            ensure
              io.close
            end
          end

          html = TEMPLATE.render(self, {query: query, results: results, started: started, exceptions: exceptions, ver: Jq.data_version})

          @@mutex.synchronize do
            @@results[id] = {id: id, html: html, stamp: Time.now, by: m.user, query: query}
            @@queries.delete(m.user.mask)
          end

          url = "#{CataBot.config['web']['url']}/jq/#{id}"
          m.reply "Done, have a look at #{url}", true
        end

        def self.results
          if @@results.any?
            res = @@results.values.sort {|a,b| b[:stamp] <=> a[:stamp] }.slice(0, 5).map do |r|
              "#{r[:id]}: \"#{r[:query]}\""
            end
            "Last results: #{res.join(', ')}"
          else
            'No results in my memory'
          end
        end

        get '/:id' do
          id = params['id']
          @@mutex.synchronize do
            if @@results.has_key? id
              reply(@@results[id][:html], 200, {'Content-Type' => 'text/html'})
            else
              reply_err('Not found.')
            end
          end
        end

        CataBot.aux_thread_every(:jq_expire, 5 * 60) do
          threshold = Chronic.parse(EXPIRE + ' ago')
          deleted = 0
          @@results.each_pair do |k, v|
            if v[:stamp] < threshold
              @@mutex.synchronize { @@results.delete(k) }
              deleted += 1
            end
          end
          CataBot.log :debug, "JQ cleaner: #{deleted} deleted, #{@@results.length} kept"
        end
      end
      Web.mount('/jq', App)

      class IRC
        include CataBot::IRC::Plugin

        HELP = 'Can do: jq wtf, jq version, jq query [query], jq last'
        command(:jq, /jq ?(\w+)? ?(.*)?$/, 'jq [...]', HELP)
        def jq(m, cmd, rest)
          case cmd
          when 'help'
            m.reply HELP, true
          when 'wtf'
            m.reply 'RTFM - http://stedolan.github.io/jq/manual/', true
          when 'version'
            jver = `#{JQ} --version`.chop
            m.reply "You can run #{jver} queries against #{Jq.data_version}", true
          when 'last'
            m.reply App.results, true
          when 'query'
            ok, msg = App.can_query?(m.user)
            unless ok
              m.reply msg, true
              return
            end
            App.query(m, rest)
          else
            m.reply 'Sorry, didn\'t get that... ' + HELP, true
          end
        end
      end
    end
  end
end
