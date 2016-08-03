require 'rubygems'


# From http://stackoverflow.com/questions/5830835/how-to-add-openssl-dependency-to-gemspec
# the whole reason this file exists:   to return an error if openssl
# isn't installed.
require 'openssl'

f = File.open(File.join(File.dirname(__FILE__), "Rakefile"), "w")   # create dummy rakefile to indicate success
f.write("task :default\n")
f.close