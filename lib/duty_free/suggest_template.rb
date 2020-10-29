# frozen_string_literal: true

# :nodoc:
module DutyFree
  module SuggestTemplate
    module ClassMethods
      # Helpful suggestions to get started creating a template
      # Pass in -1 for hops if you want to traverse all possible links
      def suggest_template(hops = 0, do_has_many = false, show_output = true, this_klass = self)
        ::DutyFree.instance_variable_set(:@errored_assocs, [])
        ::DutyFree.instance_variable_set(:@errored_columns, [])
        uniques, _required = ::DutyFree::SuggestTemplate._suggest_unique_column(this_klass, nil, '')
        template, required = ::DutyFree::SuggestTemplate._suggest_template(hops, do_has_many, this_klass)
        template = {
          uniques: uniques,
          required: required.map(&:to_sym),
          all: template,
          as: {}
        }
        # puts "Errors: #{::DutyFree.instance_variable_get(:@errored_assocs).inspect}"

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

    def self._suggest_template(hops, do_has_many, this_klass, poison_links = [], path = '')
      errored_assocs = ::DutyFree.instance_variable_get(:@errored_assocs)
      this_primary_key = Array(this_klass.primary_key)
      # Find all associations, and track all belongs_tos
      this_belongs_tos = []
      assocs = {}
      this_klass.reflect_on_all_associations.each do |assoc|
        # PolymorphicReflection AggregateReflection RuntimeReflection
        is_belongs_to = assoc.is_a?(ActiveRecord::Reflection::BelongsToReflection)
        # Figure out if it's belongs_to, has_many, or has_one
        belongs_to_or_has_many =
          if is_belongs_to
            'belongs_to'
          elsif (is_habtm = assoc.is_a?(ActiveRecord::Reflection::HasAndBelongsToManyReflection))
            'has_and_belongs_to_many'
          else
            (assoc.is_a?(ActiveRecord::Reflection::HasManyReflection) ? 'has_many' : 'has_one')
          end
        # Always process belongs_to, and also process has_one and has_many if do_has_many is chosen.
        # Skip any HMT or HABTM. (Maybe break out HABTM into a combo HM and BT in the future.)
        if is_habtm
          unless ActiveRecord::Base.connection.table_exists?(assoc.join_table)
            puts "* In the #{this_klass.name} model there's a problem with:  \"has_and_belongs_to_many :#{assoc.name}\"  because join table \"#{assoc.join_table}\" does not exist.  You can create it with a create_join_table migration."
          end
          # %%% Search for other associative candidates to use instead of this HABTM contraption
          if assoc.options.include?(:through)
            puts "* In the #{this_klass.name} model there's a problem with:  \"has_and_belongs_to_many :#{assoc.name}\"  because it includes \"through: #{assoc.options[:through].inspect}\" which is pointless and should be removed."
          end
        end
        if (is_through = assoc.is_a?(ActiveRecord::Reflection::ThroughReflection)) && assoc.options.include?(:as)
          puts "* In the #{this_klass.name} model there's a problem with:  \"has_many :#{assoc.name} through: #{assoc.options[:through].inspect}\"  because it also includes \"as: #{assoc.options[:as].inspect}\", so please choose either for this line to be a \"has_many :#{assoc.name} through:\" or to be a polymorphic \"has_many :#{assoc.name} as:\".  It can't be both."
        end
        next if is_through || is_habtm || (!is_belongs_to && !do_has_many) || errored_assocs.include?(assoc)

        if is_belongs_to && assoc.polymorphic? # Polymorphic belongs_to?
          # Load all models
          # %%% Note that this works in Rails 5.x, but may not work in Rails 6.0 and later, which uses the Zeitwerk loader by default:
          Rails.configuration.eager_load_namespaces.select { |ns| ns < Rails::Application }.each(&:eager_load!)
          # Find all current possible polymorphic relations
          ActiveRecord::Base.descendants.each do |model|
            # Skip auto-generated HABTM_DestinationModel models
            next if model.respond_to?(:table_name_resolver) &&
                    model.name.start_with?('HABTM_') &&
                    model.table_name_resolver.is_a?(
                      ActiveRecord::Associations::Builder::HasAndBelongsToMany::JoinTableResolver::KnownClass
                    )

            # Find applicable polymorphic has_many associations from each real model
            model.reflect_on_all_associations.each do |poly_assoc|
              next unless poly_assoc.is_a?(ActiveRecord::Reflection::HasManyReflection) &&
                          poly_assoc.inverse_of == assoc

              this_belongs_tos += (fkeys = [poly_assoc.type, poly_assoc.foreign_key])
              assocs["#{assoc.name}_#{poly_assoc.active_record.name.underscore}".to_sym] = [[fkeys, assoc.active_record], poly_assoc.active_record]
            end
          end
        else
          # Is it a polymorphic has_many, which is defined using as: :somethingable ?
          is_polymorphic_hm = assoc.inverse_of&.polymorphic?
          begin
            # Standard has_one, or has_many, and belongs_to uses assoc.klass.
            # Also polymorphic belongs_to uses assoc.klass.
            assoc_klass = is_polymorphic_hm ? assoc.inverse_of.active_record : assoc.klass
          rescue NameError # For models which cannot be found by name
          end
          new_assoc =
            if assoc_klass.nil?
              puts "* In the #{this_klass.name} model there's a problem with:  \"#{belongs_to_or_has_many} :#{assoc.name}\"  because there is no \"#{assoc.class_name}\" model."
              nil # Cause this one to be excluded
            elsif is_belongs_to
              this_belongs_tos << (fk = assoc.foreign_key.to_s)
              [[[fk], assoc.active_record], assoc_klass]
            else # has_many or has_one
              inverse_foreign_keys = is_polymorphic_hm ? [assoc.type, assoc.foreign_key] : [assoc.inverse_of&.foreign_key&.to_s]
              puts "* Missing inverse foreign key for #{assoc.inspect}" if inverse_foreign_keys.first.nil?
              missing_key_columns = inverse_foreign_keys - assoc_klass.columns.map(&:name)
              if missing_key_columns.empty?
                # puts "Has columns #{inverse_foreign_keys.inspect}"
                [[inverse_foreign_keys, assoc_klass], assoc_klass]
              else
                if inverse_foreign_keys.length > 1
                  puts "* The #{assoc_klass.name} model is missing #{missing_key_columns.join(' and ')} columns to allow it to support polymorphic inheritance."
                else
                  print "* In the #{this_klass.name} model there's a problem with:  \"#{belongs_to_or_has_many} :#{assoc.name}\"."

                  if (inverses = _find_belongs_tos(assoc_klass, this_klass, errored_assocs)).empty?
                    if inverse_foreign_keys.first.nil?
                      puts "  Consider adding \"foreign_key: :#{this_klass.name.underscore}_id\" regarding some column in #{assoc_klass.name} to this #{belongs_to_or_has_many} entry."
                    else
                      puts "  (Cannot find foreign key \"#{inverse_foreign_keys.first.inspect}\" in #{assoc_klass.name}.)"
                    end
                  else
                    puts "  Consider adding \"#{inverses.map { |x| "inverse_of: :#{x.name}" }.join(' or ')}\" to this entry."
                  end
                end
                nil
              end
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
      template = (this_klass.columns.map(&:name) - this_primary_key - this_belongs_tos - excluded_columns)
      template.map!(&:to_sym)
      requireds = _find_requireds(this_klass).map { |r| "#{path}#{r}".to_sym }
      # Now add the foreign keys and any has_manys in the form of references to associated models
      assocs.each do |k, assoc|
        # assoc.first describes this foreign key and class, and is used for a "reverse poison"
        # detection so we don't fold back on ourselves
        next if poison_links.include?(assoc.first)

        is_has_many = (assoc.first.last == assoc.last)
        # puts "#{k} #{hops}"
        unique, new_requireds =
          if hops.zero?
            # For has_one or has_many, exclude with priority the foreign key column(s) we rode in here on
            priority_excluded_columns = assoc.first.first if is_has_many
            # puts "Excluded: #{priority_excluded_columns.inspect}"
            _suggest_unique_column(assoc.last, priority_excluded_columns, "#{path}#{k}_")
          else
            new_poison_links =
              if is_has_many
                # has_many is simple, just exclude how we got here from the foreign table
                [assoc.first]
              else
                # belongs_to is more involved since there may be multiple foreign keys which point
                # from the foreign table to this primary one, so exclude all these links.
                _find_belongs_tos(assoc.first.last, assoc.last, errored_assocs).map do |f_assoc|
                  [f_assoc.foreign_key.to_s, f_assoc.active_record]
                end
              end
            # puts "New Poison: #{new_poison_links.inspect}"
            _suggest_template(hops - 1, do_has_many, assoc.last, poison_links + new_poison_links, "#{path}#{k}_")
          end
        template << { k => unique }
        requireds += new_requireds
      end
      [template, requireds]
    end

    # Find belongs_tos for this model to one more more other klasses
    def self._find_belongs_tos(klass, to_klass, errored_assocs)
      klass.reflect_on_all_associations.each_with_object([]) do |bt_assoc, s|
        next unless bt_assoc.is_a?(ActiveRecord::Reflection::BelongsToReflection) && !errored_assocs.include?(bt_assoc)

        begin
          s << bt_assoc if !bt_assoc.polymorphic? && bt_assoc.klass == to_klass
        rescue NameError
          errored_assocs << bt_assoc
          puts "* In the #{bt_assoc.active_record.name} model  \"belongs_to :#{bt_assoc.name}\"  could not find a model named #{bt_assoc.class_name}."
        end
      end
    end

    def self._suggest_unique_column(klass, priority_excluded_columns, path)
      # %%% Try to find out if this klass already has an import template, and if so then
      # bring in its first unique column set as a suggestion
      # ...
      # Not available, so grasping at straws, just search for any available column
      # %%% add EXCLUDED_UNIQUE_COLUMNS || ...
      klass_columns = klass.columns

      # Requireds takes its cues from all attributes having a presence validator
      requireds = _find_requireds(klass)
      if priority_excluded_columns
        klass_columns = klass_columns.reject { |col| priority_excluded_columns.include?(col.name) }
      end
      excluded_columns = %w[created_at updated_at deleted_at]
      unique = [(
        # Find the first text field of a required if one exists
        klass_columns.find { |col| requireds.include?(col.name) && col.type == :string }&.name ||
        # Find the first text field, now of a non-required, if one exists
        klass_columns.find { |col| col.type == :string }&.name ||
        # If no string then look for the first non-PK that is also not a foreign key or created_at or updated_at
        klass_columns.find do |col|
          requireds.include?(col.name) && col.name != klass.primary_key && !excluded_columns.include?(col.name)
        end&.name ||
        # And now the same but not a required, the first non-PK that is also not a foreign key or created_at or updated_at
        klass_columns.find do |col|
          col.name != klass.primary_key && !excluded_columns.include?(col.name)
        end&.name ||
        # Finally just accept the PK if nothing else
        klass.primary_key
      ).to_sym]

      [unique, requireds.map { |r| "#{path}#{r}".to_sym }]
    end

    def self._find_requireds(klass)
      errored_columns = ::DutyFree.instance_variable_get(:@errored_columns)
      klass.validators.select do |v|
        v.is_a?(ActiveRecord::Validations::PresenceValidator)
      end.each_with_object([]) do |v, s|
        v.attributes.each do |a|
          attrib = a.to_s
          klass_col = [klass, attrib]
          next if errored_columns.include?(klass_col)

          if klass.columns.map(&:name).include?(attrib)
            s << attrib
          else
            puts "* In the #{klass.name} model  \"validates_presence_of :#{attrib}\"  should be removed as it does not refer to any existing column."
            errored_columns << klass_col
          end
        end
      end
    end

    # Show a "pretty" version of IMPORT_COLUMNS, to be placed in a model
    def self._template_pretty_print(template, indent = 0, child_count = 0, is_hash_in_hash = false)
      unless indent.negative?
        if indent.zero?
          print 'IMPORT_COLUMNS = '
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
            if item.is_a?(Hash)
              # puts '^' unless child_count < 5 || indent.negative?
              child_count = _template_pretty_print(item, indent + 2, child_count)
            elsif item.is_a?(Symbol)
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
        puts '}'
      elsif indent >= 0
        print "#{' ' unless child_count.zero?}}"
      end
      child_count
    end
  end
end
