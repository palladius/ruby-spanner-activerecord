# frozen_string_literal: true

require "active_record/connection_adapters/spanner/schema_creation"

module ActiveRecord
  module ConnectionAdapters
    module Spanner
      #
      # # SchemaStatements
      #
      # Collection of methods to handle database schema.
      #
      # [Schema Doc](https://cloud.google.com/spanner/docs/information-schema)
      #
      module SchemaStatements
        def current_database
          @connection.database_id
        end

        # Table

        def data_sources
          information_schema.tables.map(&:name)
        end
        alias tables data_sources

        def table_exists? table_name
          !information_schema.table(table_name).nil?
        end
        alias data_source_exists? table_exists?

        def create_table table_name, **options
          options[:options] ||= {}
          options[:options].merge!(
            parent_table: options[:parent_table],
            on_delete: options[:on_delete]
          )

          td = create_table_definition table_name, options

          if options[:id] != false
            pk = options.fetch :primary_key do
              Base.get_primary_key table_name.to_s.singularize
            end

            if pk.is_a? Array
              td.primary_keys pk
            else
              td.primary_key pk, options.fetch(:id, :primary_key), {}
            end
          end

          yield td if block_given?

          schema_creation.create_table(td).create(drop_table: options[:force])
        end

        def drop_table table_name, _options = {}
          information_schema.table(table_name, view: :indexes)&.drop
        end

        def rename_table _table_name, _new_name
          raise SpannerActiverecord::NotSupportedError, \
                "rename_table is not implemented"
        end

        # Column

        def column_definitions table_name
          information_schema.table_columns table_name
        end

        def new_column_from_field _table_name, field
          ConnectionAdapters::Column.new \
            field.name,
            field.default,
            fetch_type_metadata(field.spanner_type, field.ordinal_position),
            field.nullable
        end

        def fetch_type_metadata sql_type, ordinal_position = nil
          Spanner::TypeMetadata.new \
            super(sql_type), ordinal_position: ordinal_position
        end

        def add_column table_name, column_name, type, **options
          at = create_alter_table table_name
          at.add_column column_name, type, options
          schema_creation.alter_table(at).alter
        end

        def remove_column table_name, column_name
          information_schema.table_column(table_name, column_name)&.drop
        end

        def change_column table_name, column_name, type, options = {}
          column = information_schema.table_column table_name, column_name

          column.type = type_to_sql type if type
          column.limit = options[:limit] if options.key? :limit
          column.nullable = options[:null] if options.key? :null

          if options.key? :allow_commit_timestamp
            column.allow_commit_timestamp = options[:allow_commit_timestamp]
            column.change :options
          else
            # type or limit change
            column.change
          end
        end

        def change_column_null table_name, column_name, null, _default = nil
          change_column table_name, column_name, nil, null: null
        end

        def change_column_default _table_name, _column_name, _default_or_changes
          raise SpannerActiverecord::Error, \
                "change column default not supported"
        end

        def rename_column _table_name, _column_name, _new_column_name
          raise SpannerActiverecord::Error, \
                "rename column default not supported"
        end

        # Index

        def indexes table_name
          information_schema.indexes table_name
        end

        def add_index table_name, column_name, options = {}
          index_name = options[:name].to_s if options.key? :name
          index_name ||= index_name table_name, column_name
          index = SpannerActiverecord::Index.new(
            table_name,
            index_name,
            [],
            unique: options[:unique],
            null_filtered: options[:null_filtered],
            interleve_in: options[:interleve_in],
            storing: options[:storing],
            connection: self
          )

          options[:orders] ||= {}
          Array(column_name).each do |c|
            index.add_column c, order: options[:orders][c.to_sym]
          end

          index.create
        end

        def remove_index table_name, options = {}
          index_name = index_name_for_remove table_name, options
          information_schema.index(table_name, index_name)&.drop
        end

        def rename_index table_name, old_name, new_name
          validate_index_length! table_name, new_name

          old_index = information_schema.index table_name, old_name
          return unless old_index

          old_index.name = new_name
          old_index.create
          remove_index table_name, name: old_name
        end

        # Foreign keys are not supported.
        def foreign_keys _table_name
          []
        end

        def type_to_sql type
          native_type = native_database_types[type.to_sym]
          native_type ? native_type[:name] : type
        end

        def schema_creation
          SchemaCreation.new self
        end
      end
    end
  end
end