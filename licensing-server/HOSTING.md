# Free hosting choice — Cloudflare

Recommended starting point: **Cloudflare Workers + D1**, subject to the free plan's limits. The existing GitHub Pages website can stay where it is. The Workers implementation is prepared in `../licensing-worker/`. Create a D1 database, apply migration 0001, and configure your account and database IDs locally. Worker deployment requires `workers_scripts:write`; connect Stripe sandbox secrets separately.

Checked October 24, 2026:

- Workers Free: 100,000 requests/day and 10 ms CPU/request. https://developers.cloudflare.com/workers/platform/pricing/
- D1 Free: 5 million rows read/day, 100,000 rows written/day and 5 GB total storage. https://developers.cloudflare.com/d1/platform/pricing/
- Free-plan quotas must be monitored. Per-minute license refreshes and database writes consume the quotas; free hosting is not an unlimited-capacity promise.

## Cloudflare implementation

The Python/Gunicorn reference service remains available. The JavaScript Worker preserves its API contract and uses D1 transactions, database seat-limit triggers and expiring per-license billing locks. Its 23 tests pass against the local Cloudflare D1 runtime; Stripe is simulated in these tests. On 26 October 2026, the hosted test Worker also passed a real Stripe sandbox checkout, signed webhook processing, paid entitlement refresh, cancellation at period end and immediate cancellation/revocation. See `../licensing-worker/README.md` for deployment status. The separate live Worker is connected, and live checkout/portal creation passed without a real payment. Mac 0.8.0 enables live licensing.

Explicitly verify concurrent trial creation, atomic device-seat limits, checkout idempotency, signature verification, webhook ordering and revocation against the hosted database. Use indexed queries and avoid writing a new rate-limit record on every entitlement check. Cloudflare-managed secrets must hold the Stripe test key and webhook secret; they must never enter the public website, Swift bundle or source control.

Use separate test and production databases/Worker environments. Complete Stripe sandbox end-to-end tests before configuring live credentials or shipping Luma 0.8.0.

## Why not the current server on Render Free?

Render Free cannot attach a persistent disk. Local SQLite changes are lost on restart, redeploy or spin-down, and free Postgres expires after 30 days. That is unsuitable for retaining licensing records. Source: https://render.com/docs/free

## Stripe configuration already created

Keep your **sandbox-only** product and €4 monthly Price ID in local, ignored deployment settings. Do not use that Price ID with a live Stripe key. The 72-hour trial remains in Luma, not in the Stripe product.
