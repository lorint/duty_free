# frozen_string_literal: true

# :nodoc:
module DutyFree
  module Util
    # def self._parse(arel)
    #   arel = arel.arel if arel.is_a?(ActiveRecord::Relation)
    #   sels = arel.ast.cores.select { |x| x.is_a?(Arel::Nodes::SelectCore) }
    #   # source (joinsource) / projections (6) is the most interesting here
    #   sels.each_with_index do |sel, idx|
    #     puts "#{idx} ============="
    #     # Columns:
    #     sel.projections.map do |x|
    #       case
    #       when x.is_a?(Arel::Nodes::SqlLiteral)
    #         puts x.to_s
    #       else
    #         puts "#{x.class} #{x.name}"
    #       end
    #     end
    #   end
    #   nil
    # end

    def self._recurse_arel(piece, prefix = '')
      names = []
      # Our JOINs mashup of nested arrays and hashes
      if piece.is_a?(Array)
        names += piece.inject([]) { |s, v| s + _recurse_arel(v, prefix) }
      elsif piece.is_a?(Hash)
        names += piece.inject([]) do |s, v|
          new_prefix = "#{prefix}#{v.first}_"
          s << new_prefix
          s + _recurse_arel(v.last, new_prefix)
        end

      # ActiveRecord AREL objects
      elsif piece.is_a?(Arel::Nodes::JoinSource)
        # The left side is the "FROM" table
        # names += _recurse_arel(piece.left)
        # The right side is an array of all JOINs
        names += piece.right.inject([]) { |s, v| s + _recurse_arel(v) }
      elsif piece.is_a?(Arel::Nodes::Join) # INNER or OUTER JOIN
        # The left side is the "JOIN" table
        names += _recurse_arel(piece.left)
        # (The right side of these is the "ON" clause)
      elsif piece.is_a?(Arel::Table) # Table
        names << piece.name
      elsif piece.is_a?(Arel::Nodes::TableAlias) # Alias
        # Can get the real table name from:  self._recurse_arel(piece.left)
        names << piece.right.to_s # This is simply a string; the alias name itself
      end
      names
    end

    def self._prefix_join(prefixes, separator = nil)
      prefixes.reject(&:blank?).join(separator || '.')
    end

    def self._clean_name(name, import_template_as)
      return name if name.is_a?(Symbol)

      # Expand aliases
      (import_template_as || []).each do |k, v|
        if (k[-1] == ' ' && name.start_with?(k)) || name == k
          name.replace(v + name[k.length..-1])
          break
        end
      end
      name
    end
  end
end
