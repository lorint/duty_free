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

# Allow ActiveRecord 4.0 and 4.1 to work with newer Ruby (>= 2.4) by avoiding a "stack level too deep"
# error when ActiveSupport tries to smarten up Numeric by messing with Fixnum and Bignum at the end of:
# activesupport-4.0.13/lib/active_support/core_ext/numeric/conversions.rb
if ActiveRecord.version < ::Gem::Version.new('4.2') &&
   ActiveRecord.version > ::Gem::Version.new('3.2') &&
   Object.const_defined?('Integer') && Integer.superclass.name == 'Numeric'
  class OurFixnum < Integer; end
  Numeric.const_set('Fixnum', OurFixnum)
  class OurBignum < Integer; end
  Numeric.const_set('Bignum', OurBignum)
end

# Allow ActiveRecord < 3.2 to run with newer versions of Psych gem
if BigDecimal.respond_to?(:yaml_tag) && !BigDecimal.respond_to?(:yaml_as)
  class BigDecimal
    class <<self
      alias yaml_as yaml_tag
    end
  end
end

require 'duty_free/util'

# Allow ActiveRecord < 3.2 to work with Ruby 2.7 and later
if ActiveRecord.version < ::Gem::Version.new('3.2') &&
   ::Gem::Version.new(RUBY_VERSION) >= ::Gem::Version.new('2.7')
  # Remove circular reference for "now"
  ::DutyFree::Util._patch_require(
    'active_support/values/time_zone.rb', '/activesupport',
    '  def parse(str, now=now)',
    '  def parse(str, now=now())'
  )
  # Remove circular reference for "reflection" for ActiveRecord 3.1
  if ActiveRecord.version >= ::Gem::Version.new('3.1')
    ::DutyFree::Util._patch_require(
      'active_record/associations/has_many_association.rb', '/activerecord',
      'reflection = reflection)',
      'reflection = reflection())',
      :HasManyAssociation # Make sure the path for this guy is available to be autoloaded
    )
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
  # Rails < 4.0 cannot do #find_by, #find_or_create_by, or do #pluck on multiple columns, so here are the patches:
  if ActiveRecord.version < ::Gem::Version.new('4.0')
    module ActiveRecord
      # Normally find_by is in FinderMethods, which older AR doesn't have
      module Calculations
        def find_by(*args)
          where(*args).limit(1).to_a.first
        end

        def find_or_create_by(attributes, &block)
          find_by(attributes) || create(attributes, &block)
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
                           PG::BasicTypeRegistry.alias_type(0, 'numeric', 'text') # oid 1700
                           PG::BasicTypeRegistry.alias_type(0, 'time', 'text') # oid 1083
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
            delegate :pluck, :find_by, :find_or_create_by, to: :scoped
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

      # ActiveRecord 3.1 and 3.2 didn't try to bring in &block for the .extending() convenience thing
      # that smartens up scopes, and Ruby 2.7 complained loudly about just doing the magical "Proc.new"
      # that historically would just capture the incoming block.
      module QueryMethods
        unless instance_method(:extending).parameters.include?([:block, :block])
          # These first two lines used to be:
          # def extending(*modules)
          #   modules << Module.new(&Proc.new) if block_given?

          def extending(*modules, &block)
            modules << Module.new(&block) if block_given?

            return self if modules.empty?

            relation = clone
            relation.send(:apply_modules, modules.flatten)
            relation
          end
        end
      end

      # Same kind of thing for ActiveRecord::Scoping::Default#default_scope
      module Scoping
        module Default
          module ClassMethods
            if instance_methods.include?(:default_scope) &&
               !instance_method(:default_scope).parameters.include?([:block, :block])
              # Fix for AR 3.2-5.1
              def default_scope(scope = nil, &block)
                scope = block if block_given?

                if scope.is_a?(Relation) || !scope.respond_to?(:call)
                  raise ArgumentError,
                        'Support for calling #default_scope without a block is removed. For example instead ' \
                        "of `default_scope where(color: 'red')`, please use " \
                        "`default_scope { where(color: 'red') }`. (Alternatively you can just redefine " \
                        'self.default_scope.)'
                end

                self.default_scopes += [scope]
              end
            end
          end
        end
      end
    end
  end

  # Rails < 4.2 is not innately compatible with Ruby 2.4 and later, and comes up with:
  # "TypeError: Cannot visit Integer" unless we patch like this:
  if ::Gem::Version.new(RUBY_VERSION) >= ::Gem::Version.new('2.4') &&
     Arel::Visitors.const_defined?('DepthFirst') &&
     !Arel::Visitors::DepthFirst.private_instance_methods.include?(:visit_Integer)
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

  unless DateTime.instance_methods.include?(:nsec)
    class DateTime < Date
      def nsec
        (sec_fraction * 1_000_000_000).to_i
      end
    end
  end

  # First part of arel_table_type stuff:
  # ------------------------------------
  # (more found below)
  if ActiveRecord.version < ::Gem::Version.new('5.0')
    # Used by Util#_arel_table_type
    module ActiveRecord
      class Base
        def self.arel_table
          @arel_table ||= Arel::Table.new(table_name, arel_engine).tap do |x|
            x.instance_variable_set(:@_arel_table_type, self)
          end
        end
      end
    end
  end

  include ::DutyFree::Extensions
end

# Do this earlier because stuff here gets mixed into JoinDependency::JoinAssociation and AssociationScope
if ActiveRecord.version < ::Gem::Version.new('5.0') && Object.const_defined?('PG::Connection')
  # Avoid pg gem deprecation warning:  "You should use PG::Connection, PG::Result, and PG::Error instead"
  PGconn = PG::Connection
  PGresult = PG::Result
  PGError = PG::Error
end

# More arel_table_type stuff:
# ---------------------------
if ActiveRecord.version < ::Gem::Version.new('5.2')
  # Specifically for AR 3.1 and 3.2 to avoid:  "undefined method `delegate' for ActiveRecord::Reflection::ThroughReflection:Class"
  require 'active_support/core_ext/module/delegation' if ActiveRecord.version < ::Gem::Version.new('4.0')
  # Used by Util#_arel_table_type
  # rubocop:disable Style/CommentedKeyword
  module ActiveRecord
    module Reflection
      # AR < 4.0 doesn't know about join_table and derive_join_table
      unless AssociationReflection.instance_methods.include?(:join_table)
        class AssociationReflection < MacroReflection
          def join_table
            @join_table ||= options[:join_table] || derive_join_table
          end

        private

          def derive_join_table
            [active_record.table_name, klass.table_name].sort.join("\0").gsub(/^(.*[._])(.+)\0\1(.+)/, '\1\2_\3').gsub("\0", '_')
          end
        end
      end
    end

    module Associations
      # Specific to AR 4.2 - 5.1:
      if Associations.const_defined?('JoinDependency') && JoinDependency.private_instance_methods.include?(:table_aliases_for)
        class JoinDependency
        private

          if ActiveRecord.version < ::Gem::Version.new('5.1') # 4.2 or 5.0
            def table_aliases_for(parent, node)
              node.reflection.chain.map do |reflection|
                alias_tracker.aliased_table_for(
                  reflection.table_name,
                  table_alias_for(reflection, parent, reflection != node.reflection)
                ).tap do |x|
                  # %%% Specific only to Rails 4.2 (and maybe 4.1?)
                  x = x.left if x.is_a?(Arel::Nodes::TableAlias)
                  y = reflection.chain.find { |c| c.table_name == x.name }
                  x.instance_variable_set(:@_arel_table_type, y.klass)
                end
              end
            end
          end
        end
      elsif Associations.const_defined?('JoinHelper') && JoinHelper.private_instance_methods.include?(:construct_tables)
        module JoinHelper
        private

          # AR > 3.0 and < 4.2 (%%% maybe only < 4.1?) uses construct_tables like this:
          def construct_tables
            tables = []
            chain.each do |reflection|
              tables << alias_tracker.aliased_table_for(
                table_name_for(reflection),
                table_alias_for(reflection, reflection != self.reflection)
              ).tap do |x|
                x = x.left if x.is_a?(Arel::Nodes::TableAlias)
                x.instance_variable_set(:@_arel_table_type, reflection.chain.find { |c| c.table_name == x.name }.klass)
              end

              next unless reflection.source_macro == :has_and_belongs_to_many

              tables << alias_tracker.aliased_table_for(
                (reflection.source_reflection || reflection).join_table,
                table_alias_for(reflection, true)
              )
            end
            tables
          end
        end
      end
    end
  end # module ActiveRecord
  # rubocop:enable Style/CommentedKeyword
end
