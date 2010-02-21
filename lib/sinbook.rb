begin
  require 'sinatra/base'
rescue LoadError
  retry if require 'rubygems'
  raise
end

class FacebookError < StandardError
  attr_accessor :data
end

module Sinatra
  require 'digest/md5'

  class FacebookObject
    def initialize app
      if app.respond_to?(:options)
        @app = app

        [ :api_key, :secret, :app_id, :url, :callback, :symbolize_keys ].each do |var|
          instance_variable_set("@#{var}", app.options.send("facebook_#{var}"))
        end
      else
        [ :api_key, :secret, :app_id ].each do |var|
          raise ArgumentError, "missing option #{var}" unless app[var]
          instance_variable_set("@#{var}", app[var])
        end
        [:url, :callback, :symbolize_keys ].each do |var|
          instance_variable_set("@#{var}", app[var]) if app.has_key?(var)
        end
      end
    end

    attr_reader :app
    attr_accessor :api_key, :secret
    attr_writer :url, :callback, :app_id

    def app_id
      @app_id || self[:app_id]
    end

    def url postfix=nil
      postfix ? "#{@url}#{postfix}" : @url
    end

    def callback postfix=nil
      postfix ? "#{@callback}#{postfix}" : @callback
    end

    def addurl
      "http://apps.facebook.com/add.php?api_key=#{self.api_key}"
    end

    def appurl
      "http://www.facebook.com/apps/application.php?id=#{self.app_id}"
    end

    def require_login!
      if valid?
        redirect addurl unless params[:user]
      else
        app.redirect url
      end
    end

    def redirect url
      url = self.url + url unless url =~ /^http/
      if params[:in_iframe]
        app.body "<script type=\"text/javascript\">top.location.href=\"#{url}\"</script>"
      else
        app.body "<fb:redirect url='#{url}'/>"
      end
      throw :halt
    end

    def params
      return {} unless valid?
      app.env['facebook.params'] ||= \
        app.env['facebook.vars'].inject({}) do |h,(k,v)|
          s = k.to_sym
          case k
          when 'friends'
            h[s] = v.split(',').map{|e|e.to_i}
          when /time$/
            h[s] = Time.at(v.to_f)
          when 'expires'
            v = v.to_i
            h[s] = v>0 ? Time.at(v) : v
          when 'user', 'app_id', 'canvas_user'
            h[s] = v.to_i
          when /^(logged_out|position_|in_|is_|added)/
            h[s] = v=='1'
          else
            h[s] = v
          end
          h
        end
    end

    def [] key
      params[key]
    end

    def valid?
      if app.nil?
        return false
      elsif app.params['fb_sig'] # canvas/iframe mode
        prefix = 'fb_sig'
        vars = app.request.POST[prefix] ? app.request.POST : app.request.GET
      elsif app.request.cookies[api_key] # fbconnect mode
        prefix = api_key
        vars = app.request.cookies
      else
        return false
      end

      if app.env['facebook.valid?'].nil?
        fbvars = {}
        sig = Digest::MD5.hexdigest(vars.map{|k,v|
          if k =~ /^#{prefix}_(.+)$/
            fbvars[$1] = v
            "#{$1}=#{v}"
          end
        }.compact.sort.join+self.secret)

        if app.env['facebook.valid?'] = (vars[prefix] == sig)
          app.env['facebook.vars'] = fbvars
        end
      end

      app.env['facebook.valid?']
    end

    class APIProxy
      Types = %w[
        admin
        application
        auth
        batch
        comments
        connect
        data
        events
        fbml
        feed
        fql
        friends
        groups
        links
        liveMessage
        notes
        notifications
        pages
        photos
        profile
        sms
        status
        stream
        users
        video
      ]

      alias :__class__ :class
      alias :__inspect__ :inspect
      instance_methods.each { |m| undef_method m unless m =~ /^(__|object_id)/ }
      alias :inspect :__inspect__

      def initialize name, obj
        @name, @obj = name, obj
      end

      def method_missing method, opts = {}
        @obj.request "#{@name}.#{method}", opts
      end
    end

    APIProxy::Types.each do |n|
      class_eval %[
        def #{n}
          (@proxies||={})[:#{n}] ||= APIProxy.new(:#{n}, self)
        end
      ]
    end

    def request method, opts = {}
      if method == 'photos.upload'
        image = opts.delete :image
      end

      opts = { :api_key => self.api_key,
               :call_id => Time.now.to_f,
               :format => 'JSON',
               :v => '1.0',
               :session_key => %w[ photos.upload ].include?(method) ? nil : params[:session_key],
               :method => method }.merge(opts)

      args = opts.map{ |k,v|
                       next nil unless v

                       "#{k}=" + case v
                                 when Hash
                                   if Object.const_defined?("Yajl") && Yajl.const_defined?("Encoder")
                                     Yajl::Encoder.encode(v)
                                   elsif Object.const_defined("JSON")
                                     JSON.generate(v)
                                   else
                                     throw "you need to require either 'yajl' or 'json' for sinbook to work"
                                   end
                                 when Array
                                   if k == :tags
                                     if Object.const_defined?("Yajl") && Yajl.const_defined?("Encoder")
                                       Yajl::Encoder.encode(v)
                                     elsif Object.const_defined("JSON")
                                       JSON.generate(v)
                                     else
                                       throw "you need to require either 'yajl' or 'json' for sinbook to work"
                                     end
                                   else
                                     v.join(',')
                                   end
                                 else
                                   v.to_s
                                 end
                     }.compact.sort

      sig = Digest::MD5.hexdigest(args.join+self.secret)

      if method == 'photos.upload'
        data = MimeBoundary
        data += opts.merge(:sig => sig).inject('') do |buf, (key, val)|
          if val
            buf << (MimePart % [key, val])
          else
            buf
          end
        end
        data += MimeImage % ['upload.jpg', 'jpg', image.respond_to?(:read) ? image.read : image]
      else
        data = Array["sig=#{sig}", *args.map{|a| a.gsub('&','%26') }].join('&')
      end

      ret = self.class.request(data, method == 'photos.upload')

      ret = if ['true', '1'].include? ret
              true
            elsif ['false', '0'].include? ret
              false
            elsif (n = Integer(ret) rescue nil)
              n
            else
              Yajl::Parser.parse(ret, :symbolize_keys => @symbolize_keys)
            end

      if ret.is_a?(Hash) and (ret['error_code'] or ret[:error_code])
        err = FacebookError.new(ret['error_msg'] || ret[:error_msg])
        err.data = ret
        raise err
      end

      ret
    end

    MimeBoundary = "--SoMeTeXtWeWiLlNeVeRsEe\r\n"
    MimePart = %[Content-Disposition: form-data; name="%s"\r\n\r\n%s\r\n] + MimeBoundary
    MimeImage = %[Content-Disposition: form-data; filename="%s"\r\nContent-Type: image/%s\r\n\r\n%s\r\n] + MimeBoundary

    require 'resolv'
    @keepalive = false

    def self.connect
      sock = TCPSocket.new(@api_server_ip ||= Resolv.getaddress('api.facebook.com'), 80)
      begin
        timeout = [3,0].pack('l_2') # 3 seconds
        sock.setsockopt Socket::SOL_SOCKET, Socket::SO_RCVTIMEO, timeout
        sock.setsockopt Socket::SOL_SOCKET, Socket::SO_SNDTIMEO, timeout
      rescue Exception => ex
        # causes issues on solaris?
        puts ex.inspect
      end
      sock
    end

    def self.request data, mime=false
      if @keepalive
        @socket ||= connect
      else
        @socket = connect
      end

      @socket.print "POST /restserver.php HTTP/1.1\r\n"
      @socket.print "Host: api.facebook.com\r\n"
      @socket.print "Connection: keep-alive\r\n" if @keepalive
      if mime
        @socket.print "Content-Type: multipart/form-data; boundary=#{MimeBoundary[2..-3]}\r\n"
        @socket.print "MIME-version: 1.0\r\n"
      else
        @socket.print "Content-Type: application/x-www-form-urlencoded\r\n"
      end
      @socket.print "Content-Length: #{data.length}\r\n"
      @socket.print "\r\n#{data}\r\n"
      @socket.print "\r\n\r\n"

      buf = ''
      headers = ''
      headers_done = false
      chunked = true

      while true
        line = @socket.gets
        headers << line unless headers_done
        raise Errno::ECONNRESET unless line

        if line == "\r\n" # end of headers/chunk
          unless headers_done
            headers_done = true
            if headers =~ /Encoding: chunked/i
              chunked = true
            else
              len = headers[/Content-Length: (\d+)/i,1].to_i
              buf = @socket.read(len)
              break # done!
            end
          end

          line = @socket.gets # get size of next chunk
          if line.strip! == '0' # 0 sized chunk
            @socket.gets # read last crlf
            break # done!
          end

          buf << @socket.read(line.to_i(16)) # read in chunk
        end
      end

      buf
    rescue Errno::EPIPE, Errno::ECONNRESET
      @socket = nil
      retry
    ensure
      @socket.close if @socket and !@keepalive
    end
  end

  module FacebookHelper
    def facebook
      env['facebook.helper'] ||= FacebookObject.new(self)
    end
    alias fb facebook
  end

  class FacebookSettings
    def initialize app, &blk
      @app = app
      @app.set :facebook_symbolize_keys, false
      instance_eval &blk
    end
    %w[ api_key secret app_id url callback symbolize_keys ].each do |param|
      class_eval %[
        def #{param} val, &blk
          @app.set :facebook_#{param}, val
        end
      ]
    end
  end

  module Facebook
    def facebook &blk
      FacebookSettings.new(self, &blk)
    end

    FixRequestMethod = proc{
      if method = request.params['fb_sig_request_method']
        request.env['REQUEST_METHOD'] = method
      end
    }

    def self.registered app
      app.helpers FacebookHelper
      app.before(&FixRequestMethod)
    end
  end

  Application.register Facebook
end

Sinbook = Sinatra::FacebookObject
