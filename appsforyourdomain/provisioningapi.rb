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

require 'rexml/document'
require 'date'

require 'appsforyourdomain/connection'
require 'appsforyourdomain/exceptions'

module AppsForYourDomain #:nodoc:

  # Google Apps for Your Domain Provisioning API - Example Client in Ruby
  #
  # == What Is This Library?
  #
  # This API enables partners to create, retrieve, update and delete hosted
  # accounts. Partners can also use the API to create email accounts, user
  # aliases and mailing lists.
  #
  # This module expects REXML Ruby module to be already installed
  #
  # == Examples
  #
  #   #!/usr/bin/ruby
  #   require 'appsforyourdomain/provisioningapi'
  #   domain    = "mydomain.com"
  #   adminuser = "root@mydomain.com"
  #   password  = "secret"
  #   a = AppsForYourDomain::ProvisioningAPI.new(domain, adminuser, password)
  #
  #   newuser   = "juser-test"
  #   a.accountCreateWithEmail("joe", "user",    "newpass1", newuser)
  #   a.accountUpdate("jack","the dude","newpass2", newuser)
  #
  #   a.aliasDelete("Test-Alias1")       if a.aliasRetrieve("Test-Alias1")
  #   a.aliasCreate(newuser,"Test-Alias1")
  #
  #   a.mailingListDelete("Test-Group1") if a.mailingListRetrieve("Test-Group1")
  #   a.mailingListCreate("Test-Group1")
  #
  #   a.mailingListAddUser("Test-Group1",newuser)
  #   p a.accountRetrieve(newuser)
  #   a.mailingListRemoveUser("Test-Group1",newuser)
  #
  #   a.aliasDelete("Test-Alias1")
  #   a.accountDelete(newuser)
  #   a.mailingListDelete("Test-Group1")
  #
  class ProvisioningAPI

    # Can be reused across sessions
    attr_accessor :auth_token

    # XML namespace for hosted account provisioning requests and responses
    NS = 'google:accounts:rest:protocol'

    # Base URL for hosted account provisioning requests
    BASEURL = 'https://www.google.com/a/services/v1.0/'

    # Porivisioning API response tags that map to lists.  The key is
    # the tag for the list, the value is the tag for the items.
    LISTTAGS = {
      'aliases' => 'alias',
      'emailLists' => 'emailList',
      'emailAddresses' => 'emailAddress',
    }

    # Creates an Administrative object
    #
    # Args:
    # - domain: such as "google.com"
    # - email: Administrator user such as "root@gmail.com"
    # - password:  Administrator password
    # - backend: ProvisioningAPI URL to connect to (normally not needed)
    #
    def initialize(domain, email = nil, password = nil, backend = BASEURL)
      creds = {'accountType' => 'HOSTED', 'Email' => email,
               'Passwd' => password}
      @domain = domain
      @conn = AppsForYourDomain::Connection.new backend
      @conn.user_agent = "Ruby-ProvisioningAPI/0.1"
      @auth_token = @conn.clientAuth(creds)['SID'] if password
      @backend = backend
    end

    # Convert nested hashes to xml nodes
    #
    # Args:
    # - message: hash of hashes of ...
    #
    # Returns:
    # - REXML::Element tree
    #
    def encode_message(message, name = "rest") #:nodoc: internal
      e = REXML::Element.new "hs:#{name}"
      message.each do |k,v|
        next if v.nil?
        if v.kind_of? Hash
          e.elements << encode_message(v, k)
        else
          e.add_element("hs:#{k}").text = v.to_s
        end
      end
      return e
    end

    # Convert xml nodes to nested hashes
    #
    # Args:
    # - node: REXML::Element
    #
    # Returns:
    # - hash of hashes of ...
    #
    def decode_message(node) #:nodoc: internal
      node.has_elements? or return node.text
      h = {}
      node.elements.each do |e|
        if LISTTAGS[e.name]
          h[e.name] = decode_list(e, LISTTAGS[e.name])
        else
          h[e.name] = decode_message(e)
        end
      end
      return h
    end

    # Convert xml node representing a list into a list
    # of text or nested hashes
    #
    # Args:
    # - node: REXML::Element
    # - elemname: name of the tag denoting each list element
    #
    # Returns:
    # - list of strings and hashes
    #
    def decode_list(node, elemname) #:nodoc: internal
      result = []
      node.elements.each do |e|
        result += [decode_message(e)] if e.name == elemname
      end
      return result
    end

    # encodes, sends, receives decodes message to/from
    # provisioning service
    def request(path, message_in) #:nodoc: internal

      # prepare the request
      p message_in if $DEBUG
      doc = REXML::Document.new '<?xml version="1.0" encoding="UTF-8"?>'
      message_in['token']  = auth_token
      message_in['domain'] = @domain
      doc.add encode_message(message_in)
      doc.root.add_namespace 'hs', NS

      # submit and decode
      body = @conn.perform("POST", @backend + path, doc.to_s).body
      doc  = REXML::Document.new body
      resp = decode_message(doc.root)
      p resp if $DEBUG

      # empty Fetches should not raise exceptions
      if resp['reason'] == 'UserDoesNotExist(1009)' && path.match( /Retrieve/ )
        return nil 
      end

      # sanity check the response before returning
      return resp['RetrievalSection'] if resp['status'] == 'Success(2000)'

      # oops we have an error
      p message_in
      raise APIError, resp['reason'] + ":" + resp['extendedMessage']
    end

    # Creates a new user with an email account
    # Args:
    # - firstName -- The firstName of the user.
    # - lastName -- The lastName of the user.
    # - password -- The password for the user.
    # - userName -- The userName of the user.
    # - quota -- email quota in MB (Only specify if your domain has custom
    # quota values. 
    def accountCreateWithEmail(firstName, lastName, password, userName, quota = 0)
      request 'Create/Account/Email', {
        'type' => 'Account',  'CreateSection' => {
        'firstName' => firstName, 'lastName' => lastName,
        'password'  => password,  'userName' => userName,
        'quota' => quota
      }}
    end
    alias_method :accountCreate, :accountCreateWithEmail

    # Updates an existing user
    def accountUpdate(firstName, lastName, password,
          userName, oldUserName = userName)
      request 'Update/Account', {
        'queryKey' => 'userName', 'queryData' => oldUserName,
        'type' => 'Account',  'UpdateSection' => {
        'firstName' => firstName, 'lastName' => lastName,
        'password'  => password,  'userName' => userName,
      }}
    end

    # Lock/unlock an account
    def accountStatus(userName, lock = false)
      request 'Update/Account/Status', {
        'queryKey' => 'userName', 'queryData' => userName,
        'type' => 'Account',  'UpdateSection' => {
        'accountStatus' => lock ? "locked" : "unlocked",
      }}
    end

    # Retrieves information about a user
    def accountRetrieve(userName)
      request 'Retrieve/Account', {
        'queryKey' => 'userName', 'queryData' => userName, 'type' => 'Account'
      }
    end

    # Deletes a user
    def accountDelete(userName)
      request 'Delete/Account', {
        'queryKey' => 'userName', 'queryData' => userName, 'type' => 'Account'
      }
    end

    # Enable email for a user.
    def accountEnableEmail(userName, enable = true, quota = 0) #:nodoc:
      request 'Update/Account/Email', {
        'queryKey' => 'userName', 'queryData' => userName,
        'type' => 'Account',  'UpdateSection' => {
        'shouldEnableEmailAccount' => enable.to_s,
	'quota' => quota
      }}
    end

     # Creates an alias to an existing user
     def aliasCreate(userName, aliasName)
      request 'Create/Alias', {
        'type'     => 'Alias',  'CreateSection' => {
        'userName' => userName, 'aliasName' => aliasName,
      }}
    end

    # Fetch an alias definition
    def aliasRetrieve(aliasName)
      request 'Retrieve/Alias', {
        'queryKey' => 'aliasName', 'queryData' => aliasName, 'type' => 'Alias'
      }
    end

    # Deletes an alias
    def aliasDelete(aliasName)
      request 'Delete/Alias', {
        'queryKey' => 'aliasName', 'queryData' => aliasName, 'type' => 'Alias'
      }
    end

    # Creates a new mailing list
    def mailingListCreate(mailingListName)
      request 'Create/MailingList', {
        'type'            => 'MailingList',  'CreateSection' => {
        'mailingListName' => mailingListName
      }}
    end

    # Adds a user to a mailinglist
    def mailingListAddUser(mailingListName, username)
      mailingListUpdate(mailingListName, username, 'add')
    end

    # Removes a user from a mailinglist
    def mailingListRemoveUser(mailingListName, username)
      mailingListUpdate(mailingListName, username, 'remove')
    end

    # Add or removes a user from a mailinglist
    #
    # Args:
    # - mailingListName -- The name of the mailing list to update
    # - userName --  The name of user to add or remove
    # - listOperation ( 'add' or 'remove' ) -- whether to add/remove the user
    #
    def mailingListUpdate(mailingListName, userName,
        listOperation = "add") #:nodoc: internal
      request 'Update/MailingList', {
        'queryKey' => 'mailingListName', 'queryData'     => mailingListName,
        'type'     => 'MailingList',     'UpdateSection' => {
        'userName' => userName,          'listOperation' => listOperation
      }}
    end

    # Fetches mailing list membership
    def mailingListRetrieve(mailingListName)
      request 'Retrieve/MailingList', {
        'queryKey' => 'mailingListName', 'queryData'     => mailingListName,
        'type'     => 'MailingList',
      }
    end

    # Removes a mailing list
    def mailingListDelete(mailingListName)
      request 'Delete/MailingList', {
        'queryKey' => 'mailingListName', 'queryData'     => mailingListName,
        'type'     => 'MailingList',
      }
    end

  end

end
