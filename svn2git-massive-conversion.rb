#!/usr/bin/env ruby

# author: Olivier Bazoud
# url: https://github.com/obazoud/svn2git-massive-conversion
# You have to install Ruby SVN and Ruby Perl bindings

require 'rubygems'
require 'parallel'
require 'optparse'
require 'yaml'
require "svn/core"
require "svn/client"
require "svn/wc"
require "svn/repos"

def parse(args)
    options = {}
    options[:verbose] = false
    options[:threads] = Parallel.processor_count
    options[:configFile] = 'config.yaml'
    options[:layout] = false
    options[:layoutFile] = 'layout.dump'
    options[:gitexternal] = false
    options[:push] = false
    opts = OptionParser.new do |opts|
        opts.banner = 'Usage: ./svn2git-massive-conversion.rb [options]'
        opts.separator ''
        opts.separator 'Specific options:'
        opts.on('--config-file FILENAME', 'Load config file') do |configFile| options[:configFile] = configFile end
        opts.on('--layout', 'Update SVN projets layout from SVN server') do options[:layout] = true end
        opts.on('--layout-file FILENAME', 'Filename of SVN layout projets') do |layoutFile| options[:layoutFile] = layoutFile end
        opts.on('--gitexternal', 'Generate git-external configuration') do options[:gitexternal] = true end
        opts.on('-t', '--threads NUMBER', Integer, 'Use git svn fetch in t threads -- Speed up in large projets in svn repository') do |threads| options[:threads] = threads end
        opts.on('-p', '--push', 'Git push each project') do options[:push] = true end
        opts.on('-v', '--verbose', 'Be verbose in logging -- useful for debugging issues') do options[:verbose] = true end
        opts.separator ""
        opts.on_tail('-h', '--help', 'Show this message') do puts opts exit end
    end

    opts.parse! args
    options
end

class SVNPath
  attr_accessor :path
  attr_accessor :abs_path
  attr_accessor :branches
  attr_accessor :trunk
  attr_accessor :tags

  def initialize(path, abs_path, trunk, branches, tags)  
    @path = path
    @abs_path = abs_path
    @trunk = trunk
    @branches = branches
    @tags = tags
  end
end

def load_conf(conf)
    conf = IO.read(conf)
    YAML::load(conf)
end

def list_svn(ctx, conf, path)
    locations = []
    begin
        repoUri = conf['svn_repo']
        repoUri += path unless path.nil?
        ctx.list(repoUri, 'HEAD') do |path, dirent, lock, abs_path|
            locations.push SVNPath.new path, abs_path, false, false, false unless path.nil? || path.empty?
        end
        return locations
    rescue Svn::Error => e
      raise "Failed to list SVN repo: " + e
    end
end

def isProject(ctx, conf, loc)
    path = loc.abs_path
    path += '/' unless loc.abs_path == '/'
    path += loc.path
    locations = list_svn ctx, conf, path
    loc.trunk =  locations.any?{ |l| l.path.strip == 'trunk' }
    loc.branches = locations.any?{ |l| l.path.strip == 'branches' }
    loc.tags = locations.any?{ |l| l.path.strip == 'tags' }
    return loc.branches || loc.tags || loc.trunk
end

def list_project(ctx, conf, path)
    puts "Scanning: #{path}"
    removeLocations = []
    locations = []
    if path =~ /#{conf['svn_git_excludes']}/
        puts " * #{path} excluded."
    else
      locations = list_svn ctx, conf, path
      locations.each do |loc|
          if !isProject(ctx, conf, loc)
              removeLocations.push loc
              newpath = loc.abs_path
              newpath += '/' unless loc.abs_path == '/'
              newpath += loc.path
              locations += list_project(ctx, conf, newpath)
          end
      end
    end
    removeLocations.each do |loc|
        locations.delete loc
    end
    return locations
end

# main
options = parse(ARGV)
puts "Loading #{options[:configFile]}"
conf = load_conf options[:configFile]
beginning_time = Time.now

puts "Import SVN Repository into Git..."

locations = []
if options[:layout]
    puts ""
    puts "Preparing SVN client"
    ctx = Svn::Client::Context.new()
    ctx.add_simple_provider
    ctx.auth_baton[Svn::Core::AUTH_PARAM_DEFAULT_USERNAME] = conf['svn_user']
    ctx.auth_baton[Svn::Core::AUTH_PARAM_DEFAULT_PASSWORD] = conf['svn_password']

    puts ""
    puts "Scaning SVN repo..."
    locations = list_project ctx, conf, conf['svn_path']

    puts ""
    puts "Dumping layout file..."
    locations.each do |loc| puts "project : #{conf['svn_repo']}#{loc.abs_path}/#{loc.path} [trunk:#{loc.trunk}, branches:#{loc.branches}, tags:#{loc.tags}]" end

    puts ""
    puts "Writing layout file..."
    marshal_dump = Marshal.dump(locations)
    file = File.new(options[:layoutFile],'w')
    file.write marshal_dump
    file.close
    exit
end

puts ""
puts "Reading layout file..."
begin
    file = File.open(options[:layoutFile], 'r')
ensure
    locations = Marshal.load file.read
    file.close
end

puts ""
puts "Found #{locations.length} project(s)"

if options[:gitexternal]
    puts ""
    puts "Creating git-external script"
    File.open('git-externals.sh', 'w') do |f|
        f.puts "#!/bin/sh"
        f.puts "set -x"
        f.puts "set -e"
        f.puts ""

        locations.each do |loc|
            repositoryUrl = "#{conf['git_url']}#{loc.abs_path}/#{loc.path}.git"
            path = loc.abs_path.sub(/^\//, '') + "/#{loc.path}"
            branch = "master"
            f.puts "git external add #{repositoryUrl} #{path} #{branch}"
        end
    end
    puts ""
    STDOUT.flush
    exit
end

currentDir = Dir.getwd();
puts ""
puts "Preparing SNV2Git Mass convertions..."
puts "Found #{Parallel.processor_count} procesor(s)"
puts "Use #{options[:threads]} thread(s)"

puts ""
puts "Creating directories @ #{conf['svn_git_tmp']}"
locations.each do |loc|
    FileUtils.mkpath "#{conf['svn_git_tmp']}#{loc.abs_path}/#{loc.path}"
end

if options[:push]
    options[:threads] = 1
end

begin
    results = Parallel.map(locations, :in_threads => options[:threads]) do |loc|
        if options[:push]
            cmd = "cd #{conf['svn_git_tmp']}#{loc.abs_path}/#{loc.path} && git push --all -u"
            result = system(cmd)
            raise "Fail command @ #{loc.abs_path}/#{loc.path} : #{cmd}" unless result
        else
            puts ""
            puts "SVN2Git : #{conf['svn_repo']}#{loc.abs_path}/#{loc.path}"
            if File.directory? "#{conf['svn_git_tmp']}#{loc.abs_path}/#{loc.path}/.git"
                cmd = "cd #{conf['svn_git_tmp']}#{loc.abs_path}/#{loc.path} && svn2git --rebase --notags --metadata"
                loc.trunk ? cmd += "--trunk trunk " : cmd += "--notrunk "
                loc.branches ? cmd += "--branches branches " : cmd += "--nobranches "
                cmd += "--verbose " if options[:verbose]
                result = system(cmd)
                raise "Fail command @ #{loc.abs_path}/#{loc.path} : #{cmd}" unless result
            else
                cmd = "cd #{conf['svn_git_tmp']}#{loc.abs_path}/#{loc.path} && svn2git #{conf['svn_repo']}#{loc.abs_path}/#{loc.path} --authors #{currentDir}/git-authors.txt --notags --metadata --no-minimize-url "
                loc.trunk ? cmd += "--trunk trunk " : cmd += "--notrunk "
                loc.branches ? cmd += "--branches branches " : cmd += "--nobranches "
                cmd += "--verbose " if options[:verbose]
                cmd += "&& git remote add origin #{conf['git_url']}#{loc.abs_path}/#{loc.path}.git "
                result = system(cmd)
                raise "Fail command @ #{loc.abs_path}/#{loc.path} : #{cmd}" unless result
            end
        end
    end
rescue RuntimeError
    puts $!.message
end

end_time = Time.now
timeElapsed = end_time - beginning_time

puts ""
puts "Done in #{(timeElapsed / 3600).to_i} hours, #{((timeElapsed / 60) % 60).to_i} minutes and #{(timeElapsed % 60).to_i} seconds."
puts "Have fun with Git ;)"
puts ""
