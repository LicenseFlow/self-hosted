#!/bin/sh
set -e

echo "╔════════════════════════════════════════════════════════════╗"
echo "║           LicenseFlow Self-Hosted Edition                  ║"
echo "║                   Starting up...                           ║"
echo "╚════════════════════════════════════════════════════════════╝"

# Validate required environment variables
check_env() {
    if [ -z "${!1}" ]; then
        echo "ERROR: Required environment variable $1 is not set"
        exit 1
    fi
}

echo "→ Validating configuration and security posture..."

# Required variables
check_env "DATABASE_URL"
check_env "JWT_SECRET"

# Reject insecure/default JWT secrets
if [ ${#JWT_SECRET} -lt 32 ] || [ "$JWT_SECRET" = "your-super-secret-jwt-key-minimum-32-characters" ] || [ "$JWT_SECRET" = "changeme" ]; then
    echo "❌ SECURITY ERROR: JWT_SECRET must be at least 32 characters long and not a default placeholder."
    echo "   Generate a secure secret using: openssl rand -base64 32"
    exit 1
fi

# Reject default database credentials in production
if echo "$DATABASE_URL" | grep -qiE "(password|changeme|postgres:postgres|admin123)"; then
    echo "❌ SECURITY ERROR: Insecure or default database password detected in DATABASE_URL."
    echo "   Please configure a strong, unique PostgreSQL password before starting."
    exit 1
fi

# Validate MinIO / S3 credentials if configured
if [ "$MINIO_ROOT_PASSWORD" = "strongpassword-change-me" ] || [ "$MINIO_ROOT_PASSWORD" = "minioadmin" ]; then
    echo "⚠️  SECURITY WARNING: Default MINIO_ROOT_PASSWORD detected. Change this in production."
fi

# Validate Master Encryption Key if provided
if [ -n "$MASTER_ENCRYPTION_KEY" ] && [ ${#MASTER_ENCRYPTION_KEY} -lt 32 ]; then
    echo "❌ SECURITY ERROR: MASTER_ENCRYPTION_KEY must be at least 32 characters long."
    exit 1
fi

# Optional but recommended
if [ -z "$SUPABASE_URL" ]; then
    echo "ℹ️  Notice: SUPABASE_URL not set, using local database standalone mode"
fi

# Wait for database to be ready
if [ -n "$DATABASE_URL" ]; then
    echo "→ Waiting for database connection..."
    
    # Extract host and port from DATABASE_URL
    DB_HOST=$(echo $DATABASE_URL | sed -E 's/.*@([^:\/]+).*/\1/')
    DB_PORT=$(echo $DATABASE_URL | sed -E 's/.*:([0-9]+)\/.*/\1/')
    
    # Default port if not specified
    DB_PORT=${DB_PORT:-5432}
    
    # Wait up to 60 seconds for database
    RETRIES=30
    until pg_isready -h "$DB_HOST" -p "$DB_PORT" > /dev/null 2>&1 || [ $RETRIES -eq 0 ]; do
        echo "   Waiting for PostgreSQL at $DB_HOST:$DB_PORT... ($RETRIES retries left)"
        RETRIES=$((RETRIES-1))
        sleep 2
    done
    
    if [ $RETRIES -eq 0 ]; then
        echo "ERROR: Could not connect to database"
        exit 1
    fi
    
    echo "✓ Database connection established"
fi

# Generate runtime config for frontend
echo "→ Generating runtime configuration..."
cat > /usr/share/nginx/html/config.js << EOF
window.__LICENSEFLOW_CONFIG__ = {
    SUPABASE_URL: "${SUPABASE_URL:-}",
    SUPABASE_ANON_KEY: "${SUPABASE_ANON_KEY:-}",
    APP_URL: "${APP_URL:-http://localhost:3000}",
    SELF_HOSTED: true,
    VERSION: "${VERSION:-1.0.0}"
};
EOF

# Create log directories
mkdir -p /var/log/supervisor
mkdir -p /var/log/nginx
mkdir -p /var/log/licenseflow

# Run database migrations if enabled
if [ "${RUN_MIGRATIONS:-true}" = "true" ] && [ -f "/app/migrate.sh" ]; then
    echo "→ Running database migrations..."
    chmod +x /app/migrate.sh
    /app/migrate.sh up || {
        echo "WARNING: Migrations failed, continuing anyway..."
    }
fi

echo "✓ Configuration complete"
echo "→ Starting services..."

# Execute the main command
exec "$@"
