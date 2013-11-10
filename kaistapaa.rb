#!/usr/bin/env ruby

# Author      : 2xT@iki.fi
# Last update : 2013-11-10
# License     : http://www.dbad-license.org/

# Path to configuration files i.e. asetukset.yml and avainsanat.yml
# Defaults to the same directory with kaistapaa.rb
path_to_config = '.'

# TODO
# ====
# => Refactor the code
#    1. This started out as one of those "quick'n'dirty hacks" and I ended up writing a lot
#       more functionality than I originally had planned for and as a result the codebase
#       is a total effin' mess ...
#    2. I decided to learn ruby on the side i.e. this is my "hello world" and I'm quite sure
#       the rubyists out there will find the code utterly disgusting. Sorry about that, I'm just
#       learning :)
#    3. I'm a bit ashamed to publish this cruft ... but I figured that if this solved the case
#       for me it might do the same for others as well. Sharing is caring :)
#
# => Web UI
#    1. Manage keywords
#    2. Test out keywords
#    3. Manage configuration
#
# => Add logging
#    1. Log errors
#    2. Log activity
#
# => Add proxy support
#    1. Add configuration items
#    2. Add code

require 'cgi'
require 'fileutils'
require 'net/http'
require 'open-uri'
require 'optparse'
require 'ostruct'
require 'rss'
require 'thread'
require 'yaml'

class Locking
  def initialize(filename, time)
    @filename = filename
    @time     = time
    @file     = nil
  end

  # Check if lock is in place
  def status
    File.exist?(@filename)
  end

  # Enable locking
  def enable
    @file = File.open(@filename, 'w')
    @file.write(@time) 
  end

  # Disable locking
  def disable
    @file.close
    File.delete(@filename)
  end

  # Only remove 'dangling' lockfile
  def remove
    File.delete(@filename)
  end
end # class Locking

class TVkaistaFeed
  # This class contains feeds created for given keywords
  attr_reader :feed, :keyword, :target, :lifespan, :channel

  def initialize(feed, keyword, target='title', lifespan=nil, channel=nil)
    @feed     = feed
    @keyword  = keyword    # top gun
    @target   = target     # description
    @lifespan = lifespan   # 21
    @channel  = channel    # MTV3
  end
end # class TVkaistaFeed

class Optparse
  # Return a structure describing the options.
  def self.parse(args)
    # The options specified on the command line will be collected in *options*.
    # We set default values here.
    options = OpenStruct.new
    options.concurrency = false
    options.debug       = false
    options.removelock  = false
    options.verbose     = true
    options.test        = false

    opt_parser = OptionParser.new do |opts|
      opts.banner = "Usage: #{File.basename($PROGRAM_NAME)} [options]"

      opts.on("-c", "--enable-concurrency", "Enable concurrent downloads") do |c|
        options.concurrency = true
      end

      opts.on("-d", "--enable-debug-mode", "Enable debug mode") do |d|
        options.debug = true
      end

      opts.on("-f", "--force-remove-lock", "Force remove lockfile") do |r|
        options.removelock = true
      end

      opts.on("-s KEYWORD", "--search", "Search for KEYWORD - ignore configuration") do |s|
        options.search = s
      end

      opts.on("-t", "--test-run", "Test run without downloading the media") do |t|
        options.test = true
      end

      opts.on("-v", "--disable-verbose-mode", "Disable verbose mode") do |v|
        options.verbose = false
      end

    end

    opt_parser.parse!(args)
    options
  end  # parse()
end  # class Optparse

def parse_yaml(filename)
  parsed = begin
    config = YAML.load(File.open(filename))
  rescue ArgumentError => e
    puts "[!] Could not parse #{filename}: #{e.message}"
  end

  config
end # def

# program       => contains single RSS feed item
# config        => contains config from 'asetukset.yml'
# options       => contains command line parameters
# tvkaista_item => contains keyword information
def fetch_file(program, config, options, tvkaista_item)
  program_channel  = program.source.content
  program_url      = program.enclosure.url
  program_size     = program.enclosure.length
  program_filename = nil
  download_flag    = nil
  uri              = URI(program_url)

  Net::HTTP.start(uri.host, uri.port) do |http|
    request = Net::HTTP::Get.new uri
    request.basic_auth config['credentials']['user'], config['credentials']['password']
    response = http.request request

    # Check for redirection
    case response
    when Net::HTTPSuccess then
      response
    when Net::HTTPRedirection then
      location = response['location']
      uri = URI(location)
      out = CGI::parse(uri.query)
      program_filename = out['outputfilename'][0]
    else
      response.value
    end
  end # Net::HTTP.start(uri.host, uri.port) do |http|

  # Init semaphore
  semaphore = "#{config['settings']['historydir']}/#{program_filename}"

  # Add fule path to program_filename
  program_dir      = program_filename.split(/_/)[0]
  program_filename = "#{config['settings']['mediadir']}/#{program_dir}/#{program_filename}"

  # Check whether the program matches the defined criteria
  if (tvkaista_item.target == 'title' and                      # match title
             program.title =~ /#{tvkaista_item.keyword}/i) or
     (tvkaista_item.target == 'description' and                # match description
       program.description =~ /#{tvkaista_item.keyword}/i) or
     (tvkaista_item.target == 'either' and                     # match either
            (program.title =~ /#{tvkaista_item.keyword}/i or
       program.description =~ /#{tvkaista_item.keyword}/i))

       # Check if the file already exists (both presence on local disk and semaphore metadata)
       if File.exist?(program_filename) == false and File.exist?(semaphore) == false
         if options[:verbose] == true
           puts "#{config['labels']['new']} : #{program_filename} [#{program_channel}]"
         end
         download_flag = true
       elsif File.exist?(program_filename) == true
         if File.stat(program_filename).size == program_size
           if options[:debug] == true
             puts "#{config['labels']['old']} : #{program_filename} [#{program_channel}]"
           end
         else
           if options[:verbose] == true
             puts "#{config['labels']['reload']} : #{program_filename} [#{program_channel}]"
           end
           download_flag = true
           if File.exists?(semaphore)
             File.delete(semaphore)
           end
         end
       end

  end # if title | description | either ...

  # Download file
  if options[:test] == true
    download_flag = false
  end

  if program_filename and download_flag == true and File.exist?(semaphore) == false
    Net::HTTP.start(uri.host, uri.port) do |http|
      request = Net::HTTP::Get.new uri
      request.basic_auth config['credentials']['user'], config['credentials']['password']

      http.request request do |response|
        if options[:debug] == true
          puts "[+] Writing #{program_filename} ..."
        end

        unless Dir.exists?(program_dir)
          FileUtils.mkdir_p program_dir
          puts "[+] Created directory #{program_dir}"
        end

        open program_filename, 'wb' do |io|
          response.read_body do |chunk|
            io.write chunk
          end
        end
      end
    end
    s = File.open(semaphore, 'w')
    s.write("")
    s.close
    if options[:debug] == true
      puts "[+] Semaphore created for #{program_filename}"
    end
  end

  program_filename
end # def

# Main
keywords = parse_yaml("#{path_to_config}/avainsanat.yml")
config   = parse_yaml("#{path_to_config}/asetukset.yml")
options  = Optparse.parse(ARGV)
time_now = Time.new
threads  = []
feeds    = []

# Check that the environment is sane

# Check that the state (history) is directory available - create if needed
unless Dir.exists?(config['settings']['historydir'])
  puts "[-] Directory #{config['settings']['historydir']} does not exist"
  FileUtils.mkdir_p config['settings']['historydir']
  puts "[+] Created directory #{config['settings']['historydir']}"
end

# Check that the media directory is available - create if needed
unless Dir.exists?(config['settings']['mediadir'])
  puts "[-] Directory #{config['settings']['mediadir']} does not exist"
  FileUtils.mkdir_p config['settings']['mediadir']
  puts "[+] Created directory #{config['settings']['mediadir']}"
end

# Check that we're not already running!
locking = Locking.new(filename=config['settings']['lockfile'], time=time_now)

if locking.status
  if options[:removelock] == true
    locking.remove
  else
    puts "[!] Lockfile #{config['settings']['lockfile']} was found."
    puts "    Effectively this means either:"
    puts "    a) #{File.basename($PROGRAM_NAME)} is already running."
    puts "       Please take a look at the process list to see if that is the case."
    puts "    b) The previous run of #{File.basename($PROGRAM_NAME)} did not end well."
    puts "       You can delete the lockfile by issuing:"
    puts "       #{File.basename($PROGRAM_NAME)} --force-remove-lock"
    exit
  end
end

locking.enable
if options[:debug] == true
  puts "[+] Lock acquired"
end

if options[:search]
  puts "[+] Searching #{options[:search]}"
  keywords = {}
  term = { 'keyword' => options[:search] }
  keywords['search'] = term
end

keywords.each_key do |key|
  # Default target to title
  unless keywords[key]['target']
    keywords[key]['target'] = 'title'
  end

  feed = "http://tvkaista.fi/feed/search/#{URI.escape(keywords[key]['target'])}/#{URI.escape(keywords[key]['keyword'])}/#{URI.escape(config['settings']['quality'])}.rss"

  if options[:debug] == true
    print "[+] KEYWORD #{keywords[key]['keyword']} IN #{keywords[key]['target']}"
    if keywords[key]['channel']
      print " CHANNEL #{keywords[key]['channel']}"
    end
    puts
    puts "    #{feed}"
  end
  feeds << TVkaistaFeed.new(
                feed     = feed,
                keyword  = keywords[key]['keyword'],
                target   = keywords[key]['target'],
                lifespan = keywords[key]['lifespan'],
                channel  = keywords[key]['channel']
                )
end

# Iterate array of TVkaistaFeed objects i.e. for each entry we
# 1. Fetch the RSS feed derived from the configuration
# 2. Process the results i.e. get the individual programs from
#    the feed process the ones that match the given criteria
feeds.each do |entry|
  open(entry.feed, :http_basic_authentication => [config['credentials']['user'], config['credentials']['password']]) do |rss|
    feed = RSS::Parser.parse(rss, false)
    feed.items.each do |program|
      # puts program.inspect
      # puts "#{program}"
      # puts "#{program.title}"
      # puts "#{program.description}"
      queue_for_download = true

      # Does the entry have a lifespan restriction?
      if entry.lifespan and queue_for_download == true
        # How old is the current program (in days)?
        delta = (time_now - program.dc_date).to_i / (24 * 60 * 60)
        if delta < entry.lifespan
          if options[:debug] == true
            puts "[+] KEYWORD #{entry.keyword} AGE MATCH (#{delta}/#{entry.lifespan} DAYS)"
          end
        else
          if options[:debug] == true
            puts "[-] KEYWORD #{entry.keyword} AGE MISMATCH (#{delta}/#{entry.lifespan} DAYS)"
          end
          queue_for_download = false
        end
      end

      # Does the entry have a lifespan restriction?
      if entry.channel and queue_for_download == true
        # if entry.channel.include? program.source.content
        if entry.channel.any?{ |s| s.casecmp(program.source.content)==0 }
          if options[:debug] == true
            puts "[+] KEYWORD #{entry.keyword} CHANNEL MATCH #{program.source.content}"
          end
        else
          if options[:debug] == true
            puts "[-] KEYWORD #{entry.keyword} CHANNEL MISMATCH #{entry.channel} != #{program.source.content}"
          end
          queue_for_download = false
        end
      end

      # Download the actual media file if it is already available (program.respond_to?('enclosure'))
      if queue_for_download == true
        if program.enclosure
          if options[:concurrency] == true
            # threads << Thread.new { fetch_file(program.source.content, program.enclosure.url, program.enclosure.length, config, options, entry) }
            threads << Thread.new { fetch_file(program, config, options, entry) }
          else
            # fetch_file(program.source.content, program.enclosure.url, program.enclosure.length, config, options)
            fetch_file(program, config, options, entry)
          end
        else
          if options[:debug] == true
            puts "[-] Current program does not contain the information needed for the download."
            puts "    This usually means that the media conversion has not yet completed on the server."
            puts "    In other words: please check back later :)"
          end
        end
      end

    end # feed.items.each do |program|
  end # open(entry.url ...
end # feeds.each do |entry|

if options[:concurrency] == true
  threads.each(&:join) # Wait for all the threads to finish before proceeding
end

# Remove lock
locking.disable
if options[:debug] == true
  puts "[+] Lock released"
  puts "[+] All done."
end

# END
