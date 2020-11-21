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

# Allow Rails < 3.2 to run with newer versions of Psych gem
if BigDecimal.respond_to?(:yaml_tag) && !BigDecimal.respond_to?(:yaml_as)
  class BigDecimal
    class <<self
      alias yaml_as yaml_tag
    end
  end
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

# Major compatibility fixes for ActiveRecord < 4.2
# ================================================
ActiveSupport.on_load(:active_record) do
  # Rails < 4.0 cannot do #find_by, or do #pluck on multiple columns, so here are the patches:
  if ActiveRecord.version < ::Gem::Version.new('4.0')
    module ActiveRecord
      module Calculations # Normally find_by is in FinderMethods, which older AR doesn't have
        def find_by(*args)
          where(*args).limit(1).to_a.first
        end

        def pluck(*column_names)
          column_names.map! do |column_name|
            if column_name.is_a?(Symbol) && self.column_names.include?(column_name.to_s)
              "#{connection.quote_table_name(table_name)}.#{connection.quote_column_name(column_name)}"
            else
              column_name
            end
          end

          # Same as:  if has_include?(column_names.first)
          if eager_loading? || (includes_values.present? && (column_names.first || references_eager_loaded_tables?))
            construct_relation_for_association_calculations.pluck(*column_names)
          else
            relation = clone # spawn
            relation.select_values = column_names
            result = if klass.connection.class.name.end_with?('::PostgreSQLAdapter')
                       rslt = klass.connection.execute(relation.arel.to_sql)
                       rslt.type_map =
                         @type_map ||= proc do
                           # This aliasing avoids the warning:
                           # "no type cast defined for type "numeric" with oid 1700. Please cast this type
                           # explicitly to TEXT to be safe for future changes."
                           PG::BasicTypeRegistry.alias_type(0, 'numeric', 'text')
                           PG::BasicTypeMapForResults.new(klass.connection.raw_connection)
                         end.call
                       rslt.to_a
                     elsif respond_to?(:bind_values)
                       klass.connection.select_all(relation.arel, nil, bind_values)
                     else
                       klass.connection.select_all(relation.arel.to_sql, nil)
                     end
            if result.empty?
              []
            else
              columns = result.first.keys.map do |key|
                # rubocop:disable Style/SingleLineMethods Naming/MethodParameterName
                klass.columns_hash.fetch(key) do
                  Class.new { def type_cast(v); v; end }.new
                end
                # rubocop:enable Style/SingleLineMethods Naming/MethodParameterName
              end

              result = result.map do |attributes|
                values = klass.initialize_attributes(attributes).values

                columns.zip(values).map do |column, value|
                  column.type_cast(value)
                end
              end
              columns.one? ? result.map!(&:first) : result
            end
          end
        end
      end

      unless Base.is_a?(Calculations)
        class Base
          class << self
            delegate :pluck, :find_by, to: :scoped
          end
        end
      end

      # ActiveRecord < 3.2 doesn't have initialize_attributes, used by .pluck()
      unless AttributeMethods.const_defined?('Serialization')
        class Base
          class << self
            def initialize_attributes(attributes, options = {}) #:nodoc:
              serialized = (options.delete(:serialized) { true }) ? :serialized : :unserialized
              # super(attributes, options)

              serialized_attributes.each do |key, coder|
                attributes[key] = Attribute.new(coder, attributes[key], serialized) if attributes.key?(key)
              end

              attributes
            end
          end
        end
      end

      # This only gets added for ActiveRecord < 3.2
      module Reflection
        unless AssociationReflection.instance_methods.include?(:foreign_key)
          class AssociationReflection < MacroReflection
            alias foreign_key association_foreign_key
          end
        end
      end
    end
  end

  # Rails < 4.2 is not innately compatible with Ruby 2.4 and later, and comes up with:
  # "TypeError: Cannot visit Integer" unless we patch like this:
  unless ::Gem::Version.new(RUBY_VERSION) < ::Gem::Version.new('2.4')
    unless Arel::Visitors::DepthFirst.private_instance_methods.include?(:visit_Integer)
      module Arel
        module Visitors
          class DepthFirst < Visitor
            alias visit_Integer terminal
          end

          class Dot < Visitor
            alias visit_Integer visit_String
          end

          class ToSql < Visitor
          private

            # ActiveRecord before v3.2 uses Arel < 3.x, which does not have Arel#literal.
            unless private_instance_methods.include?(:literal)
              def literal(obj)
                obj
              end
            end
            alias visit_Integer literal
          end
        end
      end
    end
  end

  if ActiveRecord.version < ::Gem::Version.new('5.0')
    # Avoid pg gem deprecation warning:  "You should use PG::Connection, PG::Result, and PG::Error instead"
    PGconn = PG::Connection
    PGresult = PG::Result
    PGError = PG::Error
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
