# frozen_string_literal: true

require 'active_record'

require 'duty_free/config'
require 'duty_free/extensions'
require 'duty_free/version_number'
# require 'duty_free/serializers/json'
# require 'duty_free/serializers/yaml'

# An ActiveRecord extension that simplifies importing and exporting of data
# stored in one or more models.  Source and destination can be CSV, XLS,
# XLSX, ODT, HTML tables, or simple Ruby arrays.
module DutyFree
  class << self
    # Switches DutyFree on or off, for all threads.
    # @api public
    def enabled=(value)
      DutyFree.config.enabled = value
    end

    # Returns `true` if DutyFree is on, `false` otherwise. This is the
    # on/off switch that affects all threads. Enabled by default.
    # @api public
    def enabled?
      !!DutyFree.config.enabled
    end

    # Returns DutyFree's `::Gem::Version`, convenient for comparisons. This is
    # recommended over `::DutyFree::VERSION::STRING`.
    #
    # @api public
    def gem_version
      ::Gem::Version.new(VERSION::STRING)
    end

    # Set the DutyFree serializer. This setting affects all threads.
    # @api public
    def serializer=(value)
      DutyFree.config.serializer = value
    end

    # Get the DutyFree serializer used by all threads.
    # @api public
    def serializer
      DutyFree.config.serializer
    end

    # Returns DutyFree's global configuration object, a singleton. These
    # settings affect all threads.
    # @api private
    def config
      @config ||= DutyFree::Config.instance
      yield @config if block_given?
      @config
    end
    alias configure config

    def version
      VERSION::STRING
    end
  end
end

ActiveSupport.on_load(:active_record) do
  include ::DutyFree::Extensions
end

# # Require frameworks
# if defined?(::Rails)
#   # Rails module is sometimes defined by gems like rails-html-sanitizer
#   # so we check for presence of Rails.application.
#   if defined?(::Rails.application)
#     require "duty_free/frameworks/rails"
#   else
#     ::Kernel.warn(<<-EOS.freeze
# DutyFree has been loaded too early, before rails is loaded. This can
# happen when another gem defines the ::Rails namespace, then DF is loaded,
# all before rails is loaded. You may want to reorder your Gemfile, or defer
# the loading of DF by using `require: false` and a manual require elsewhere.
# EOS
# )
#   end
# else
#   require "duty_free/frameworks/active_record"
# end
