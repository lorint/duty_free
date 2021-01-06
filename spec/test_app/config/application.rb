# frozen_string_literal: true

require File.expand_path('boot', __dir__)

require 'duty_free'

# Pick the frameworks you want:
require 'active_record/railtie'
# require 'action_controller/railtie'

# Set up one common way to call #update for testing
module ActiveRecord
  module Persistence
    if ActiveRecord::Persistence.instance_methods.include?(:update)
      # For ActiveRecord >= 4.0, wire up update2 to point to #update
      alias update2 update
    else
      # For ActiveRecord < 4.0, wire up update2 to point to #update_attributes
      alias update2 update_attributes
    end
  end
end

Bundler.require(:default, Rails.env)

module TestApp
  class Application < Rails::Application
    config.encoding = 'utf-8'
    config.filter_parameters += [:password]
    config.active_support.escape_html_entities_in_json = true
    config.active_support.test_order = :sorted

    # Disable assets in rails 4.2. In rails 5, config does not respond to
    # assets, probably because it was moved out of railties to some other gem,
    # and we only have dev. dependencies on railties, not all of rails.
    config.assets.enabled = false if config.respond_to?(:assets)

    config.secret_key_base = '17314af7039573cb0aa484f61005727de8cbc635a0e429816f54254eb07eb3db4bd8d689558403bfa2201b1161baa262974a75042a1eebe56fad8ba7feaae10f'

    # `raise_in_transactional_callbacks` was added in rails 4, then deprecated in rails 5.
    v = ActiveRecord.version
    config.active_record.raise_in_transactional_callbacks = true if v >= Gem::Version.new('4.2') && v < Gem::Version.new('5.0.0.beta1')
    if v >= Gem::Version.new('5.0.0.beta1') && v < Gem::Version.new('5.1')
      config.active_record.belongs_to_required_by_default = true
      config.active_record.time_zone_aware_types = [:datetime]
    end
    if v >= Gem::Version.new('5.1')
      config.load_defaults '5.1'
      config.active_record.time_zone_aware_types = [:datetime]
    end

    if v < Gem::Version.new('6.0') && (ar = config.active_record).respond_to?(:sqlite3) && ar.sqlite3.respond_to?(:represent_boolean_as_integer)
      ar.sqlite3.represent_boolean_as_integer = true
    end
  end
end
