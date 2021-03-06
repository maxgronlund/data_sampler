require "data_sampler/dependency"

module DataSampler

  class TableSample

    attr_reader :table_name
    attr_reader :pending_dependencies

    def initialize(connection, table_name, size = 1000)
      @table_name = table_name
      @connection = connection
      @size = size
      @pending_dependencies = Set.new
      @sample = Set.new
      @sampled = false
      @sampled_ids = Set.new
    end

    def sample!
      fetch_sample(@size) unless @sampled
      @sample
    end

    def size
      @sampled ? @sample.size : @size
    end

    def fulfil(dependency)
      return 0 if fulfilled?(dependency)
      where = dependency.keys.collect { |col, val| "#{@connection.quote_column_name col} = #{@connection.quote val}" } * ' AND '
      sql = "SELECT * FROM #{@connection.quote_table_name @table_name} WHERE " + where
      row = @connection.select_one(sql)
      raise "Could not find #{dependency}" if row.nil?
      add row
    end

    def fulfilled?(dependency)
      # FIXME: Only checks id column
      if dependency.keys.values.size == 1
        dependency.keys.each_pair do |key, val|
          if key == 'id'
            return true if @sampled_ids.include?(val)
          end
        end
      end
      false
    end

    def add(row)
      return 0 unless @sample.add? row
      @sampled_ids.add row['id'] if row['id']
      newly_added = 0
      dependencies_for(row).each do |dep|
        newly_added += 1 if @pending_dependencies.add?(dep)
      end
      newly_added
    rescue ActiveRecord::StatementInvalid => e
      # Don't choke on unknown table engines, such as Sphinx
    end

    def ensure_referential_integrity(table_samples)
      newly_added = 0
      deps_in_progress = @pending_dependencies
      @pending_dependencies = Set.new
      deps_in_progress.each do |dependency|
        raise "Table sample for `#{dependency.table_name}` not found" unless table_samples[dependency.table_name]
        newly_added += table_samples[dependency.table_name].fulfil(dependency)
      end
      newly_added
    end

    def to_sql
      ret = "-- #{@table_name}: #{@sample.count} rows\n"
      unless @sample.empty?
        quoted_cols = @sample.first.keys.collect { |col| @connection.quote_column_name col }
        # INSERT in batches of 1000
        @sample.each_slice(1000) do |rows|
          values = rows.collect { |row|
            quoted_vals = []
            row.each_pair do |field,val|
              # HACK: Brute attempt at not revealing sensitive data
              val.gsub! /./, '*' if field.downcase == 'password'
              quoted_vals << @connection.quote(val)
            end
            quoted_vals * ','
          } * '),('
          ret << "INSERT INTO #{@connection.quote_table_name @table_name} (#{quoted_cols * ','}) VALUES (#{values});\n"
        end
      end
      ret
    end

    protected

    def fetch_sample(count)
      warn "  Sampling #{count} rows from table `#{@table_name}`"
      sql = "SELECT * FROM #{@connection.quote_table_name @table_name}"
      pk = @connection.primary_key(@table_name)
      sql += " ORDER BY #{@connection.quote_column_name pk} DESC" unless pk.nil?
      sql += " LIMIT #{count}"
      @connection.select_all(sql).each { |row| add(row) }
      @sampled = true
    rescue ActiveRecord::StatementInvalid => e
      # Don't choke on unknown table engines, such as Sphinx
      []
    end

    def samplable?
      # We shouldn't be sampling views
      @connection.views.grep(@table_name).empty?
    end

    def dependency_for(fk, row)
      ref = {}
      cols = Array.wrap(fk.column)
      raise "No column names in foreign key #{fk.inspect}" if cols.empty?
      Array.wrap(fk.primary_key).each do |ref_col|
        col = cols.shift
        ref[ref_col] = row[col] unless row[col].nil?
      end
      Dependency.new(fk.to_table, ref, table_name) unless ref.empty?
    end

    def dependencies_for(row)
      foreign_keys.collect { |fk| dependency_for(fk, row) }.compact
    end

    def foreign_keys
      @fks ||= @connection.foreign_keys(@table_name)
    end

  end
end
