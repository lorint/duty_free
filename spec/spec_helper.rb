# frozen_string_literal: true

ENV['RAILS_ENV'] ||= 'test'
ENV['DB'] ||= 'sqlite'

# In order for pry-byebug to work, in gemfiles/vendor/bundle/gems/pry-0.13.1/lib/pry.rb
# "require 'pry/cli'" must exist AFTER "require 'pry/commands/exit_all'"
# (You can put the requires for wrapped_module, wrapped_module/candidate, slop, cli, core_extensions,
# repl_file_loader, code/loc, code/code_range, code/code_file, method/weird_method_locator,
# method/disowned, and method/patcher all together at the end and it all works.)
require 'pry-byebug'
# require 'byebug'

warn 'No database.yml detected for the test app, please run `rake prepare` first' unless File.exist?(File.expand_path('test_app/config/database.yml', __dir__))

require 'active_record/version'

RSpec.configure do |config|
  config.example_status_persistence_file_path = '.rspec_results'
  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end
  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end
  config.filter_run :focus
  config.run_all_when_everything_filtered = true
  config.disable_monkey_patching!
  config.warnings = false
  config.default_formatter = 'doc' if config.files_to_run.one?
  config.order = :random
  Kernel.srand config.seed
end

# ActiveRecord before 4.0 didn't have #version
unless ActiveRecord.respond_to?(:version)
  module ActiveRecord
    def self.version
      ::Gem::Version.new(ActiveRecord::VERSION::STRING)
    end
  end
end

# Wrap args in a hash to support the ActionController::TestCase and
# ActionDispatch::Integration HTTP request method switch to keyword args
# (see https://github.com/rails/rails/blob/master/actionpack/CHANGELOG.md)
def params_wrapper(args)
  defined?(::Rails) && ActiveRecord.version >= ::Gem::Version.new('5') ? { params: args } : args
end

require File.expand_path('test_app/config/environment', __dir__)
# Avoid the RSpec error message:  "Ruby 2.2+ is not supported on Rails 3.0.20"
if ActiveRecord.version < ::Gem::Version.new('3.2') && RUBY_VERSION >= '2.2.0'
  original_ruby_version = Object.send(:remove_const, :RUBY_VERSION)
  Object.const_set('RUBY_VERSION', '2.1.9')
end
require 'rspec/rails'
if original_ruby_version
  Object.send(:remove_const, :RUBY_VERSION)
  Object.const_set('RUBY_VERSION', original_ruby_version)
end

require 'duty_free/frameworks/rspec'
require 'ffaker'

RSpec.configure do |config|
  config.fixture_path = "#{::Rails.root}/spec/fixtures"

  # %%% In rails < 5, some tests could require truncation
  if ActiveRecord.version < ::Gem::Version.new('5')
    require 'database_cleaner'
    DatabaseCleaner.strategy = :truncation

    config.use_transactional_fixtures = false
    config.before { DatabaseCleaner.start }
    config.after { DatabaseCleaner.clean }
  else
    config.use_transactional_fixtures = true
  end
end

# Migrate
require_relative 'support/duty_free_spec_migrator'
::DutyFreeSpecMigrator.new(::File.expand_path('test_app/db/migrate/', __dir__)).migrate
