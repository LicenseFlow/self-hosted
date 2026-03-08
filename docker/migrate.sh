#!/bin/bash
set -e

# ============================================================================
# LicenseFlow Self-Hosted - Database Migration Script
# ============================================================================
# This script handles database schema migrations for self-hosted deployments.
# It supports:
#   - Applying new migrations
#   - Rolling back migrations
#   - Checking migration status
#   - Version tracking
# ============================================================================

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
MIGRATIONS_DIR="${MIGRATIONS_DIR:-/app/migrations}"
VERSION_TABLE="schema_migrations"
LOG_FILE="${LOG_FILE:-/var/log/licenseflow/migrations.log}"

# Ensure log directory exists
mkdir -p "$(dirname "$LOG_FILE")"

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo -e "$msg" | tee -a "$LOG_FILE"
}

log_success() {
    log "${GREEN}✓ $1${NC}"
}

log_error() {
    log "${RED}✗ $1${NC}"
}

log_info() {
    log "${BLUE}→ $1${NC}"
}

log_warn() {
    log "${YELLOW}⚠ $1${NC}"
}

# Check required environment variables
check_env() {
    if [ -z "$DATABASE_URL" ]; then
        log_error "DATABASE_URL environment variable is required"
        exit 1
    fi
}

# Extract database connection details from DATABASE_URL
parse_database_url() {
    # postgresql://user:pass@host:port/dbname
    DB_USER=$(echo "$DATABASE_URL" | sed -E 's/.*:\/\/([^:]+):.*/\1/')
    DB_PASS=$(echo "$DATABASE_URL" | sed -E 's/.*:\/\/[^:]+:([^@]+)@.*/\1/')
    DB_HOST=$(echo "$DATABASE_URL" | sed -E 's/.*@([^:\/]+).*/\1/')
    DB_PORT=$(echo "$DATABASE_URL" | sed -E 's/.*:([0-9]+)\/.*/\1/' || echo "5432")
    DB_NAME=$(echo "$DATABASE_URL" | sed -E 's/.*\/([^?]+).*/\1/')
    
    DB_PORT=${DB_PORT:-5432}
}

# Execute SQL command
exec_sql() {
    PGPASSWORD="$DB_PASS" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -t -c "$1" 2>/dev/null
}

# Execute SQL file
exec_sql_file() {
    PGPASSWORD="$DB_PASS" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -f "$1" 2>&1
}

# Create migrations table if it doesn't exist
init_migrations_table() {
    log_info "Checking migrations table..."
    exec_sql "
        CREATE TABLE IF NOT EXISTS $VERSION_TABLE (
            id SERIAL PRIMARY KEY,
            version VARCHAR(255) NOT NULL UNIQUE,
            name VARCHAR(255),
            applied_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
            checksum VARCHAR(64),
            execution_time_ms INTEGER
        );
    " > /dev/null
    log_success "Migrations table ready"
}

# Get list of applied migrations
get_applied_migrations() {
    exec_sql "SELECT version FROM $VERSION_TABLE ORDER BY version;"
}

# Check if a migration is applied
is_migration_applied() {
    local version="$1"
    local result=$(exec_sql "SELECT COUNT(*) FROM $VERSION_TABLE WHERE version = '$version';")
    [ "$result" -gt 0 ]
}

# Calculate file checksum
get_checksum() {
    sha256sum "$1" | cut -d' ' -f1
}

# Apply a single migration
apply_migration() {
    local file="$1"
    local filename=$(basename "$file")
    local version="${filename%%_*}"
    local name="${filename#*_}"
    name="${name%.sql}"
    
    if is_migration_applied "$version"; then
        log_warn "Migration $version already applied, skipping"
        return 0
    fi
    
    log_info "Applying migration: $filename"
    
    local start_time=$(date +%s%3N)
    local checksum=$(get_checksum "$file")
    
    # Run the migration
    if output=$(exec_sql_file "$file" 2>&1); then
        local end_time=$(date +%s%3N)
        local duration=$((end_time - start_time))
        
        # Record the migration
        exec_sql "
            INSERT INTO $VERSION_TABLE (version, name, checksum, execution_time_ms)
            VALUES ('$version', '$name', '$checksum', $duration);
        " > /dev/null
        
        log_success "Applied $filename (${duration}ms)"
        return 0
    else
        log_error "Failed to apply $filename"
        echo "$output" | tee -a "$LOG_FILE"
        return 1
    fi
}

# Apply all pending migrations
migrate_up() {
    log_info "Running pending migrations..."
    
    if [ ! -d "$MIGRATIONS_DIR" ]; then
        log_warn "Migrations directory not found: $MIGRATIONS_DIR"
        log_info "Creating migrations directory..."
        mkdir -p "$MIGRATIONS_DIR"
        return 0
    fi
    
    local applied=0
    local failed=0
    
    # Process migrations in order
    for file in $(ls "$MIGRATIONS_DIR"/*.sql 2>/dev/null | sort); do
        if apply_migration "$file"; then
            ((applied++))
        else
            ((failed++))
            log_error "Migration failed, stopping"
            exit 1
        fi
    done
    
    if [ $applied -eq 0 ]; then
        log_info "No pending migrations"
    else
        log_success "Applied $applied migration(s)"
    fi
}

# Rollback the last migration
migrate_down() {
    local count="${1:-1}"
    log_info "Rolling back $count migration(s)..."
    
    # Get the last N applied migrations
    local versions=$(exec_sql "
        SELECT version FROM $VERSION_TABLE 
        ORDER BY version DESC 
        LIMIT $count;
    ")
    
    for version in $versions; do
        version=$(echo "$version" | tr -d ' ')
        [ -z "$version" ] && continue
        
        # Look for rollback file
        local rollback_file=$(ls "$MIGRATIONS_DIR"/${version}_*.down.sql 2>/dev/null | head -1)
        
        if [ -z "$rollback_file" ]; then
            log_warn "No rollback file found for $version, removing from history only"
        else
            log_info "Rolling back: $(basename "$rollback_file")"
            if ! exec_sql_file "$rollback_file"; then
                log_error "Rollback failed for $version"
                exit 1
            fi
        fi
        
        # Remove from migrations table
        exec_sql "DELETE FROM $VERSION_TABLE WHERE version = '$version';" > /dev/null
        log_success "Rolled back $version"
    done
}

# Show migration status
status() {
    log_info "Migration Status"
    echo ""
    echo "Applied migrations:"
    echo "───────────────────────────────────────────────────────────"
    exec_sql "
        SELECT 
            version,
            name,
            to_char(applied_at, 'YYYY-MM-DD HH24:MI:SS') as applied_at,
            execution_time_ms || 'ms' as duration
        FROM $VERSION_TABLE
        ORDER BY version;
    "
    echo ""
    
    # Show pending migrations
    echo "Pending migrations:"
    echo "───────────────────────────────────────────────────────────"
    local pending=0
    for file in $(ls "$MIGRATIONS_DIR"/*.sql 2>/dev/null | grep -v '.down.sql' | sort); do
        local filename=$(basename "$file")
        local version="${filename%%_*}"
        if ! is_migration_applied "$version"; then
            echo "  → $filename"
            ((pending++))
        fi
    done
    
    if [ $pending -eq 0 ]; then
        echo "  (none)"
    fi
    echo ""
}

# Create a new migration file
create() {
    local name="$1"
    if [ -z "$name" ]; then
        log_error "Migration name is required"
        echo "Usage: migrate.sh create <migration_name>"
        exit 1
    fi
    
    local timestamp=$(date +%Y%m%d%H%M%S)
    local slug=$(echo "$name" | tr '[:upper:]' '[:lower:]' | tr ' ' '_' | tr -cd 'a-z0-9_')
    local filename="${timestamp}_${slug}.sql"
    local rollback_filename="${timestamp}_${slug}.down.sql"
    
    mkdir -p "$MIGRATIONS_DIR"
    
    cat > "$MIGRATIONS_DIR/$filename" << EOF
-- Migration: $name
-- Created at: $(date)
-- 
-- Add your migration SQL here

-- Example:
-- CREATE TABLE example (
--     id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
--     name TEXT NOT NULL,
--     created_at TIMESTAMPTZ DEFAULT NOW()
-- );

EOF

    cat > "$MIGRATIONS_DIR/$rollback_filename" << EOF
-- Rollback for: $name
-- 
-- Add your rollback SQL here (reverses the migration)

-- Example:
-- DROP TABLE IF EXISTS example;

EOF

    log_success "Created migration: $filename"
    log_info "Rollback file: $rollback_filename"
    echo ""
    echo "Edit the files at:"
    echo "  $MIGRATIONS_DIR/$filename"
    echo "  $MIGRATIONS_DIR/$rollback_filename"
}

# Verify migration integrity
verify() {
    log_info "Verifying migration integrity..."
    local errors=0
    
    # Check for checksum mismatches
    for file in $(ls "$MIGRATIONS_DIR"/*.sql 2>/dev/null | grep -v '.down.sql' | sort); do
        local filename=$(basename "$file")
        local version="${filename%%_*}"
        local current_checksum=$(get_checksum "$file")
        
        local stored_checksum=$(exec_sql "
            SELECT checksum FROM $VERSION_TABLE WHERE version = '$version';
        " | tr -d ' ')
        
        if [ -n "$stored_checksum" ] && [ "$stored_checksum" != "$current_checksum" ]; then
            log_warn "Checksum mismatch for $filename"
            log_warn "  Stored:  $stored_checksum"
            log_warn "  Current: $current_checksum"
            ((errors++))
        fi
    done
    
    if [ $errors -eq 0 ]; then
        log_success "All migrations verified"
    else
        log_error "$errors migration(s) have checksum mismatches"
        exit 1
    fi
}

# Print usage
usage() {
    cat << EOF
LicenseFlow Database Migration Tool

Usage: migrate.sh <command> [options]

Commands:
  up              Apply all pending migrations
  down [count]    Rollback the last N migrations (default: 1)
  status          Show migration status
  create <name>   Create a new migration file
  verify          Verify migration integrity (checksum)
  help            Show this help message

Environment Variables:
  DATABASE_URL    PostgreSQL connection string (required)
  MIGRATIONS_DIR  Directory containing migration files (default: /app/migrations)
  LOG_FILE        Log file path (default: /var/log/licenseflow/migrations.log)

Examples:
  migrate.sh up                    # Apply all pending migrations
  migrate.sh down                  # Rollback the last migration
  migrate.sh down 3                # Rollback the last 3 migrations
  migrate.sh status                # Show migration status
  migrate.sh create "add users"    # Create a new migration

EOF
}

# Main
main() {
    check_env
    parse_database_url
    
    case "${1:-up}" in
        up|migrate)
            init_migrations_table
            migrate_up
            ;;
        down|rollback)
            init_migrations_table
            migrate_down "${2:-1}"
            ;;
        status)
            init_migrations_table
            status
            ;;
        create|new)
            create "$2"
            ;;
        verify|check)
            init_migrations_table
            verify
            ;;
        help|--help|-h)
            usage
            ;;
        *)
            log_error "Unknown command: $1"
            usage
            exit 1
            ;;
    esac
}

main "$@"
