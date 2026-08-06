-- LicenseFlow Self-Hosted Database Initialization
-- This script sets up the complete schema for self-hosted deployments
-- Synchronized with production portal as of 2026-04-05

-- Enable required extensions
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ═══════════════════════════════════════════════════════════════
-- USERS & AUTHENTICATION
-- ═══════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS users (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    email TEXT UNIQUE NOT NULL,
    encrypted_password TEXT NOT NULL,
    email_confirmed_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    last_sign_in_at TIMESTAMPTZ,
    raw_user_meta_data JSONB DEFAULT '{}',
    is_admin BOOLEAN DEFAULT FALSE
);

CREATE TABLE IF NOT EXISTS profiles (
    id UUID PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    email TEXT NOT NULL,
    full_name TEXT,
    company_name TEXT,
    avatar_url TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS sessions (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID REFERENCES users(id) ON DELETE CASCADE,
    token TEXT UNIQUE NOT NULL,
    expires_at TIMESTAMPTZ NOT NULL,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    user_agent TEXT,
    ip_address INET
);

-- ═══════════════════════════════════════════════════════════════
-- ORGANIZATIONS
-- ═══════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS organizations (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    name TEXT NOT NULL,
    owner_id UUID REFERENCES users(id),
    metadata JSONB DEFAULT '{}',
    branding_config JSONB DEFAULT '{}',
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS organization_members (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    organization_id UUID REFERENCES organizations(id) ON DELETE CASCADE,
    user_id UUID REFERENCES users(id) ON DELETE CASCADE,
    role TEXT DEFAULT 'member',
    joined_at TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE(organization_id, user_id)
);

-- ═══════════════════════════════════════════════════════════════
-- ENVIRONMENTS (Environment Scoping)
-- ═══════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS environments (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    organization_id UUID REFERENCES organizations(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    description TEXT,
    is_default BOOLEAN DEFAULT FALSE,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE(organization_id, name)
);

-- ═══════════════════════════════════════════════════════════════
-- SUBSCRIPTION PLANS & ORGANIZATION SUBSCRIPTIONS
-- ═══════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS subscription_plans (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    name TEXT NOT NULL,
    slug TEXT UNIQUE NOT NULL,
    description TEXT,
    price_monthly NUMERIC(10,2) DEFAULT 0,
    price_yearly NUMERIC(10,2) DEFAULT 0,
    features JSONB DEFAULT '{}',
    limits JSONB DEFAULT '{}',
    is_active BOOLEAN DEFAULT TRUE,
    sort_order INTEGER DEFAULT 0,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS organization_subscriptions (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    organization_id UUID REFERENCES organizations(id) ON DELETE CASCADE,
    plan_id UUID REFERENCES subscription_plans(id),
    status TEXT DEFAULT 'active',
    current_period_start TIMESTAMPTZ,
    current_period_end TIMESTAMPTZ,
    stripe_subscription_id TEXT,
    stripe_customer_id TEXT,
    metadata JSONB DEFAULT '{}',
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- ═══════════════════════════════════════════════════════════════
-- PRODUCTS & LICENSES
-- ═══════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS products (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID REFERENCES users(id),
    organization_id UUID REFERENCES organizations(id),
    name TEXT NOT NULL,
    description TEXT,
    category TEXT,
    is_public BOOLEAN DEFAULT FALSE,
    metadata JSONB DEFAULT '{}',
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS license_key_formats (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    organization_id UUID REFERENCES organizations(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    prefix TEXT DEFAULT 'LF',
    segment_count INTEGER DEFAULT 4,
    segment_length INTEGER DEFAULT 4,
    separator TEXT DEFAULT '-',
    format_type TEXT NOT NULL DEFAULT 'alphanumeric',
    numeric_digits INTEGER,
    generate_password BOOLEAN NOT NULL DEFAULT FALSE,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS license_tiers (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID REFERENCES users(id),
    organization_id UUID REFERENCES organizations(id),
    name TEXT NOT NULL,
    description TEXT,
    features JSONB DEFAULT '{}',
    max_activations INTEGER DEFAULT 1,
    usage_limit INTEGER,
    usage_period TEXT,
    metadata JSONB DEFAULT '{}',
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS license_bundles (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    organization_id UUID REFERENCES organizations(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    description TEXT,
    products JSONB DEFAULT '[]',
    discount_percentage NUMERIC(5,2) DEFAULT 0,
    is_active BOOLEAN DEFAULT TRUE,
    metadata JSONB DEFAULT '{}',
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS licenses (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID REFERENCES users(id),
    product_id UUID REFERENCES products(id) ON DELETE CASCADE,
    organization_id UUID REFERENCES organizations(id),
    license_key TEXT UNIQUE NOT NULL,
    status TEXT DEFAULT 'active',
    max_activations INTEGER DEFAULT 1,
    current_activations INTEGER DEFAULT 0,
    expires_at TIMESTAMPTZ,
    features JSONB DEFAULT '{}',
    metadata JSONB DEFAULT '{}',
    is_floating BOOLEAN DEFAULT FALSE,
    hardware_binding_enabled BOOLEAN DEFAULT FALSE,
    geo_restricted BOOLEAN DEFAULT FALSE,
    environment_id UUID REFERENCES environments(id),
    key_format_id UUID REFERENCES license_key_formats(id),
    tier_id UUID REFERENCES license_tiers(id),
    bundle_id UUID REFERENCES license_bundles(id),
    usage_limit INTEGER,
    usage_period TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS license_passwords (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    license_id UUID NOT NULL REFERENCES licenses(id) ON DELETE CASCADE,
    password_hash TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE(license_id)
);

CREATE TABLE IF NOT EXISTS license_activations (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    license_id UUID REFERENCES licenses(id) ON DELETE CASCADE,
    device_id TEXT NOT NULL,
    device_name TEXT,
    ip_address INET,
    activated_at TIMESTAMPTZ DEFAULT NOW(),
    last_seen_at TIMESTAMPTZ DEFAULT NOW(),
    deactivated_at TIMESTAMPTZ,
    deactivation_reason TEXT,
    environment_id UUID REFERENCES environments(id),
    UNIQUE(license_id, device_id)
);

CREATE TABLE IF NOT EXISTS device_fingerprints (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    activation_id UUID REFERENCES license_activations(id) ON DELETE CASCADE UNIQUE,
    hardware_id TEXT NOT NULL,
    cpu_id TEXT,
    motherboard_id TEXT,
    mac_addresses TEXT[],
    disk_serials TEXT[],
    os_info JSONB,
    collected_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS license_geo_restrictions (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    license_id UUID REFERENCES licenses(id) ON DELETE CASCADE,
    allowed_countries TEXT[] DEFAULT '{}',
    blocked_countries TEXT[] DEFAULT '{}',
    allowed_regions TEXT[] DEFAULT '{}',
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- ═══════════════════════════════════════════════════════════════
-- LICENSE LEASES (CI/CD Support)
-- ═══════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS license_leases (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    license_id UUID REFERENCES licenses(id) ON DELETE CASCADE,
    lease_key TEXT UNIQUE NOT NULL,
    requester_id TEXT NOT NULL,
    requester_type TEXT DEFAULT 'ci_job',
    requester_metadata JSONB DEFAULT '{}',
    checked_out_at TIMESTAMPTZ DEFAULT NOW(),
    expires_at TIMESTAMPTZ NOT NULL,
    checked_in_at TIMESTAMPTZ,
    duration_seconds INTEGER NOT NULL,
    status TEXT DEFAULT 'active',
    release_reason TEXT,
    ip_address INET,
    user_agent TEXT,
    environment_id UUID REFERENCES environments(id),
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- ═══════════════════════════════════════════════════════════════
-- POLICIES & ENTITLEMENTS
-- ═══════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS policies (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    organization_id UUID REFERENCES organizations(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    description TEXT,
    max_activations INTEGER DEFAULT 1,
    duration_days INTEGER,
    is_floating BOOLEAN DEFAULT FALSE,
    require_heartbeat BOOLEAN DEFAULT FALSE,
    heartbeat_interval INTEGER DEFAULT 60,
    metadata JSONB DEFAULT '{}',
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS entitlements (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    organization_id UUID REFERENCES organizations(id) ON DELETE CASCADE,
    code TEXT NOT NULL,
    name TEXT NOT NULL,
    description TEXT,
    data_type TEXT DEFAULT 'boolean',
    metadata JSONB DEFAULT '{}',
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS license_entitlements (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    license_id UUID REFERENCES licenses(id) ON DELETE CASCADE,
    entitlement_id UUID REFERENCES entitlements(id) ON DELETE CASCADE,
    value JSONB DEFAULT '{}',
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE(license_id, entitlement_id)
);

CREATE TABLE IF NOT EXISTS policy_entitlements (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    policy_id UUID REFERENCES policies(id) ON DELETE CASCADE,
    entitlement_id UUID REFERENCES entitlements(id) ON DELETE CASCADE,
    default_value JSONB DEFAULT '{}',
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE(policy_id, entitlement_id)
);

-- ═══════════════════════════════════════════════════════════════
-- RELEASES & ARTIFACTS
-- ═══════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS releases (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    product_id UUID REFERENCES products(id) ON DELETE CASCADE,
    user_id UUID REFERENCES users(id),
    organization_id UUID REFERENCES organizations(id),
    version TEXT NOT NULL,
    channel TEXT DEFAULT 'stable',
    status TEXT DEFAULT 'draft',
    release_notes TEXT,
    changelog TEXT,
    is_published BOOLEAN DEFAULT FALSE,
    published_at TIMESTAMPTZ,
    metadata JSONB DEFAULT '{}',
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS artifacts (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    release_id UUID REFERENCES releases(id) ON DELETE CASCADE,
    filename TEXT NOT NULL,
    platform TEXT NOT NULL,
    architecture TEXT,
    file_size BIGINT NOT NULL,
    checksum_sha256 TEXT NOT NULL,
    storage_path TEXT NOT NULL,
    download_count INTEGER DEFAULT 0,
    metadata JSONB DEFAULT '{}',
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS download_tracking (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    artifact_id UUID REFERENCES artifacts(id) ON DELETE CASCADE,
    license_id UUID REFERENCES licenses(id),
    ip_address INET,
    user_agent TEXT,
    downloaded_at TIMESTAMPTZ DEFAULT NOW()
);

-- ═══════════════════════════════════════════════════════════════
-- API KEYS
-- ═══════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS api_keys (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID REFERENCES users(id),
    organization_id UUID REFERENCES organizations(id),
    name TEXT NOT NULL,
    key_prefix TEXT NOT NULL,
    key_hash TEXT NOT NULL,
    permissions JSONB DEFAULT '{}',
    is_active BOOLEAN DEFAULT TRUE,
    status TEXT DEFAULT 'active',
    environment TEXT DEFAULT 'production',
    expires_at TIMESTAMPTZ,
    last_used_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- ═══════════════════════════════════════════════════════════════
-- OFFLINE VALIDATION TOKENS
-- ═══════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS offline_validation_tokens (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    license_id UUID REFERENCES licenses(id) ON DELETE CASCADE,
    token TEXT UNIQUE NOT NULL,
    expires_at TIMESTAMPTZ NOT NULL,
    used_at TIMESTAMPTZ,
    metadata JSONB DEFAULT '{}',
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- ═══════════════════════════════════════════════════════════════
-- USAGE METRICS & RATE LIMITING
-- ═══════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS usage_records (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    license_id UUID REFERENCES licenses(id) ON DELETE CASCADE,
    organization_id UUID REFERENCES organizations(id),
    metric_name TEXT NOT NULL,
    value NUMERIC NOT NULL DEFAULT 0,
    environment_id UUID REFERENCES environments(id),
    recorded_at TIMESTAMPTZ DEFAULT NOW(),
    metadata JSONB DEFAULT '{}'
);

CREATE TABLE IF NOT EXISTS request_logs (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    api_key_id UUID REFERENCES api_keys(id),
    organization_id UUID REFERENCES organizations(id),
    endpoint TEXT NOT NULL,
    method TEXT NOT NULL,
    status_code INTEGER,
    response_time_ms INTEGER,
    ip_address INET,
    user_agent TEXT,
    metadata JSONB DEFAULT '{}',
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS rate_limit_rules (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    organization_id UUID REFERENCES organizations(id) ON DELETE CASCADE,
    endpoint_pattern TEXT NOT NULL,
    max_requests INTEGER NOT NULL DEFAULT 100,
    window_seconds INTEGER NOT NULL DEFAULT 60,
    is_active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS rate_limit_buckets (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    rule_id UUID REFERENCES rate_limit_rules(id) ON DELETE CASCADE,
    identifier TEXT NOT NULL,
    request_count INTEGER DEFAULT 0,
    window_start TIMESTAMPTZ DEFAULT NOW(),
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- ═══════════════════════════════════════════════════════════════
-- WEBHOOKS
-- ═══════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS webhook_endpoints (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    organization_id UUID REFERENCES organizations(id) ON DELETE CASCADE,
    url TEXT NOT NULL,
    events TEXT[] DEFAULT '{}',
    secret TEXT NOT NULL,
    is_active BOOLEAN DEFAULT TRUE,
    metadata JSONB DEFAULT '{}',
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS webhook_deliveries (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    endpoint_id UUID REFERENCES webhook_endpoints(id) ON DELETE CASCADE,
    event_type TEXT NOT NULL,
    payload JSONB NOT NULL,
    response_status INTEGER,
    response_body TEXT,
    delivered_at TIMESTAMPTZ,
    attempts INTEGER DEFAULT 0,
    next_retry_at TIMESTAMPTZ,
    status TEXT DEFAULT 'pending',
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- ═══════════════════════════════════════════════════════════════
-- CREDITS & USAGE-BASED BILLING
-- ═══════════════════════════════════════════════════════════════

DO $$ BEGIN
    CREATE TYPE credit_transaction_type AS ENUM ('grant', 'consume', 'expire', 'refund', 'adjustment');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

CREATE TABLE IF NOT EXISTS credit_balances (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    organization_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
    product_id UUID REFERENCES products(id) ON DELETE SET NULL,
    balance BIGINT NOT NULL DEFAULT 0,
    lifetime_granted BIGINT NOT NULL DEFAULT 0,
    lifetime_consumed BIGINT NOT NULL DEFAULT 0,
    currency TEXT NOT NULL DEFAULT 'credits',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (organization_id, product_id, currency)
);

CREATE TABLE IF NOT EXISTS credit_transactions (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    organization_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
    credit_balance_id UUID NOT NULL REFERENCES credit_balances(id) ON DELETE CASCADE,
    amount BIGINT NOT NULL,
    transaction_type credit_transaction_type NOT NULL,
    reference_id UUID,
    reference_type TEXT,
    description TEXT,
    metadata JSONB DEFAULT '{}',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ═══════════════════════════════════════════════════════════════
-- PRICING TEMPLATES
-- ═══════════════════════════════════════════════════════════════

DO $$ BEGIN
    CREATE TYPE pricing_template_type AS ENUM ('token_seat', 'pure_consumption', 'freemium_soft', 'hybrid', 'custom');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

CREATE TABLE IF NOT EXISTS pricing_templates (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    organization_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    slug TEXT NOT NULL,
    template_type pricing_template_type NOT NULL DEFAULT 'custom',
    config JSONB NOT NULL DEFAULT '{}',
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ═══════════════════════════════════════════════════════════════
-- PRICING EXPERIMENTS (A/B Testing)
-- ═══════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS pricing_experiments (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    organization_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    description TEXT,
    status TEXT NOT NULL DEFAULT 'draft',
    variants JSONB NOT NULL DEFAULT '[]',
    target_metric TEXT NOT NULL DEFAULT 'conversion_rate',
    started_at TIMESTAMPTZ,
    ended_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS experiment_assignments (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    experiment_id UUID NOT NULL REFERENCES pricing_experiments(id) ON DELETE CASCADE,
    visitor_id TEXT NOT NULL,
    variant_index INTEGER NOT NULL DEFAULT 0,
    assigned_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    converted BOOLEAN NOT NULL DEFAULT FALSE,
    converted_at TIMESTAMPTZ,
    metadata JSONB,
    UNIQUE (experiment_id, visitor_id)
);

-- ═══════════════════════════════════════════════════════════════
-- COHORT ANALYTICS
-- ═══════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS cohort_definitions (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    organization_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    description TEXT,
    filter_criteria JSONB NOT NULL DEFAULT '{}',
    granularity TEXT NOT NULL DEFAULT 'monthly',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS cohort_snapshots (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    cohort_id UUID NOT NULL REFERENCES cohort_definitions(id) ON DELETE CASCADE,
    snapshot_date DATE NOT NULL DEFAULT CURRENT_DATE,
    period_index INT NOT NULL DEFAULT 0,
    total_users INT NOT NULL DEFAULT 0,
    active_users INT NOT NULL DEFAULT 0,
    churned_users INT NOT NULL DEFAULT 0,
    retention_rate NUMERIC(5,2) NOT NULL DEFAULT 0,
    metadata JSONB,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE(cohort_id, snapshot_date, period_index)
);

-- ═══════════════════════════════════════════════════════════════
-- LICENSE POOLS
-- ═══════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS license_pools (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    organization_id UUID REFERENCES organizations(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    total_seats INTEGER NOT NULL DEFAULT 0,
    used_seats INTEGER NOT NULL DEFAULT 0,
    product_id UUID REFERENCES products(id),
    metadata JSONB DEFAULT '{}',
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- ═══════════════════════════════════════════════════════════════
-- AUDIT LOGS
-- ═══════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS audit_logs (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID REFERENCES users(id),
    license_id UUID REFERENCES licenses(id),
    organization_id UUID REFERENCES organizations(id),
    action TEXT NOT NULL,
    details JSONB DEFAULT '{}',
    ip_address INET,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- ═══════════════════════════════════════════════════════════════
-- PARTNER / MARKETPLACE
-- ═══════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS partner_applications (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    organization_id UUID REFERENCES organizations(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    status TEXT DEFAULT 'pending',
    commission_rate NUMERIC(5,2) DEFAULT 0,
    stripe_connect_id TEXT,
    metadata JSONB DEFAULT '{}',
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- ═══════════════════════════════════════════════════════════════
-- INDEXES
-- ═══════════════════════════════════════════════════════════════

CREATE INDEX IF NOT EXISTS idx_licenses_key ON licenses(license_key);
CREATE INDEX IF NOT EXISTS idx_licenses_status ON licenses(status);
CREATE INDEX IF NOT EXISTS idx_licenses_user ON licenses(user_id);
CREATE INDEX IF NOT EXISTS idx_licenses_org ON licenses(organization_id);
CREATE INDEX IF NOT EXISTS idx_licenses_environment ON licenses(environment_id);
CREATE INDEX IF NOT EXISTS idx_activations_license ON license_activations(license_id);
CREATE INDEX IF NOT EXISTS idx_activations_device ON license_activations(device_id);
CREATE INDEX IF NOT EXISTS idx_activations_environment ON license_activations(environment_id);
CREATE INDEX IF NOT EXISTS idx_leases_license ON license_leases(license_id);
CREATE INDEX IF NOT EXISTS idx_leases_status ON license_leases(status);
CREATE INDEX IF NOT EXISTS idx_leases_expires ON license_leases(expires_at);
CREATE INDEX IF NOT EXISTS idx_leases_environment ON license_leases(environment_id);
CREATE INDEX IF NOT EXISTS idx_api_keys_hash ON api_keys(key_hash);
CREATE INDEX IF NOT EXISTS idx_audit_logs_user ON audit_logs(user_id);
CREATE INDEX IF NOT EXISTS idx_audit_logs_license ON audit_logs(license_id);
CREATE INDEX IF NOT EXISTS idx_audit_logs_org ON audit_logs(organization_id);
CREATE INDEX IF NOT EXISTS idx_sessions_token ON sessions(token);
CREATE INDEX IF NOT EXISTS idx_sessions_user ON sessions(user_id);
CREATE INDEX IF NOT EXISTS idx_usage_records_license ON usage_records(license_id);
CREATE INDEX IF NOT EXISTS idx_usage_records_org ON usage_records(organization_id);
CREATE INDEX IF NOT EXISTS idx_request_logs_org ON request_logs(organization_id);
CREATE INDEX IF NOT EXISTS idx_request_logs_created ON request_logs(created_at);
CREATE INDEX IF NOT EXISTS idx_credit_transactions_balance_date ON credit_transactions(credit_balance_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_credit_transactions_org ON credit_transactions(organization_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_pricing_experiments_org ON pricing_experiments(organization_id);
CREATE INDEX IF NOT EXISTS idx_pricing_experiments_status ON pricing_experiments(status);
CREATE INDEX IF NOT EXISTS idx_experiment_assignments_experiment ON experiment_assignments(experiment_id);
CREATE INDEX IF NOT EXISTS idx_experiment_assignments_visitor ON experiment_assignments(visitor_id);
CREATE INDEX IF NOT EXISTS idx_cohort_definitions_org ON cohort_definitions(organization_id);
CREATE INDEX IF NOT EXISTS idx_cohort_snapshots_cohort ON cohort_snapshots(cohort_id);
CREATE INDEX IF NOT EXISTS idx_cohort_snapshots_date ON cohort_snapshots(snapshot_date);
CREATE INDEX IF NOT EXISTS idx_webhook_deliveries_endpoint ON webhook_deliveries(endpoint_id);
CREATE INDEX IF NOT EXISTS idx_webhook_deliveries_status ON webhook_deliveries(status);
CREATE INDEX IF NOT EXISTS idx_entitlements_org ON entitlements(organization_id);
CREATE INDEX IF NOT EXISTS idx_license_entitlements_license ON license_entitlements(license_id);
CREATE INDEX IF NOT EXISTS idx_policy_entitlements_policy ON policy_entitlements(policy_id);
CREATE INDEX IF NOT EXISTS idx_offline_tokens_license ON offline_validation_tokens(license_id);
CREATE INDEX IF NOT EXISTS idx_offline_tokens_token ON offline_validation_tokens(token);

-- ═══════════════════════════════════════════════════════════════
-- FUNCTIONS
-- ═══════════════════════════════════════════════════════════════

-- Updated at trigger function
CREATE OR REPLACE FUNCTION update_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Apply updated_at triggers
DO $$
DECLARE
    t TEXT;
BEGIN
    FOR t IN 
        SELECT table_name 
        FROM information_schema.columns 
        WHERE column_name = 'updated_at' 
        AND table_schema = 'public'
    LOOP
        EXECUTE format('
            DROP TRIGGER IF EXISTS update_%I_updated_at ON %I;
            CREATE TRIGGER update_%I_updated_at
            BEFORE UPDATE ON %I
            FOR EACH ROW
            EXECUTE FUNCTION update_updated_at();
        ', t, t, t, t);
    END LOOP;
END;
$$;

-- Clean expired sessions
CREATE OR REPLACE FUNCTION clean_expired_sessions()
RETURNS void AS $$
BEGIN
    DELETE FROM sessions WHERE expires_at < NOW();
END;
$$ LANGUAGE plpgsql;

-- Clean expired leases
CREATE OR REPLACE FUNCTION process_expired_leases()
RETURNS INTEGER AS $$
DECLARE
    expired_count INTEGER;
BEGIN
    UPDATE license_leases 
    SET status = 'expired', 
        updated_at = NOW(),
        release_reason = 'auto_expired'
    WHERE status = 'active' 
    AND expires_at < NOW();
    
    GET DIAGNOSTICS expired_count = ROW_COUNT;
    RETURN expired_count;
END;
$$ LANGUAGE plpgsql;

-- License key generation function
CREATE OR REPLACE FUNCTION generate_license_key(
    p_prefix TEXT DEFAULT 'LF',
    p_segment_count INTEGER DEFAULT 4,
    p_segment_length INTEGER DEFAULT 4,
    p_separator TEXT DEFAULT '-'
)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = 'public'
AS $$
DECLARE
    v_chars TEXT := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    v_key TEXT := p_prefix || p_separator;
    v_segment TEXT;
    i INTEGER;
    j INTEGER;
BEGIN
    FOR i IN 1..p_segment_count LOOP
        v_segment := '';
        FOR j IN 1..p_segment_length LOOP
            v_segment := v_segment || substr(v_chars, floor(random() * length(v_chars) + 1)::int, 1);
        END LOOP;
        IF i > 1 THEN
            v_key := v_key || p_separator;
        END IF;
        v_key := v_key || v_segment;
    END LOOP;
    RETURN v_key;
END;
$$;

-- Numeric license key + password generation function
CREATE OR REPLACE FUNCTION generate_numeric_license_key(p_digits INTEGER)
RETURNS TABLE(license_id TEXT, password TEXT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = 'public'
AS $$
DECLARE
    v_min BIGINT;
    v_max BIGINT;
    v_id TEXT;
    v_password TEXT;
    v_chars TEXT := 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789!@#$%';
    i INTEGER;
BEGIN
    IF p_digits < 1 OR p_digits > 18 THEN
        RAISE EXCEPTION 'Digits must be between 1 and 18';
    END IF;

    v_min := power(10, p_digits - 1)::BIGINT;
    v_max := power(10, p_digits)::BIGINT - 1;
    v_id := lpad((floor(random() * (v_max - v_min + 1) + v_min))::BIGINT::TEXT, p_digits, '0');

    v_password := '';
    FOR i IN 1..16 LOOP
        v_password := v_password || substr(v_chars, floor(random() * length(v_chars) + 1)::int, 1);
    END LOOP;

    RETURN QUERY SELECT v_id, v_password;
END;
$$;

-- Consume credits function (atomic deduction)
CREATE OR REPLACE FUNCTION consume_credits(
    p_org_id UUID,
    p_amount BIGINT,
    p_description TEXT DEFAULT NULL,
    p_reference_id UUID DEFAULT NULL,
    p_reference_type TEXT DEFAULT NULL,
    p_product_id UUID DEFAULT NULL,
    p_currency TEXT DEFAULT 'credits'
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = 'public'
AS $$
DECLARE
    v_balance_id UUID;
    v_current_balance BIGINT;
    v_new_balance BIGINT;
BEGIN
    SELECT id, balance INTO v_balance_id, v_current_balance
    FROM credit_balances
    WHERE organization_id = p_org_id
      AND (product_id = p_product_id OR (product_id IS NULL AND p_product_id IS NULL))
      AND currency = p_currency
    FOR UPDATE;

    IF v_balance_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'No credit balance found', 'remaining', 0);
    END IF;

    IF v_current_balance < p_amount THEN
        RETURN jsonb_build_object('success', false, 'error', 'Insufficient credits', 'remaining', v_current_balance);
    END IF;

    v_new_balance := v_current_balance - p_amount;

    UPDATE credit_balances
    SET balance = v_new_balance,
        lifetime_consumed = lifetime_consumed + p_amount,
        updated_at = now()
    WHERE id = v_balance_id;

    INSERT INTO credit_transactions (organization_id, credit_balance_id, amount, transaction_type, reference_id, reference_type, description)
    VALUES (p_org_id, v_balance_id, -p_amount, 'consume', p_reference_id, p_reference_type, p_description);

    RETURN jsonb_build_object('success', true, 'remaining', v_new_balance, 'consumed', p_amount);
END;
$$;

-- Grant credits function (atomic grant)
CREATE OR REPLACE FUNCTION grant_credits(
    p_org_id UUID,
    p_amount BIGINT,
    p_description TEXT DEFAULT NULL,
    p_reference_id UUID DEFAULT NULL,
    p_reference_type TEXT DEFAULT NULL,
    p_product_id UUID DEFAULT NULL,
    p_currency TEXT DEFAULT 'credits'
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = 'public'
AS $$
DECLARE
    v_balance_id UUID;
    v_new_balance BIGINT;
BEGIN
    INSERT INTO credit_balances (organization_id, product_id, balance, lifetime_granted, currency)
    VALUES (p_org_id, p_product_id, p_amount, p_amount, p_currency)
    ON CONFLICT (organization_id, product_id, currency)
    DO UPDATE SET
        balance = credit_balances.balance + p_amount,
        lifetime_granted = credit_balances.lifetime_granted + p_amount,
        updated_at = now()
    RETURNING id, balance INTO v_balance_id, v_new_balance;

    INSERT INTO credit_transactions (organization_id, credit_balance_id, amount, transaction_type, reference_id, reference_type, description)
    VALUES (p_org_id, v_balance_id, p_amount, 'grant', p_reference_id, p_reference_type, p_description);

    RETURN jsonb_build_object('success', true, 'balance', v_new_balance, 'granted', p_amount);
END;
$$;

COMMENT ON DATABASE licenseflow IS 'LicenseFlow Self-Hosted Edition Database — Schema v2.1.0';

-- ============================================================================
-- LICENSE SEATS & ORGADMIN DELEGATION SYSTEM (v2.1.0)
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.license_seats (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    license_id UUID NOT NULL REFERENCES public.licenses(id) ON DELETE CASCADE,
    organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
    user_id UUID REFERENCES auth.users(id) ON DELETE SET NULL,
    seat_status VARCHAR(50) NOT NULL DEFAULT 'unassigned',
    assigned_at TIMESTAMPTZ,
    expires_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_license_seats_org ON public.license_seats(organization_id);
CREATE INDEX IF NOT EXISTS idx_license_seats_license ON public.license_seats(license_id);
CREATE INDEX IF NOT EXISTS idx_license_seats_user ON public.license_seats(user_id);

ALTER TABLE public.license_seats ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view seats in their organization"
    ON public.license_seats FOR SELECT
    USING (
        organization_id IN (
            SELECT organization_id FROM public.organization_members
            WHERE user_id = auth.uid()
        )
    );

CREATE POLICY "OrgAdmins can manage seats in their organization"
    ON public.license_seats FOR ALL
    USING (
        organization_id IN (
            SELECT organization_id FROM public.organization_members
            WHERE user_id = auth.uid() AND role IN ('owner', 'admin')
        )
    );

-- Function: Resolve Identity Entitlements (Self-Hosted)
CREATE OR REPLACE FUNCTION public.resolve_identity_entitlements(
    p_organization_id UUID,
    p_product_id UUID,
    p_user_id UUID
)
RETURNS TABLE (
    licensed BOOLEAN,
    seats_total INT,
    seats_used INT,
    seat_status TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_seats_total INT := 0;
    v_seats_used INT := 0;
    v_is_licensed BOOLEAN := FALSE;
    v_user_seat_status TEXT := 'unassigned';
BEGIN
    SELECT COUNT(*), COUNT(user_id)
    INTO v_seats_total, v_seats_used
    FROM public.license_seats
    WHERE organization_id = p_organization_id;

    IF EXISTS (
        SELECT 1 FROM public.license_seats
        WHERE organization_id = p_organization_id
          AND user_id = p_user_id
          AND seat_status = 'assigned'
    ) THEN
        v_is_licensed := TRUE;
        v_user_seat_status := 'assigned';
    END IF;

    RETURN QUERY SELECT v_is_licensed, v_seats_total, v_seats_used, v_user_seat_status;
END;
$$;
