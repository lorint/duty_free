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
      def df_export(is_with_data = true, import_template = nil)
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
          # Automatically create a JOINs strategy and select list to get back all related rows
          template_cols, template_joins = ::DutyFree::Extensions._recurse_def(self, import_template[:all], import_template)
          relation = left_joins(template_joins)

          # So we can properly create the SELECT list, create a mapping between our
          # column alias prefixes and the aliases AREL creates.
          arel_alias_names = ::DutyFree::Util._recurse_arel(relation.arel.ast.cores.first.source)
          our_names = ::DutyFree::Util._recurse_arel(template_joins)
          mapping = our_names.zip(arel_alias_names).to_h

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
        self.instance_variable_set(:@defined_uniques, nil)
        self.instance_variable_set(:@valid_uniques, nil)

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
          if before_import ||= (import_template[:before_import]) # || some generic before_import)
            before_import.call(data)
          end
          col_list = nil
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
              # %%% Will the uniques saved into @defined_uniques here just get redefined later
              # after the next line, the map! with clean to change out the alias names?  So we can't yet set
              # col_list?
              defined_uniques(uniques, cols, cols.join('|'), starred)
              cols.map! { |col| ::DutyFree::Util._clean_name(col, import_template[:as]) } # %%%
              # Make sure that at least half of them match what we know as being good column names
              template_column_objects = ::DutyFree::Extensions._recurse_def(self, import_template[:all], import_template).first
              cols.each_with_index do |col, idx|
                # prefixes = col_detail.pre_prefix + (col_detail.prefix.blank? ? [] : [col_detail.prefix])
                keepers[idx] = template_column_objects.find { |col_obj| col_obj.titleize == col }
                # puts "Could not find a match for column #{idx + 1}, #{col}" if keepers[idx].nil?
              end
              if keepers.length < (cols.length / 2) - 1
                raise ::DutyFree::LessThanHalfAreMatchingColumnsError, I18n.t('import.altered_import_template_coumns')
              end

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
              is_do_save = true
              existing_unique = valid_unique.inject([]) do |s, v|
                s << if v.last.is_a?(Array)
                       v.last[0].where(v.last[1] => row[v.last[2]]).limit(1).pluck(MAX_ID).first.to_s
                     else
                       binding.pry if v.last.nil?
                       row[v.last].to_s
                     end
              end
              # Check to see if they want to preprocess anything
              if @before_process ||= import_template[:before_process]
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
                  # puts sub_obj.class.name
                  if respond_to?(:around_import_save)
                    # Send them the sub_obj even if it might be invalid so they can choose
                    # to make it valid if they wish.
                    # binding.pry
                    around_import_save(sub_obj) do |modded_obj = nil|
                      modded_obj = (modded_obj || sub_obj)
                      modded_obj.save if sub_obj&.valid?
                    end
                  elsif sub_obj&.valid?
                    # binding.pry if sub_obj.is_a?(Employee) && sub_obj.first_name == 'Andrew'
                    sub_obj.save
                  end
                end
                sub_obj = obj
                this_path = +''
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
                                   sub_bt = nil
                                   begin
                                     # Goofs up if trim_prefix isn't the same name as the class, or if it's
                                     # a self-join?  (like when trim_prefix == 'Reports To')
                                     # %%% Need to test this more when the self-join is more than one hop away,
                                     # such as importing orders and having employees come along :)
                                     # if sub_obj.class == klass
                                     #   trim_prefix = ''
                                     #   # binding.pry
                                     # end
                                     # %%% Maybe instead of passing in "klass" we can give the belongs_to association and build through that instead,
                                     # allowing us to nix the klass.new(criteria) line below.
                                     trim_prefix = v.titleize[0..-(v.name.length + 2)]
                                     trim_prefix << ' ' unless trim_prefix.blank?
                                     if klass == sub_obj.class # Self-referencing thing pointing to us?
                                       # %%% This should be more general than just for self-referencing things.
                                       sub_cols = cols.map { |c| c.start_with?(trim_prefix) ? c[trim_prefix.length..-1] : nil }
                                       # assoc
                                       sub_bt, criteria = klass.find_existing(uniques, sub_cols, starred, import_template, keepers, nil, row, klass, all, '')
                                     else
                                       sub_bt, criteria = klass.find_existing(uniques, cols, starred, import_template, keepers, nil, row, klass, all, trim_prefix)
                                     end
                                   rescue ::DutyFree::NoUniqueColumnError
                                     sub_unique = nil
                                   end
                                   # Self-referencing shouldn't build a new one if it couldn't find one
                                   # %%% Can criteria really ever be nil anymore?
                                   unless klass == sub_obj.class && criteria.empty?
                                     sub_bt ||= klass.new(criteria || {})
                                   end
                                   sub_obj.send("#{path_part}=", sub_bt)
                                   sub_bt
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
                      # in IMPORT_TEMPLATE[:all] that this will break.  Need to test deeply nested things.
                      start = (v.pre_prefix.blank? ? 0 : v.pre_prefix.length)
                      trim_prefix = v.titleize[start..-(v.name.length + 2)]
                      trim_prefix << ' ' unless trim_prefix.blank?
                      klass = sub_next.klass
                      # binding.pry if klass.name == 'OrderDetail'

                      # assoc.inverse_of is the belongs_to side of the has_many train we came in here on.
                      sub_hm, criteria = klass.find_existing(uniques, cols, starred, import_template, keepers, assoc.inverse_of, row, sub_next, all, trim_prefix)

                      # If still not found then create a new related object using this has_many collection
                      # (criteria.empty? ? nil : sub_next.new(criteria))
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
                  # binding.pry if sub_obj.reports_to
                  sub_obj = sub_next #if sub_next
                end
                # binding.pry if sub_obj.nil?
                next if sub_obj.nil?

                sym = "#{v.name}=".to_sym
                next unless sub_obj.respond_to?(sym)

                col_type = (sub_class = sub_obj.class).columns_hash[v.name.to_s]&.type
                if col_type.nil? && (virtual_columns = import_template[:virtual_columns]) &&
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
                # binding.pry if v.name.to_s == 'first_name' && sub_obj.first_name == 'Nancy'
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
          # Check to see if they want to do anything after the import
          ret = { inserted: inserts, updated: updates, duplicates: duplicates, errors: errors }
          if @after_import ||= (import_template[:after_import]) # || some generic after_import)
            ret = ret2 if (ret2 = @after_import.call(ret)).is_a?(Hash)
          end
        end
        ret
      end

      # For use with importing, based on the provided column list calculate all valid combinations
      # of unique columns.  If there is no valid combination, throws an error.
      # Returns an object found by this means.
      def find_existing(uniques, cols, starred, import_template, keepers, train_we_came_in_here_on, row = nil, obj = nil, all = nil, trim_prefix = '')
        col_name_offset = trim_prefix.length
        @valid_uniques ||= {} # Fancy memoisation
        col_list = cols.join('|')
        unless (vus = @valid_uniques[col_list])
          # Find all unique combinations that are available based on incoming columns, and
          # pair them up with column number mappings.
          template_column_objects = ::DutyFree::Extensions._recurse_def(self, all || import_template[:all], import_template).first
          available = if trim_prefix.blank?
                        template_column_objects.select { |col| col.pre_prefix.blank? && col.prefix.blank? }
                      else
                        trim_prefix_snake = trim_prefix.downcase.tr(' ', '_')
                        template_column_objects.select do |col|
                          this_prefix = ::DutyFree::Util._prefix_join([col.pre_prefix, col.prefix], '_').tr('.', '_')
                          trim_prefix_snake == "#{this_prefix}_"
                        end
                      end.map { |avail| avail.name.to_s.titleize }
          vus = defined_uniques(uniques, cols, nil, starred).select do |k, _v|
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
        ret = {}
        unless vus.empty? # raise NoUniqueColumnError.new(I18n.t('import.no_unique_column_error'))
          # Convert the first entry to a simplified hash, such as:
          #   {[:investigator_institutions_name, :investigator_institutions_email] => [8, 9], ...}
          #     to {:name => 8, :email => 9}
          key, val = vus.first
          key.each_with_index do |k, idx|
            ret[k[col_name_offset..-1].downcase.tr(' ', '_').to_sym] = val[idx] if k.start_with?(trim_prefix)
          end
        end

        # %%% If uniqueness is based on something else hanging out on a belongs_to then we're pretty hosed.
        # (Case in point, importing Order with related Order Detail and Product, and then Product needs to
        # be found or built first before OrderDetail.)
        # Might have to do a deferred save kind of thing, and also make sure the product stuff came first
        # before the other stuff

        # Find by all corresponding columns

        # Add in any foreign key stuff we can find from other belongs_to associations
        # %%% This is starting to look like the other BelongsToAssociation code above around line
        # 697, so it really needs to be turned into something recursive instead of this two-layer
        # thick thing at best.

        # First check the belongs_tos
        criteria = {}
        bt_criteria = {}
        bt_criteria_all_nil = true
        bt_col_indexes = []
        only_valid_uniques = (train_we_came_in_here_on == false)
        bts = reflect_on_all_associations.each_with_object([]) do |sn_assoc, s|
          if sn_assoc.is_a?(ActiveRecord::Reflection::BelongsToReflection) &&
             (!train_we_came_in_here_on || sn_assoc != train_we_came_in_here_on) # &&
             # sn_assoc.klass != self # Omit stuff pointing to us (like self-referencing stuff)
            # %%% Make sure there's a starred column we know about from this one
            ret[sn_assoc.foreign_key] = nil if only_valid_uniques
            s << sn_assoc
          end
          s
        end
        bts.each do |sn_bt|
          # This search prefix becomes something like "Order Details Product "
          # binding.pry
          cols.each_with_index do |bt_col, idx|
            next if bt_col_indexes.include?(idx) ||
                    !bt_col&.start_with?(trim_prefix + "#{sn_bt.name.to_s.underscore.tr('_', ' ').titleize} ")

            fk_id = if row
                      # Max ID so if there are multiple, only the most recent one is picked.
                      # %%% Need to stack these up in case there are multiple
                      # (like first_name, last_name on a referenced employee)
                      # binding.pry
                      sn_bt.klass.where(keepers[idx].name => row[idx]).limit(1).pluck(MAX_ID).first
                    else
                      [sn_bt.klass, keepers[idx].name, idx]
                    end
            if fk_id
              bt_col_indexes << idx
              bt_criteria_all_nil = false
            end
            bt_criteria[(fk_name = sn_bt.foreign_key)] = fk_id
            # Add to our criteria if this belongs_to is required
            # %%% Rails older than 5.0 handles this stuff differently!
            unless sn_bt.options[:optional] || !sn_bt.klass.belongs_to_required_by_default
              criteria[fk_name] = fk_id
            else # Should not have this fk as a requirement
              ret.delete(fk_name) if only_valid_uniques && ret.include?(fk_name)
            end
          end
        end

        new_criteria_all_nil = bt_criteria_all_nil
        if train_we_came_in_here_on != false
          criteria = ret.each_with_object({}) do |v, s|
            next if bt_col_indexes.include?(v.last)

            new_criteria_all_nil = false if (s[v.first.to_sym] = row[v.last])
            s
          end
        end

        # Short-circuiting this to only get back the valid_uniques?
        return ret.merge(criteria) if only_valid_uniques

        # binding.pry if obj.is_a?(Order)
        # If there's nothing to match upon then we're out
        return [nil, {}] if new_criteria_all_nil

        # With this criteria, find any matching has_many row we can so we can update it
        sub_hm = obj.find do |hm_obj|
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
        # %%% Should we perhaps do this first before the more intensive find routine above?
        sub_hm = obj.find_by(criteria) if sub_hm.nil?
        [sub_hm, criteria.merge(bt_criteria)]
      end

    private

      def defined_uniques(uniques, cols = [], col_list = nil, starred = [])
        col_list ||= cols.join('|')
        @defined_uniques ||= {}
        unless (defined_uniq = @defined_uniques[col_list])
          utilised = {} # Track columns that have been referenced thusfar
          defined_uniq = uniques.each_with_object({}) do |unique, s|
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
          (starred - utilised.keys).each { |star| defined_uniq[[star]] = [cols.index(star)] }
          @defined_uniques[col_list] = defined_uniq
        end
        defined_uniq
      end
    end # module ClassMethods

    # The snake-cased column alias names used in the query to export data
    def self._template_columns(klass, import_template = nil)
      template_detail_columns = klass.instance_variable_get(:@template_detail_columns)
      if (template_import_columns = klass.instance_variable_get(:@template_import_columns)) != import_template
        klass.instance_variable_set(:@template_import_columns, template_import_columns = import_template)
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
    def self._recurse_def(klass, array, import_template, assocs = [], joins = [], pre_prefix = '', prefix = '')
      # Confirm we can actually navigate through this association
      prefix_assoc = (assocs.last&.klass || klass).reflect_on_association(prefix) if prefix.present?
      assocs = assocs.dup << prefix_assoc unless prefix_assoc.nil?
      prefixes = ::DutyFree::Util._prefix_join([pre_prefix, prefix])
      array = array.inject([]) do |s, col|
        s + if col.is_a?(Hash)
              col.inject([]) do |s2, v|
                joins << { v.first.to_sym => (joins_array = []) }
                s2 += _recurse_def(klass, (v.last.is_a?(Array) ? v.last : [v.last]), import_template, assocs, joins_array, prefixes, v.first.to_sym).first
              end
            elsif col.nil?
              if assocs.empty?
                []
              else
                # Bring in from another class
                joins << { prefix => (joins_array = []) }
                # %%% Also bring in uniques and requireds
                _recurse_def(klass, assocs.last.klass::IMPORT_TEMPLATE[:all], import_template, assocs, joins_array, prefixes).first
              end
            else
              [::DutyFree::Column.new(col, pre_prefix, prefix, assocs, klass, import_template[:as])]
            end
      end
      [array, joins]
    end
  end # module Extensions

  class NoUniqueColumnError < ActiveRecord::RecordNotUnique
  end

  class LessThanHalfAreMatchingColumnsError < ActiveRecord::RecordInvalid
  end
end
