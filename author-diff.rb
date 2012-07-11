#!/usr/bin/env ruby
require 'optparse'

def parse(args)
    options = {}
    options[:update] = false
    options[:repo] = 'http://localhost/svn/repos'
    opts = OptionParser.new do |opts|
        opts.banner = 'Usage: ./author-diff.rb [options]'

        opts.separator ''
        opts.separator 'Specific options:'

        opts.on('--update', 'Update authors.txt file from SVN repository') do
          options[:update] = true
        end
        opts.on('--repo repo', 'SVN repository URL (default: http://localhost/svn/repos)') do |repo|
          options[:repo] = repo
        end
        opts.separator ""

        opts.on_tail('-h', '--help', 'Show this message') do
          puts opts
          exit
        end
    end

    opts.parse! args
    options
end

options = parse(ARGV)

if options[:update]
    puts ""
    puts "Fetching SVN authors..."
    cmd = "svn log "
    cmd += options[:repo]
    cmd += " --quiet | grep -E \"r[0-9]+ \| .+ \|\" | awk '{print $3}' | sort | uniq > svn-authors.txt"
    puts cmd
    result = system(cmd)
    exit unless result
end

puts ""
puts "Diff between authors.txt and svn-authors.txt"
svnAuthors = []
fileAuthors = []

sa = File.open('svn-authors.txt', 'r')
sa.each_line() do |line|
   svnAuthors.push line.split("=")[0].strip
end

fa = File.open('git-authors.txt', 'r')
fa.each_line() do |line|
   fileAuthors.push(line.strip)
end

puts fileAuthors - svnAuthors

