#!/usr/bin/env ruby
# frozen_string_literal: true

# Script para migrar cuentas individuales de Chatwoot
# 
# Uso básico:
#   ruby scripts/migrate_account.rb --help
#   ruby scripts/migrate_account.rb list-accounts
#   ruby scripts/migrate_account.rb export --account-id 1 --output /tmp/account_1_backup.sql --compress
#   ruby scripts/migrate_account.rb import --input /tmp/account_1_backup.sql.gz
#   ruby scripts/migrate_account.rb validate --account-id 1
#
# Flujo completo de migración:
#   1. Exportar: ruby scripts/migrate_account.rb export --account-id 1 --compress
#   2. Transferir: scp account_1_*.sql.gz usuario@servidor-destino:/tmp/
#   3. Importar: ruby scripts/migrate_account.rb import --input /tmp/account_1_*.sql.gz

require 'optparse'
require 'json'
require 'yaml'
require 'fileutils'

class ChatwootAccountMigrator
  attr_accessor :source_db_config, :target_db_config, :options

  # Tablas principales relacionadas con la cuenta
  CORE_TABLES = {
    # Tabla principal
    'accounts' => {
      primary_key: 'id',
      where_clause: 'id = ?'
    },
    
    # Usuarios y relaciones
    'account_users' => {
      foreign_key: 'account_id',
      where_clause: 'account_id = ?'
    },
    'users' => {
      custom_query: lambda { |account_id|
        "id IN (SELECT user_id FROM account_users WHERE account_id = #{account_id})"
      }
    },
    
    # Inboxes y canales
    'inboxes' => {
      foreign_key: 'account_id',
      where_clause: 'account_id = ?'
    },
    'channels' => {
      custom_query: lambda { |account_id|
        "id IN (SELECT channel_id FROM inboxes WHERE account_id = #{account_id})"
      }
    },
    
    # Contacts y conversaciones
    'contacts' => {
      foreign_key: 'account_id',
      where_clause: 'account_id = ?'
    },
    'contact_inboxes' => {
      custom_query: lambda { |account_id|
        "contact_id IN (SELECT id FROM contacts WHERE account_id = #{account_id})"
      }
    },
    'conversations' => {
      foreign_key: 'account_id',
      where_clause: 'account_id = ?'
    },
    'messages' => {
      foreign_key: 'account_id',
      where_clause: 'account_id = ?'
    },
    
    # Teams y miembros
    'teams' => {
      foreign_key: 'account_id',
      where_clause: 'account_id = ?'
    },
    'team_members' => {
      custom_query: lambda { |account_id|
        "team_id IN (SELECT id FROM teams WHERE account_id = #{account_id})"
      }
    },
    
    # Configuraciones y settings
    'canned_responses' => {
      foreign_key: 'account_id',
      where_clause: 'account_id = ?'
    },
    'labels' => {
      foreign_key: 'account_id',
      where_clause: 'account_id = ?'
    },
    'webhooks' => {
      foreign_key: 'account_id',
      where_clause: 'account_id = ?'
    },
    'automation_rules' => {
      foreign_key: 'account_id',
      where_clause: 'account_id = ?'
    },
    'macros' => {
      foreign_key: 'account_id',
      where_clause: 'account_id = ?'
    },
    
    # Portales y contenido
    'portals' => {
      foreign_key: 'account_id',
      where_clause: 'account_id = ?'
    },
    'categories' => {
      foreign_key: 'account_id',
      where_clause: 'account_id = ?'
    },
    'articles' => {
      foreign_key: 'account_id',
      where_clause: 'account_id = ?'
    },
    
    # Reportes y eventos
    'reporting_events' => {
      foreign_key: 'account_id',
      where_clause: 'account_id = ?'
    },
    'notifications' => {
      foreign_key: 'account_id',
      where_clause: 'account_id = ?'
    },
    'notification_settings' => {
      foreign_key: 'account_id',
      where_clause: 'account_id = ?'
    },
    
    # Working hours y configuraciones adicionales
    'working_hours' => {
      foreign_key: 'account_id',
      where_clause: 'account_id = ?'
    },
    'custom_attribute_definitions' => {
      foreign_key: 'account_id',
      where_clause: 'account_id = ?'
    },
    'custom_filters' => {
      foreign_key: 'account_id',
      where_clause: 'account_id = ?'
    },
    
    # Attachments y archivos
    'attachments' => {
      custom_query: lambda { |account_id|
        "message_id IN (SELECT id FROM messages WHERE account_id = #{account_id})"
      }
    },
    
    # Bot configurations
    'agent_bots' => {
      foreign_key: 'account_id',
      where_clause: 'account_id = ?'
    },
    'agent_bot_inboxes' => {
      foreign_key: 'account_id',
      where_clause: 'account_id = ?'
    },
    
    # Campaign data
    'campaigns' => {
      foreign_key: 'account_id',
      where_clause: 'account_id = ?'
    }
  }

  # Tablas Enterprise (opcional)
  ENTERPRISE_TABLES = {
    'sla_policies' => {
      foreign_key: 'account_id',
      where_clause: 'account_id = ?'
    },
    'applied_slas' => {
      foreign_key: 'account_id',
      where_clause: 'account_id = ?'
    },
    'sla_events' => {
      foreign_key: 'account_id',
      where_clause: 'account_id = ?'
    },
    'custom_roles' => {
      foreign_key: 'account_id',
      where_clause: 'account_id = ?'
    },
    'captain_assistants' => {
      foreign_key: 'account_id',
      where_clause: 'account_id = ?'
    },
    'captain_documents' => {
      foreign_key: 'account_id',
      where_clause: 'account_id = ?'
    },
    'copilot_threads' => {
      foreign_key: 'account_id',
      where_clause: 'account_id = ?'
    }
  }

  def initialize
    @options = {
      include_enterprise: true,
      backup_files: true,
      compress_output: false,
      exclude_tables: [],
      include_only_tables: [],
      new_account_id: nil,
      dry_run: false,
      verbose: false
    }
    
    load_database_config
  end

  def load_database_config
    database_yml_path = File.join(File.dirname(__FILE__), '..', 'config', 'database.yml')
    
    if File.exist?(database_yml_path)
      db_config = YAML.load_file(database_yml_path)
      environment = ENV['RAILS_ENV'] || 'development'
      @source_db_config = db_config[environment]
    else
      puts "⚠️  Archivo database.yml no encontrado. Usando variables de entorno."
      @source_db_config = {
        'adapter' => 'postgresql',
        'host' => ENV['DATABASE_HOST'] || 'localhost',
        'port' => ENV['DATABASE_PORT'] || 5432,
        'database' => ENV['DATABASE_NAME'] || 'chatwoot_development',
        'username' => ENV['DATABASE_USERNAME'] || 'chatwoot',
        'password' => ENV['DATABASE_PASSWORD'] || ''
      }
    end
    
    @target_db_config = @source_db_config.dup
  end

  def run(args)
    parser = OptionParser.new do |opts|
      opts.banner = "Uso: #{$0} [comando] [opciones]"
      opts.separator ""
      opts.separator "Comandos:"
      opts.separator "  export        Crear backup de una cuenta específica"
      opts.separator "  import        Restaurar cuenta desde un archivo de backup"
      opts.separator "  list-accounts Listar todas las cuentas disponibles"
      opts.separator "  validate      Validar integridad de datos de una cuenta"
      opts.separator ""
      opts.separator "Opciones:"

      opts.on('--account-id ID', Integer, 'ID de la cuenta a migrar') do |id|
        @options[:account_id] = id
      end

      opts.on('--account-name NAME', 'Nombre de la cuenta a migrar') do |name|
        @options[:account_name] = name
      end

      opts.on('--output FILE', 'Archivo de salida para exportación') do |file|
        @options[:output_file] = file
      end

      opts.on('--input FILE', 'Archivo de entrada para importación') do |file|
        @options[:input_file] = file
      end

      opts.on('--new-account-id ID', Integer, 'Nuevo ID para la cuenta importada') do |id|
        @options[:new_account_id] = id
      end

      opts.on('--target-host HOST', 'Host de la base de datos destino') do |host|
        @target_db_config['host'] = host
      end

      opts.on('--target-database DB', 'Nombre de la base de datos destino') do |db|
        @target_db_config['database'] = db
      end

      opts.on('--target-username USER', 'Usuario de la base de datos destino') do |user|
        @target_db_config['username'] = user
      end

      opts.on('--target-password PASS', 'Contraseña de la base de datos destino') do |pass|
        @target_db_config['password'] = pass
      end

      opts.on('--exclude-tables TABLES', Array, 'Tablas a excluir (separadas por comas)') do |tables|
        @options[:exclude_tables] = tables
      end

      opts.on('--include-only-tables TABLES', Array, 'Solo incluir estas tablas (separadas por comas)') do |tables|
        @options[:include_only_tables] = tables
      end

      opts.on('--[no-]enterprise', 'Incluir tablas Enterprise (por defecto: true)') do |enterprise|
        @options[:include_enterprise] = enterprise
      end

      opts.on('--[no-]backup', 'Crear respaldo antes de importar (por defecto: true)') do |backup|
        @options[:backup_files] = backup
      end

      opts.on('--[no-]compress', 'Comprimir archivo de salida') do |compress|
        @options[:compress_output] = compress
      end

      opts.on('--dry-run', 'Simular operación sin ejecutar cambios') do
        @options[:dry_run] = true
      end

      opts.on('-v', '--verbose', 'Salida detallada') do
        @options[:verbose] = true
      end

      opts.on('-h', '--help', 'Mostrar esta ayuda') do
        puts opts
        exit
      end
    end

    parser.parse!(args)

    command = args.shift

    case command
    when 'export'
      export_account
    when 'import'
      import_account
    when 'list-accounts'
      list_accounts
    when 'validate'
      validate_account
    else
      puts parser
      exit 1
    end
  end

  def export_account
    validate_export_options
    
    account_id = resolve_account_id
    output_file = @options[:output_file] || "account_#{account_id}_#{Time.now.strftime('%Y%m%d_%H%M%S')}.sql"
    
    puts "🚀 Iniciando exportación de la cuenta ID: #{account_id}"
    puts "📁 Archivo de salida: #{output_file}"
    
    if @options[:dry_run]
      puts "🔍 [DRY RUN] Simulando exportación..."
      simulate_export(account_id)
      return
    end

    # Verificar que la cuenta existe
    unless account_exists?(account_id)
      puts "❌ Error: La cuenta con ID #{account_id} no existe."
      exit 1
    end

    # Crear el archivo SQL
    create_export_file(account_id, output_file)
    
    # Comprimir si se requiere
    if @options[:compress_output]
      compress_file(output_file)
    end
    
    puts "✅ Exportación completada exitosamente: #{output_file}"
    
    # Mostrar estadísticas
    show_export_stats(account_id)
  end

  def import_account
    validate_import_options
    
    input_file = @options[:input_file]
    
    puts "🚀 Iniciando importación desde: #{input_file}"
    
    unless File.exist?(input_file)
      puts "❌ Error: El archivo #{input_file} no existe."
      exit 1
    end

    if @options[:dry_run]
      puts "🔍 [DRY RUN] Simulando importación..."
      simulate_import(input_file)
      return
    end

    # Crear respaldo si está habilitado
    if @options[:backup_files]
      create_backup
    end

    # Procesar el archivo de importación
    process_import_file(input_file)
    
    puts "✅ Importación completada exitosamente"
  end

  def list_accounts
    puts "📋 Listando todas las cuentas:"
    puts ""
    
    begin
      require 'pg'
      
      conn = PG.connect(
        host: @source_db_config['host'],
        port: @source_db_config['port'],
        dbname: @source_db_config['database'],
        user: @source_db_config['username'],
        password: @source_db_config['password']
      )
      
      result = conn.exec("
        SELECT 
          a.id,
          a.name,
          a.domain,
          a.status,
          a.created_at,
          COUNT(DISTINCT au.user_id) as user_count,
          COUNT(DISTINCT i.id) as inbox_count,
          COUNT(DISTINCT c.id) as conversation_count
        FROM accounts a
        LEFT JOIN account_users au ON a.id = au.account_id
        LEFT JOIN inboxes i ON a.id = i.account_id
        LEFT JOIN conversations c ON a.id = c.account_id
        GROUP BY a.id, a.name, a.domain, a.status, a.created_at
        ORDER BY a.id
      ")
      
      printf "%-4s %-30s %-20s %-10s %-8s %-8s %-8s %-12s\n", 
             "ID", "Nombre", "Dominio", "Estado", "Usuarios", "Inboxes", "Conv.", "Creado"
      puts "-" * 100
      
      result.each do |row|
        printf "%-4s %-30s %-20s %-10s %-8s %-8s %-8s %-12s\n",
               row['id'],
               row['name'][0..29],
               row['domain'] || 'N/A',
               row['status'],
               row['user_count'],
               row['inbox_count'],
               row['conversation_count'],
               Date.parse(row['created_at']).strftime('%Y-%m-%d')
      end
      
      conn.close
      
    rescue PG::Error => e
      puts "❌ Error conectando a la base de datos: #{e.message}"
      exit 1
    end
  end

  def validate_account
    validate_export_options
    
    account_id = resolve_account_id
    
    puts "🔍 Validando integridad de datos para la cuenta ID: #{account_id}"
    
    unless account_exists?(account_id)
      puts "❌ Error: La cuenta con ID #{account_id} no existe."
      exit 1
    end

    validation_results = perform_validation(account_id)
    
    if validation_results[:errors].empty?
      puts "✅ Validación completada. No se encontraron problemas."
    else
      puts "⚠️  Se encontraron #{validation_results[:errors].length} problemas:"
      validation_results[:errors].each { |error| puts "  - #{error}" }
    end
    
    puts ""
    puts "📊 Estadísticas de datos:"
    validation_results[:stats].each { |table, count| puts "  #{table}: #{count} registros" }
  end

  private

  def validate_export_options
    unless @options[:account_id] || @options[:account_name]
      puts "❌ Error: Debe especificar --account-id o --account-name"
      exit 1
    end
  end

  def validate_import_options
    unless @options[:input_file]
      puts "❌ Error: Debe especificar --input con el archivo a importar"
      exit 1
    end
  end

  def resolve_account_id
    if @options[:account_id]
      return @options[:account_id]
    elsif @options[:account_name]
      return find_account_by_name(@options[:account_name])
    else
      puts "❌ Error: No se pudo resolver el ID de la cuenta"
      exit 1
    end
  end

  def find_account_by_name(name)
    begin
      require 'pg'
      
      conn = PG.connect(
        host: @source_db_config['host'],
        port: @source_db_config['port'],
        dbname: @source_db_config['database'],
        user: @source_db_config['username'],
        password: @source_db_config['password']
      )
      
      result = conn.exec_params("SELECT id FROM accounts WHERE name = $1", [name])
      
      if result.ntuples == 0
        puts "❌ Error: No se encontró una cuenta con el nombre '#{name}'"
        exit 1
      elsif result.ntuples > 1
        puts "❌ Error: Se encontraron múltiples cuentas con el nombre '#{name}'"
        exit 1
      end
      
      account_id = result[0]['id'].to_i
      conn.close
      
      account_id
    rescue PG::Error => e
      puts "❌ Error conectando a la base de datos: #{e.message}"
      exit 1
    end
  end

  def account_exists?(account_id)
    begin
      require 'pg'
      
      conn = PG.connect(
        host: @source_db_config['host'],
        port: @source_db_config['port'],
        dbname: @source_db_config['database'],
        user: @source_db_config['username'],
        password: @source_db_config['password']
      )
      
      result = conn.exec_params("SELECT 1 FROM accounts WHERE id = $1", [account_id])
      exists = result.ntuples > 0
      
      conn.close
      exists
    rescue PG::Error => e
      puts "❌ Error verificando la cuenta: #{e.message}"
      false
    end
  end

  def get_tables_to_export
    tables = CORE_TABLES.dup
    
    if @options[:include_enterprise]
      tables.merge!(ENTERPRISE_TABLES)
    end
    
    if @options[:include_only_tables].any?
      tables.select! { |table, _| @options[:include_only_tables].include?(table) }
    end
    
    if @options[:exclude_tables].any?
      tables.reject! { |table, _| @options[:exclude_tables].include?(table) }
    end
    
    tables
  end

  def create_export_file(account_id, output_file)
    begin
      require 'pg'
      
      conn = PG.connect(
        host: @source_db_config['host'],
        port: @source_db_config['port'],
        dbname: @source_db_config['database'],
        user: @source_db_config['username'],
        password: @source_db_config['password']
      )
      
      File.open(output_file, 'w') do |file|
        write_file_header(file, account_id)
        
        tables_to_export = get_tables_to_export
        
        tables_to_export.each do |table_name, config|
          puts "📄 Exportando tabla: #{table_name}" if @options[:verbose]
          export_table_data(conn, file, table_name, config, account_id)
        end
        
        write_file_footer(file)
      end
      
      conn.close
      
    rescue PG::Error => e
      puts "❌ Error durante la exportación: #{e.message}"
      exit 1
    end
  end

  def write_file_header(file, account_id)
    file.puts "-- Exportación de cuenta Chatwoot"
    file.puts "-- Cuenta ID: #{account_id}"
    file.puts "-- Fecha: #{Time.now}"
    file.puts "-- Generado por: #{$0}"
    file.puts ""
    file.puts "SET session_replication_role = replica;"
    file.puts "BEGIN;"
    file.puts ""
  end

  def write_file_footer(file)
    file.puts ""
    file.puts "COMMIT;"
    file.puts "SET session_replication_role = DEFAULT;"
    file.puts "-- Fin de la exportación"
  end

  def export_table_data(conn, file, table_name, config, account_id)
    # Verificar si la tabla existe
    table_exists = conn.exec_params(
      "SELECT 1 FROM information_schema.tables WHERE table_name = $1",
      [table_name]
    ).ntuples > 0
    
    unless table_exists
      puts "⚠️  Tabla #{table_name} no existe, omitiendo..." if @options[:verbose]
      return
    end

    # Construir la consulta
    where_clause = build_where_clause(config, account_id)
    query = "SELECT * FROM #{table_name}"
    query += " WHERE #{where_clause}" if where_clause
    
    result = conn.exec(query)
    
    if result.ntuples > 0
      file.puts "-- Datos para la tabla: #{table_name}"
      file.puts "-- Registros: #{result.ntuples}"
      
      # Obtener los nombres de las columnas
      columns = result.fields
      
      result.each do |row|
        values = columns.map do |col|
          value = row[col]
          if value.nil?
            'NULL'
          elsif value.is_a?(String)
            "'#{value.gsub("'", "''")}'"
          else
            value
          end
        end
        
        # Ajustar IDs si se especifica un nuevo account_id
        if @options[:new_account_id] && columns.include?('account_id')
          account_id_index = columns.index('account_id')
          values[account_id_index] = @options[:new_account_id]
        end
        
        file.puts "INSERT INTO #{table_name} (#{columns.join(', ')}) VALUES (#{values.join(', ')});"
      end
      
      file.puts ""
    end
  end

  def build_where_clause(config, account_id)
    if config[:where_clause]
      config[:where_clause].gsub('?', account_id.to_s)
    elsif config[:custom_query]
      config[:custom_query].call(account_id)
    elsif config[:foreign_key]
      "#{config[:foreign_key]} = #{account_id}"
    end
  end

  def simulate_export(account_id)
    tables_to_export = get_tables_to_export
    
    puts "📋 Tablas que se exportarían:"
    tables_to_export.each do |table_name, config|
      puts "  - #{table_name}"
    end
    
    puts ""
    puts "🔧 Configuración:"
    puts "  - Incluir Enterprise: #{@options[:include_enterprise]}"
    puts "  - Comprimir salida: #{@options[:compress_output]}"
    puts "  - Tablas excluidas: #{@options[:exclude_tables].join(', ')}" if @options[:exclude_tables].any?
    puts "  - Solo tablas: #{@options[:include_only_tables].join(', ')}" if @options[:include_only_tables].any?
  end

  def simulate_import(input_file)
    puts "📋 Archivo a importar: #{input_file}"
    puts "🔧 Configuración:"
    puts "  - Crear respaldo: #{@options[:backup_files]}"
    puts "  - Nuevo Account ID: #{@options[:new_account_id] || 'Mantener original'}"
    puts "  - Base de datos destino: #{@target_db_config['database']}"
  end

  def process_import_file(input_file)
    puts "🔄 Procesando archivo de importación..."
    
    begin
      require 'pg'
      
      conn = PG.connect(
        host: @target_db_config['host'],
        port: @target_db_config['port'],
        dbname: @target_db_config['database'],
        user: @target_db_config['username'],
        password: @target_db_config['password']
      )
      
      sql_content = File.read(input_file)
      conn.exec(sql_content)
      
      conn.close
      
    rescue PG::Error => e
      puts "❌ Error durante la importación: #{e.message}"
      exit 1
    end
  end

  def create_backup
    timestamp = Time.now.strftime('%Y%m%d_%H%M%S')
    backup_file = "backup_before_import_#{timestamp}.sql"
    
    puts "💾 Creando respaldo: #{backup_file}"
    
    # Usar pg_dump para crear un respaldo completo
    cmd = build_pg_dump_command(backup_file)
    system(cmd)
    
    unless $?.success?
      puts "❌ Error creando respaldo"
      exit 1
    end
  end

  def build_pg_dump_command(backup_file)
    cmd = "pg_dump"
    cmd += " -h #{@target_db_config['host']}" if @target_db_config['host']
    cmd += " -p #{@target_db_config['port']}" if @target_db_config['port']
    cmd += " -U #{@target_db_config['username']}" if @target_db_config['username']
    cmd += " -d #{@target_db_config['database']}"
    cmd += " -f #{backup_file}"
    cmd += " --clean --if-exists"
    
    # Establecer contraseña como variable de entorno
    if @target_db_config['password']
      cmd = "PGPASSWORD='#{@target_db_config['password']}' #{cmd}"
    end
    
    cmd
  end

  def compress_file(file_path)
    puts "🗜️  Comprimiendo archivo..."
    
    compressed_file = "#{file_path}.gz"
    system("gzip #{file_path}")
    
    if File.exist?(compressed_file)
      puts "✅ Archivo comprimido: #{compressed_file}"
    else
      puts "⚠️  No se pudo comprimir el archivo"
    end
  end

  def show_export_stats(account_id)
    puts ""
    puts "📊 Estadísticas de exportación:"
    
    tables_to_export = get_tables_to_export
    
    begin
      require 'pg'
      
      conn = PG.connect(
        host: @source_db_config['host'],
        port: @source_db_config['port'],
        dbname: @source_db_config['database'],
        user: @source_db_config['username'],
        password: @source_db_config['password']
      )
      
      tables_to_export.each do |table_name, config|
        where_clause = build_where_clause(config, account_id)
        
        count_query = "SELECT COUNT(*) FROM #{table_name}"
        count_query += " WHERE #{where_clause}" if where_clause
        
        begin
          result = conn.exec(count_query)
          count = result[0]['count']
          puts "  #{table_name}: #{count} registros"
        rescue PG::Error
          puts "  #{table_name}: Error obteniendo conteo"
        end
      end
      
      conn.close
      
    rescue PG::Error => e
      puts "❌ Error obteniendo estadísticas: #{e.message}"
    end
  end

  def perform_validation(account_id)
    results = { errors: [], stats: {} }
    
    # Aquí puedes agregar validaciones específicas
    # Por ejemplo, verificar relaciones de claves foráneas
    
    results
  end
end

# Punto de entrada del script
if __FILE__ == $0
  migrator = ChatwootAccountMigrator.new
  migrator.run(ARGV)
end
