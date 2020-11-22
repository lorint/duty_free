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
      elsif piece.is_a?(Arel::Nodes::Join) # INNER or OUTER JOIN
        # rubocop:disable Style/IdenticalConditionalBranches
        if piece.right.is_a?(Arel::Table) # Came in from AR < 3.2?
          # Arel 2.x and older is a little curious because these JOINs work "back to front".
          # The left side here is either another earlier JOIN, or at the end of the whole tree, it is
          # the first table.
          names += _recurse_arel(piece.left)
          # The right side here at the top is the very last table, and anywhere else down the tree it is
          # the later "JOIN" table of this pair.  (The table that comes after all the rest of the JOINs
          # from the left side.)
          names << (piece.right.table_alias || piece.right.name)
        else # "Normal" setup, fed from a JoinSource which has an array of JOINs
          # The left side is the "JOIN" table
          names += _recurse_arel(piece.left)
          # (The right side of these is the "ON" clause)
        end
        # rubocop:enable Style/IdenticalConditionalBranches
      elsif piece.is_a?(Arel::Table) # Table
        names << (piece.table_alias || piece.name)
      elsif piece.is_a?(Arel::Nodes::TableAlias) # Alias
        # Can get the real table name from:  self._recurse_arel(piece.left)
        names << piece.right.to_s # This is simply a string; the alias name itself
      elsif piece.is_a?(Arel::Nodes::JoinSource) # Leaving this until the end because AR < 3.2 doesn't know at all about JoinSource!
        # The left side is the "FROM" table
        # names += _recurse_arel(piece.left)
        names << (piece.left.table_alias || piece.left.name)
        # The right side is an array of all JOINs
        names += piece.right.inject([]) { |s, v| s + _recurse_arel(v) }
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
