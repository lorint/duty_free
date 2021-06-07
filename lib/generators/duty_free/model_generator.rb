# frozen_string_literal: true

require 'rails/generators'
require 'rails/generators/active_record'
require 'fancy_gets'

module DutyFree
  # Auto-generates an IMPORT_TEMPLATE entry for a model
  class ModelGenerator < ::Rails::Generators::Base
    include FancyGets
    # include ::Rails::Generators::Migration

    # # source_root File.expand_path('templates', __dir__)
    # class_option(
    #   :with_changes,
    #   type: :boolean,
    #   default: false,
    #   desc: 'Add IMPORT_TEMPLATE to model'
    # )

    desc 'Adds an appropriate IMPORT_TEMPLATE entry into a model of your choosing so that' \
         '  DutyFree can perform exports, and with the Pro version, the same template also' \
         '  does imports.'

    def df_model_template
      # %%% If Apartment is active, ask which schema they want

      # Load all models
      Rails.configuration.eager_load_namespaces.select { |ns| ns < Rails::Application }.each(&:eager_load!)

      # Generate a list of viable models that can be chosen
      longest_length = 0
      model_info = Hash.new { |h, k| h[k] = {} }
      tableless = Hash.new { |h, k| h[k] = [] }
      models = ActiveRecord::Base.descendants.reject do |m|
        trouble = if m.abstract_class?
                    true
                  elsif !m.table_exists?
                    tableless[m.table_name] << m.name
                    ' (No Table)'
                  else
                    this_f_keys = (model_info[m][:f_keys] = m.reflect_on_all_associations.select { |a| a.macro == :belongs_to }) || []
                    column_names = (model_info[m][:column_names] = m.columns.map(&:name) - [m.primary_key, 'created_at', 'updated_at', 'deleted_at'] - this_f_keys.map(&:foreign_key))
                    if column_names.empty? && this_f_keys && !this_f_keys.empty?
                      fk_message = ", although #{this_f_keys.length} foreign keys"
                      " (No columns#{fk_message})"
                    end
                  end
        # puts "#{m.name}#{trouble}" if trouble&.is_a?(String)
        trouble
      end
      models.sort! do |a, b| # Sort first to separate namespaced stuff from the rest, then alphabetically
        is_a_namespaced = a.name.include?('::')
        is_b_namespaced = b.name.include?('::')
        if is_a_namespaced && !is_b_namespaced
          1
        elsif !is_a_namespaced && is_b_namespaced
          -1
        else
          a.name <=> b.name
        end
      end
      models.each do |m| # Find longest name in the list for future use to show lists on the right side of the screen
        # Strangely this can't be inlined since it assigns to "len"
        if longest_length < (len = m.name.length)
          longest_length = len
        end
      end

      model_name = ARGV[0]&.camelize
      unless (starting = models.find { |m| m.name == model_name })
        puts "#{"Couldn't find #{model_name}.  " if model_name}Pick a model to start from:"
        starting = gets_list(
          list: models,
          on_select: proc do |item|
            selected = item[:selected] || item[:focused]
            this_model_info = model_info[selected]
            selected.name + " (#{(this_model_info[:column_names] + this_model_info[:f_keys].map(&:name).map(&:upcase)).join(', ')})"
          end
        )
      end
      print "\nThinking..."

      # %%% Find out how many hops at most we can go from this model
      max_hm_nav = starting.suggest_template(-1, true, false)
      max_bt_nav = starting.suggest_template(-1, false, false)
      hops_with_hm, num_hm_hops_tables = calc_num_hops([[starting, max_hm_nav[:all]]], models)
      hops, num_hops_tables = calc_num_hops([[starting, max_bt_nav[:all]]], models)
      print "\b" * 11
      unless hops_with_hm.length == hops.length
        starting_name = starting.name
        unless (is_hm = ARGV[1]&.downcase)
          puts "Navigate from #{starting_name} using:\n#{'=' * (21 + starting_name.length)}"
          is_hm = gets_list(
            ["Only belongs_to (max of #{hops.length} hops and #{num_hops_tables} tables)",
             "has_many as well as belongs_to (max of #{hops_with_hm.length} hops and #{num_hm_hops_tables} tables)"]
          )
        end
        is_hm = is_hm.start_with?('has_many') || is_hm[0] == 'y'
        hops = hops_with_hm if is_hm
      end

      unless (num_hops = ARGV[2]&.to_i)
        puts "\nNow, how many hops total would you like to navigate?"
        index = 0
        cumulative = 0
        hops_list = ['0'] + hops.map { |h| "#{index += 1} (#{cumulative += h.length} linkages)" }
        num_hops = gets_list(
          list: hops_list,
          on_select: proc do |value|
                       associations = Hash.new { |h, k| h[k] = 0 }
                       index = (value[:selected] || value[:focused]).split(' ').first.to_i - 1
                       layer = hops[index] if index >= 0
                       layer ||= []
                       layer.each { |i| associations[i.last] += 1 }
                       associations.each { |k, v| associations.delete(k) if v == 1 }
                       layer.map do |l|
                         associations.keys.include?(l.last) ? "#{l.first.name.demodulize} #{l.last}" : l.last
                       end.join(', ')
                       # y = model_info[data[:focused].name]
                       # data[:focused].name + " (#{(y[:column_names] + y[:f_keys].map(&:name).map(&:upcase)).join(', ')})"
                       # layer.inspect
                     end
        ).split(' ').first.to_i
      end

      print "Navigating from #{starting_name}" if model_name
      puts "\nOkay, #{num_hops} hops#{', including has_many,' if is_hm} it is!"
      # Grab the console output from this:
      original_stdout = $stdout
      $stdout = StringIO.new
      starting.suggest_template(num_hops, is_hm)
      output = $stdout
      $stdout = original_stdout
      filename = nil
      output.rewind
      lines = output.each_line.each_with_object([]) do |line, s|
        if line == "\n"
          # Do nothing
        elsif filename
          s << line
        elsif line.start_with?('# Place the following into ')
          filename = line[27..-1]&.split(':')&.first
        end
        s
      end

      model_file = File.open(filename, 'r+')
      insert_at = nil
      starting_name = starting.name.demodulize
      loop do
        break if model_file.eof?

        line_parts = model_file.readline.strip.gsub(/ +/, ' ').split(' ')
        if line_parts.first == 'class' && line_parts[1] && (line_parts[1] == starting_name || line_parts[1].end_with?("::#{starting_name}"))
          insert_at = model_file.pos
          break
        end
      end
      line = nil
      import_template_blocks = []
      import_template_block = nil
      indentation = nil
      # See if there's already any IMPORT_TEMPLATE entries in the model file.
      # If there already is just one, we will comment it out if needs be before adding a fresh one.
      loop do
        break if model_file.eof?

        line_parts = (line = model_file.readline).strip.split(/[\s=]+/)
        indentation ||= line[0...(/\S/ =~ line)]
        case line_parts[-2..-1]
        when ['IMPORT_TEMPLATE', '{']
          import_template_blocks << import_template_block if import_template_block
          import_template_block = [model_file.pos - line.length, nil, line.strip[0] == '#', []]
        when ['#', '------------------------------------------']
          import_template_block[1] = model_file.pos if import_template_block # && import_template_block[1].nil?
        end
        next unless import_template_block

        # Collect all the lines of any existing block
        import_template_block[3] << line
        # Cap this one if it's done
        if import_template_block[1]
          import_template_blocks << import_template_block
          import_template_block = nil
        end
      end
      import_template_blocks << import_template_block if import_template_block
      comments = nil
      is_add_cr = nil
      if import_template_blocks.length > 1
        # %%% maybe in the future:  remove any older commented ones
        puts 'Found multiple existing import template blocks.  Will not attempt to automatically add yet another.'
        insert_at = nil
      elsif import_template_blocks.length == 1
        # Get set up to add the new block after the existing one
        insert_at = (import_template_block = import_template_blocks.first)[1]
        if insert_at.nil?
          puts "Found what looked like the start of an existing IMPORT_TEMPLATE block, but couldn't determine where it ends.  Will not attempt to automatically add anything."
        elsif import_template_block[2] # Already commented
          is_add_cr = true
        else # Needs to be commented
          # Find what kind and how much indentation is present from the first commented line
          indentation = import_template_block[3].first[0...(/\S/ =~ import_template_block[3].first)]
          comments = import_template_block[3].map { |l| "#{l[0...indentation.length]}# #{l[indentation.length..-1]}" }
        end
        # else # Must be no IMPORT_TEMPLATE block yet
        #   insert_at = model_file.pos
      end
      if insert_at.nil?
        puts "Please edit #{filename} manually and add this code:\n\n#{lines.join}"
      else
        is_good = ARGV[3]&.downcase&.start_with?('y')
        args = [starting_name,
                is_hm ? 'has_many' : 'no',
                num_hops]
        args << 'yes' if is_good
        args = args.each_with_object(+'') do |v, s|
          s << " #{v}"
          s
        end
        lines.unshift("# Added #{DateTime.now.strftime('%b %d, %Y %I:%M%P')} by running `bin/rails g duty_free:model#{args}`\n")
        # add a new one afterwards
        print is_good ? 'Will' : 'OK to'
        print "#{" comment #{comments.length} existing lines and" if comments} add #{lines.length} new lines to #{filename}"
        puts is_good ? '.' : '?'
        if is_good || gets_list(%w[Yes No]) == 'Yes'
          # Store rest of file
          model_file.pos = insert_at
          rest_of_file = model_file.read
          if comments
            model_file.pos = import_template_block[0]
            model_file.write("#{comments.join}\n")
            puts "Commented #{comments.length} existing lines"
          else
            model_file.pos = insert_at
          end
          model_file.write("\n") if is_add_cr
          model_file.write(lines.map { |l| "#{indentation}#{l}" }.join)
          model_file.write(rest_of_file)
        end
      end
      model_file.close
    end

  private

    # def calc_num_hops(all, num = 0)
    #   max_num = num
    #   all.each do |item|
    #     if item.is_a?(Hash)
    #       item.each do |k, v|
    #         # puts "#{k} - #{num}"
    #         this_num = calc_num_hops(item[k], num + 1)
    #         max_num = this_num if this_num > max_num
    #       end
    #     end
    #   end
    #   max_num
    # end

    # Breadth first approach
    def calc_num_hops(this_layer, models = nil)
      seen_it = {}
      layers = []
      loop do
        this_keys = []
        next_layer = []
        this_layer.each do |grouping|
          klass = grouping.first
          # binding.pry #unless klass.is_a?(Class)
          grouping.last.each do |item|
            next unless item.is_a?(Hash) && !seen_it.include?([klass, (k, v = item.first).first])

            seen_it[[klass, k]] = nil
            this_keys << [klass, k]
            this_klass = klass.reflect_on_association(k)&.klass
            if this_klass.nil? # Perhaps it's polymorphic
              polymorphics = klass.reflect_on_all_associations.each_with_object([]) do |r, s|
                prefix = "#{r.name}_"
                if r.polymorphic? && k.to_s.start_with?(prefix)
                  suffix = k.to_s[prefix.length..-1]
                  possible_klass = models.find { |m| m.name.underscore == suffix }
                  s << [suffix, possible_klass] if possible_klass
                end
                s
              end
              # binding.pry if polymorphics.length != 1
              this_klass = polymorphics.first&.last
            end
            next_layer << [this_klass, v.select { |ip| ip.is_a?(Hash) }] if this_klass
          end
        end
        layers << this_keys unless this_keys.empty?
        break if next_layer.empty?

        this_layer = next_layer
      end
      # puts "#{k} - #{num}"
      [layers, seen_it.keys.map(&:first).uniq.length]
    end

    # # MySQL 5.6 utf8mb4 limit is 191 chars for keys used in indexes.
    # def item_type_options
    #   opt = { null: false }
    #   opt[:limit] = 191 if mysql?
    #   ", #{opt}"
    # end

    # def migration_version
    #   return unless (major = ActiveRecord::VERSION::MAJOR) >= 5

    #   "[#{major}.#{ActiveRecord::VERSION::MINOR}]"
    # end

    # # Class names of MySQL adapters.
    # # - `MysqlAdapter` - Used by gems: `mysql`, `activerecord-jdbcmysql-adapter`.
    # # - `Mysql2Adapter` - Used by `mysql2` gem.
    # def mysql?
    #   [
    #     'ActiveRecord::ConnectionAdapters::MysqlAdapter',
    #     'ActiveRecord::ConnectionAdapters::Mysql2Adapter'
    #   ].freeze.include?(ActiveRecord::Base.connection.class.name)
    # end

    # # Even modern versions of MySQL still use `latin1` as the default character
    # # encoding. Many users are not aware of this, and run into trouble when they
    # # try to use DutyFree in apps that otherwise tend to use UTF-8. Postgres, by
    # # comparison, uses UTF-8 except in the unusual case where the OS is configured
    # # with a custom locale.
    # #
    # # - https://dev.mysql.com/doc/refman/5.7/en/charset-applications.html
    # # - http://www.postgresql.org/docs/9.4/static/multibyte.html
    # #
    # # Furthermore, MySQL's original implementation of UTF-8 was flawed, and had
    # # to be fixed later by introducing a new charset, `utf8mb4`.
    # #
    # # - https://mathiasbynens.be/notes/mysql-utf8mb4
    # # - https://dev.mysql.com/doc/refman/5.5/en/charset-unicode-utf8mb4.html
    # #
    # def versions_table_options
    #   if mysql?
    #     ', { options: "ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci" }'
    #   else
    #     ''
    #   end
    # end
  end
end
