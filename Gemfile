source "https://rubygems.org", cooldown: 7

gemspec

# Cooldown is configured per source, so exempting our own libraries from it
# requires a second remote for the same registry.
source "https://index.rubygems.org", cooldown: 0 do
  gem "ld-eventsource"
end
