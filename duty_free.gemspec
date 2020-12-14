# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path('lib', __dir__)
require 'duty_free/version_number'

Gem::Specification.new do |s|
  s.name = 'duty_free'
  s.version = DutyFree::VERSION::STRING
  s.platform = Gem::Platform::RUBY
  s.summary = 'Import and Export Data'
  s.description = <<~EOS
    Simplify data imports and exports with this slick ActiveRecord extension
  EOS
  s.homepage = 'https://github.com/lorint/duty_free'
  s.authors = ['Lorin Thwaits']
  s.email = 'lorint@gmail.com'
  s.license = 'MIT'

  s.files = `git ls-files -z`.split("\x0").select do |f|
    f.match(%r{^(Gemfile|LICENSE|lib|duty_free.gemspec)/})
  end
  s.executables = []
  s.require_paths = ['lib']

  s.required_rubygems_version = '>= 1.3.6'
  # rubocop:disable Gemspec/RequiredRubyVersion
  s.required_ruby_version = '>= 2.3.5'
  # rubocop:enable Gemspec/RequiredRubyVersion

  s.add_dependency 'activerecord', ['>= 3.0', '< 6.1']

  s.add_development_dependency 'appraisal', '~> 2.2'
  s.add_development_dependency 'pry-byebug', '~> 3.7.0'
  # s.add_development_dependency 'byebug'
  s.add_development_dependency 'ffaker', '~> 2.11'
  s.add_development_dependency 'generator_spec', '~> 0.9.4'
  s.add_development_dependency 'memory_profiler', '~> 0.9.14'
  s.add_development_dependency 'rake', '~> 13.0'
  s.add_development_dependency 'rspec-rails', '~> 4.0'
  s.add_development_dependency 'rubocop', '~> 0.89.1'
  s.add_development_dependency 'rubocop-rspec', '~> 1.42.0'

  # Check for presence of libmysqlclient-dev, default-libmysqlclient-dev, libmariadb-dev, mysql-devel, etc
  require 'mkmf'
  Bundler::Dsl.instance_variable_set(:@_has_mysql, (has_mysql = have_library('mysqlclient')))
  s.add_development_dependency 'mysql2', '~> 0.5' if has_mysql
  s.add_development_dependency 'pg', '>= 0.18', '< 2.0'
  s.add_development_dependency 'sqlite3', '~> 1.4'
end
