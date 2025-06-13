require "bundler/inline"

gemfile do
  # Inline gemfiles don't appear to load the gemspec so we are loading it explicitly
  gemspec 
end

Bundler.require(:development)
abort unless $LOADED_FEATURES.any? { |file| file =~ /ldclient-rb\.rb/ }
