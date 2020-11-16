# frozen_string_literal: true

require 'active_record/version'

# ActiveRecord before 4.0 didn't have #version
unless ActiveRecord.respond_to?(:version)
  module ActiveRecord
    def self.version
      ::Gem::Version.new(ActiveRecord::VERSION::STRING)
    end
  end
end

# In ActiveSupport older than 5.0, the duplicable? test tries to new up a BigDecimal,
# and Ruby 2.6 and later deprecates #new.  This removes the warning from BigDecimal.
require 'bigdecimal'
if ActiveRecord.version < ::Gem::Version.new('5.0') &&
   ::Gem::Version.new(RUBY_VERSION) >= ::Gem::Version.new('2.6')
  def BigDecimal.new(*args, **kwargs)
    BigDecimal(*args, **kwargs)
  end
end

# Allow Rails 4.0 and 4.1 to work with newer Ruby (>= 2.4) by avoiding a "stack level too deep" error
# when ActiveSupport tries to smarten up Numeric by messing with Fixnum and Bignum at the end of:
# activesupport-4.0.13/lib/active_support/core_ext/numeric/conversions.rb
if ActiveRecord.version < ::Gem::Version.new('4.2') &&
   ActiveRecord.version > ::Gem::Version.new('3.2') &&
   Object.const_defined?('Integer') && Integer.superclass.name == 'Numeric'
  class OurFixnum < Integer; end
  Numeric.const_set('Fixnum', OurFixnum)
  class OurBignum < Integer; end
  Numeric.const_set('Bignum', OurBignum)
end

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
  # 
  #   klasses = [Float, BigDecimal]
  # # Ruby 2.4+ unifies Fixnum & Bignum into Integer.
  # if 0.class == Integer
  #   klasses << Integer
  # else
  #   klasses << Fixnum << Bignum
  # end

  # klasses.each do |klass|

  # Rails < 4.2 is not innately compatible with Ruby 2.4 and later, and comes up with:
  # "TypeError: Cannot visit Integer" unless we patch like this:
  unless ::Gem::Version.new(RUBY_VERSION) < ::Gem::Version.new('2.4')
    unless Arel::Visitors::DepthFirst.private_instance_methods.include?(:visit_Integer)
      module Arel
        module Visitors
          class DepthFirst < Arel::Visitors::Visitor
            alias :visit_Integer :terminal
          end

          class Dot < Arel::Visitors::Visitor
            alias :visit_Integer :visit_String
          end

          class ToSql < Arel::Visitors::Visitor
            alias :visit_Integer :literal
          end
        end
      end
    end
  end

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
