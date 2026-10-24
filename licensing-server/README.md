# Luma licensing and subscriptions

Prepared integration: **72 hours free, no card**, then an optional **€4 monthly subscription**. Developer product keys unlock full access without payment. Configure a €4/month product and customer portal in your own Stripe sandbox; keep their identifiers in local deployment settings. Backend API credentials are not connected and the service is not deployed yet. See [free hosting plan](HOSTING.md) for the recommended Cloudflare adaptation. The public 0.7.x releases remain free; it cannot be retroactively locked by this service.

## What is implemented

- Explicit Start trial action, with an expiry calculated by the server. Opening the app does not start the clock.
- A trial record per hashed Mac hardware identifier. Normal reinstall or Keychain removal does not restart it. This is practical anti-reset protection, not tamper-proof DRM: a modified client can spoof an identifier or bypass client code. A different Mac is a separate trial.
- Private activation tokens and recovery product keys in macOS Keychain. Only their SHA-256 hashes are stored in the database. No shared developer password or admin secret is embedded in Luma.
- Individual developer keys, configurable Mac limits, revocation and releasing an old Mac activation. Default limit: two Macs per license. Developer keys need an online check just like subscriptions.
- Server-verified access on launch and every minute. In-memory access leases last at most five minutes, never past the known trial/paid expiry. Continuous monotonic time includes sleep and resists wall-clock rollback. No offline receipt is saved. Service outages stop playback after the remaining lease expires; keep this service monitored and available.
- Stripe-hosted recurring checkout and cancellation/customer portal. No checkout until the free trial ends. The server verifies the configured price is active and exactly EUR 400 cents per month. No card details pass through Luma or this server.
- Signed Stripe webhooks, tolerance/replay checks, deduplication and retries. Current Stripe state is fetched instead of trusting old webhook payloads. Unpaid, past-due, canceled, incomplete or paused subscriptions do not unlock playback. Cancellation at period end keeps access while Stripe still reports an active paid period.
- An existing open Checkout session is reused; an existing subscription leads to the billing portal, avoiding a second subscription. Merely visiting the success page never grants access.

## Remaining account setup

1. Create and activate **your own Stripe account**, complete Stripe's verification, and connect your payout bank account. Customers pay your Stripe account; payouts go to your connected bank after applicable fees. Account creation and bank details must be completed by you, not shared in chat.
2. In Stripe's **test environment**, create a Luma product and recurring monthly EUR price for **400 cents**. Configure the intended tax treatment and customer-facing business/support information before accepting real payments. The code does not add automatic tax or decide your tax obligations. The displayed plan is €4/month; ensure the final checkout matches the advertised price.
3. Enable Stripe's customer portal with cancellation and payment-method updates. Set your business privacy/terms/support details. Do not allow switching to unrelated products.
4. Host the backend below on an HTTPS service with a **persistent disk**, then configure its secrets using the host's secret/environment settings. GitHub Pages can continue hosting the marketing site, but cannot run this backend.
5. Register a **snapshot** webhook at `https://YOUR-HOST/v1/stripe/webhook`, using API version `2025-02-24.acacia` (also pinned in the server's Stripe client). Subscribe to `checkout.session.completed`, `checkout.session.async_payment_succeeded`, `customer.subscription.created`, `customer.subscription.updated`, `customer.subscription.deleted`, `invoice.paid`, and `invoice.payment_failed`. The endpoint rereads Stripe state, so duplicate and out-of-order deliveries are safe.
6. Run real Stripe test checkout, renewal, failed renewal, cancellation, restoration and webhook retry tests. The automated tests here use a fake Stripe service; they do not substitute for an account-connected end-to-end test.
7. Switch backend secrets, webhook secret and Price ID to the matching **live** environment only when ready. Update the public privacy page with licensing data collection, price and subscription details before releasing the licensed app. The existing site's privacy text describes the free 0.7.0 build.

Official references: [Checkout](https://docs.stripe.com/api/checkout/sessions/create), [webhooks](https://docs.stripe.com/webhooks), [customer portal](https://docs.stripe.com/customer-management), [payout bank account](https://support.stripe.com/questions/add-a-bank-account-for-payouts).

## Host the backend

Use Python 3.13 and Gunicorn, or build the supplied Dockerfile. Keep the SQLite file on a persistent volume; losing it loses trial history and licenses. Run **one service replica** with this SQLite architecture, take encrypted backups, and put it behind a managed HTTPS reverse proxy. Gunicorn is bound to the private HTTP port; expose only the proxy to the internet. Do not deploy the test fixture or test-only endpoints.

```sh
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
# Configure the environment variables from .env.example in your host's secret settings.
.venv/bin/gunicorn --bind 127.0.0.1:8080 --workers 1 --threads 4 --timeout 120 wsgi:application
```

Environment: `LUMA_DB`, `LUMA_PUBLIC_URL` (HTTPS), `STRIPE_SECRET_KEY`, `STRIPE_PRICE_ID`, `STRIPE_WEBHOOK_SECRET`. With no Stripe configuration, trials and developer keys work but subscriptions remain unavailable. Production requests never return secrets or internal exception details. Rate limits use the direct peer address, not an untrusted forwarded header; a shared proxy address shares the application limit, so configure appropriate per-client rate limiting at your trusted edge when scaling.

Use a restricted OS account and private database permissions. Do not upload `.env`, SQLite files, issued product keys or private deployment output to the public website repository.

## Build the licensed Mac app

After the HTTPS backend is deployed:

```sh
LUMA_LICENSE_SERVER_URL=https://YOUR-HOST ./scripts/build-app.sh --licensed
```

This creates **`dist/Luma-licensed.zip`, version 0.8.0**, with the public backend URL in its Info.plist. Only the URL goes into the app; no Stripe secret goes there. Normal builds remain version 0.7.0 with legacy free access. The flags are a build-time rollout safeguard, not anti-tamper protection. Add `--install` only when ready to replace your installed app. Apply Developer ID signing/notarization as part of public release preparation.

Choose **Luma → Luma Access…** for the trial, product-key activation, copying the recovery key, refreshing access, and managing/canceling billing. Save the recovery product key privately before moving to a different Mac. Subscription entitlement is restored with that key. If the key is lost and no activated Mac remains, support must verify ownership in Stripe and rotate the account's key on the backend; there is no email-based self-service recovery yet.

## Developer keys

Run these on the host using the same `LUMA_DB` as the running service:

```sh
python3 admin.py issue --label 'Developer name' --macs 2
python3 admin.py revoke LICENSE_ID
python3 admin.py release-device LICENSE_ID HASHED_DEVICE_ID
```

Issuing prints the key **once**. Share it privately with its developer. Revoking blocks future checks; an already-issued lease can remain valid for at most five minutes. Releasing an old Mac frees a seat but retains that Mac's used-trial record. There is no public admin endpoint.

## Verification

From the project root:

```sh
python3 -m unittest discover -s licensing-server -p 'test_*.py'
swift run StreamCoreChecks
./scripts/check-licensing.sh
./scripts/check-licensing.sh --manual
```

The native check uses a loopback-only test service and isolated Keychain service, never a provider account, live Stripe account or production key. It tests trial activation, persistence, invalid-key rejection, developer activation and revocation. `--manual` leaves the activation screen open for inspection.

## Data and support

The licensing service holds a hashed Mac identifier, hashed activation token, hashed recovery key, trial end, device-to-license mapping, Stripe customer/subscription IDs and access state. Developer labels are operator-supplied. Rate buckets contain a hashed peer address and expire automatically. No Xtream credentials, media URLs or watch history are sent to it. Stripe holds customer billing/contact details. Plan retention, support verification and account deletion handling before public launch; deleting all trial records allows a future new trial on that Mac.
