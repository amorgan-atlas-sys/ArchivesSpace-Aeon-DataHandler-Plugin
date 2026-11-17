# frozen_string_literal: true

#
# LOCAL DEVELOPMENT ONLY. This Gemfile is used for running specs and lint
# locally (`bundle exec rspec`, `bundle exec rubocop`) and for vendoring the
# runtime jsonpath dependency into vendor/bundle.
#
# IMPORTANT: This file MUST NOT be shipped to a deployed ArchivesSpace plugin
# directory — AS would process it via ASUtils.load_plugin_gems and fail
# because the gems aren't in AS's bundler-managed GEM_HOME. See README.md for
# the correct deploy procedure that excludes Gemfile and Gemfile.lock.
#
# At runtime inside AS, jsonpath is loaded from vendor/bundle via $LOAD_PATH
# manipulation in backend/plugin_init.rb.

source "https://rubygems.org"

gem "jsonpath", "~> 1.1"
# Pin multi_json to 1.15.x. jsonpath's gemspec only requires multi_json
# ">= 0", and later multi_json releases (even within 1.x — 1.21.1 needs
# Ruby >= 3.2) drop older Rubies. This gem is vendored into the release
# zip and loaded inside ArchivesSpace's JRuby (Ruby 2.6/3.1 compat
# depending on AS version), so it must stay on a version that runs
# everywhere AS does. 1.15.x is pure Ruby and does.
gem "multi_json", "~> 1.15.0"

group :test do
  gem "rspec", "~> 3.0"
  gem "rubocop", "~> 1.0"
end
