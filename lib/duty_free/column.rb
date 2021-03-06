# frozen_string_literal: true

require 'duty_free/util'

module DutyFree
  # Holds detail about each column as we recursively explore the scope of what to import
  class Column
    attr_accessor :name, :pre_prefix, :prefix, :prefix_assocs, :import_template_as
    attr_writer :obj_class

    def initialize(name, pre_prefix, prefix, prefix_assocs, obj_class, import_template_as)
      self.name = name
      self.pre_prefix = pre_prefix
      self.prefix = prefix
      self.prefix_assocs = prefix_assocs
      self.import_template_as = import_template_as
      self.obj_class = obj_class
    end

    def to_s(mapping = nil)
      # Crap way:
      # sql_col = ::DutyFree::Util._prefix_join([prefix_assocs.last&.klass&.table_name, name])

      # Slightly less crap:
      # table_name = [prefix_assocs.first&.klass&.table_name]
      # alias_name = prefix_assocs.last&.plural_name&.to_s
      # table_name.unshift(alias_name) unless table_name.first == alias_name
      # sql_col = ::DutyFree::Util._prefix_join([table_name.compact.join('_'), name])

      # Foolproof way, using the AREL mapping:
      this_pre_prefix = pre_prefix.tr('.', '_')
      this_pre_prefix << '_' unless pre_prefix.blank?
      sql_col = ::DutyFree::Util._prefix_join([mapping["#{this_pre_prefix}#{prefix}_"], name])
      sym = to_sym.to_s
      sql_col == sym ? sql_col : "#{sql_col} AS #{sym}"
    end

    def titleize
      @titleize ||= to_sym.titleize
    end

    def path
      @path ||= ::DutyFree::Util._prefix_join([pre_prefix, prefix]).split('.').map(&:to_sym)
    end

    # The snake-cased column name to be used for building the full list of template_columns
    def to_sym
      @to_sym ||= ::DutyFree::Util._prefix_join(
        [pre_prefix, prefix, ::DutyFree::Util._clean_name(name, import_template_as)],
        '_'
      ).tr('.', '_')
    end
  end
end
