#!/bin/bash

# Script para automatizar el backup y migración de cuentas Chatwoot
# 
# Uso:
#   ./backup_and_migrate.sh --help
#   ./backup_and_migrate.sh --account-id 1 --target-server usuario@servidor.com
#   ./backup_and_migrate.sh --account-name "Mi Empresa" --target-server usuario@servidor.com

set -e

# Configuración por defecto
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MIGRATE_SCRIPT="$SCRIPT_DIR/migrate_account.rb"
TEMP_DIR="/tmp/chatwoot_backups"
ACCOUNT_ID=""
ACCOUNT_NAME=""
TARGET_SERVER=""
OUTPUT_DIR="$TEMP_DIR"
COMPRESS=true
VERBOSE=false
DRY_RUN=false

# Colores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Funciones de logging
log() {
    echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# Función de ayuda
show_help() {
    cat << EOF
Uso: $0 [opciones]

Este script automatiza el proceso completo de backup y migración de cuentas Chatwoot:
1. Crea un backup de la cuenta especificada
2. Transfiere el backup al servidor destino (opcional)
3. Proporciona comandos para importar en el destino

Opciones:
  --account-id ID             ID de la cuenta a migrar
  --account-name "NOMBRE"     Nombre de la cuenta a migrar
  --target-server USER@HOST   Servidor destino (formato: usuario@servidor.com)
  --output-dir DIR            Directorio para guardar backups (default: $TEMP_DIR)
  --no-compress               No comprimir el archivo de backup
  --verbose                   Salida detallada
  --dry-run                   Simular operaciones sin ejecutar
  --help                      Mostrar esta ayuda

Ejemplos:
  # Crear backup de cuenta por ID
  $0 --account-id 1

  # Crear backup y transferir a servidor
  $0 --account-id 1 --target-server usuario@mi-servidor.com

  # Backup por nombre de cuenta
  $0 --account-name "Mi Empresa" --target-server usuario@servidor.com

  # Solo simular (dry-run)
  $0 --account-id 1 --dry-run

EOF
}

# Parsear argumentos
while [[ $# -gt 0 ]]; do
    case $1 in
        --account-id)
            ACCOUNT_ID="$2"
            shift 2
            ;;
        --account-name)
            ACCOUNT_NAME="$2"
            shift 2
            ;;
        --target-server)
            TARGET_SERVER="$2"
            shift 2
            ;;
        --output-dir)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --no-compress)
            COMPRESS=false
            shift
            ;;
        --verbose)
            VERBOSE=true
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --help)
            show_help
            exit 0
            ;;
        *)
            error "Argumento desconocido: $1"
            show_help
            exit 1
            ;;
    esac
done

# Validaciones
if [[ -z "$ACCOUNT_ID" && -z "$ACCOUNT_NAME" ]]; then
    error "Debe especificar --account-id o --account-name"
    show_help
    exit 1
fi

if [[ ! -f "$MIGRATE_SCRIPT" ]]; then
    error "Script de migración no encontrado: $MIGRATE_SCRIPT"
    exit 1
fi

# Crear directorio de salida
mkdir -p "$OUTPUT_DIR"

# Construir comando de exportación
export_cmd="ruby \"$MIGRATE_SCRIPT\" export"

if [[ -n "$ACCOUNT_ID" ]]; then
    export_cmd="$export_cmd --account-id $ACCOUNT_ID"
    backup_file="$OUTPUT_DIR/account_${ACCOUNT_ID}_$(date +%Y%m%d_%H%M%S).sql"
elif [[ -n "$ACCOUNT_NAME" ]]; then
    export_cmd="$export_cmd --account-name \"$ACCOUNT_NAME\""
    safe_name=$(echo "$ACCOUNT_NAME" | tr ' ' '_' | tr -cd '[:alnum:]_-')
    backup_file="$OUTPUT_DIR/account_${safe_name}_$(date +%Y%m%d_%H%M%S).sql"
fi

export_cmd="$export_cmd --output \"$backup_file\""

if [[ "$COMPRESS" == true ]]; then
    export_cmd="$export_cmd --compress"
    final_file="${backup_file}.gz"
else
    final_file="$backup_file"
fi

if [[ "$VERBOSE" == true ]]; then
    export_cmd="$export_cmd --verbose"
fi

if [[ "$DRY_RUN" == true ]]; then
    export_cmd="$export_cmd --dry-run"
fi

# Mostrar información del proceso
log "=== BACKUP Y MIGRACIÓN DE CUENTA CHATWOOT ==="
log ""
if [[ -n "$ACCOUNT_ID" ]]; then
    log "Cuenta ID: $ACCOUNT_ID"
else
    log "Cuenta: $ACCOUNT_NAME"
fi
log "Archivo backup: $final_file"
log "Servidor destino: ${TARGET_SERVER:-'No especificado'}"
log "Compresión: $COMPRESS"
log "Dry run: $DRY_RUN"
log ""

# Paso 1: Crear backup
log "=== PASO 1: CREANDO BACKUP ==="
log "Comando: $export_cmd"

if [[ "$DRY_RUN" == true ]]; then
    warning "DRY RUN: Simulando creación de backup..."
    eval "$export_cmd"
    log "Backup simulado completado"
else
    log "Ejecutando backup..."
    if eval "$export_cmd"; then
        success "Backup creado exitosamente: $final_file"
        
        # Verificar que el archivo existe
        if [[ -f "$final_file" ]]; then
            file_size=$(du -h "$final_file" | cut -f1)
            log "Tamaño del archivo: $file_size"
        else
            error "El archivo de backup no fue creado"
            exit 1
        fi
    else
        error "Error creando el backup"
        exit 1
    fi
fi

# Paso 2: Transferir al servidor destino (si se especifica)
if [[ -n "$TARGET_SERVER" ]]; then
    log ""
    log "=== PASO 2: TRANSFIRIENDO AL SERVIDOR DESTINO ==="
    
    if [[ "$DRY_RUN" == true ]]; then
        warning "DRY RUN: Simulando transferencia a $TARGET_SERVER"
        log "Comando que se ejecutaría: scp \"$final_file\" \"$TARGET_SERVER:/tmp/\""
    else
        log "Transfiriendo backup a $TARGET_SERVER..."
        
        if scp "$final_file" "$TARGET_SERVER:/tmp/"; then
            success "Backup transferido exitosamente al servidor destino"
            remote_file="/tmp/$(basename "$final_file")"
            log "Archivo remoto: $remote_file"
        else
            error "Error transfiriendo el backup"
            exit 1
        fi
    fi
    
    # Paso 3: Mostrar comandos para importar
    log ""
    log "=== PASO 3: COMANDOS PARA IMPORTAR EN EL DESTINO ==="
    log ""
    log "Para importar en el servidor destino, ejecute los siguientes comandos:"
    log ""
    echo -e "${GREEN}# Conectar al servidor destino:${NC}"
    echo "ssh $TARGET_SERVER"
    echo ""
    echo -e "${GREEN}# Navegar al directorio de Chatwoot:${NC}"
    echo "cd /path/to/chatwoot"
    echo ""
    echo -e "${GREEN}# Importar el backup:${NC}"
    if [[ -n "$ACCOUNT_ID" ]]; then
        echo "ruby scripts/migrate_account.rb import --input /tmp/$(basename "$final_file")"
        echo ""
        echo -e "${GREEN}# O con nuevo ID de cuenta:${NC}"
        echo "ruby scripts/migrate_account.rb import --input /tmp/$(basename "$final_file") --new-account-id 999"
    else
        echo "ruby scripts/migrate_account.rb import --input /tmp/$(basename "$final_file")"
    fi
    echo ""
    echo -e "${GREEN}# Validar después de importar:${NC}"
    if [[ -n "$ACCOUNT_ID" ]]; then
        echo "ruby scripts/migrate_account.rb validate --account-id $ACCOUNT_ID"
    else
        echo "ruby scripts/migrate_account.rb validate --account-name \"$ACCOUNT_NAME\""
    fi
    
else
    log ""
    log "=== BACKUP COMPLETADO ==="
    log ""
    log "El backup está listo en: $final_file"
    log ""
    log "Para transferir manualmente al servidor destino:"
    echo "scp \"$final_file\" usuario@servidor-destino:/tmp/"
    log ""
    log "Para importar en el servidor destino:"
    echo "ruby scripts/migrate_account.rb import --input /tmp/$(basename "$final_file")"
fi

log ""
success "Proceso completado exitosamente"

# Mostrar resumen final
log ""
log "=== RESUMEN ==="
log "Backup creado: $final_file"
if [[ -f "$final_file" && "$DRY_RUN" == false ]]; then
    log "Tamaño: $(du -h "$final_file" | cut -f1)"
fi
if [[ -n "$TARGET_SERVER" ]]; then
    log "Transferido a: $TARGET_SERVER:/tmp/$(basename "$final_file")"
fi
log "Estado: ✅ Exitoso"
