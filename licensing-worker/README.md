# Luma licensing on Cloudflare

Workers + D1 implementation of the existing macOS licensing API. The client needs no additional software. Node/Wrangler are developer tools only. The checked-in configuration is **Stripe sandbox only**; no live payments are enabled.

## Local development

Use Node 24 LTS, `npm ci`, then `npm test`. On this Mac, the verified official Node distribution is in `../.tools/node-v24.22.1-darwin-arm64/bin`; add it to PATH for these commands. All 23 tests pass. Tests run the actual D1 implementation in Cloudflare's local runtime and use a simulated Stripe API. They cover concurrent trials/seats/checkout, expiry, token restoration, revocation, renewal, cancellation, webhook signatures/order/retries, body limits and rate limits. They do not substitute for Stripe sandbox end-to-end testing.

Wrangler and Miniflare are development dependencies only. Undici is overridden to the patched 7.30.1-or-newer line; the installed dependency audit is clean.

## First test deployment

1. Authenticate Wrangler with account/user read, Workers write, Workers scripts write, Workers routes write, D1 write, and offline access. Review its Cloudflare authorization screen first.
2. `npx wrangler d1 create luma-licenses-test --location weur`
3. Put the returned database ID in `wrangler.jsonc`. No database ID is fabricated in the template.
4. `npx wrangler d1 migrations apply luma-licenses-test --remote`
5. `npm run deploy`. Register the account's workers.dev subdomain if prompted. Set `LUMA_PUBLIC_URL` to the returned HTTPS URL and redeploy. No custom domain or paid plan is necessary for this setup.
6. Store sandbox `STRIPE_SECRET_KEY` via `npx wrangler secret put STRIPE_SECRET_KEY`. Never place it in the config, app, website, screenshots or chat.
7. In the Luma **Stripe sandbox**, create a webhook destination at `https://YOUR-WORKER/v1/stripe/webhook` for `checkout.session.completed`, `checkout.session.async_payment_succeeded`, `customer.subscription.created`, `customer.subscription.updated`, `customer.subscription.deleted`, `invoice.paid`, and `invoice.payment_failed`. Use API version `2025-02-24.acacia` where a version is requested. Store its signing secret with `npx wrangler secret put STRIPE_WEBHOOK_SECRET`.
8. Test the public service using synthetic device identities. A new trial lasts exactly 72 hours; to exercise checkout immediately, expire only that synthetic license using D1 admin SQL. Complete a sandbox checkout, refresh in Luma, cancel at period end, and verify an unpaid/canceled subscription loses access. Build an isolated licensed test app with `LUMA_LICENSE_SERVER_URL=https://YOUR-WORKER ./scripts/build-app.sh --licensed` from the project root. Do not overwrite the public 0.7.0 download yet.

Copy `wrangler.example.jsonc` to `wrangler.jsonc`, then fill in your Cloudflare account, D1 database, Stripe sandbox Price and portal configuration IDs. The actual deployment configuration and any local `../licensing-server/stripe-test-config.json` are ignored by Git. Cloudflare configuration pins test mode and rejects live keys/events in that mode. Payment links stay unavailable until the sandbox key and HTTPS return URL are configured. Trial registration and developer-key activation work independently of Stripe.

## Developer product keys

`node admin.js issue 2 "Developer name"` writes a private key file and hashed SQL in ignored `private/` (directory mode 0700, files 0600). Apply the SQL using `npx wrangler d1 execute luma-licenses-test --remote --file PATH`. Send the key privately yourself. The console does not print it. Keys are individual, high-entropy and revocable; there is no universal bypass key.

`node admin.js revoke LICENSE_ID` or `node admin.js release-device LICENSE_ID DEVICE_HASH` prepares the matching SQL. Review/apply it to the intended environment. Releasing a device never removes its trial history. Revocation takes effect on the next refresh, at most the existing five-minute lease.

## Reliability, limits and data

Trial registration is one D1 transaction; seat limits use database triggers to survive concurrent Worker isolates. Billing operations use an expiring per-license lock and Stripe idempotency keys. Webhooks verify the raw body with HMAC and a five-minute timestamp window, reject the wrong mode, and query current Stripe state. Hourly cleanup deletes expired rate-limit counters. Entitlement checks use indexed reads and avoid per-request rate-limit writes. Payment checks are limited to once per minute per license.

Stored data: hashed device identity, hashed activation token/product key, trial/access dates, activation seats, Stripe customer/subscription/session IDs and processed webhook IDs. Provider credentials, channel lists, watching history and media never enter this service. Card details go directly to Stripe Checkout. The app intentionally requires online verification at launch; existing access can survive a brief outage only until its five-minute lease ends.

The hash is a deterrent to casual trial resets, not hardware attestation: a modified client can spoof identities or bypass local gates. Monitor Cloudflare quotas; each active paying license can cause several D1 writes per minute. Free hosting has finite capacity. See `../licensing-server/HOSTING.md` for checked quotas and sources.

## Before a paid public release

Use a separate production Worker and D1 database, a live €4 EUR monthly Price and portal configuration, and live secrets. Change billing mode only in that production environment. Finish sandbox verification first, update the public privacy/pricing/support information, and configure the signed production app URL. Test-mode developer keys and trial records do not transfer to production. Keep the current free release and its privacy notice unchanged until the paid release is ready.
