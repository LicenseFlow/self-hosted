-- LicenseFlow Sovereign Control Plane Schema Extensions
-- Dedicated tables for Air-Gapped Leases, Hardware Fingerprints, Heartbeat Consensus, and Merkle Ledger Seals

CREATE TABLE IF NOT EXISTS public.sovereign_nodes (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    node_id VARCHAR(128) UNIQUE NOT NULL,
    organization_id UUID NOT NULL,
    hostname VARCHAR(255) NOT NULL,
    hardware_fingerprint VARCHAR(255) NOT NULL,
    ip_address INET,
    consensus_state VARCHAR(50) DEFAULT 'ACTIVE' CHECK (consensus_state IN ('ACTIVE', 'GRACE_PERIOD', 'EXPIRED', 'REVOKED', 'TAMPER_LOCKED')),
    lamport_clock BIGINT DEFAULT 0,
    last_heartbeat_at TIMESTAMPTZ DEFAULT NOW(),
    grace_period_seconds INTEGER DEFAULT 86400,
    enclave_verified BOOLEAN DEFAULT FALSE,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.airgap_leases (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    lease_id VARCHAR(128) UNIQUE NOT NULL,
    license_id UUID,
    organization_id UUID NOT NULL,
    machine_fingerprint VARCHAR(255) NOT NULL,
    node_id VARCHAR(128) REFERENCES public.sovereign_nodes(node_id),
    issued_at TIMESTAMPTZ NOT NULL,
    expires_at TIMESTAMPTZ NOT NULL,
    grace_period_seconds INTEGER DEFAULT 86400,
    allocated_units JSONB DEFAULT '{}'::jsonb,
    permitted_features TEXT[] DEFAULT '{}',
    signature TEXT NOT NULL,
    key_id VARCHAR(128) NOT NULL,
    tamper_anti_rollback_timestamp BIGINT DEFAULT 0,
    status VARCHAR(50) DEFAULT 'VALID' CHECK (status IN ('VALID', 'EXPIRED', 'REVOKED', 'TAMPER_DETECTED')),
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.sovereign_consensus_journal (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    node_id VARCHAR(128) NOT NULL,
    organization_id UUID NOT NULL,
    lamport_timestamp BIGINT NOT NULL,
    operation_type VARCHAR(64) NOT NULL,
    payload JSONB NOT NULL,
    checksum VARCHAR(64) NOT NULL,
    committed_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.merkle_tree_seals (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id UUID NOT NULL,
    tree_root VARCHAR(64) NOT NULL,
    leaf_count INTEGER NOT NULL,
    algorithm VARCHAR(32) DEFAULT 'sha256',
    signature TEXT,
    signer_key_id VARCHAR(128),
    sealed_at TIMESTAMPTZ DEFAULT NOW()
);

-- Indices for high performance offline lookup
CREATE INDEX IF NOT EXISTS idx_sovereign_nodes_org ON public.sovereign_nodes(organization_id);
CREATE INDEX IF NOT EXISTS idx_airgap_leases_node ON public.airgap_leases(node_id);
CREATE INDEX IF NOT EXISTS idx_airgap_leases_machine ON public.airgap_leases(machine_fingerprint);
CREATE INDEX IF NOT EXISTS idx_sovereign_journal_lamport ON public.sovereign_consensus_journal(node_id, lamport_timestamp);
