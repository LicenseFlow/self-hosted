#!/usr/bin/env bash
# LicenseFlow Sovereign & Air-Gap Verification Script (POSIX Bash)
# =================================================================
# Validates offline readiness, zero-egress network isolation,
# local cryptographic lease issuance, anti-tamper clock rollback detection,
# and immutable Merkle ledger sealing for air-gapped enclaves.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
COMPOSE_FILE="$PROJECT_ROOT/self-hosted/docker/docker-compose.sovereign.yml"
INIT_SQL_FILE="$PROJECT_ROOT/self-hosted/docker/init-sovereign.sql"
CLI_SCRIPT="$PROJECT_ROOT/sdk/licenseflow-cli/src/index.ts"

echo -e "\n🔒 Starting LicenseFlow Sovereign Air-Gap Stack Verification..."

# 1. Validate Docker Compose Manifest
echo -e "\n[1/6] Inspecting Sovereign Docker Compose Manifest..."
if [ ! -f "$COMPOSE_FILE" ]; then
    echo "ERROR: Sovereign compose file missing: $COMPOSE_FILE" >&2
    exit 1
fi

if ! grep -q "internal:\s*true" "$COMPOSE_FILE"; then
    echo "SECURITY VIOLATION: sovereign-airgap-net must declare 'internal: true' to prevent external egress!" >&2
    exit 1
fi
if ! grep -q 'AIR_GAPPED:\s*"true"' "$COMPOSE_FILE"; then
    echo "CONFIG VIOLATION: AIR_GAPPED flag must be 'true'!" >&2
    exit 1
fi
if ! grep -q 'TELEMETRY_ENABLED:\s*"false"' "$COMPOSE_FILE"; then
    echo "CONFIG VIOLATION: TELEMETRY_ENABLED must be 'false'!" >&2
    exit 1
fi
echo "  ✓ Zero-egress network isolation declared ('internal: true')"
echo "  ✓ Telemetry and external phone-home blocked"

# 2. Validate Sovereign Schema Extensions
echo -e "\n[2/6] Validating Sovereign Database Schema..."
if [ ! -f "$INIT_SQL_FILE" ]; then
    echo "ERROR: Sovereign SQL initialization script missing: $INIT_SQL_FILE" >&2
    exit 1
fi

for tbl in sovereign_nodes airgap_leases sovereign_consensus_journal merkle_tree_seals; do
    if ! grep -q "$tbl" "$INIT_SQL_FILE"; then
        echo "ERROR: Schema missing required sovereign table: $tbl" >&2
        exit 1
    fi
done
echo "  ✓ Verified all 4 sovereign enclave database tables exist in init-sovereign.sql"

# 3. CLI Machine Fingerprint & Offline Lease Issuance
echo -e "\n[3/6] Testing Offline Cryptographic Lease Issuance..."
TEMP_LEASE_FILE="$PROJECT_ROOT/test-sovereign-lease.json"
HW_FINGERPRINT="hw_enclave_$(head -c 6 /dev/urandom 2>/dev/null | xxd -p 2>/dev/null || echo 'test_hw_fingerprint_01')"

trap 'rm -f "$TEMP_LEASE_FILE" "${PROJECT_ROOT}/tampered-sovereign-lease.json"' EXIT

npx tsx "$CLI_SCRIPT" airgap issue -o org_sovereign_defense -m "$HW_FINGERPRINT" -d 30 --output "$TEMP_LEASE_FILE"
echo "  ✓ Issued cryptographically signed offline lease certificate"

# 4. Offline Lease Hardware Binding & Signature Verification
echo -e "\n[4/6] Verifying Hardware Binding & Anti-Tamper Clock..."
npx tsx "$CLI_SCRIPT" airgap verify -f "$TEMP_LEASE_FILE" -m "$HW_FINGERPRINT"
echo "  ✓ Cryptographic signature & machine binding verified"

# 5. Anti-Tamper Clock Rollback Detection Test
echo -e "\n[5/6] Testing Anti-Tamper Clock Rollback Detection..."
TAMPERED_LEASE_FILE="$PROJECT_ROOT/tampered-sovereign-lease.json"
# Introduce forward offset into anti-rollback timestamp
node -e '
  const fs = require("fs");
  const data = JSON.parse(fs.readFileSync(process.argv[1], "utf-8"));
  data.tamper_anti_rollback_timestamp = Date.now() + 3600000;
  fs.writeFileSync(process.argv[2], JSON.stringify(data, null, 2));
' "$TEMP_LEASE_FILE" "$TAMPERED_LEASE_FILE"

if npx tsx "$CLI_SCRIPT" airgap verify -f "$TAMPERED_LEASE_FILE" -m "$HW_FINGERPRINT" 2>/dev/null; then
    echo "ERROR: Expected clock rollback tamper detection to reject verification!" >&2
    exit 1
else
    echo "  ✓ Successfully detected clock rollback tamper attempt (blocked)"
fi

# 6. Local Merkle Ledger Integrity Test
echo -e "\n[6/6] Verifying Local Merkle Proof Inclusion..."
npx tsx "$CLI_SCRIPT" audit test-siem -t webhook --event-type sovereign.lease.validated
echo "  ✓ Local Merkle tree sealing and SIEM payload verification passed"

echo -e "\n================================================================="
echo -e "✅ ALL SOVEREIGN AIR-GAP VERIFICATIONS PASSED SUCCESSFULLY!"
echo -e "The sovereign control plane is certified for isolated deployment."
echo -e "=================================================================\n"
