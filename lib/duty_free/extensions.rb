# frozen_string_literal: true

require 'duty_free/column'
require 'duty_free/suggest_template'
# require 'duty_free/model_config'

# :nodoc:
module DutyFree
  module Extensions
    def self.included(base)
      base.send :extend, ClassMethods
      base.send :extend, ::DutyFree::SuggestTemplate::ClassMethods
    end

    # :nodoc:
    module ClassMethods
      MAX_ID = Arel.sql('MAX(id)')
      # def self.extended(model)
      # end

      # Export at least column header, and optionally include all existing data as well
      def df_export(is_with_data = true, import_template = nil, use_inner_joins = false)
        use_inner_joins = true unless respond_to?(:left_joins)
        # In case they are only supplying the columns hash
        if is_with_data.is_a?(Hash) && !import_template
          import_template = is_with_data
          is_with_data = true
        end
        import_template ||= if constants.include?(:IMPORT_TEMPLATE)
                              self::IMPORT_TEMPLATE
                            else
                              suggest_template(0, false, false)
                            end

        # Friendly column names that end up in the first row of the CSV
        # Required columns get prefixed with a *
        requireds = (import_template[:required] || [])
        rows = ::DutyFree::Extensions._template_columns(self, import_template).map do |col|
          is_required = requireds.include?(col)
          col = col.to_s.titleize
          # Alias-ify the full column names
          aliases = (import_template[:as] || [])
          aliases.each do |k, v|
            if col.start_with?(v)
              col = k + col[v.length..-1]
              break
            end
          end
          (is_required ? '* ' : '') + col
        end
        rows = [rows]

        if is_with_data
          order_by = []
          order_by << ['_', primary_key] if primary_key
          # Automatically create a JOINs strategy and select list to get back all related rows
          template_cols, template_joins = ::DutyFree::Extensions._recurse_def(self, import_template[:all], import_template, order_by)
          relation = use_inner_joins ? joins(template_joins) : left_joins(template_joins)

          # So we can properly create the SELECT list, create a mapping between our
          # column alias prefixes and the aliases AREL creates.
          # %%% If with Rails 3.1 and older you get "NoMethodError: undefined method `eq' for nil:NilClass"
          # when trying to call relation.arel, then somewhere along the line while navigating a has_many
          # relationship it can't find the proper foreign key.
          core = relation.arel.ast.cores.first
          # Accommodate AR < 3.2
          arel_alias_names = if core.froms.is_a?(Arel::Table)
                               # All recent versions of AR have #source which brings up an Arel::Nodes::JoinSource
                               ::DutyFree::Util._recurse_arel(core.source)
                             else
                               # With AR < 3.2, "froms" brings up the top node, an Arel::Nodes::InnerJoin
                               ::DutyFree::Util._recurse_arel(core.froms)
                             end
          our_names = ['_'] + ::DutyFree::Util._recurse_arel(template_joins)
          mapping = our_names.zip(arel_alias_names).to_h
          relation = (order_by.empty? ? relation : relation.order(order_by.map { |o| "#{mapping[o.first]}.#{o.last}" }))
          # puts mapping.inspect
          # puts relation.dup.select(template_cols.map { |x| x.to_s(mapping) }).to_sql
          relation.select(template_cols.map { |x| x.to_s(mapping) }).each do |result|
            rows << ::DutyFree::Extensions._template_columns(self, import_template).map do |col|
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
      def df_import(data, import_template = nil)
        instance_variable_set(:@defined_uniques, nil)
        instance_variable_set(:@valid_uniques, nil)

        import_template ||= if constants.include?(:IMPORT_TEMPLATE)
                              self::IMPORT_TEMPLATE
                            else
                              suggest_template(0, false, false)
                            end
        # puts "Chose #{import_template}"
        inserts = []
        updates = []
        counts = Hash.new { |h, k| h[k] = [] }
        errors = []

        is_first = true
        uniques = nil
        cols = nil
        starred = []
        partials = []
        all = import_template[:all]
        keepers = {}
        valid_unique = nil
        existing = {}
        devise_class = ''
        ret = nil

        # Multi-tenancy gem Apartment can be used if there are separate schemas per tenant
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
          # Filenames with full paths can not be longer than 4096 characters, and can not
          # include newline characters
          data = if data.length <= 4096 && !data.index('\n')
                   File.open(data)
                 else
                   # Any multi-line string is likely CSV data
                   # %%% Test to see if TAB characters are present on the first line, instead of commas
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
          # First if defined in the import_template, then if there is a method in the class,
          # and finally (not yet implemented) a generic global before_import
          my_before_import = import_template[:before_import]
          my_before_import ||= respond_to?(:before_import) && method(:before_import)
          # my_before_import ||= some generic my_before_import
          if my_before_import
            last_arg_idx = my_before_import.parameters.length - 1
            arguments = [data, import_template][0..last_arg_idx]
            data = ret if (ret = my_before_import.call(*arguments)).is_a?(Enumerable)
          end
          data.each_with_index do |row, row_num|
            row_errors = {}
            if is_first # Anticipate that first row has column names
              uniques = import_template[:uniques]

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
              cols.map! { |col| ::DutyFree::Util._clean_name(col, import_template[:as]) }
              defined_uniques(uniques, cols, cols.join('|'), starred)
              # Make sure that at least half of them match what we know as being good column names
              template_column_objects = ::DutyFree::Extensions._recurse_def(self, import_template[:all], import_template).first
              cols.each_with_index do |col, idx|
                # prefixes = col_detail.pre_prefix + (col_detail.prefix.blank? ? [] : [col_detail.prefix])
                keepers[idx] = template_column_objects.find { |col_obj| col_obj.titleize == col }
                # puts "Could not find a match for column #{idx + 1}, #{col}" if keepers[idx].nil?
              end
              raise ::DutyFree::LessThanHalfAreMatchingColumnsError, I18n.t('import.altered_import_template_coumns') if keepers.length < (cols.length / 2) - 1

              # Returns just the first valid unique lookup set if there are multiple
              valid_unique = find_existing(uniques, cols, starred, import_template, keepers, false)
              # Make a lookup from unique values to specific IDs
              existing = pluck(*([:id] + valid_unique.keys)).each_with_object(existing) do |v, s|
                s[v[1..-1].map(&:to_s)] = v.first
                s
              end
              is_first = false
            else # Normal row of data
              is_insert = false
              existing_unique = valid_unique.inject([]) do |s, v|
                s << if v.last.is_a?(Array)
                       v.last[0].where(v.last[1] => row[v.last[2]]).limit(1).pluck(MAX_ID).first.to_s
                     else
                       row[v.last].to_s
                     end
              end
              to_be_saved = []
              # Check to see if they want to preprocess anything
              existing_unique = @before_process.call(valid_unique, existing_unique) if @before_process ||= import_template[:before_process]
              if (criteria = existing[existing_unique])
                obj = find(criteria)
              else
                is_insert = true
                to_be_saved << [obj = new]
              end
              sub_obj = nil
              is_has_one = false
              has_ones = []
              polymorphics = []
              sub_objects = {}
              this_path = nil
              keepers.each do |key, v|
                next if v.nil?

                sub_obj = obj
                this_path = +''
                # puts "p: #{v.path}"
                v.path.each_with_index do |path_part, idx|
                  this_path << (this_path.blank? ? path_part.to_s : ",#{path_part}")
                  unless (sub_next = sub_objects[this_path])
                    # Check if we're hitting reference data / a lookup thing
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
                      # Reference data from the public level means we stop here
                      sub_obj = nil
                      break
                    end
                    # Get existing related object, or create a new one
                    # This first part works for belongs_to.  has_many and has_one get sorted below.
                    if (sub_next = sub_obj.send(path_part)).nil? && assoc.belongs_to?
                      klass = Object.const_get(assoc&.class_name)
                      # Try to find a unique item if one is referenced
                      sub_next = nil
                      begin
                        trim_prefix = v.titleize[0..-(v.name.length + 2)]
                        trim_prefix << ' ' unless trim_prefix.blank?
                        sub_next, criteria = klass.find_existing(uniques, cols, starred, import_template, keepers, nil, row, klass, all, trim_prefix)
                      rescue ::DutyFree::NoUniqueColumnError
                      end
                      # puts "#{v.path} #{criteria.inspect}"
                      bt_name = "#{path_part}="
                      unless sub_next || (klass == sub_obj.class && criteria.empty?)
                        sub_next = klass.new(criteria || {})
                        to_be_saved << [sub_next, sub_obj, bt_name, sub_next]
                      end
                      # This wires it up in memory, but doesn't yet put the proper foreign key ID in
                      # place when the primary object is a new one (and thus not having yet been saved
                      # doesn't yet have an ID).
                      # binding.pry if !sub_next.new_record? && sub_next.name == 'Squidget Widget' # !sub_obj.changed?
                      # # %%% Question is -- does the above set changed? when a foreign key is not yet set
                      # # and only the in-memory object has changed?
                      is_yet_changed = sub_obj.changed?
                      sub_obj.send(bt_name, sub_next)

                      # We need this in the case of updating the primary object across a belongs_to when
                      # the foreign one already exists and is not otherwise changing, such as when it is
                      # not a new one, so wouldn't otherwise be getting saved.
                      to_be_saved << [sub_obj] if !sub_obj.new_record? && !is_yet_changed && sub_obj.changed?
                    # From a has_many or has_one?
                    # Rails 4.0 and later can do:  sub_next.is_a?(ActiveRecord::Associations::CollectionProxy)
                    elsif [:has_many, :has_one].include?(assoc.macro) && !assoc.options[:through]
                      ::DutyFree::Extensions._save_pending(to_be_saved)
                      # Try to find a unique item if one is referenced
                      # %%% There is possibility that when bringing in related classes using a nil
                      # in IMPORT_TEMPLATE[:all] that this will break.  Need to test deeply nested things.
                      start = (v.pre_prefix.blank? ? 0 : v.pre_prefix.length)
                      trim_prefix = v.titleize[start..-(v.name.length + 2)]
                      trim_prefix << ' ' unless trim_prefix.blank?
                      # assoc.inverse_of is the belongs_to side of the has_many train we came in here on.
                      sub_hm, criteria = assoc.klass.find_existing(uniques, cols, starred, import_template, keepers, assoc.inverse_of, row, sub_next, all, trim_prefix)
                      # If still not found then create a new related object using this has_many collection
                      # (criteria.empty? ? nil : sub_next.new(criteria))
                      if sub_hm
                        sub_next = sub_hm
                      elsif assoc.macro == :has_one
                        # assoc.active_record.name.underscore is only there to support older Rails
                        # that doesn't do automatic inverse_of
                        ho_name = "#{assoc.inverse_of&.name || assoc.active_record.name.underscore}="
                        sub_next = assoc.klass.new(criteria)
                        to_be_saved << [sub_next, sub_next, ho_name, sub_obj]
                      else
                        # Two other methods that are possible to check for here are :conditions and
                        # :sanitized_conditions, which do not exist in Rails 4.0 and later.
                        sub_next = if assoc.respond_to?(:require_association)
                                     # With Rails < 4.0, sub_next could come in as an Array or a broken CollectionProxy
                                     assoc.klass.new({ fk_from(assoc) => sub_obj.send(sub_obj.class.primary_key) }.merge(criteria))
                                   else
                                     sub_next.proxy_association.reflection.instance_variable_set(:@foreign_key, fk_from(assoc))
                                     sub_next.new(criteria)
                                   end
                        to_be_saved << [sub_next]
                      end
                    end
                    # Look for possible missing polymorphic detail
                    # Maybe can test for this via assoc.through_reflection
                    if assoc.is_a?(ActiveRecord::Reflection::ThroughReflection) &&
                       (delegate = assoc.send(:delegate_reflection)&.active_record&.reflect_on_association(assoc.source_reflection_name)) &&
                       delegate.options[:polymorphic]
                      polymorphics << { parent: sub_next, child: sub_obj, type_col: delegate.foreign_type, id_col: delegate.foreign_key.to_s }
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
                  sub_obj = sub_next
                end
                next if sub_obj.nil?

                next unless sub_obj.respond_to?(sym = "#{v.name}=".to_sym)

                col_type = sub_obj.class.columns_hash[v.name.to_s]&.type
                if col_type.nil? && (virtual_columns = import_template[:virtual_columns]) &&
                   (virtual_columns = virtual_columns[this_path] || virtual_columns)
                  col_type = virtual_columns[v.name]
                end
                if col_type == :boolean
                  if row[key].nil?
                    # Do nothing when it's nil
                  elsif %w[true t yes y].include?(row[key]&.strip&.downcase) # Used to cover 'on'
                    row[key] = true
                  elsif %w[false f no n].include?(row[key]&.strip&.downcase) # Used to cover 'off'
                    row[key] = false
                  else
                    row_errors[v.name] ||= []
                    row_errors[v.name] << "Boolean value \"#{row[key]}\" in column #{key + 1} not recognized"
                  end
                end

                is_yet_changed = sub_obj.changed?
                sub_obj.send(sym, row[key])
                # If this one is transitioning from having not changed to now having been changed,
                # and is not a new one anyway that would already be lined up to get saved, then we
                # mark it to now be saved.
                to_be_saved << [sub_obj] if !sub_obj.new_record? && !is_yet_changed && sub_obj.changed?
                # else
                #   puts "  #{sub_obj.class.name} doesn't respond to #{sym}"
              end
              # Try to save final sub-object(s) if any exist
              ::DutyFree::Extensions._save_pending(to_be_saved)

              # Reinstate any missing polymorphic _type and _id values
              polymorphics.each do |poly|
                if !poly[:parent].new_record? || poly[:parent].save
                  poly[:child].send("#{poly[:type_col]}=".to_sym, poly[:parent].class.name)
                  poly[:child].send("#{poly[:id_col]}=".to_sym, poly[:parent].id)
                end
              end

              # Give a window of opportunity to tweak user objects controlled by Devise
              obj_class = obj.class
              is_do_save = if obj_class.respond_to?(:before_devise_save) && obj_class.name == devise_class
                             obj_class.before_devise_save(obj, existing)
                           else
                             true
                           end

              if obj.valid?
                obj.save if is_do_save
                # Snag back any changes to the unique columns.  (For instance, Devise downcases email addresses.)
                existing_unique = valid_unique.keys.inject([]) { |s, v| s << obj.send(v).to_s }
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
          duplicates = counts.each_with_object([]) do |v, s|
            s += v.last[1..-1].map { |line_num| { line_num => v.first } } if v.last.count > 1
            s
          end
          ret = { inserted: inserts, updated: updates, duplicates: duplicates, errors: errors }

          # Check to see if they want to do anything after the import
          # First if defined in the import_template, then if there is a method in the class,
          # and finally (not yet implemented) a generic global after_import
          my_after_import = import_template[:after_import]
          my_after_import ||= respond_to?(:after_import) && method(:after_import)
          # my_after_import ||= some generic my_after_import
          if my_after_import
            last_arg_idx = my_after_import.parameters.length - 1
            arguments = [ret][0..last_arg_idx]
            ret = ret2 if (ret2 = my_after_import.call(*arguments)).is_a?(Hash)
          end
        end
        ret
      end

      def fk_from(assoc)
        # Try first to trust whatever they've marked as being the foreign_key, and then look
        # at the inverse's foreign key setting if available.  In all cases don't accept
        # anything that's not backed with a real column in the table.
        col_names = assoc.klass.column_names
        if (fk_name = assoc.options[:foreign_key]) && col_names.include?(fk_name.to_s)
          return fk_name
        end
        if (fk_name = assoc.inverse_of&.options&.fetch(:foreign_key) { nil }) &&
           col_names.include?(fk_name.to_s)
          return fk_name
        end
        if assoc.respond_to?(:foreign_key) && (fk_name = assoc.foreign_key) &&
           col_names.include?(fk_name.to_s)
          return fk_name
        end
        if (fk_name = assoc.inverse_of&.foreign_key) &&
           col_names.include?(fk_name.to_s)
          return fk_name
        end
        if (fk_name = assoc.inverse_of&.association_foreign_key) &&
           col_names.include?(fk_name.to_s)
          return fk_name
        end
        # Don't let this fool you -- we really are in search of the foreign key name here,
        # and Rails 3.0 and older used some fairly interesting conventions, calling it instead
        # the "primary_key_name"!
        if assoc.respond_to?(:primary_key_name)
          if (fk_name = assoc.primary_key_name) && col_names.include?(fk_name.to_s)
            return fk_name
          end
          if (fk_name = assoc.inverse_of.primary_key_name) && col_names.include?(fk_name.to_s)
            return fk_name
          end
        end

        puts "* Wow, had no luck at all finding a foreign key for #{assoc.inspect}"
      end

      # For use with importing, based on the provided column list calculate all valid combinations
      # of unique columns.  If there is no valid combination, throws an error.
      # Returns an object found by this means.
      def find_existing(uniques, cols, starred, import_template, keepers, train_we_came_in_here_on,
                        row = nil, klass_or_collection = nil, template_all = nil, trim_prefix = '')
        unless trim_prefix.blank?
          cols = cols.map { |c| c.start_with?(trim_prefix) ? c[trim_prefix.length..-1] : nil }
          starred = starred.each_with_object([]) do |v, s|
            s << v[trim_prefix.length..-1] if v.start_with?(trim_prefix)
            s
          end
        end
        col_list = cols.join('|')

        # First add in foreign key stuff we can find from belongs_to associations (other than the
        # one we might have arrived here upon).
        criteria = {} # Enough detail to find or build a new object
        bt_criteria = {}
        bt_criteria_all_nil = true
        bt_col_indexes = []
        available_bts = []
        only_valid_uniques = (train_we_came_in_here_on == false)
        uniq_lookups = {} # The data, or how to look up the data

        vus = ((@valid_uniques ||= {})[col_list] ||= {}) # Fancy memoisation

        # First, get an overall list of AVAILABLE COLUMNS before considering tricky foreign key stuff.
        # ============================================================================================
        # Generate a list of column names matched up with their zero-ordinal column number mapping for
        # all columns from the incoming import data.
        if (is_new_vus = vus.empty?)
          template_column_objects = ::DutyFree::Extensions._recurse_def(
            self,
            template_all || import_template[:all],
            import_template
          ).first
          available = if trim_prefix.blank?
                        template_column_objects.select { |col| col.pre_prefix.blank? && col.prefix.blank? }
                      else
                        trim_prefix_snake = trim_prefix.downcase.tr(' ', '_')
                        template_column_objects.select do |col|
                          this_prefix = ::DutyFree::Util._prefix_join([col.pre_prefix, col.prefix], '_').tr('.', '_')
                          trim_prefix_snake == "#{this_prefix}_"
                        end
                      end.map { |avail| avail.name.to_s.titleize }
        end

        # Process FOREIGN KEY stuff by going through each belongs_to in this model.
        # =========================================================================
        # This list of all valid uniques will help to filter which foreign keys are kept, and also
        # get further filtered later to arrive upon a final set of valid uniques.  (Often but not
        # necessarily a specific valid unique as perhaps with a list of users you want to update some
        # folks based on having their email as a unique identifier, and other folks by having a
        # combination of their name and street address as unique, and use both of those possible
        # unique variations to update phone numbers, and do that all as a part of one import.)
        all_vus = defined_uniques(uniques, cols, col_list, starred, trim_prefix)

        # %%% Ultimately may consider making this recursive
        reflect_on_all_associations.each do |sn_bt|
          next unless sn_bt.belongs_to? && (!train_we_came_in_here_on || sn_bt != train_we_came_in_here_on)

          # # %%% Make sure there's a starred column we know about from this one
          # uniq_lookups[sn_bt.foreign_key] = nil if only_valid_uniques

          # This search prefix becomes something like "Order Details Product "
          cols.each_with_index do |bt_col, idx|
            next if bt_col_indexes.include?(idx) ||
                    !bt_col&.start_with?(bt_prefix = (trim_prefix + "#{sn_bt.name.to_s.underscore.tr('_', ' ').titleize} "))

            available_bts << bt_col
            fk_id = if row
                      # Max ID so if there are multiple matches, only the most recent one is picked.
                      # %%% Need to stack these up in case there are multiple
                      # (like first_name, last_name on a referenced employee)
                      sn_bt.klass.where(keepers[idx].name => row[idx]).limit(1).pluck(MAX_ID).first
                    else
                      # elsif is_new_vus
                      #   # Add to our criteria if this belongs_to is required
                      #   bt_req_by_default = sn_bt.klass.respond_to?(:belongs_to_required_by_default) &&
                      #                       sn_bt.klass.belongs_to_required_by_default
                      #   unless !vus.values.first&.include?(idx) &&
                      #          (sn_bt.options[:optional] || (sn_bt.options[:required] == false) || !bt_req_by_default)
                      #     # # Add this fk to the criteria
                      #     # criteria[fk_name] = fk_id

                      #     ref = [keepers[idx].name, idx]
                      #     # bt_criteria[(fk_name = sn_bt.foreign_key)] ||= [sn_bt.klass, []]
                      #     # bt_criteria[fk_name].last << ref
                      #     # bt_criteria[bt_col] = [sn_bt.klass, ref]

                      #     # Maybe this is the most useful
                      #     # First array is friendly column names, second is references
                      #     foreign_uniques = (bt_criteria[sn_bt.name] ||= [sn_bt.klass, [], []])
                      #     foreign_uniques[1] << ref
                      #     foreign_uniques[2] << bt_col
                      #     vus[bt_col] = foreign_uniques # And we can look up this growing set from any foreign column
                      [sn_bt.klass, keepers[idx].name, idx]
                    end
            if fk_id
              bt_col_indexes << idx
              bt_criteria_all_nil = false
            end
            # If we're processing a row then this list of foreign key column name entries, named such as
            # "order_id" or "product_id" instead of column-specific stuff like "Order Date" and "Product Name",
            # is kept until the last and then gets merged on top of the other criteria before being returned.
            bt_criteria[(fk_name = sn_bt.foreign_key)] = fk_id

            # Check to see if belongs_tos are generally required on this specific table
            bt_req_by_default = sn_bt.klass.respond_to?(:belongs_to_required_by_default) &&
                                sn_bt.klass.belongs_to_required_by_default

            # Add to our CRITERIA just the belongs_to things that check out.
            # ==============================================================
            # The first check, "all_vus.keys.first.none? { |k| k.start_with?(bt_prefix) }"
            # is to see if one of the columns we're working with from the unique that we've chosen
            # comes from the table referenced by this belongs_to (sn_bt).
            #
            # The second check on the :optional option and bt_req_by_default comes directly from
            # how Rails 5 and later checks to see if a specific belongs_to is marked optional
            # (or required), and without having that indication will fall back on checking the model
            # itself to see if it requires belongs_tos by default.
            next if all_vus.keys.first.none? { |k| k.start_with?(bt_prefix) } &&
                    (sn_bt.options[:optional] || !bt_req_by_default)

            # Add to the criteria
            criteria[fk_name] = fk_id
          end
        end

        # Now circle back find a final list of VALID UNIQUES by re-assessing the list of all valid uniques
        # in relation to the available belongs_tos found in the last foreign key step.
        if is_new_vus
          available += available_bts
          all_vus.each do |k, v|
            combined_k = []
            combined_v = []
            k.each_with_index do |key, idx|
              if available.include?(key)
                combined_k << key
                combined_v << v[idx]
              end
            end
            vus[combined_k] = combined_v unless combined_k.empty?
          end
        end

        # uniq_lookups = vus.inject({}) do |s, v|
        #   return s if available_bts.include?(v.first) # These will be provided in criteria, and not uniq_lookups

        #   # uniq_lookups[k[trim_prefix.length..-1].downcase.tr(' ', '_').to_sym] = val[idx] if k.start_with?(trim_prefix)
        #   s[v.first.downcase.tr(' ', '_').to_sym] = v.last
        #   s
        # end

        new_criteria_all_nil = bt_criteria_all_nil

        # Make sure they have at least one unique combination to take cues from
        unless vus.empty? # raise NoUniqueColumnError.new(I18n.t('import.no_unique_column_error'))
          # Convert the first entry to a simplified hash, such as:
          #   {[:investigator_institutions_name, :investigator_institutions_email] => [8, 9], ...}
          #     to {:name => 8, :email => 9}
          key, val = vus.first # Utilise the first identified set of valid uniques
          key.each_with_index do |k, idx|
            next if available_bts.include?(k) # These will be provided in criteria, and not uniq_lookups

            # uniq_lookups[k[trim_prefix.length..-1].downcase.tr(' ', '_').to_sym] = val[idx] if k.start_with?(trim_prefix)
            k_sym = k.downcase.tr(' ', '_').to_sym
            v = val[idx]
            uniq_lookups[k_sym] = v # The column number in which to find the data

            next if only_valid_uniques || bt_col_indexes.include?(v)

            # Find by all corresponding columns
            if (row_value = row[v])
              new_criteria_all_nil = false
              criteria[k_sym] = row_value # The data, or how to look up the data
            end
          end
        end

        return uniq_lookups.merge(criteria) if only_valid_uniques

        # If there's nothing to match upon then we're out
        return [nil, {}] if new_criteria_all_nil

        # With this criteria, find any matching has_many row we can so we can update it.
        # First try directly looking it up through ActiveRecord.
        found_object = klass_or_collection.find_by(criteria)
        # If not successful, such as when fields are exposed via helper methods instead of being
        # real columns in the database tables, try this more intensive approach.  This is useful
        # if you had full name kind of data coming in on a spreadsheeet, but in the destination
        # table it's broken out to first_name, middle_name, surname.  By writing both full_name
        # and full_name= methods, the importer can check to see if this entry is already there,
        # and put a new row in if not, having one incoming name break out to populate three
        # destination columns.
        unless found_object || klass_or_collection.is_a?(Array)
          found_object = klass_or_collection.find do |obj|
            is_good = true
            criteria.each do |k, v|
              if obj.send(k).to_s != v.to_s
                is_good = false
                break
              end
            end
            is_good
          end
        end
        # Standard criteria as well as foreign key column name detail with exact foreign keys
        # that match up to a primary key so that if needed a new related object can be built,
        # complete with all its association detail.
        [found_object, criteria.merge(bt_criteria)]
      end

    private

      def defined_uniques(uniques, cols = [], col_list = nil, starred = [], trim_prefix = '')
        col_list ||= cols.join('|')
        unless (defined_uniq = (@defined_uniques ||= {})[col_list])
          utilised = {} # Track columns that have been referenced thusfar
          defined_uniq = uniques.each_with_object({}) do |unique, s|
            if unique.is_a?(Array)
              key = []
              value = []
              unique.each do |unique_part|
                val = (unique_part_name = unique_part.to_s.titleize).start_with?(trim_prefix) &&
                      cols.index(upn = unique_part_name[trim_prefix.length..-1])
                next unless val

                key << upn
                value << val
              end
              unless key.empty?
                s[key] = value
                utilised[key] = nil
              end
            else
              val = (unique_name = unique.to_s.titleize).start_with?(trim_prefix) &&
                    cols.index(un = unique_name[trim_prefix.length..-1])
              if val
                s[[un]] = [val]
                utilised[[un]] = nil
              end
            end
            s
          end
          if defined_uniq.empty?
            (starred - utilised.keys).each { |star| defined_uniq[[star]] = [cols.index(star)] }
            # %%% puts "Tried to establish #{defined_uniq.inspect}"
          end
          @defined_uniques[col_list] = defined_uniq
        end
        defined_uniq
      end
    end # module ClassMethods

    # Called before building any object linked through a has_one or has_many so that foreign key IDs
    # can be added properly to those new objects.  Finally at the end also called to save everything.
    def self._save_pending(to_be_saved)
      while (tbs = to_be_saved.pop)
        # puts "Will be calling #{tbs[1].class.name} #{tbs[1]&.id} .#{tbs[2]} #{tbs[3].class.name} #{tbs[3]&.id}"

        # Wire this one up if it had came from a has_one association
        tbs[1].send(tbs[2], tbs[3]) if tbs[0] == tbs[1]

        ais = (tbs.first.class.respond_to?(:around_import_save) && tbs.first.class.method(:around_import_save)) ||
              (respond_to?(:around_import_save) && method(:around_import_save))
        if ais
          # Send them the sub_obj even if it might be invalid so they can choose
          # to make it valid if they wish.
          ais.call(tbs.first) do |modded_obj = nil|
            modded_obj = (modded_obj || tbs.first)
            modded_obj.save if modded_obj&.valid?
          end
        elsif tbs.first.valid?
          tbs.first.save
        else
          puts "* Unable to save #{tbs.first.inspect}"
        end

        next if tbs[1].nil? || # From a has_many?
                tbs[0] == tbs[1] || # From a has_one?
                tbs.first.new_record?

        tbs[1].send(tbs[2], tbs[3])
      end
    end

    # The snake-cased column alias names used in the query to export data
    def self._template_columns(klass, import_template = nil)
      template_detail_columns = klass.instance_variable_get(:@template_detail_columns)
      if klass.instance_variable_get(:@template_import_columns) != import_template
        klass.instance_variable_set(:@template_import_columns, import_template)
        klass.instance_variable_set(:@template_detail_columns, (template_detail_columns = nil))
      end
      unless template_detail_columns
        # puts "* Redoing *"
        template_detail_columns = _recurse_def(klass, import_template[:all], import_template).first.map(&:to_sym)
        klass.instance_variable_set(:@template_detail_columns, template_detail_columns)
      end
      template_detail_columns
    end

    # Recurse and return two arrays -- one with all columns in sequence, and one a hierarchy of
    # nested hashes to be used with ActiveRecord's .joins() to facilitate export.
    def self._recurse_def(klass, array, import_template, order_by = [], assocs = [], joins = [], pre_prefix = '', prefix = '')
      prefixes = ::DutyFree::Util._prefix_join([pre_prefix, prefix])
      # Confirm we can actually navigate through this association
      prefix_assoc = (assocs.last&.klass || klass).reflect_on_association(prefix) if prefix.present?
      if prefix_assoc
        assocs = assocs.dup << prefix_assoc
        if prefix_assoc.macro == :has_many && (pk = prefix_assoc.active_record.primary_key)
          order_by << ["#{prefixes.tr('.', '_')}_", pk]
        end
      end
      array = array.inject([]) do |s, col|
        s + if col.is_a?(Hash)
              col.inject([]) do |s2, v|
                joins << { v.first.to_sym => (joins_array = []) }
                s2 + _recurse_def(klass, (v.last.is_a?(Array) ? v.last : [v.last]), import_template, order_by, assocs, joins_array, prefixes, v.first.to_sym).first
              end
            elsif col.nil?
              if assocs.empty?
                []
              else
                # Bring in from another class
                joins << { prefix => (joins_array = []) }
                # %%% Also bring in uniques and requireds
                _recurse_def(klass, assocs.last.klass::IMPORT_TEMPLATE[:all], import_template, order_by, assocs, joins_array, prefixes).first
              end
            else
              [::DutyFree::Column.new(col, pre_prefix, prefix, assocs, klass, import_template[:as])]
            end
      end
      [array, joins]
    end
  end # module Extensions

  # Rails < 4.0 doesn't have ActiveRecord::RecordNotUnique, so use the more generic ActiveRecord::ActiveRecordError instead
  ar_not_unique_error = ActiveRecord.const_defined?('RecordNotUnique') ? ActiveRecord::RecordNotUnique : ActiveRecord::ActiveRecordError
  class NoUniqueColumnError < ar_not_unique_error
  end

  # Rails < 4.2 doesn't have ActiveRecord::RecordInvalid, so use the more generic ActiveRecord::ActiveRecordError instead
  ar_invalid_error = ActiveRecord.const_defined?('RecordInvalid') ? ActiveRecord::RecordInvalid : ActiveRecord::ActiveRecordError
  class LessThanHalfAreMatchingColumnsError < ar_invalid_error
  end
end
