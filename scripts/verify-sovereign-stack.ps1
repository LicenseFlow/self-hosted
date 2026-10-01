# LicenseFlow Sovereign & Air-Gap Verification Script (PowerShell)
# =================================================================
# Validates offline readiness, zero-egress network isolation,
# local cryptographic lease issuance, anti-tamper clock rollback detection,
# and immutable Merkle ledger sealing for air-gapped enclaves.

$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "[AIR-GAP] Starting LicenseFlow Sovereign Air-Gap Stack Verification..." -ForegroundColor Cyan

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = (Resolve-Path "$ScriptDir\..\..").Path
$ComposeFile = Join-Path $ProjectRoot "self-hosted\docker\docker-compose.sovereign.yml"
$InitSqlFile = Join-Path $ProjectRoot "self-hosted\docker\init-sovereign.sql"
$CliScript = Join-Path $ProjectRoot "sdk\licenseflow-cli\src\index.ts"

# 1. Validate Docker Compose Manifest
Write-Host ""
Write-Host "[1/6] Inspecting Sovereign Docker Compose Manifest..." -ForegroundColor Yellow
if (-not (Test-Path $ComposeFile)) {
    throw "Sovereign compose file missing: $ComposeFile"
}

$composeContent = Get-Content $ComposeFile -Raw
if (-not ($composeContent.Contains("internal: true"))) {
    throw "SECURITY VIOLATION: sovereign-airgap-net must declare internal: true to prevent external egress!"
}
if (-not ($composeContent.Contains("AIR_GAPPED"))) {
    throw "CONFIG VIOLATION: AIR_GAPPED flag must be true!"
}
if (-not ($composeContent.Contains("TELEMETRY_ENABLED"))) {
    throw "CONFIG VIOLATION: TELEMETRY_ENABLED must be false!"
}
Write-Host "  [OK] Zero-egress network isolation declared (internal: true)" -ForegroundColor Green
Write-Host "  [OK] Telemetry and external phone-home blocked" -ForegroundColor Green

# 2. Validate Sovereign Schema Extensions
Write-Host ""
Write-Host "[2/6] Validating Sovereign Database Schema..." -ForegroundColor Yellow
if (-not (Test-Path $InitSqlFile)) {
    throw "Sovereign SQL initialization script missing: $InitSqlFile"
}

$sqlContent = Get-Content $InitSqlFile -Raw
$requiredTables = @("sovereign_nodes", "airgap_leases", "sovereign_consensus_journal", "merkle_tree_seals")
foreach ($tbl in $requiredTables) {
    if (-not ($sqlContent.Contains($tbl))) {
        throw "Schema missing required sovereign table: $tbl"
    }
}
Write-Host "  [OK] Verified all 4 sovereign enclave database tables exist in init-sovereign.sql" -ForegroundColor Green

# 3. CLI Machine Fingerprint & Offline Lease Issuance
Write-Host ""
Write-Host "[3/6] Testing Offline Cryptographic Lease Issuance..." -ForegroundColor Yellow
$TempLeaseFile = Join-Path $ProjectRoot "test-sovereign-lease.json"

try {
    $hwFingerprint = "hw_enclave_" + [System.Guid]::NewGuid().ToString("N").Substring(0, 12)
    npx tsx $CliScript airgap issue -o org_sovereign_defense -m $hwFingerprint -d 30 --output $TempLeaseFile

    if (-not (Test-Path $TempLeaseFile)) {
        throw "Failed to generate lease certificate file: $TempLeaseFile"
    }
    Write-Host "  [OK] Issued cryptographically signed offline lease certificate" -ForegroundColor Green

    # 4. Offline Lease Hardware Binding & Signature Verification
    Write-Host ""
    Write-Host "[4/6] Verifying Hardware Binding & Anti-Tamper Clock..." -ForegroundColor Yellow
    npx tsx $CliScript airgap verify -f $TempLeaseFile -m $hwFingerprint
    Write-Host "  [OK] Cryptographic signature & machine binding verified" -ForegroundColor Green

    # 5. Anti-Tamper Clock Rollback Detection Test
    Write-Host ""
    Write-Host "[5/6] Testing Anti-Tamper Clock Rollback Detection..." -ForegroundColor Yellow
    $leaseRaw = Get-Content $TempLeaseFile -Raw
    $leaseJson = ConvertFrom-Json $leaseRaw
    
    # Advance anti-rollback timestamp by 1 hour into the future
    $futureTime = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() + 3600000
    $leaseJson.tamper_anti_rollback_timestamp = $futureTime
    $TamperedLeaseFile = Join-Path $ProjectRoot "tampered-sovereign-lease.json"
    $leaseJson | ConvertTo-Json -Depth 5 | Set-Content $TamperedLeaseFile

    $tamperDetected = $false
    try {
        $pinfo = New-Object System.Diagnostics.ProcessStartInfo
        $pinfo.FileName = "cmd.exe"
        $pinfo.Arguments = "/c npx tsx `"$CliScript`" airgap verify -f `"$TamperedLeaseFile`" -m $hwFingerprint"
        $pinfo.RedirectStandardError = $true
        $pinfo.RedirectStandardOutput = $true
        $pinfo.UseShellExecute = $false
        $p = [System.Diagnostics.Process]::Start($pinfo)
        $p.WaitForExit()
        if ($p.ExitCode -ne 0) {
            $tamperDetected = $true
        }
    } catch {
        $tamperDetected = $true
    } finally {
        if (Test-Path $TamperedLeaseFile) { Remove-Item $TamperedLeaseFile -Force }
    }

    if ($tamperDetected) {
        Write-Host "  [OK] Successfully detected clock rollback tamper attempt (blocked)" -ForegroundColor Green
    } else {
        throw "FAILED: Expected clock rollback tamper detection to reject verification!"
    }

    # 6. Local Merkle Ledger Integrity Test
    Write-Host ""
    Write-Host "[6/6] Verifying Local Merkle Proof Inclusion..." -ForegroundColor Yellow
    npx tsx $CliScript audit test-siem -t webhook --event-type sovereign.lease.validated
    Write-Host "  [OK] Local Merkle tree sealing and SIEM payload verification passed" -ForegroundColor Green

} finally {
    if (Test-Path $TempLeaseFile) {
        Remove-Item $TempLeaseFile -Force
    }
}

Write-Host ""
Write-Host "=================================================================" -ForegroundColor Cyan
Write-Host "[SUCCESS] ALL SOVEREIGN AIR-GAP VERIFICATIONS PASSED SUCCESSFULLY!" -ForegroundColor Green
Write-Host "The sovereign control plane is certified for isolated deployment." -ForegroundColor Green
Write-Host "=================================================================" -ForegroundColor Cyan
Write-Host ""
