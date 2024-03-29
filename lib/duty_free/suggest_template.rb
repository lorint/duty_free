# frozen_string_literal: true

# :nodoc:
module DutyFree
  module SuggestTemplate
    module ClassMethods
      # Helpful suggestions to get started creating a template
      # Pass in -1 for hops if you want to traverse all possible links
      def suggest_template(hops = 0, do_has_many = false, show_output = true, this_klass = self)
        ::DutyFree.instance_variable_set(:@errored_columns, [])
        uniques, _required = ::DutyFree::SuggestTemplate._suggest_unique_column(this_klass, nil, '')
        template, required = ::DutyFree::SuggestTemplate._suggest_template(hops, do_has_many, this_klass)
        template = {
          uniques: uniques,
          required: required.map(&:to_sym),
          all: template,
          as: {}
        }

        if show_output
          path = this_klass.name.split('::').map(&:underscore).join('/')
          puts "\n# Place the following into app/models/#{path}.rb:"
          arguments = method(__method__).parameters[0..2].map { |_, name| binding.local_variable_get(name).to_s }
          puts "# Generated by:  #{this_klass.name}.suggest_template(#{arguments.join(', ')})"
          ::DutyFree::SuggestTemplate._template_pretty_print(template)
          puts '# ------------------------------------------'
          puts
        end
        template
      end
    end

    def self._suggest_template(hops, do_has_many, this_klass)
      poison_links = []
      requireds = []
      errored_assocs = []
      buggy_bts = []
      is_papertrail = Object.const_defined?('::PaperTrail::Version')
      # Get a list of all polymorphic models by searching out every has_many that has an :as option
      all_polymorphics = Hash.new { |h, k| h[k] = [] }
      _all_models.each do |model|
        model.reflect_on_all_associations.select do |assoc|
          # If the model name can not be found then we get something like this here:
          # 1: from /home/lorin/.rvm/gems/ruby-2.6.5/gems/activerecord-5.2.4.6/lib/active_record/reflection.rb:418:in `compute_class'
          # /home/lorin/.rvm/gems/ruby-2.6.5/gems/activerecord-5.2.4.6/lib/active_record/inheritance.rb:196:in `compute_type': uninitialized constant Site::SiteTeams (NameError)
          ret = nil
          begin
            ret = assoc.polymorphic? ||
                  (assoc.options.include?(:as) && !(is_papertrail && assoc.klass&.<=(PaperTrail::Version)))
          rescue NameError
            false
          end
          ret
        end.each do |assoc|
          poly_hm = if assoc.belongs_to?
                      poly_key = [model, assoc.name.to_sym] if assoc.polymorphic?
                      nil
                    else
                      poly_key = [assoc.klass, assoc.options[:as]]
                      [model, assoc.macro, assoc.name.to_sym]
                    end
          next if all_polymorphics.include?(poly_key) && all_polymorphics[poly_key].include?(poly_hm)

          poly_hms = all_polymorphics[poly_key]
          poly_hms << poly_hm if poly_hm
        end
      end

      bad_polymorphic_hms = []
      # "path" starts with ''
      # "template" starts with [], and we hold on to the root piece here so we can return it after
      # going through all the layers, at which point it will have grown to include the entire hierarchy.
      this_layer = [[do_has_many, this_klass, '', (whole_template = [])]]
      loop do
        next_layer = []
        this_layer.each do |klass_item|
          do_has_many, this_klass, path, template = klass_item
          this_primary_key = Array(this_klass.primary_key)
          # Find all associations, and track all belongs_tos
          this_belongs_tos = []
          assocs = {}
          this_klass.reflect_on_all_associations.each do |assoc|
            # PolymorphicReflection AggregateReflection RuntimeReflection
            is_belongs_to = assoc.belongs_to?
            # Figure out if it's belongs_to, has_many, or has_one
            belongs_to_or_has_many =
              if is_belongs_to
                'belongs_to'
              elsif (is_habtm = assoc.macro == :has_and_belongs_to_many)
                'has_and_belongs_to_many'
              elsif assoc.macro == :has_many
                'has_many'
              else
                'has_one'
              end
            # Always process belongs_to, and also process has_one and has_many if do_has_many is chosen.
            # Skip any HMT or HABTM. (Maybe break out HABTM into a combo HM and BT in the future.)
            if is_habtm
              puts "* #{this_klass.name} model - problem with:  \"has_and_belongs_to_many :#{assoc.name}\"  because join table \"#{assoc.join_table}\" does not exist.  You can create it with a create_join_table migration." unless ActiveRecord::Base.connection.table_exists?(assoc.join_table)
              # %%% Search for other associative candidates to use instead of this HABTM contraption
              puts "* #{this_klass.name} model - problem with:  \"has_and_belongs_to_many :#{assoc.name}\"  because it includes \"through: #{assoc.options[:through].inspect}\" which is pointless and should be removed." if assoc.options.include?(:through)
            end
            if (is_through = assoc.is_a?(ActiveRecord::Reflection::ThroughReflection)) && assoc.options.include?(:as)
              puts "* #{this_klass.name} model - problem with:  \"has_many :#{assoc.name} through: #{assoc.options[:through].inspect}\"  because it also includes \"as: #{assoc.options[:as].inspect}\", " \
                   "so please choose either for this line to be a \"has_many :#{assoc.name} through:\" or to be a polymorphic \"has_many :#{assoc.name} as:\".  It can't be both."
            end
            next if is_through || is_habtm || (!is_belongs_to && !do_has_many) || errored_assocs.include?(assoc)

            # Polymorphic belongs_to?
            # (checking all_polymorphics in order to handle the rare case when the belongs_to side of a polymorphic association is missing  "polymorphic: true")
            if is_belongs_to && (
                                  assoc.options[:polymorphic] ||
                                  (
                                    all_polymorphics.include?(poly_key = [assoc.active_record, assoc.name.to_sym]) &&
                                    all_polymorphics[poly_key].map { |p| p&.first }.include?(this_klass)
                                  )
                                )
              # Find all current possible polymorphic relations
              _all_models.each do |model|
                # Skip auto-generated HABTM_DestinationModel models
                next if model.respond_to?(:table_name_resolver) &&
                        model.name.start_with?('HABTM_') &&
                        model.table_name_resolver.is_a?(
                          ActiveRecord::Associations::Builder::HasAndBelongsToMany::JoinTableResolver::KnownClass
                        )

                # Find applicable polymorphic has_many associations from each real model
                model.reflect_on_all_associations.each do |poly_assoc|
                  next unless [:has_many, :has_one].include?(poly_assoc.macro) && poly_assoc.inverse_of == assoc

                  this_belongs_tos += (fkeys = [poly_assoc.type, poly_assoc.foreign_key])
                  assocs["#{assoc.name}_#{poly_assoc.active_record.name.underscore}".to_sym] = [[fkeys, assoc.active_record], poly_assoc.active_record]
                end
              end
            else
              # Is it a polymorphic has_many, which is defined using as: :somethingable ?
              is_polymorphic_hm = assoc.inverse_of&.options&.fetch(:polymorphic) { nil }
              begin
                # Standard has_one, or has_many, and belongs_to uses assoc.klass.
                # Also polymorphic belongs_to uses assoc.klass.
                assoc_klass = is_polymorphic_hm ? assoc.inverse_of.active_record : assoc.klass
              rescue NameError # For models which cannot be found by name
              end
              # Skip any PaperTrail audited things
              # rubocop:disable Lint/SafeNavigationConsistency
              next if (Object.const_defined?('PaperTrail::Version') && assoc_klass&.<=(PaperTrail::Version) && assoc.options.include?(:as)) ||
                      # And any goofy self-referencing aliases
                      (!is_belongs_to && assoc_klass <= assoc.active_record && assoc.foreign_key.to_s == assoc.active_record.primary_key)

              # rubocop:enable Lint/SafeNavigationConsistency

              # Avoid getting goofed up by the belongs_to side of a broken polymorphic association
              assoc_klass = nil if assoc.belongs_to? && !(assoc_klass <= ActiveRecord::Base)

              if !is_polymorphic_hm && assoc.options.include?(:as)
                assoc_klass = assoc.inverse_of.active_record
                is_polymorphic_hm = true
                bad_polymorphic_hm = [assoc_klass, assoc.inverse_of]
                unless bad_polymorphic_hms.include?(bad_polymorphic_hm)
                  bad_polymorphic_hms << bad_polymorphic_hm
                  puts "* #{assoc_klass.name} model - problem with the polymorphic association  \"belongs_to :#{assoc.inverse_of.name}\".  You can fix this in one of two ways:"
                  puts '  (1) add "polymorphic: true" on this belongs_to line, or'
                  poly_hms = all_polymorphics.inject([]) do |s, poly_hm|
                    if (key = poly_hm.first).first <= assoc_klass && key.last == assoc.inverse_of.name
                      s += poly_hm.last
                    end
                    s
                  end
                  puts "  (2) Undo #{assoc_klass.name} polymorphism by removing  \"as: :#{assoc.inverse_of.name}\"  in these #{poly_hms.length} places:"
                  poly_hms.each { |poly_hm| puts "      In the #{poly_hm.first.name} class from the line:  #{poly_hm[1]} :#{poly_hm.last}" }
                end
              end

              new_assoc =
                if assoc_klass.nil?
                  # In case this is a buggy polymorphic belongs_to, keep track of all of these and at the very end
                  # only show the pertinent ones.
                  if is_belongs_to
                    buggy_bts << [this_klass, assoc]
                  else
                    puts "* #{this_klass.name} model - problem with:  \"#{belongs_to_or_has_many} :#{assoc.name}\"  because there is no \"#{assoc.class_name}\" model."
                  end
                  nil # Cause this one to be excluded
                elsif is_belongs_to
                  this_belongs_tos << (foreign_key = assoc.foreign_key.to_s)
                  [[[foreign_key], assoc.active_record], assoc_klass]
                elsif _all_tables.include?(assoc_klass.table_name) || # has_many or has_one
                      (assoc_klass.table_name.start_with?('public.') && _all_tables.include?(assoc_klass.table_name[7..-1]))
                  inverse_foreign_keys = is_polymorphic_hm ? [assoc.type, assoc.foreign_key] : [assoc.inverse_of&.foreign_key&.to_s]
                  missing_key_columns = inverse_foreign_keys - assoc_klass.columns.map(&:name)
                  if missing_key_columns.empty?
                    puts "* Missing inverse foreign key for #{this_klass.name} #{belongs_to_or_has_many} :#{assoc.name}" if inverse_foreign_keys.first.nil?
                    # puts "Has columns #{inverse_foreign_keys.inspect}"
                    [[inverse_foreign_keys, assoc_klass], assoc_klass]
                  else
                    if inverse_foreign_keys.length > 1
                      puts "* #{assoc_klass.name} model - missing #{missing_key_columns.join(' and ')} columns to allow it to support polymorphic inheritance."
                    else
                      puts "* #{this_klass.name} model - problem with:  \"#{belongs_to_or_has_many} :#{assoc.name}\"."

                      # Most general related parent class in case we're STI
                      root_class = test_class = this_klass
                      while (test_class = test_class.superclass) != ActiveRecord::Base
                        root_class = test_class unless test_class.abstract_class?
                      end
                      # If we haven't yet found a match, search for any appropriate unused foreign key that belongs_to the primary class
                      is_mentioned_consider = false
                      if (inverses = _find_assocs(:belongs_to, assoc_klass, root_class, errored_assocs, assoc.foreign_key)).empty?
                        if inverse_foreign_keys.first.nil?
                          # So we can rule them out, find the belongs_tos that already are inverses of any other relevant has_many
                          hm_assocs = _find_assocs(:has_many, this_klass, assoc_klass, errored_assocs)
                          hm_inverses = hm_assocs.each_with_object([]) do |hm, s|
                            s << hm.inverse_of if hm.inverse_of
                            s
                          end
                          # Remaining belongs_tos are also good candidates to become an inverse_of, so we'll suggest
                          # both to establish a :foreign_key and also duing the inverses.present? check an :inverse_of.
                          inverses = _find_assocs(:belongs_to, assoc_klass, root_class, errored_assocs).reject do |bt|
                            hm_inverses.include?(bt)
                          end
                          fks = inverses.map(&:foreign_key)
                          # All that and still no matches?
                          unless fks.present? || assoc_klass.columns.map(&:name).include?(suggested_fk = "#{root_class.name.underscore}_id")
                            # Find any polymorphic association on this model (that we're not already tied to) that could be used.
                            poly_hms = all_polymorphics.each_with_object([]) do |p, s|
                              if p.first.first == assoc_klass &&
                                 p.last.none? { |poly_hm| this_klass <= poly_hm.first } # <= to deal with polymorphic inheritance
                                s << p.first
                              end
                              s
                            end

                            # Consider all the HMT with through: :contacts, find their source(s)
                            poly_hmts = this_klass.reflect_on_all_associations.each_with_object([]) do |a, s|
                              if [:has_many, :has_one].include?(a.macro) && a.options[:source] &&
                                 a.options[:through] == assoc.name
                                s << a.options[:source]
                              end
                              s
                            end
                            poly_hms_hmts = poly_hms.select { |poly_hm| poly_hmts.include?(poly_hm.last) }
                            poly_hms = poly_hms_hmts unless poly_hms_hmts.blank?

                            poly_hms.map! { |poly_hm| "\"as: :#{poly_hm.last}\"" }
                            if poly_hms.blank?
                              puts "    Consider removing this #{belongs_to_or_has_many} because the #{assoc_klass.name} model does not include a column named \"#{suggested_fk}\"."
                            else
                              puts "    Consider adding #{poly_hms.join(' or ')} to establish a valid polymorphic association."
                            end
                            is_mentioned_consider = true
                          end
                          unless fks.empty? || fks.include?(assoc.foreign_key.to_s)
                            puts "    Consider adding #{fks.map { |fk| "\"foreign_key: :#{fk}\"" }.join(' or ')} (or some other appropriate column from #{assoc_klass.name}) to this #{belongs_to_or_has_many} entry."
                            is_mentioned_consider = true
                          end
                        else
                          puts "    (Cannot find foreign key \"#{inverse_foreign_keys.first.inspect}\" in #{assoc_klass.name}.)"
                        end
                      end
                      if inverses.empty?
                        opposite_macro = assoc.belongs_to? ? 'has_many or has_one' : 'belongs_to'
                        puts "    (Could not identify any inverse #{opposite_macro} association in the #{assoc_klass.name} model.)"
                      else
                        print is_mentioned_consider ? '    Also consider ' : '    Consider '
                        puts "adding \"#{inverses.map { |x| "inverse_of: :#{x.name}" }.join(' or ')}\" to this entry."
                      end
                    end
                    nil
                  end
                else
                  puts "* Missing table #{assoc_klass.table_name} for class #{assoc_klass.name}"
                  puts '    (Maybe try running:  bin/rails db:migrate )'
                  nil # Related has_* is missing its table
                end
              if new_assoc.nil?
                errored_assocs << assoc
              else
                assocs[assoc.name] = new_assoc
              end
            end
          end

          # Include all columns except for the primary key, any foreign keys, and excluded_columns
          # %%% add EXCLUDED_ALL_COLUMNS || ...
          excluded_columns = %w[created_at updated_at deleted_at]
          (this_klass.columns.map(&:name) - this_primary_key - this_belongs_tos - excluded_columns).each do |column|
            template << column.to_sym
          end
          # Okay, at this point it really searches for the uniques, and in the "strict" (not loose) kind of way
          requireds += _find_requireds(this_klass, false, [this_klass.primary_key]).first.map { |r| "#{path}#{r}".to_sym }
          # Now add the foreign keys and any has_manys in the form of references to associated models
          assocs.each do |k, assoc|
            # # assoc.first describes this foreign key and class, and is used for a "reverse poison"
            # # detection so we don't fold back on ourselves
            next if poison_links.include?(assoc.first)

            is_has_many = (assoc.first.last == assoc.last)
            if hops.zero?
              # For has_one or has_many, exclude with priority the foreign key column(s) we rode in here on
              priority_excluded_columns = assoc.first.first if is_has_many
              # puts "Excluded: #{priority_excluded_columns.inspect}"
              unique, new_requireds = _suggest_unique_column(assoc.last, priority_excluded_columns, "#{path}#{k}_")
              template << { k => unique }
              requireds += new_requireds
            else
              new_poison_links =
                if is_has_many
                  # binding.pry if assoc.first.last.nil?
                  # has_many is simple, just exclude how we got here from the foreign table
                  [assoc.first]
                else
                  # belongs_to is more involved since there may be multiple foreign keys which point
                  # from the foreign table to this primary one, so exclude all these links.
                  _find_assocs(:belongs_to, assoc.first.last, assoc.last, errored_assocs).map do |f_assoc|
                    [[f_assoc.foreign_key.to_s], f_assoc.active_record]
                  end
                end
              # puts "New Poison: #{new_poison_links.map{|a| "#{a.first.inspect} - #{a.last.name}"}.join(' / ')}"
              # if (poison_links & new_poison_links).empty?
              #   Store the ones to do the next round
              #   puts "Test against #{assoc.first.inspect}"
              template << { k => (next_template = []) }
              next_layer << [do_has_many, assoc.last, "#{path}#{k}_", next_template]
              poison_links += (new_poison_links - poison_links)
              # end
            end
          end
        end
        break if hops.zero? || next_layer.empty?

        hops -= 1
        this_layer = next_layer
      end
      (buggy_bts - bad_polymorphic_hms).each do |bad_bt|
        puts "* #{bad_bt.first.name} model - problem with:  \"belongs_to :#{bad_bt.last.name}\"  because there is no \"#{bad_bt.last.class_name}\" model."
      end
      [whole_template, requireds]
    end

    # Load all models
    # %%% Note that this works in Rails 5.x, but may not work in Rails 6.0 and later, which uses the Zeitwerk loader by default:
    def self._all_models
      unless ActiveRecord::Base.instance_variable_get(:@eager_loaded_all)
        if ActiveRecord.version < ::Gem::Version.new('4.0')
          Rails.configuration.eager_load_paths
        else
          Rails.configuration.eager_load_namespaces.select { |ns| ns < Rails::Application }.each(&:eager_load!)
        end
        ActiveRecord::Base.instance_variable_set(:@eager_loaded_all, true)
      end
      ActiveRecord::Base.descendants
    end

    # Load all tables
    def self._all_tables
      unless (all_tables = ActiveRecord::Base.instance_variable_get(:@_all_tables))
        sql = if ActiveRecord::Base.connection.class.name.end_with?('::SQLite3Adapter')
                "SELECT DISTINCT name AS table_name FROM sqlite_master WHERE type = 'table'"
              else
                # For everything else, which would be "::PostgreSQLAdapter", "::MysqlAdapter", or "::Mysql2Adapter":
                "SELECT DISTINCT table_name FROM INFORMATION_SCHEMA.TABLES WHERE table_type = 'BASE TABLE'"
              end
        # The MySQL version of execute_sql returns arrays instead of a hash when there's just one column asked for.
        all_tables = ActiveRecord::Base.execute_sql(sql).each_with_object({}) do |row, s|
          s[row.is_a?(Array) ? row.first : row['table_name']] = nil
          s
        end
        ActiveRecord::Base.instance_variable_set(:@_all_tables, all_tables)
      end
      all_tables
    end

    # Find belongs_tos for this model to one more more other klasses
    def self._find_assocs(macro, klass, to_klass, errored_assocs, using_fk = nil)
      case macro
      when :belongs_to
        klass.reflect_on_all_associations.each_with_object([]) do |bt_assoc, s|
          next unless bt_assoc.belongs_to? && !errored_assocs.include?(bt_assoc)

          begin
            s << bt_assoc if !bt_assoc.options[:polymorphic] && bt_assoc.klass <= to_klass &&
                             (using_fk.nil? || bt_assoc.foreign_key == using_fk)
          rescue NameError
            errored_assocs << bt_assoc
            puts "* #{bt_assoc.active_record.name} model -  \"belongs_to :#{bt_assoc.name}\"  could not find a model named #{bt_assoc.class_name}."
          end
          s
        end
      when :has_many # Also :has_one
        klass.reflect_on_all_associations.each_with_object([]) do |hm_assoc, s|
          next if ![:has_many, :has_one].include?(hm_assoc.macro) || errored_assocs.include?(hm_assoc) ||
                  (Object.const_defined?('PaperTrail::Version') && hm_assoc.klass <= PaperTrail::Version && hm_assoc.options.include?(:as)) # Skip any PaperTrail associations

          s << hm_assoc if hm_assoc.klass == to_klass && (using_fk.nil? || hm_assoc.foreign_key == using_fk)
          s
        end
      end
    end

    def self._suggest_unique_column(klass, priority_excluded_columns, path)
      # %%% Try to find out if this klass already has an import template, and if so then
      # bring in its first unique column set as a suggestion
      # ...
      # Not available, so grasping at straws, just search for any available column
      # %%% add EXCLUDED_UNIQUE_COLUMNS || ...
      uniques, requireds = _find_requireds(klass, true, priority_excluded_columns)
      [[uniques.first.to_sym], requireds.map { |r| "#{path}#{r}".to_sym }]
    end

    def self._find_requireds(klass, is_loose = false, priority_excluded_columns = nil)
      errored_columns = ::DutyFree.instance_variable_get(:@errored_columns)
      # %%% In case we need to exclude foreign keys in the future, this will do it:
      # bts = klass.reflect_on_all_associations.each_with_object([]) do |bt_assoc, s|
      #   next unless bt_assoc.belongs_to?

      #   s << bt_assoc.name
      # end
      requireds = klass.validators.select do |v|
        v.is_a?(ActiveRecord::Validations::PresenceValidator) # && (v.attributes & bts).empty?
      end.each_with_object([]) do |v, s|
        v.attributes.each do |a|
          attrib = a.to_s
          klass_col = [klass, attrib]
          next if errored_columns.include?(klass_col)

          if klass.columns.map(&:name).include?(attrib)
            s << attrib
          else
            unless klass.instance_methods.map(&:to_s).include?(attrib)
              puts "* #{klass.name} model -  \"validates_presence_of :#{attrib}\"  should be removed as it does not refer to any existing column or relation."
              errored_columns << klass_col
            end
          end
        end
      end
      klass_columns = klass.columns

      # Take our cues from all attributes having a presence validator
      klass_columns = klass_columns.reject { |col| priority_excluded_columns.include?(col.name) } if priority_excluded_columns
      excluded_columns = %w[created_at updated_at deleted_at]

      # First find any text fields that are required
      uniques = klass_columns.select { |col| requireds.include?(col.name) && [:string, :text].include?(col.type) }
      # If not that then find any text field, even those not required
      uniques = klass_columns.select { |col| [:string, :text].include?(col.type) } if is_loose && uniques.empty?
      # If still not then look for any required non-PK that is also not a foreign key or created_at or updated_at
      if uniques.empty?
        uniques = klass_columns.select do |col|
          requireds.include?(col.name) && col.name != klass.primary_key && !excluded_columns.include?(col.name)
        end
      end
      # If still nothing then the same but not a required, any non-PK that is also not a foreign key or created_at or updated_at
      if is_loose && uniques.empty?
        uniques = klass_columns.select do |col|
          col.name != klass.primary_key && !excluded_columns.include?(col.name)
        end
      end
      uniques.map!(&:name)
      # Finally if nothing else then just accept the PK, if there is one
      uniques = [klass.primary_key] if klass.primary_key && uniques.empty? && (!priority_excluded_columns || priority_excluded_columns.exclude?(klass.primary_key))
      [uniques, requireds]
    end

    # Show a "pretty" version of IMPORT_TEMPLATE, to be placed in a model
    def self._template_pretty_print(template, indent = 0, child_count = 0, is_hash_in_hash = false)
      unless indent.negative?
        if indent.zero?
          print 'IMPORT_TEMPLATE = '
        else
          puts unless is_hash_in_hash
        end
        print "#{' ' * indent unless is_hash_in_hash}{"
        if indent.zero?
          indent = 2
          print "\n#{' ' * indent}"
        else
          print ' ' unless is_hash_in_hash
        end
      end
      is_first = true
      template.each do |k, v|
        # Skip past this when doing a child count
        child_count = _template_pretty_print(v, -10_000) if indent >= 0
        if is_first
          is_first = false
        elsif indent == 2 || (indent >= 0 && child_count > 5)
          print ",\n#{' ' * indent}" # Comma, newline, and indentation
        end
        if indent.negative?
          child_count += 1
        else
          # Fairly good to troubleshoot child_count things with:  "#{k}#{child_count}: "
          print "#{k}: "
        end
        if v.is_a?(Array)
          print '[' unless indent.negative?
          v.each_with_index do |item, idx|
            # This is where most of the commas get printed, so you can do "#{child_count}," to diagnose things
            print ',' if idx.positive? && indent >= 0
            case item
            when Hash
              # puts '^' unless child_count < 5 || indent.negative?
              child_count = _template_pretty_print(item, indent + 2, child_count)
            when Symbol
              if indent.negative?
                child_count += 1
              else
                print ' ' if idx.positive?
                print item.inspect
              end
            end
          end
          print ']' unless indent.negative?
        elsif v.is_a?(Hash) # A hash in a hash
          child_count = _template_pretty_print(v, indent + 2, child_count, true)
        elsif v.nil?
          puts 'nil' unless indent.negative?
        end
      end
      if indent == 2
        puts
        indent = 0
        puts '}.freeze'
      elsif indent >= 0
        print "#{' ' unless child_count.zero?}}"
      end
      child_count
    end
  end
end
