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
      case piece
      when Array
        names += piece.inject([]) { |s, v| s + _recurse_arel(v, prefix) }
      when Hash
        names += piece.inject([]) do |s, v|
          new_prefix = "#{prefix}#{v.first}_"
          s << [v.last.shift, new_prefix]
          s + _recurse_arel(v.last, new_prefix)
        end

      # ActiveRecord AREL objects
      when Arel::Nodes::Join # INNER or OUTER JOIN
        # rubocop:disable Style/IdenticalConditionalBranches
        if piece.right.is_a?(Arel::Table) # Came in from AR < 3.2?
          # Arel 2.x and older is a little curious because these JOINs work "back to front".
          # The left side here is either another earlier JOIN, or at the end of the whole tree, it is
          # the first table.
          names += _recurse_arel(piece.left)
          # The right side here at the top is the very last table, and anywhere else down the tree it is
          # the later "JOIN" table of this pair.  (The table that comes after all the rest of the JOINs
          # from the left side.)
          names << [_arel_table_type(piece.right), (piece.right.table_alias || piece.right.name)]
        else # "Normal" setup, fed from a JoinSource which has an array of JOINs
          # The left side is the "JOIN" table
          names += _recurse_arel(piece.left)
          # (The right side of these is the "ON" clause)
        end
        # rubocop:enable Style/IdenticalConditionalBranches
      when Arel::Table # Table
        names << [_arel_table_type(piece), (piece.table_alias || piece.name)]
      when Arel::Nodes::TableAlias # Alias
        # Can get the real table name from:  self._recurse_arel(piece.left)
        names << [_arel_table_type(piece.left), piece.right.to_s] # This is simply a string; the alias name itself
      when Arel::Nodes::JoinSource # Leaving this until the end because AR < 3.2 doesn't know at all about JoinSource!
        # The left side is the "FROM" table
        # names += _recurse_arel(piece.left)
        names << [_arel_table_type(piece.left), (piece.left.table_alias || piece.left.name)]
        # The right side is an array of all JOINs
        names += piece.right.inject([]) { |s, v| s + _recurse_arel(v) }
      end
      names
    end

    def self._arel_table_type(tbl)
      # AR < 4.2 doesn't have type_caster at all, so rely on an instance variable getting set
      # AR 4.2 - 5.1 have buggy type_caster entries for the root node
      tbl.instance_variable_get(:@_arel_table_type) ||
        # 5.2-6.1 does type_caster just fine, no bugs there, but the property with the type differs:
        # 5.2 has "types" as public, 6.0 "types" as private, and 6.1 "klass" as private.
        ((tc = tbl.send(:type_caster)) && tc.instance_variable_get(:@types)) ||
        tc.send(:klass)
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

    # ===================================
    # Epic require patch
    def self._patch_require(module_filename, folder_matcher, replacements, autoload_symbol = nil, is_bundler = false)
      mod_name_parts = module_filename.split('.')
      extension = case mod_name_parts.last
                  when 'rb', 'so', 'o'
                    module_filename = mod_name_parts[0..-2].join('.')
                    ".#{mod_name_parts.last}"
                  else
                    '.rb'
                  end

      if autoload_symbol
        unless Object.const_defined?('ActiveSupport::Dependencies')
          require 'active_support'
          require 'active_support/dependencies'
        end
        alp = ActiveSupport::Dependencies.autoload_paths
        custom_require_dir = ::DutyFree::Util._custom_require_dir
        # Create any missing folder structure leading up to this file
        module_filename.split('/')[0..-2].inject(custom_require_dir) do |s, part|
          new_part = File.join(s, part)
          Dir.mkdir(new_part) unless Dir.exist?(new_part)
          new_part
        end
        if ::DutyFree::Util._write_patched(folder_matcher, module_filename, extension, custom_require_dir, nil, replacements) &&
           !alp.include?(custom_require_dir)
          alp.unshift(custom_require_dir)
        end
      elsif is_bundler
        puts "Bundler hack"
        require 'pry-byebug'
        binding.pry
        x = 5
        # bin_path
        # puts Bundler.require.inspect
      else
        unless (require_overrides = ::DutyFree::Util.instance_variable_get(:@_require_overrides))
          ::DutyFree::Util.instance_variable_set(:@_require_overrides, (require_overrides = {}))

          # Patch "require" itself so that when it specifically sees "active_support/values/time_zone" then
          # a copy is taken of the original, an attempt is made to find the line with a circular error, that
          # single line is patched, and then an updated version is written to a temporary folder which is
          # then required in place of the original.

          Kernel.module_exec do
            alias_method :orig_require, :require
            # To be most faithful to Ruby's normal behaviour, this should look like a public singleton
            define_method(:require) do |name|
              # %%% Can get a message such as "ActionDispatch::Routing is not missing constant RouteSet! (NameError)"
              # binding.pry if name.start_with?('action_dispatch/routing/route_') # || name == 'active_support/values/time_zone'
              if (require_override = ::DutyFree::Util.instance_variable_get(:@_require_overrides)[name])
                extension, folder_matcher, replacements, autoload_symbol = require_override
                patched_filename = "/patched_#{name.tr('/', '_')}#{extension}"
                if $LOADED_FEATURES.find { |f| f.end_with?(patched_filename) }
                  false
                else
                  is_replaced = false
                  if (replacement_path = ::DutyFree::Util._write_patched(folder_matcher, name, extension, ::DutyFree::Util._custom_require_dir, patched_filename, replacements))
                    is_replaced = Kernel.send(:orig_require, replacement_path)
                  elsif replacement_path.nil?
                    puts "Couldn't find #{name} to require it!"
                  end
                  is_replaced
                end
              else
                Kernel.send(:orig_require, name)
              end
            end
          end
        end
        require_overrides[module_filename] = [extension, folder_matcher, replacements, autoload_symbol]
      end
    end

    def self._custom_require_dir
      unless (custom_require_dir = ::DutyFree::Util.instance_variable_get(:@_custom_require_dir))
        require 'tmpdir'
        ::DutyFree::Util.instance_variable_set(:@_custom_require_dir, (custom_require_dir = Dir.mktmpdir))
        # So normal Ruby require will now pick this one up
        $LOAD_PATH.unshift(custom_require_dir)
        # When Ruby is exiting, remove this temporary directory
        at_exit do
          FileUtils.rm_rf(::DutyFree::Util.instance_variable_get(:@_custom_require_dir))
        end
      end
      custom_require_dir
    end

    # Returns the full path to the replaced filename, or
    # false if the file already exists, and nil if it was unable to write anything.
    def self._write_patched(folder_matcher, name, extension, dir, patched_filename, replacements)
      # See if our replacement file might already exist for some reason
      name = +"/#{name}" unless name.start_with?('/')
      name << extension unless name.end_with?(extension)
      puts (replacement_path = "#{dir}#{patched_filename || name}")
      return false if File.exist?(replacement_path)

      # Dredge up the original .rb file, doctor it, and then require it instead
      num_written = nil
      orig_path = nil
      orig_as = nil
      # Using Ruby's approach to find files to require
      $LOAD_PATH.each do |path|
        orig_path = "#{path}#{name}"
        break if path.include?(folder_matcher) && (orig_as = File.open(orig_path))
      end
      puts [folder_matcher, name].inspect
      if (updated_text = orig_as&.read)
        File.open(replacement_path, 'w') do |replaced_file|
          replacements = [replacements] unless replacements.first.is_a?(Array)
          replacements.each do |search_text, replacement_text|
            updated_text.gsub!(search_text, replacement_text)
          end
          num_written = replaced_file.write(updated_text)
        end
        orig_as.close
      end
      (num_written&.> 0) ? replacement_path : nil
    end
  end
end
