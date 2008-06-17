#!/usr/bin/ruby

# ruby migrate-pop.rb -d example.com -e admin@example.com -p passwd -u pop_user -t apple --inbox path_to/INBOX.mbox

require 'rubygems'
require 'getoptlong'
require 'tmail'
require 'appsforyourdomain/migrationapi'

class Migrator
  attr_accessor :dry_run, :count
  
  def initialize(domain, user, email, passwd, type, props, labels, source)
    @domain = domain
    @user = user
    @email = email
    @passwd = passwd
    @type = type
    @props = props
    @labels = labels
    @source = source
    @dry_run = false
    @count = 0
  end
  
  def is_mbox?
    @type == 'mbox'
  end
  
  def do_migration
    @migration = AppsForYourDomain::EmailMigrationAPI.new(@domain, @user, @email, @passwd)
    if is_mbox?
      upload_mbox_tree(@source)
    else
      upload_maildir(@source)
    end
  end

  # Uploads a unix mbox file
  def upload_mbox(source_file)
    msg_num = 0
    begin
      mbox = TMail::UNIXMbox.new(source_file, nil, true)
      print "opened mbox file #{source_file}\n"
      mbox.each_port do |port|
        msg_num += 1
        begin
          mail = TMail::Mail.new(port)
          if mail.date.nil?
            # Eudora mbx files don't put the date in a Date: header
            # Instead they put it in the From line, like this:
            # From ???@??? Mon Oct 13 07:26:26 2003
            # We rebuild the message with the added date header.
            # The port (tmp file) has its utime set by TMail.
            mail.date =  File.mtime(port.filename)
            print "using #{mail.date} from mtime\n"
            
            # Eudora (and others?) don't specify html email.
            # We assume text/html content-type if body begins with <html>.
            if  mail.body =~ /^\s*\<html\>/
              print "setting text/html content type\n"
              mail.content_type = 'text/html'
            end
            msg = mail.encoded
          else
            # Just use the message as read
            msg = port.read_all
          end
          if is_mail_message?(msg)
            print "uploading msg #{msg_num} in #{source_file}\n"
            if @dry_run
              print msg
            else
              status = @migration.uploadSingleMessage(msg, @props, @labels)
              p status
              if !status.nil? && !status[1].nil? && status[1][:code] == '201'
                @count += 1 
              end
            end
            sleep(1)
          else
            print "msg #{msg_num} is not a mail message\n"
          end
        rescue
          print "could not read msg #{msg_num}\n"
          print $!
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
  def upload_maildir(source_dir)
    Dir.new(source_dir).each do |f|
      next if f == '.' || f == '..'
      path = File.join(source_dir, f)
      if File.file?(path)
        if f =~ /\.emlx$/
          # Handle .emlx formatted mails 
          msg = read_emlx(path)
        else
          # Handle individual messages in a maildir
          msg = File.read(path)
        end
        if is_mail_message?(msg)
          print "uploading #{path}\n"
          begin
            status = @migration.uploadSingleMessage(msg, @props, @labels)
            p status
            @count += 1 if status[1][:code] == '201'
          rescue
          end
          sleep(1)
        else
          print "not a mail message: #{path}\n"
        end
      elsif File.directory?(path)
        # Recurse.  In Tiger, .emlx files are inside the Messages sub-folder
        upload_maildir(path)
      end
    end
  end
end

def is_mail_message?(str)
  str.match(/^[-A-Za-z0-9]+: /)
end

def read_emlx(path)
  msg = nil
  File.open(path, "r") do |f|
    msg_size = f.readline.chomp.to_i
    return nil unless msg_size > 0
    msg = f.read(msg_size)
  end
  return msg
end

opts = GetoptLong.new(
  [ '--draft',    '-a', GetoptLong::NO_ARGUMENT ],
  [ '--domain',   '-d', GetoptLong::REQUIRED_ARGUMENT ],
  [ '--admin-email', '-e', GetoptLong::REQUIRED_ARGUMENT ],
  [ '--starred',  '-f', GetoptLong::NO_ARGUMENT ],
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
  puts "  -t, --type:        type of message source (default is apple):"
  puts "     apple   (folder containing Messages folder with .emlx files)"
  puts "     maildir (folder tree with email message files)"
  puts "     mbox    (single UNIX mbox file with multiple messages)"
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
type = 'apple'
dest = nil
props = []
labels = ['Migrated-POP']
opts.each do |opt, arg|
  case opt
  when '--help'
    usage
    exit
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

source = ARGV.shift
m = Migrator.new(domain, user, email, passwd, type, props, labels, source)
m.do_migration

