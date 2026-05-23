#!/usr/bin/env node
// Seeds a minimal org / plan / API key / license set into the self-hosted bundle for SDK E2E tests.
// Emits GitHub Actions ::set-output style key=value lines on stdout.

const API_URL = process.env.API_URL || "http://localhost:8080";

async function post(path, body, headers = {}) {
  const res = await fetch(`${API_URL}${path}`, {
    method: "POST",
    headers: { "content-type": "application/json", ...headers },
    body: JSON.stringify(body),
  });
  if (!res.ok) throw new Error(`POST ${path} → ${res.status} ${await res.text()}`);
  return res.json();
}

async function main() {
  // 1. Bootstrap admin org (idempotent endpoint exposed by the bundle in CI mode)
  const bootstrap = await post("/_ci/bootstrap", {
    org: "e2e-org",
    plan: { name: "Pro", license_limit: 100, seat_limit: 10 },
  });

  const apiKey = bootstrap.api_key;
  const auth = { authorization: `Bearer ${apiKey}` };

  // 2. Create two licenses
  const active = await post("/v1/licenses", { product: "demo", seats: 3 }, auth);
  const revoked = await post("/v1/licenses", { product: "demo", seats: 1 }, auth);
  await post(`/v1/licenses/${revoked.id}/revoke`, {}, auth);

  console.log(`api_key=${apiKey}`);
  console.log(`license_key=${active.license_key}`);
  console.log(`revoked_license_key=${revoked.license_key}`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});