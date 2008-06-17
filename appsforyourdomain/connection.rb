#!/usr/bin/ruby
#
# Copyright 2006 Google Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License"); you may not
# use this file except in compliance with the License. You may obtain a copy of
# the License at
#
# http://www.apache.org/licenses/LICENSE-2.0 
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
# WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
# License for the specific language governing permissions and limitations under
# the License.
#

require 'net/https'
require 'appsforyourdomain/exceptions'

module AppsForYourDomain #:nodoc:

  # Implements Persistent Connections to Google
  #
  # This class provides built-in support for higher-performing
  # persistent http/https connections to www.google.com.
  # It supports most all HTTP methods
  # (GET, POST, PUT, DELETE, SEARCH, PROPFIND, etc).
  # It also provides easy framework for authenticating with
  # Google-Client-Login-API[http://code.google.com/apis/accounts/AuthForInstalledApps.html].
  class Connection

    GOOGLE_URL   = 'https://www.google.com'
    AUTH_PATH    = '/accounts/ClientAuth'
    LOGIN_PATH   = '/accounts/ClientLogin'
    DEFAULT_CONTENT_TYPE = 'application/x-www-form-urlencoded'

    # the underlying ruby http(s) connection
    attr_accessor :connection
    # Override User-Agent sent to web server
    attr_accessor :user_agent
    # set Authorization header
    attr_accessor :authorization
    # follow HTTP redirections up to a max. Default is 10
    attr_accessor :max_redirects

    # Establishes an SSL (or plain http) connection to a host
    # that can be cached for multiple http transactions
    #
    # Args:
    # - url: string - pass nil to suppress connecting
    #
    def initialize(url = GOOGLE_URL)

      @user_agent    = "Ruby-GoogleConnection/0.2"
      @max_redirects = 10
      @connection    = connect(url) if url
    end

    # Force connect/reconnect after initialization
    #
    # Args:
    # - url: string
    #
    def connect(url)
      uri                    = URI.parse(url)
      conn                   = Net::HTTP.new(uri.host, uri.port)
      conn.set_debug_output $stderr if $DEBUG
      if uri.scheme == 'https'
        # conn.ca_file         = __FILE__ # certs embedded at end of this file
        # conn.verify_mode     = OpenSSL::SSL::VERIFY_PEER
        conn.use_ssl         = true
      end
      conn.start             # open up connection
      return conn
    end

    # Performs a GET/PUT/POST/DELETE on the persistent connection.
    # Follows redirections.
    #
    # Args:
    # - method: string such as "POST"
    # - url: string to send
    # - body: string to send
    # - content_type: string mimetype to send
    #
    # Returns:
    # Net::HTTPResponse object.
    #
    # Raises:
    # Raises Net::HTTPException on HTTP failures.
    #
    # To suppress exceptions and glean the response object anyway,
    # use the following:
    #
    #   begin
    #     resp = perform(...)
    #   rescue => exception
    #     p exception.response.body
    #   end
    #
    def perform(method, url, body = nil, content_type = DEFAULT_CONTENT_TYPE)
      1.upto(max_redirects) do |count|
        uri  = URI.parse(url)
        path = uri.request_uri
     
        # some firewalls only allow GET/POST 
        fakemethod = method
        if method != 'GET' && method != 'POST'
          fakemethod = "POST"
        end 

        req  = Net::HTTPGenericRequest.new(fakemethod, !body.nil?, true, path)
        req['Authorization']    = authorization if authorization
        req['User-Agent']       = user_agent

        req['Connection']       = 'Keep-alive'
        req['Host']             = uri.host
   
        if body
          req['Content-Type']   = content_type if content_type
          req['Content-Length'] = body.length.to_s
        end

        # reveal real method to Google
        if method != fakemethod
          req['Content-Length'] = '0' if body.nil?
          req['X-HTTP-Method-Override'] = method
        end

        # send request, receive response
        resp = nil
        begin 
          resp        = connection.request(req,body)
        rescue EOFError, Errno::EPIPE
          # persistent connection torn down by server
          @connection = connect(url)                 # reconnect
          next
        end

        # handle response
        case resp
          when Net::HTTPSuccess:       return resp # done
          when Net::HTTPRedirection:   url = resp['location']
          else                         resp.error! # can be rescued by caller
        end

        # we have a redirect for sure
        if uri.path.match( /unavailable.html/ )
          raise TransportError, "Server Unavailable: Try again Later"
        end

        # loop to follow the redirect
      end
      raise TransportError, "HTTP::Too many HTTP redirects"
    end

    alias_method :exec, :perform

    # Converts parameters to x-www-form-urlencoded suitable for GET/PUT.
    #
    # Some versions of net/http.rb do not supply this.
    #
    # Args:
    # - hash: such as
    #   { 'q'=> 'ruby doc', 'count' => '15' }
    #
    # Returns:
    # String of http encoded params such as
    #   q=ruby+doc&count=15
    #
    def self.encode_params(hash)
      encoded = ""
      hash.each do |k,v|
        encoded << "#{k}=" + URI.escape(v) + '&' if v
      end
      return encoded.chop # remove superfluous &
    end

    # Parses authentication tokens 
    # from NAME=VALUE pairs separated by lines
    #
    # Args: 
    # - body:
    #   such as "a=1\nb=2\n=3"
    #
    # Returns:
    # Hash such as
    #   { 'a'=>1, 'b'=>2, 'c'=>3 }
    #
    def self.split_pairs(body) #:nodoc: private
      results = Hash.new
        body.each_line do |line|
          key,val = line.chomp.split(/=/,2)
          results[key] = val
        end
      return results
    end

    # Performs Client Login API
    #
    # Args
    # - params: hash of options 
    #           Email:        User's full email address. (including domain)
    #           Passwd:       User's password.
    #           accountType:  'HOSTED' or 'GOOGLE' or 'HOSTED_OR_GOOGLE' or nil
    #           service:      Google service requested
    #           source:       "companyName-applicationName-versionID"
    #           logintoken:   optional
    #           logincaptcha: optional
    #
    # - backend: Login URL to connect to (normally not needed)
    #
    # Returns
    # Hash of Authentication tokens to be used on subsequent transactions
    #
    # Raises exceptions depending on the response of the Auth server.
    #
    # See also http://code.google.com/apis/accounts/AuthForInstalledApps.html

    def clientLogin(params, backend = GOOGLE_URL + LOGIN_PATH )
      postbody = self.class.encode_params(params)
      begin
        resp = perform "POST", backend, postbody, DEFAULT_CONTENT_TYPE 
        return self.class.split_pairs(resp.body)
      rescue => exception
        raise exception, exception.response.body, caller
      end
    end

    # Performs Google Deprecated Authentication
    #
    # Args
    # - params: hash of options 
    #           Email:        User's full email address. (including domain)
    #           Passwd:       User's password.
    #           accountType:  'HOSTED' or 'GOOGLE' or 'HOSTED_OR_GOOGLE' or nil
    #
    # - backend: Login URL to connect to (normally not needed)
    #
    # Returns
    # Hash of Authentication tokens to be used on subsequent transactions
    #
    # Raises exceptions depending on the response of the Auth server.
    #
    def clientAuth(params, backend = GOOGLE_URL + AUTH_PATH ) #:nodoc:
      clientLogin(params, backend)  # code reuse
    end

  end

end

# collection of certs must be left aligned for OpenSSL::SSL to parse
<<END_OF_CERTS
C=US, O=VeriSign, Inc., OU=Class 3 Public Primary Certification Authority
Root Level CA that which issues Thawte cert, which issues www.google.com.
This cert is provided by OpenSSL distro and expires 2028-09-01
-----BEGIN CERTIFICATE-----
MIICPDCCAaUCEHC65B0Q2Sk0tjjKewPMur8wDQYJKoZIhvcNAQECBQAwXzEL
MAkGA1UEBhMCVVMxFzAVBgNVBAoTDlZlcmlTaWduLCBJbmMuMTcwNQYDVQQL
Ey5DbGFzcyAzIFB1YmxpYyBQcmltYXJ5IENlcnRpZmljYXRpb24gQXV0aG9y
aXR5MB4XDTk2MDEyOTAwMDAwMFoXDTI4MDgwMTIzNTk1OVowXzELMAkGA1UE
BhMCVVMxFzAVBgNVBAoTDlZlcmlTaWduLCBJbmMuMTcwNQYDVQQLEy5DbGFz
cyAzIFB1YmxpYyBQcmltYXJ5IENlcnRpZmljYXRpb24gQXV0aG9yaXR5MIGf
MA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDJXFme8huKARS0EN8EQNvjV69q
RUCPhAwL0TPZ2RHP7gJYHyX3KqhEBarsAx94f56TuZoAqiN91qyFomNFx3In
zPRMxnVx0jnvT0Lwdd8KkMaOIG+YD/isI19wKTakyYbnsZogy1Olhec9vn2a
/iRFM9x2Fe0PonFkTGUugWhFpwIDAQABMA0GCSqGSIb3DQEBAgUAA4GBALtM
EivPLCYATxQT3ab7/AoRhIzzKBxnki98tsX63/Dolbwdj2wsqFHMc9ikwFPw
TtYmwHYBV4GSXiHx0bH/59AhWM1pF+NEHJwZRDmJXNycAA9WjQKZ7aKQRUzk
uxCkPfAyAw7xzvjoyVGM5mKf5p/AfbdynMk2OmufTqj/ZA1k
-----END CERTIFICATE-----
END_OF_CERTS
