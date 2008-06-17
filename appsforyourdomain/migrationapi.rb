#!/usr/bin/ruby
#
# Copyright 2008 Peter F. Zingg
# Based on Provisioning API ruby client, Copyright 2006 Google Inc.
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

require 'rexml/document'
require 'date'

require 'appsforyourdomain/connection'

module AppsForYourDomain #:nodoc:

  # Google Apps Email Migration API - Example Client in Ruby
  #
  # == What Is This Library?
  #
  # This API enables partners to migrate email to GMail
  #
  # This module expects REXML Ruby module to be already installed
  #
  # There are two different groups who can migrate mail:
  #
  #   * A domain administrator can migrate mail to any mailbox, by specifying 
  #     the username of the mailbox to be migrated, and specifiying
  #     the administrator email and password in the API.new call.
  #   * An end user can migrate mail only to their own mailbox, and only if an
  #     administrator has enabled end-user access to migration. The email 
  #     in the API.new call must correspond to "#{username}@#{domain}".
  #
  # On creation of the EmailMigrationAPI object, an authentication token
  # is obtained from the Google client login.  Client programs may then invoke
  # the uploadSingleMessage or uploadBatchedMessages methods on the
  # object to post messages to the Google Email Migration API.
  #
  # The uploadSingleMessage and uploadBatchedMessages methods have 
  # a single mail object or a list of mail objects as their first 
  # argument respectively.  This can be any object that has a to_s
  # method that will convert the object to a string representing an 
  # RFC822-compliant mail message.  For example, a TMail object or the 
  # contents of a mail message in a file can be used.
  #
  # Note: Client programs must ensure that single or batch XML files
  # posted to GMail are less than 32MB in size.  Messages are base64 encoded
  # so that they will increase in size about 30%.
  #
  # == Example (using TMail)
  #
  #   #!/usr/bin/ruby
  #   require 'tmail'
  #   require 'appsforyourdomain/migrationapi'
  #
  #   domain    = "mydomain.com"
  #   username  = "root"
  #   email     = "root@mydomain.com"
  #   password  = "secret"
  #   a = AppsForYourDomain::EmailMigrationAPI.new(domain, username, email, password)
  #   
  #   mail = TMail.new
  #   mail.to = 'test@loveruby.net'
  #   mail.from = 'Minero Aoki <aamine@loveruby.net>'
  #   mail.subject = 'test mail'
  #   mail.date = Time.now
  #   mail.mime_version = '1.0'
  #   mail.set_content_type 'text', 'plain', {'charset' => 'utf-8'}
  #   mail.body = 'This is test mail.'
  #   a.uploadSingleMessage(mail, ['IS_STARRED', 'IS_UNREAD'], ['Test'])
  #
  # == Properties for migrated emails
  # 
  # 'IS_DRAFT'
  #   The message should be marked as a draft when inserted.
  # 'IS_INBOX'
  #   The message should appear in the Inbox, regardless of its labels. 
  #   (By default, a migrated mail message will appear in the Inbox only if 
  #   it has no labels.)
  # 'IS_SENT'
  #   The message should be marked as "Sent Mail" when inserted.
  # 'IS_STARRED'
  #   The message should be starred when inserted.
  # 'IS_TRASH'
  #   The message should be marked as "Trash" when inserted.
  # 'IS_UNREAD' 
  #   The message should be marked as unread when inserted. Without this 
  #   property, a migrated mail message is marked as read.
  
  class EmailMigrationAPI
    # XML Namespace for Atom feeds
    NS_ATOM  = 'http://www.w3.org/2005/Atom'
    
    # XML namespace for Google Apps
    NS_APPS  = 'http://schemas.google.com/apps/2006'
    
    # XML namespace for GData batch results
    NS_BATCH = 'http://schemas.google.com/gdata/batch'

    # Base URL for email migration requests
    BASEURL = 'https://apps-apis.google.com/a/feeds/migration/2.0/'

    # Creates an Administrative object
    #
    # Args:
    # - domain: such as "google.com"
    # - email: user such as "root@gmail.com"
    # - password:  Administrator password
    # - backend: Email Migration API URL to connect to (normally not needed)
    #
    def initialize(domain, username, email, password, backend = BASEURL)
      @domain   = domain
      @username = username
      @conn     = AppsForYourDomain::Connection.new(backend)
      @conn.user_agent = "Ruby-EmailMigrationAPI/0.1"
      
      creds = {
        'Email'   => email, 'Passwd'  => password,
        'accountType' => 'HOSTED', 'service' => 'apps' }
      tokens = @conn.clientAuth(creds)
      
      # The Auth value is the authentication token that you'll send to the 
      # Email Migration API with your request, so keep a copy of that value. 
      # You can ignore the SID and LSID values.
      raise 'No authorization' unless tokens.key?('Auth')
      @conn.authorization = "GoogleLogin auth=#{tokens['Auth']}"
      @backend = backend
    end

    def self.newXmlDocument(root_element)
      doc = REXML::Document.new
      doc << REXML::XMLDecl.new("1.0", "UTF-8")
      root = doc.add_element(root_element)
      root.add_namespace('atom',  NS_ATOM)
      root.add_namespace('batch', NS_BATCH)
      root.add_namespace('apps',  NS_APPS)
      doc
    end

    def self.decodeResponse(response) #:nodoc: internal
      status = { 'request' => { :code => response.code.to_i, :message => response.message } }
      doc  = REXML::Document.new(response.body)
      doc.root.elements.each('atom:entry') do |entry|
        batch_id     = entry.elements['batch:id']
        batch_status = entry.elements['batch:status']
        if !batch_id.nil? && !batch_status.nil?
          atom_id = entry.elements['atom:id']
          status[batch_id.text.to_i] = { 
            :id      => atom_id.nil? ? nil : atom_id.text,
            :code    => batch_status.attributes['code'],
            :message => batch_status.attributes['reason'] }
        end
      end
      status
    end

    # Encodes, sends, receives decodes message to/from
    # email migration service.
    # Returns a hash where the batch id (integer 1..n) is the key
    # and the value is a has with :code, :message and :id key-value pairs
    #
    # On a successful post, each batched item will have a code and
    # text message returned.
    # 
    # 201 Created:
    #   The message was successfully migrated
    #
    # 400 Bad Request: 
    #   If a message is rejected as malformed, you'll receive a 
    #   400 Bad Request batch status code
    #
    # 503 Service Unavailable: 
    #   If your client exceeds the maximum allowed
    # rate of message uploads per second, the entries that failed contain 
    # the batch status code 503 Service Unavailable. If you receive that
    # status code, then record which entries failed (using their batch IDs) 
    # and retry the upload. We recommend using an exponential backoff 
    # strategy for this process. For example, you might wait thirty seconds 
    # and retry the upload; then if your request still returns 503s,
    # wait 60 seconds before trying again, and so on.    
    def request(doc) #:nodoc: internal

      # submit and decode
      path = "#{@backend}#{@domain}/#{@username}/mail/batch"
      begin
        resp = @conn.perform("POST", path, doc.to_s, 'application/atom+xml')
        return EmailMigrationAPI.decodeResponse(resp)
        
        # On an overall malformed request, you'll get a 400 for the post:
      rescue Net::HTTPServerException => e
        $stderr.print "#{e} POSTing to #{path}\n" 
        return { 'request' => { :code => e.response.code.to_i, :message => e.response.message } }
      end
    end

    def addEntryContents(entry, rfc822msg,  properties=[], labels=[], batch_id=nil)
      entry.add_element('atom:category', 
        'scheme' => 'http://schemas.google.com/g/2005#kind',
        'term'   => 'http://schemas.google.com/apps/2006#mailItem')
      msg = entry.add_element('apps:rfc822Msg', 'encoding' => 'base64')
      msg.add_text([rfc822msg.to_s].pack('m')) # base64 encoding
      properties.each do |prop| 
        entry.add_element('apps:mailItemProperty', 'value' => prop)
      end
      labels.each do |label| 
        entry.add_element('apps:label', 'labelName' => label)
      end
      if !batch_id.nil?
        entry.add_element('batch:id').add_text(batch_id.to_s)
      end
    end

    def uploadBatchedMessages(message_list, properties=[], labels=[])      
      doc = EmailMigrationAPI.newXmlDocument('atom:feed')
      batch_id = 1
      message_list.each do |rfc822msg|
        entry = doc.root.add_element('atom:entry')
        addEntryContents(entry, rfc822msg, properties, labels, batch_id)
        batch_id += 1
      end
      request(doc)
    end
    
    def uploadSingleMessage(rfc822msg, properties=[], labels=[])  
      return uploadBatchedMessages([rfc822msg], properties, labels)
      
      # non-batched alternative
      # doc = EmailMigrationAPI.newXmlDocument('atom:entry')
      # addEntryContents(doc.root, rfc822msg, properties, labels)
      # request(doc)
    end
  end

end
