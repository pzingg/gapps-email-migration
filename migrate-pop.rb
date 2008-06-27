#!/usr/bin/ruby

# Copyright 2008 Peter F. Zingg--may be freely used without restriction.
# 
# A utility to upload a batch of (POP or IMAP) mail messages to a 
# Google Apps mail store using the Email Migration API. Example usage:
#
# ruby migrate-pop.rb -d example.com -e admin@example.com -p passwd \
#   -u pop_user -t apple --inbox path_to/INBOX.mbox
#
# The simple parser below will handle UNIX-style .mbx files (multiple messages
# in one file), a directory of individual messages ("maildir"), or Apple's
# .mbox directory tree containing .emlx files (email messages wrapped with 
# metadata).

# Exporting from Eudora (In.mbx and Out.mbx files on Windows; In and Out on Mac)
# 
# After a few attempts, I conclude that Eudora mbx files are not clean enough 
# use the standard TMail::UNIXMbox parser.  I recommend Eudora Mailbox Cleaner
# for Macintosh, available from:
#
# http://homepage.mac.com/aamann/Eudora_Mailbox_Cleaner.htm
#
# or Eudora Rescue for Windows, from:
#
# http://qwerky.50webs.com/eudorarescue 
# 
# I used EMC to convert to a Mozilla-Thunderbird-compatible .mbx file.
# These end up in ~/Library/Thunderbird/Profiles/*/Mail/Local Folders/*.sbd
# Even the EMC-converted file was not clean enough, so I then resorted to a 
# perl utility, mb2md.pl, from:
#
# http://batleth.sapienti-sat.org/projects/mb2md/
#
# After running this on the EMC-converted .mbx file, I upload the 
# contents of the exported ~/Maildir/cur directory with "-t maildir".

# Exporting from Outlook (.pst file)
# 
# Use the open source readpst / libpst project, available from:
#
# http://alioth.debian.org/projects/libpst

# Exporting from Entourage (Database file)
# 
# Use a freeware AppleScript, Export Folders, from:
#
# http://scriptbuilders.net/files/exportfolders1.1.html
#
# After exporting, these MBOX files must have CR line endings changed
# to LF.  I use crlf, a shell script (with IFS modification) to 
# get this done.

require 'rubygems'
require 'getoptlong'
require 'tmail'
require 'appsforyourdomain/migrationapi'

class Migrator
  attr_accessor :dry_run, :count
  
  def initialize(domain, user, email, passwd, from, type, props, labels, source)
    @domain = domain
    @user = user
    @email = email
    @passwd = passwd
    @type = type
    @props = props
    @labels = labels
    @source = source
    @default_from = from
    @dry_run = false
    @count = 0
  end
  
  def is_mbox?
    @type == 'mbox'
  end
  
  def is_apple_mail?
    @type == 'apple'
  end
  
  def is_outlook?
    @type == 'outlook'
  end
  
  def is_file?
    @type == 'file'
  end
  
  def do_migration
    @migration = AppsForYourDomain::EmailMigrationAPI.new(@domain, @user, @email, @passwd)
    if is_mbox?
      upload_mbox_tree(@source)
    elsif is_apple_mail?
      # In Tiger, .emlx files are inside the Messages sub-folder
      upload_maildir(File.join(@source, 'Messages'))
    elsif is_file?
      upload_mail_file(@source)
    else
      upload_maildir(@source)
    end
  end

  def read_emlx(path)
    msg = nil
    File.open(path, "r") do |f|
      msg_size = f.readline.chomp.to_i
      return nil unless msg_size > 0
      msg = f.read(msg_size)
    end
    msg
  end

  def is_mail_message?(str)
    !str.nil? && str.match(/^[-A-Za-z0-9]+: /)
  end
  
  def parse_addresses(str)
    addrs = [ ]
    str.split(/;/).each do |addr|
      addr_strip = addr.strip.gsub(/^['"]|['"]$/, "")
      begin
        a = TMail::Address.parse(addr_strip)
        addrs.push(a) 
      rescue TMail::SyntaxError
        print "can't parse #{addr_strip}\n"
        fake_addr = addr_strip.downcase.gsub(/[^a-z0-9_]+/, ".").gsub(/^[.]+|[.]+$/, "")
        a = TMail::Address.parse("#{fake_addr}\@unknown.com")
        a.name = addr_strip
        addrs.push(a)
      end
    end
    addrs
  end

  # Without these patches, Google will report "badly formed message"
  # or invalid RFC822 route errors.  We also add the time stamp if 
  # it is missing.
  def patch_mail_port(port)
    return nil if port.nil?

    msg = nil
    use_raw_message = true
    begin
      mail = TMail::Mail.new(port)
            
      if mail.to.nil?
        use_raw_message = false
        if port.read_all.match(/To: (.+)\n/)
          to_addresses = parse_addresses($1)
          mail.to = to_addresses
          print "patching to addresses: #{to_addresses.join(', ')}\n"
        else
          mail.to = "unknown@unknown.com"
          print "patching to addresses: #{mail.to}\n"
        end
      end
      
      if mail.from.nil?
        use_raw_message = false
        mail.from = @default_from
        print "patching from address: #{mail.from}\n"
      end
      
      if mail.date.nil?
        use_raw_message = false
        # Eudora mbx files don't put the date in a Date: header
        # Instead they put it in the From line, like this:
        # From ???@??? Mon Oct 13 07:26:26 2003
        # We rebuild the message with the added date header.
        # The port (tmp file) has its utime set by TMail.
        mail.date =  File.mtime(port.filename)
        print "patching date: #{mail.date}\n"
      end
      
      # Eudora (and others?) don't specify html email.
      # We assume text/html content-type if body begins with <html>.
      if mail.body =~ /^\s*\<html\>/ && !mail.content_type =~ /html/
        use_raw_message = false
        print "setting text/html content type\n"
        mail.content_type = 'text/html'
        print "patching content type: #{mail.content_type}\n"
      end
      
      if use_raw_message
        # Just use the message as read
        msg = port.read_all
      else
        msg = mail.encoded
      end
    rescue
      print "could not parse mail message: #{$!}\n"
    end
    
    msg
  end
  
  def patch_mail_file(path)
    port = nil
    begin
      if path =~ /\.emlx$/
        # Handle .emlx formatted mails 
        str = read_emlx(path)
        port = TMail::StringPort.new(str) if !str.nil? && !str.empty?
      elsif !is_apple_mail?
        # Handle individual messages in a maildir
        port = TMail::FilePort.new(path)
      end
    rescue
    end
    return patch_mail_port(port)
  end
  
  # Google sends a 503 message if server is busy
  def upload_with_retries(msg)
    status = nil
    1.upto(5) do |i|
      status = @migration.uploadSingleMessage(msg, @props, @labels)
      break if status.nil? || status[1].nil? || status[1][:code] != '503'
      sleep(30)
    end
    status
  end
  
  # Uploads a unix mbox file
  def upload_mbox(source_file)
    msg_num = 0
    begin
      mbox = TMail::UNIXMbox.new(source_file, nil, true)
      print "opened mbox file #{source_file}\n"
      mbox.each_port do |port|
        msg_num += 1
        msg = patch_mail_port(port)
        begin
          if is_mail_message?(msg)
            print "uploading msg #{msg_num} in #{source_file}\n"
            print "#{mail.subject}\n"
            print "#{mail.date}\n"
            if @dry_run
              print msg
            else
              status = upload_with_retries(msg)
              if !status.nil? && !status[1].nil? && status[1][:code] == '201'
                @count += 1
                print "msg #{msg_num} uploaded\n"
              else
                print "msg #{msg_num} not uploaded\n"
                p status
              end
            end
            sleep(0.5)
          else
            print "msg #{msg_num} is not a mail message\n"
          end
        rescue
          print "could not read/upload msg #{msg_num}\n"
        end
      end
    rescue
      print "#{source_file} is not a unix mbox file\n" 
    end
  end
  
  # Uploads a tree of unix mbox files
  def upload_mbox_tree(source)
    if File.file?(source)
      upload_mbox(source)
    else
      Dir.new(source).each do |f|
        next if f == '.' || f == '..'
        path = File.join(source, f)
        if File.file?(path)
          upload_mbox(path)
        elsif File.directory?(path)
          # Recurse.
          upload_mbox_tree(path)
        end
      end
    end
  end
  
  # Uploads emlx messages inside a Tiger-style .mbox directory tree.
  # Also uploads regular message files inside a maildir-style directory.
  def upload_mail_file(path)
    msg = nil
    begin
      msg = patch_mail_file(path)
      if is_mail_message?(msg)
        print "uploading #{path}\n"
        if @dry_run
          # print msg
        else
          status = upload_with_retries(msg)
          if !status.nil? && !status[1].nil? && status[1][:code] == '201'
            @count += 1 
            print "#{path} uploaded\n"
          else
            print "#{path} not uploaded\n"
            p status
          end
        end
        sleep(0.5)
      else
        print "#{path} is not a mail message\n"
      end
    rescue
      print "could not read/upload #{path}\n"
    end
    msg
  end
  
  # Uploads emlx messages inside a Tiger-style .mbox directory tree.
  # Also uploads regular message files inside a maildir-style directory.
  def upload_maildir(source_dir)
    Dir.new(source_dir).each do |f|
      next if f == '.' || f == '..'
      path = File.join(source_dir, f)
      if File.file?(path)
        upload_mail_file(path)
      elsif File.directory?(path) && !is_apple_mail?
        # Recurse.          
        upload_maildir(path)
      end
    end
  end
  
end


opts = GetoptLong.new(
  [ '--draft',    '-a', GetoptLong::NO_ARGUMENT ],
  [ '--domain',   '-d', GetoptLong::REQUIRED_ARGUMENT ],
  [ '--admin-email', '-e', GetoptLong::REQUIRED_ARGUMENT ],
  [ '--starred',  '-x', GetoptLong::NO_ARGUMENT ],
  [ '--from',     '-f', GetoptLong::REQUIRED_ARGUMENT ],
  [ '--help',     '-h', GetoptLong::NO_ARGUMENT ],
  [ '--inbox',    '-i', GetoptLong::NO_ARGUMENT ],
  [ '--label',    '-l', GetoptLong::REQUIRED_ARGUMENT ],
  [ '--unread',   '-n', GetoptLong::NO_ARGUMENT ],
  [ '--password', '-p', GetoptLong::REQUIRED_ARGUMENT ],
  [ '--trash',    '-r', GetoptLong::NO_ARGUMENT ],
  [ '--sent',     '-s', GetoptLong::NO_ARGUMENT ],
  [ '--type',     '-t', GetoptLong::REQUIRED_ARGUMENT ],
  [ '--user',     '-u', GetoptLong::REQUIRED_ARGUMENT ])

def usage
  puts "Usage: migrate-pop.rb [options] mailbox_or_dir"
  puts "Use Google Apps Email Migration API to upload messsages to a user."
  puts "Uploaded messages will be given the label 'Migrated-POP'."
  puts "Required options:"
  puts "  -d, --domain:      Google Apps domain" 
  puts "  -e, --admin-email: email address for Google Apps authentication"
  puts "  -p, --password:    password for Google Apps authentication"
  puts "  -u, --user:        user name (without domain) to migrate mail to"
  puts "  mailbox_or_dir:    source folder or mbox file"
  puts "Other options:"
  puts "  -f, --from:        if missing, email 'From:' value"
  puts "  -t, --type:        type of message source (default is apple):"
  puts "     apple   (folder containing Messages folder with .emlx files)"
  puts "     maildir (folder tree with email message files)"
  puts "     file    (one email message in a file)"
  puts "     mbox    (single UNIX mbox file with multiple messages)"
  puts "     outlook (mbox that needs help)"
  puts "  -l, --label:       tag with label (can use multiple labels)"
  puts "Optional message flags (without arguments):"
  puts "  --inbox:           migrate to GMail Inbox folder"
  puts "  --sent:            migrate to GMail Sent Messages folder"
  puts "  --draft:           migrate to GMail Drafts folder"
  puts "  --trash:           migrate to GMail Trash folder"
  puts "  --starred:         add to Starred items"
  puts "  --unread:          mark as unread"
end

domain = nil
email = nil
passwd = nil
user = nil
from = nil
type = 'apple'
dest = nil
props = []
labels = ['Migrated-POP']
opts.each do |opt, arg|
  case opt
  when '--help'
    usage
    exit
  when '--from'
    from = arg
  when '--domain'
    domain = arg
  when '--admin-email'
    email = arg
  when '--password'
    passwd = arg
  when '--user'
    user = arg
  when '--type'
    type = arg
  when '--label'
    labels.push(arg)
  when '--draft'
    dest = 'IS_DRAFT'
  when '--inbox'
    dest = 'IS_INBOX'
  when '--sent'
    dest = 'IS_SENT'
  when '--trash'
    dest = 'IS_TRASH'
  when '--starred'
    props.push('IS_STARRED')
  when '--unread'
    props.push('IS_UNREAD')
  end
end
props.push(dest) if !dest.nil?
type = type.downcase

if ARGV.length != 1 || user.nil? || domain.nil? || email.nil? || passwd.nil?
  usage
  exit
end
from = "#{user}\@#{domain}" if from.nil?

source = ARGV.shift
m = Migrator.new(domain, user, email, passwd, from, type, props, labels, source)
m.do_migration

