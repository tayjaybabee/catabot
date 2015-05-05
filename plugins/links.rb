require 'net/http'
require 'uri'
require 'haml'
require 'nokogiri'

module CataBot
  module Plugin
    module Links
      VERSION = '0.1.1'

      SCHEMES = %w{http https ftp ftps}
      TEMPLATE = Haml::Engine.new(File.read('data/links/last.haml'))

      class Link
        include DataMapper::Resource

        property :url, String, key: true
        property :channel, String, length: 1..64, required: true
        property :user, String, length: 1..128, required: true
        property :stamp, Time, default: Proc.new { Time.now }, required: true

        property :header, Boolean, default: false
        property :type, String, length: 1..128
        property :size, Integer
        property :filename, String, length: 1..512
        property :title, String, length: 1..512
      end

      class App < Web::App
        get '/last' do
          links = Link.all(limit: 50, order: [:stamp.desc])
          html = TEMPLATE.render(self, {links: links})
          reply(html, 200, {'Content-Type' => 'text/html'})
        end
      end
      Web.mount('/links', App)

      class IRC
        include CataBot::IRC::Plugin

        listen_to :channel, method: :input
        def input(m)
          URI.extract(m.message).each do |url|
            next unless url.match(/\w+:\/\/.*?/)
            begin
              uri = URI.parse(url)
            rescue StandardError => e
              CataBot.log :warn, "Links: Rejected '#{url}' on parsing"
              CataBot.log :exception, e
              next
            end

            unless SCHEMES.member? uri.scheme
              CataBot.log :warn, "Links: Ditching #{url} due to unsupported scheme"
              next
            end

            unless Link.get(url)
              entry = Link.new(url: url, channel: m.channel, user: m.user.mask)
              unless entry.save
                CataBot.log :error, "Links: Error saving entry for #{url}!"
                return false
              end

              Thread.new do
                res = Array.new
                title = nil
                begin
                  u = URI.parse(url)
                  Net::HTTP.start(u.host, u.port) do |h|
                    res = h.head(u.request_uri)
                    if res['content-type'].match(/text\/html/)
                      res = h.get(u.request_uri)
                      title = Nokogiri::HTML.parse(res.body, nil, 'UTF-8').title
                    end
                  end
                rescue StandardError => e
                  CataBot.log :warn, "Links: Error trying to extract more details for #{url}"
                  CataBot.log :exception, e
                end

                unless entry.update(:header => true,
                                    :type => res['content-type'],
                                    :size => res['content-length'],
                                    :filename => res['content-disposition'],
                                    :title => title)
                  CataBot.log :error, "Links: Error updating details for #{url}"
                end
              end
            end
          end
        end

        command(:links, /links ?(\w+)? ?(.*)?$/, 'links', 'Ask about links I\'ve seen. See "links help"')
        def links(m, cmd, rest)
          case cmd
          when 'help'
            m.reply 'Can do: links recent, links more, links about [link]', true
          when 'recent'
            limit = m.channel? ? 3 : 10
            links = Link.all(order: [:stamp.desc], limit: limit)
            if links.any?
              m.reply 'Recent links:', true
              links.each_with_index do |l, i|
                m.reply "#{i+1}. #{l.url}", true
              end
            else
              m.reply 'Don\'t have any links on record', true
            end
          when 'more'
            url = "#{CataBot.config['web']['url']}/links/last"
            m.reply "You can see more links here: #{url}", true
          when 'about'
            if link = Link.get(rest)
              m.reply "I've seen #{link.url} first mentioned on #{link.channel} at #{link.stamp.utc.strftime('%Y-%m-%d %H:%M:%S %Z')}", true
              m.reply "It was entitled \"#{link.title}\"", true if link.title
            else
              m.reply 'Don\'t recall such link', true
            end
          else
            m.reply 'Perhaps ask me "links help"?', true
          end
        end
      end
    end
  end
end
