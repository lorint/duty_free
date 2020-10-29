# frozen_string_literal: true

require 'duty_free/column'
require 'duty_free/suggest_template'
# require 'duty_free/attribute_serializers/object_attribute'
# require 'duty_free/attribute_serializers/object_changes_attribute'
# require 'duty_free/model_config'
# require 'duty_free/record_trail'

# :nodoc:
module DutyFree
  module Extensions
    def self.included(base)
      base.send :extend, ClassMethods
      base.send :extend, ::DutyFree::SuggestTemplate::ClassMethods
    end

    # :nodoc:
    module ClassMethods
      # def self.extended(model)
      # end

      # Export at least column header, and optionally include all existing data as well
      def df_export(is_with_data = true, import_columns = nil)
        # In case they are only supplying the columns hash
        if is_with_data.is_a?(Hash) && !import_columns
          import_columns = is_with_data
          is_with_data = true
        end
        import_columns ||= if constants.include?(:IMPORT_COLUMNS)
                             self::IMPORT_COLUMNS
                           else
                             suggest_template(0, false, false)
                           end
        rows = [friendly_columns(import_columns)]
        if is_with_data
          # Automatically create a JOINs strategy and select list to get back all related rows
          template_cols, template_joins = recurse_def(import_columns[:all], import_columns)
          relation = joins(template_joins)

          # So we can properly create the SELECT list, create a mapping between our
          # column alias prefixes and the aliases AREL creates.
          # Warning: Delegating ast to arel is deprecated and will be removed in Rails 6.0
          arel_alias_names = ::DutyFree::Util._recurse_arel(relation.ast.cores.first.source)
          our_names = ::DutyFree::Util._recurse_arel(template_joins)
          mapping = our_names.zip(arel_alias_names).to_h

          relation.select(template_cols.map { |x| x.to_s(mapping) }).each do |result|
            rows << template_columns(import_columns).map do |col|
              value = result.send(col)
              case value
              when true
                'Yes'
              when false
                'No'
              else
                value.to_s
              end
            end
          end
        end
        rows
      end

      # With an array of incoming data, the first row having column names, perform the import
      def df_import(data, import_columns = nil)
        import_columns ||= if constants.include?(:IMPORT_COLUMNS)
                             self::IMPORT_COLUMNS
                           else
                             suggest_template(0, false, false)
                           end
        inserts = []
        updates = []
        counts = Hash.new { |h, k| h[k] = [] }
        errors = []

        is_first = true
        uniques = nil
        cols = nil
        starred = []
        partials = []
        all = import_columns[:all]
        keepers = {}
        valid_unique = nil
        existing = {}
        devise_class = ''

        reference_models = if Object.const_defined?('Apartment')
                             Apartment.excluded_models
                           else
                             []
        end

        if Object.const_defined?('Devise')
          Object.const_get('Devise') # If this fails, devise_class will remain a blank string.
          devise_class = Devise.mappings.values.first.class_name
          reference_models -= [devise_class]
        else
          devise_class = ''
        end

        # Did they give us a filename?
        if data.is_a?(String)
          data = if data.length <= 4096 && data.split('\n').length == 1
                   File.open(data)
                 else
                   # Hope that other multi-line strings might be CSV data
                   CSV.new(data)
                 end
        end
        # Or perhaps us a file?
        if data.is_a?(File)
          # Use the "roo" gem if it's available
          data = if Object.const_defined?('Roo::Spreadsheet', { csv_options: { encoding: 'bom|utf-8' } })
                   Roo::Spreadsheet.open(data)
                 else
                   # Otherwise generic CSV parsing
                   require 'csv' unless Object.const_defined?('CSV')
                   CSV.open(data)
                 end
        end

        # Will show as just one transaction when using auditing solutions such as PaperTrail
        ActiveRecord::Base.transaction do
          # Check to see if they want to do anything before the whole import
          if before_import ||= (import_columns[:before_import]) # || some generic before_import)
            before_import.call(data)
          end
          data.each_with_index do |row, row_num|
            row_errors = {}
            if is_first # Anticipate that first row has column names
              uniques = import_columns[:uniques]

              # Look for UTF-8 BOM in very first cell
              row[0] = row[0][3..-1] if row[0].start_with?([239, 187, 191].pack('U*'))
              # How about a first character of FEFF or FFFE to support UTF-16 BOMs?
              #   FE FF big-endian (standard)
              #   FF FE little-endian
              row[0] = row[0][1..-1] if [65_279, 65_534].include?(row[0][0].ord)
              cols = row.map { |col| (col || '').strip }

              # Unique column combinations can be called out explicitly in models using uniques: {...}, or to just
              # define one column at a time simply mark with an asterisk.
              # Track and clean up stars
              starred = cols.select do |col|
                if col[0] == '*'
                  col.slice!(0)
                  col.strip!
                end
              end
              partials = cols.select do |col|
                if col[0] == '~'
                  col.slice!(0)
                  col.strip!
                end
              end
              defined_uniques(uniques, cols, starred)
              cols.map! { |col| ::DutyFree::Util._clean_name(col, import_columns[:as]) } # %%%
              # Make sure that at least half of them match what we know as being good column names
              template_column_objects = recurse_def(import_columns[:all], import_columns).first
              cols.each_with_index do |col, idx|
                # prefixes = col_detail.pre_prefix + (col_detail.prefix.blank? ? [] : [col_detail.prefix])
                keepers[idx] = template_column_objects.find { |col_obj| col_obj.titleize == col }
                # puts "Could not find a match for column #{idx + 1}, #{col}" if keepers[idx].nil?
              end
              if keepers.length < (cols.length / 2) - 1
                raise ::DutyFree::LessThanHalfAreMatchingColumnsError, I18n.t('import.altered_import_template_coumns')
              end

              # Returns just the first valid unique lookup set if there are multiple
              valid_unique = valid_uniques(uniques, cols, starred, import_columns)
              # Make a lookup from unique values to specific IDs
              existing = pluck(*([:id] + valid_unique.keys)).each_with_object(existing) { |v, s| s[v[1..-1].map(&:to_s)] = v.first; }
              is_first = false
            else # Normal row of data
              is_insert = false
              is_do_save = true
              existing_unique = valid_unique.inject([]) do |s, v|
                s << row[v.last].to_s
              end
              # Check to see if they want to preprocess anything
              if @before_process ||= import_columns[:before_process]
                existing_unique = @before_process.call(valid_unique, existing_unique)
              end
              obj = if existing.include?(existing_unique)
                      find(existing[existing_unique])
                    else
                      is_insert = true
                      new
                    end
              sub_obj = nil
              is_has_one = false
              has_ones = []
              polymorphics = []
              sub_objects = {}
              this_path = nil
              keepers.each do |key, v|
                klass = nil
                next if v.nil?

                # Not the same as the last path?
                if this_path && v.path != this_path.split(',').map(&:to_sym) && !is_has_one
                  if sub_obj&.valid?
                    # %%% Perhaps send them even invalid objects so they can be made valid here?
                    if around_import_save
                      around_import_save(sub_obj) do |yes_do_save|
                        sub_obj.save if yes_do_save && sub_obj&.valid?
                      end
                    end
                  end
                end
                sub_obj = obj
                this_path = ''
                v.path.each_with_index do |path_part, idx|
                  this_path << (this_path.blank? ? path_part.to_s : ",#{path_part}")
                  unless (sub_next = sub_objects[this_path])
                    # Check if we're hitting platform data / a lookup thing
                    assoc = v.prefix_assocs[idx]
                    # belongs_to some lookup (reference) data
                    if assoc && reference_models.include?(assoc.class_name)
                      lookup_match = assoc.klass.find_by(v.name => row[key])
                      # Do a partial match if this column allows for it
                      # and we only find one matching result.
                      if lookup_match.nil? && partials.include?(v.titleize)
                        lookup_match ||= assoc.klass.where("#{v.name} LIKE '#{row[key]}%'")
                        lookup_match = (lookup_match.length == 1 ? lookup_match.first : nil)
                      end
                      sub_obj.send("#{path_part}=", lookup_match) unless lookup_match.nil?
                      # Reference data from the platform level means we stop here
                      sub_obj = nil
                      break
                    end
                    # This works for belongs_to or has_one.  has_many gets sorted below.
                    # Get existing related object, or create a new one
                    if (sub_next = sub_obj.send(path_part)).nil?
                      is_has_one = assoc.is_a?(ActiveRecord::Reflection::HasOneReflection)
                      klass = Object.const_get(assoc&.class_name)
                      sub_next = if is_has_one
                                   has_ones << v.path
                                   klass.new
                                 else
                                   # Try to find a unique item if one is referenced
                                   trim_prefix = v.titleize[0..-(v.name.length + 2)]
                                   begin
                                     sub_unique = assoc.klass.valid_uniques(uniques, cols, starred, import_columns, all, trim_prefix)
                                   rescue ::DutyFree::NoUniqueColumnError
                                     sub_unique = nil
                                   end
                                   # Find by all corresponding columns
                                   criteria = sub_unique&.inject({}) do |s, v|
                                     s[v.first.to_sym] = row[v.last]
                                     s
                                   end
                                   # Try looking up this belongs_to object through ActiveRecord
                                   sub_bt = assoc.klass.find_by(criteria) if criteria
                                   sub_bt || sub_obj.send("#{path_part}=", klass.new(criteria || {}))
                                 end
                    end
                    # Look for possible missing polymorphic detail
                    if assoc.is_a?(ActiveRecord::Reflection::ThroughReflection) &&
                       (delegate = assoc.send(:delegate_reflection)&.active_record&.reflect_on_association(assoc.source_reflection_name)) &&
                       delegate.options[:polymorphic]
                      polymorphics << { parent: sub_next, child: sub_obj, type_col: delegate.foreign_type, id_col: delegate.foreign_key.to_s }
                    end
                    # From a has_many?
                    if sub_next.is_a?(ActiveRecord::Associations::CollectionProxy)
                      # Try to find a unique item if one is referenced
                      # %%% There is possibility that when bringing in related classes using a nil
                      # in IMPORT_COLUMNS[:all] that this will break.  Need to test deeply nested things.
                      start = (v.pre_prefix.blank? ? 0 : v.pre_prefix.length)
                      trim_prefix = v.titleize[start..-(v.name.length + 2)]
                      puts sub_next.klass
                      sub_unique = sub_next.klass.valid_uniques(uniques, cols, starred, import_columns, all, trim_prefix)
                      # Find by all corresponding columns
                      criteria = sub_unique.each_with_object({}) { |v, s| s[v.first.to_sym] = row[v.last]; }
                      sub_hm = sub_next.find do |hm_obj|
                        is_good = true
                        criteria.each do |k, v|
                          if hm_obj.send(k).to_s != v.to_s
                            is_good = false
                            break
                          end
                        end
                        is_good
                      end
                      # Try looking it up through ActiveRecord
                      sub_hm = sub_next.find_by(criteria) if sub_hm.nil?
                      # If still not found then create a new related object using this has_many collection
                      sub_next = sub_hm || sub_next.new(criteria)
                    end
                    unless sub_next.nil?
                      # if sub_next.class.name == devise_class && # only for Devise users
                      #     sub_next.email =~ Devise.email_regexp
                      #   if existing.include?([sub_next.email])
                      #     User already exists
                      #   else
                      #     sub_next.invite!
                      #   end
                      # end
                      sub_objects[this_path] = sub_next if this_path.present?
                    end
                  end
                  sub_obj = sub_next unless sub_next.nil?
                end
                next if sub_obj.nil?

                sym = "#{v.name}=".to_sym
                sub_class = sub_obj.class
                next unless sub_obj.respond_to?(sym)

                col_type = sub_class.columns_hash[v.name.to_s]&.type
                if col_type.nil? && (virtual_columns = import_columns[:virtual_columns]) &&
                   (virtual_columns = virtual_columns[this_path] || virtual_columns)
                  col_type = virtual_columns[v.name]
                end
                if col_type == :boolean
                  if row[key].nil?
                    # Do nothing when it's nil
                  elsif %w[yes y].include?(row[key]&.downcase) # Used to cover 'true', 't', 'on'
                    row[key] = true
                  elsif %w[no n].include?(row[key]&.downcase) # Used to cover 'false', 'f', 'off'
                    row[key] = false
                  else
                    row_errors[v.name] ||= []
                    row_errors[v.name] << "Boolean value \"#{row[key]}\" in column #{key + 1} not recognized"
                  end
                end
                sub_obj.send(sym, row[key])
                # else
                #   puts "  #{sub_class.name} doesn't respond to #{sym}"
              end
              # Try to save a final sub-object if one exists
              sub_obj.save if sub_obj && this_path && !is_has_one && sub_obj.valid?

              # Wire up has_one associations
              has_ones.each do |hasone|
                parent = sub_objects[hasone[0..-2].map(&:to_s).join(',')] || obj
                hasone_object = sub_objects[hasone.map(&:to_s).join(',')]
                parent.send("#{hasone[-1]}=", hasone_object) if parent.new_record? || hasone_object.valid?
              end

              # Reinstate any missing polymorphic _type and _id values
              polymorphics.each do |poly|
                if !poly[:parent].new_record? || poly[:parent].save
                  poly[:child].send("#{poly[:type_col]}=".to_sym, poly[:parent].class.name)
                  poly[:child].send("#{poly[:id_col]}=".to_sym, poly[:parent].id)
                end
              end

              # Give a window of opportinity to tweak user objects controlled by Devise
              is_do_save = before_devise_save(obj, existing) if before_devise_save && obj.class.name == devise_class

              if obj.valid?
                obj.save if is_do_save
                # Snag back any changes to the unique columns.  (For instance, Devise downcases email addresses.)
                existing_unique = valid_unique.keys.inject([]) { |s, v| s << obj.send(v) }
                # Update the duplicate counts and inserted / updated results
                counts[existing_unique] << row_num
                (is_insert ? inserts : updates) << { row_num => existing_unique } if is_do_save
                # Track this new object so we can properly sense any duplicates later
                existing[existing_unique] = obj.id
              else
                row_errors.merge! obj.errors.messages
              end
              errors << { row_num => row_errors } unless row_errors.empty?
            end
          end
          duplicates = counts.inject([]) do |s, v|
            s + v.last[1..-1].map { |line_num| { line_num => v.first } } if v.last.count > 1
          end
          # Check to see if they want to do anything before the whole import
          ret = { inserted: inserts, updated: updates, duplicates: duplicates, errors: errors }
          if @after_import ||= (import_columns[:after_import]) # || some generic after_import)
            ret = ret2 if (ret2 = @after_import.call(ret)).is_a?(Hash)
          end
        end
        ret
      end

      # Friendly column names that end up in the first row of the CSV
      # Required columns get prefixed with a *
      def friendly_columns(import_columns = self::IMPORT_COLUMNS)
        requireds = (import_columns[:required] || [])
        template_columns(import_columns).map do |col|
          is_required = requireds.include?(col)
          col = col.to_s.titleize
          # Alias-ify the full column names
          aliases = (import_columns[:as] || [])
          aliases.each do |k, v|
            if col.start_with?(v)
              col = k + col[v.length..-1]
              break
            end
          end
          (is_required ? '* ' : '') + col
        end
      end

      # The snake-cased column alias names used in the query to export data
      def template_columns(import_columns = nil)
        if @template_import_columns != import_columns
          @template_import_columns = import_columns
          @template_detail_columns = nil
        end
        @template_detail_columns ||= recurse_def(import_columns[:all], import_columns).first.map(&:to_sym)
      end

      # For use with importing, based on the provided column list calculate all valid combinations
      # of unique columns.  If there is no valid combination, throws an error.
      def valid_uniques(uniques, cols, starred, import_columns, all = nil, trim_prefix = '')
        col_name_offset = (trim_prefix.blank? ? 0 : trim_prefix.length + 1)
        @valid_uniques ||= {} # Fancy memoisation
        col_list = cols.join('|')
        unless (vus = @valid_uniques[col_list])
          # Find all unique combinations that are available based on incoming columns, and
          # pair them up with column number mappings.
          template_column_objects = recurse_def(all || import_columns[:all], import_columns).first
          available = if trim_prefix.blank?
                        template_column_objects.select { |col| col.pre_prefix.blank? && col.prefix.blank? }
                      else
                        trim_prefix_snake = trim_prefix.downcase.tr(' ', '_')
                        template_column_objects.select do |col|
                          trim_prefix_snake == ::DutyFree::Util._prefix_join([col.pre_prefix, col.prefix], '_').tr('.', '_')
                        end
                      end.map { |avail| avail.name.to_s.titleize }
          vus = defined_uniques(uniques, cols, starred).select do |k, _v|
            is_good = true
            k.each do |k_col|
              unless k_col.start_with?(trim_prefix) && available.include?(k_col[col_name_offset..-1])
                is_good = false
                break
              end
            end
            is_good
          end
          @valid_uniques[col_list] = vus
        end

        # Make sure they have at least one unique combination to take cues from
        raise ::DutyFree::NoUniqueColumnError, I18n.t('import.no_unique_column_error') if vus.empty?

        # Convert the first entry to a simplified hash, such as:
        #   {[:investigator_institutions_name, :investigator_institutions_email] => [8, 9], ...}
        #     to {:name => 8, :email => 9}
        key, val = vus.first
        ret = {}
        key.each_with_index do |k, idx|
          ret[k[col_name_offset..-1].downcase.tr(' ', '_').to_sym] = val[idx]
        end
        ret
      end

    private

      def defined_uniques(uniques, cols = [], starred = [])
        @defined_uniques ||= {}
        unless (defined_uniques = @defined_uniques[cols])
          utilised = {} # Track columns that have been referenced thusfar
          defined_uniques = uniques.each_with_object({}) do |unique, s|
            if unique.is_a?(Array)
              key = []
              value = []
              unique.each do |unique_part|
                val = cols.index(unique_part_name = unique_part.to_s.titleize)
                next if val.nil?

                key << unique_part_name
                value << val
              end
              unless key.empty?
                s[key] = value
                utilised[key] = nil
              end
            else
              val = cols.index(unique_part_name = unique.to_s.titleize)
              unless val.nil?
                s[[unique_part_name]] = [val]
                utilised[[unique_part_name]] = nil
              end
            end
          end
          (starred - utilised.keys).each { |star| defined_uniques[[star]] = [cols.index(star)] }
          @defined_uniques[cols] = defined_uniques
        end
        defined_uniques
      end

      # Recurse and return two arrays -- one with all columns in sequence, and one a hierarchy of
      # nested hashes to be used with ActiveRecord's .joins() to facilitate export.
      def recurse_def(array, import_columns, assocs = [], joins = [], pre_prefix = '', prefix = '')
        # Confirm we can actually navigate through this association
        prefix_assoc = (assocs.last&.klass || self).reflect_on_association(prefix) if prefix.present?
        assocs = assocs.dup << prefix_assoc unless prefix_assoc.nil?
        prefixes = ::DutyFree::Util._prefix_join([pre_prefix, prefix])
        array = array.inject([]) do |s, col|
          s += if col.is_a?(Hash)
                 col.inject([]) do |s2, v|
                   joins << { v.first.to_sym => (joins_array = []) }
                   s2 += recurse_def((v.last.is_a?(Array) ? v.last : [v.last]), import_columns, assocs, joins_array, prefixes, v.first.to_sym).first
                 end
               elsif col.nil?
                 if assocs.empty?
                   []
                 else
                   # Bring in from another class
                   joins << { prefix => (joins_array = []) }
                   # %%% Also bring in uniques and requireds
                   recurse_def(assocs.last.klass::IMPORT_COLUMNS[:all], import_columns, assocs, joins_array, prefixes).first
                 end
               else
                 [::DutyFree::Column.new(col, pre_prefix, prefix, assocs, self, import_columns[:as])]
               end
          s
        end
        [array, joins]
      end
    end # module ClassMethods
  end # module Extensions

  class NoUniqueColumnError < ActiveRecord::RecordNotUnique
  end

  class LessThanHalfAreMatchingColumnsError < ActiveRecord::RecordInvalid
  end
end
