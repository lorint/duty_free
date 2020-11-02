# frozen_string_literal: true

ENV['RAILS_ENV'] ||= 'test'
ENV['DB'] ||= 'sqlite'

# Note that in order for pry-byebug to work, in gemfiles/vendor/bundle/gems/pry-0.13.1/lib/pry.rb
# "require 'pry/cli'" must exist AFTER "require 'pry/commands/exit_all'"
# (You can put the requires for wrapped_module, wrapped_module/candidate, slop, cli, core_extensions, repl_file_loader, code/loc, code/code_range, code/code_file, method/weird_method_locator, method/disowned, and method/patcher all together at the end and it all works.)
# require 'pry-byebug'
require 'byebug'

unless File.exist?(File.expand_path('test_app/config/database.yml', __dir__))
  warn 'No database.yml detected for the test app, please run `rake prepare` first'
end

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

# Wrap args in a hash to support the ActionController::TestCase and
# ActionDispatch::Integration HTTP request method switch to keyword args
# (see https://github.com/rails/rails/blob/master/actionpack/CHANGELOG.md)
def params_wrapper(args)
  if defined?(::Rails) && Gem::Version.new(ActiveRecord::VERSION::STRING) >= Gem::Version.new('5.0.0.beta1')
    { params: args }
  else
    args
  end
end

require File.expand_path('test_app/config/environment', __dir__)
require 'rspec/rails'
require 'duty_free/frameworks/rspec'
require 'ffaker'

# Migrate
require_relative 'support/duty_free_spec_migrator'
::DutyFreeSpecMigrator.new(::File.expand_path('test_app/db/migrate/', __dir__)).migrate

RSpec.configure do |config|
  config.fixture_path = "#{::Rails.root}/spec/fixtures"
end

# %%% In rails < 5, some tests could require truncation
if Gem::Version.new(ActiveRecord::VERSION::STRING) < ::Gem::Version.new('5')
  require 'database_cleaner'
  DatabaseCleaner.strategy = :truncation
  RSpec.configure do |config|
    config.use_transactional_fixtures = false
    config.before { DatabaseCleaner.start }
    config.after { DatabaseCleaner.clean }
  end
else
  RSpec.configure do |config|
    config.use_transactional_fixtures = true
  end
end
