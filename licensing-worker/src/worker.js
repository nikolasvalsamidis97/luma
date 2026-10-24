// No provider credentials or media enter this service. Stripe secrets stay in Workers secrets.
export const TRIAL_SECONDS = 72 * 60 * 60;
export const LEASE_SECONDS = 300;
const encoder = new TextEncoder();
export class Problem extends Error {
  constructor(status, message) { super(message); this.status = status; }
}
const hex = bytes => Array.from(new Uint8Array(bytes), b => b.toString(16).padStart(2, '0')).join('');
export const random = (bytes = 32) => hex(crypto.getRandomValues(new Uint8Array(bytes)));
export const digest = async value => hex(await crypto.subtle.digest('SHA-256', encoder.encode(value)));
const newKey = () => 'LUMA-' + random(24).toUpperCase();
const idPattern = /^[a-f0-9]{64}$/;
function identity(data) {
  if (typeof data.device !== 'string' || typeof data.token !== 'string' ||
      !idPattern.test(data.device) || !idPattern.test(data.token)) throw new Problem(400, 'Invalid device identity.');
  return data;
}

export class Service {
  constructor(env, { clock = () => Math.floor(Date.now() / 1000), stripe } = {}) {
    this.env = env; this.db = env.DB; this.now = clock;
    this.stripe = stripe || this.stripeRequest.bind(this);
  }
  statement(sql, ...args) { return this.db.prepare(sql).bind(...args); }
  async row(id) { return this.statement('SELECT * FROM licenses WHERE id=?', id).first(); }
  configured() {
    const key = this.env.STRIPE_SECRET_KEY || '';
    return Boolean(this.env.STRIPE_PRICE_ID && /^https:\/\//.test(this.env.LUMA_PUBLIC_URL || '') &&
      (this.env.BILLING_MODE === 'test' ? /^(sk|rk)_test_/.test(key) :
        this.env.BILLING_MODE === 'live' && /^(sk|rk)_live_/.test(key)));
  }
  grant(row) {
    const now = this.now(); let status = 'expired', end = now;
    if (!row.revoked) {
      if (row.kind === 'developer') { status = 'developer'; end = now + LEASE_SECONDS; }
      else if (row.paid_until > now) { status = 'active'; end = row.paid_until; }
      else if (row.trial_end > now) { status = 'trial'; end = row.trial_end; }
    }
    return { status, serverTime: now, validUntil: Math.min(end, now + LEASE_SECONDS),
      accessUntil: end, trialEndsAt: row.trial_end, priceLabel: '€4/month',
      billingAvailable: this.configured() && row.kind !== 'developer' && !row.revoked,
      hasSubscription: Boolean(row.subscription) };
  }
  async authenticate(token) {
    if (typeof token !== 'string' || !idPattern.test(token)) throw new Problem(401, 'Activate Luma on this Mac first.');
    const row = await this.statement('SELECT l.* FROM licenses l JOIN devices d ON d.license_id=l.id WHERE d.token_hash=?', await digest(token)).first();
    if (!row) throw new Problem(401, 'Activate Luma on this Mac first.');
    return row;
  }
  async register(data) {
    const { device, token } = identity(data), tokenHash = await digest(token);
    const key = newKey(), lid = random(16);
    // D1 batch is atomic. Only the winning request creates a license and its device.
    await this.db.batch([
      this.statement(`INSERT INTO licenses(id,key_hash,kind,trial_end,seats)
        SELECT ?,?,'standard',?,2 WHERE NOT EXISTS(SELECT 1 FROM trial_devices WHERE device=?)
        AND NOT EXISTS(SELECT 1 FROM devices WHERE device=?)`, lid, await digest(key), this.now() + TRIAL_SECONDS, device, device),
      this.statement('INSERT OR IGNORE INTO trial_devices SELECT ? WHERE EXISTS(SELECT 1 FROM licenses WHERE id=?)', device, lid),
      this.statement('INSERT INTO devices SELECT ?,?,? WHERE EXISTS(SELECT 1 FROM licenses WHERE id=?)', device, tokenHash, lid, lid)
    ]);
    const deviceRow = await this.statement('SELECT * FROM devices WHERE device=?', device).first();
    if (!deviceRow || deviceRow.token_hash !== tokenHash) throw new Problem(409, 'This Mac has already been activated. Enter your product key to restore access.');
    const result = this.grant(await this.row(deviceRow.license_id));
    if (deviceRow.license_id === lid) result.productKey = key;
    return result;
  }
  async activate(data) {
    const { device, token } = identity(data);
    const key = typeof data.productKey === 'string' ? data.productKey.trim().toUpperCase() : '';
    if (!/^LUMA-[A-F0-9]{48}$/.test(key)) throw new Problem(400, 'Enter a valid Luma product key.');
    const keyHash = await digest(key);
    const row = await this.statement('SELECT * FROM licenses WHERE key_hash=?', keyHash).first();
    if (!row || row.revoked) throw new Problem(403, 'This product key is invalid or has been revoked.');
    try {
      const results = await this.db.batch([
        this.statement(`INSERT INTO devices(device,token_hash,license_id)
          SELECT ?,?,id FROM licenses WHERE id=? AND key_hash=? AND revoked=0
          ON CONFLICT(device) DO UPDATE SET token_hash=excluded.token_hash,license_id=excluded.license_id`,
          device, await digest(token), row.id, keyHash),
        this.statement('INSERT OR IGNORE INTO trial_devices VALUES(?)', device)
      ]);
      if (!results[0].meta.changes) throw new Problem(403, 'This product key is invalid or has been revoked.');
    } catch (e) {
      if (String(e).includes('seat_limit')) throw new Problem(409, 'This product key has reached its Mac limit. Contact support to release an old activation.');
      if (String(e).includes('license_revoked')) throw new Problem(403, 'This product key has been revoked.');
      throw e;
    }
    return this.grant(await this.row(row.id));
  }
  async recoveryKey(token) {
    const row = await this.authenticate(token);
    if (row.kind !== 'standard' || row.revoked) throw new Problem(403, 'Contact the key issuer to restore this key.');
    const key = newKey();
    const result = await this.statement('UPDATE licenses SET key_hash=? WHERE id=? AND key_hash=? AND revoked=0', await digest(key), row.id, row.key_hash).run();
    if (!result.meta.changes) throw new Problem(409, 'The key changed. Refresh access and try again.');
    return { productKey: key };
  }
  async rateLimit(peer, route) {
    // Entitlement polling only reads indexed records; it does not consume D1 writes.
    if (route === '/v1/entitlement') return;
    const now = this.now(), window = route === '/v1/trial' ? 3600 : 60;
    const cap = ['/v1/trial', '/v1/activate', '/v1/recovery-key'].includes(route) ? 10 : 30;
    const bucket = await digest(peer) + route + Math.floor(now / window);
    const result = await this.statement(`INSERT INTO limits VALUES(?,1,?)
      ON CONFLICT(bucket) DO UPDATE SET count=count+1 WHERE count<? RETURNING count`, bucket, now + window, cap).first();
    if (!result) throw new Problem(429, 'Too many attempts. Please try again later.');
  }
  async withBillingLock(lid, action) {
    const token = random(16);
    const acquired = await this.statement('UPDATE licenses SET billing_lock_token=?,billing_lock_until=? WHERE id=? AND billing_lock_until<=?', token, this.now() + 120, lid, this.now()).run();
    if (!acquired.meta.changes) throw new Problem(503, 'Billing is updating. Please try again shortly.');
    const update = async (sql, ...args) => {
      const result = await this.statement(sql + ' AND billing_lock_token=? AND billing_lock_until>?', ...args, token, this.now()).run();
      if (!result.meta.changes) throw new Problem(503, 'Billing is updating. Please try again shortly.');
    };
    try { return await action(await this.row(lid), update); }
    finally { await this.statement('UPDATE licenses SET billing_lock_token=NULL,billing_lock_until=0 WHERE id=? AND billing_lock_token=?', lid, token).run(); }
  }
  async stripeRequest(method, path, fields, idempotency) {
    if (!this.configured()) throw new Problem(503, 'Subscriptions are not available yet.');
    const headers = { Authorization: 'Bearer ' + this.env.STRIPE_SECRET_KEY, 'Stripe-Version': '2025-02-24.acacia' };
    if (idempotency) headers['Idempotency-Key'] = idempotency;
    try {
      const response = await fetch('https://api.stripe.com/v1/' + path, {
        method, headers, body: fields ? new URLSearchParams(fields) : undefined,
        signal: AbortSignal.timeout(15000)
      });
      if (!response.ok) throw new Error('Stripe request failed');
      return await response.json();
    } catch { throw new Problem(503, 'Billing is temporarily unavailable. Please try again.'); }
  }
  async syncCustomer(row, update) {
    // Read canonical state; an old webhook must not overwrite a newer subscription.
    const response = await this.stripe('GET', 'subscriptions?' + new URLSearchParams({ customer: row.customer, status: 'all', limit: '100' }));
    if (response.has_more) throw new Problem(503, 'Billing needs support review.');
    const matching = response.data.filter(s => s.customer === row.customer &&
      s.items?.data?.some(i => i.price?.id === this.env.STRIPE_PRICE_ID));
    const selected = matching.find(s => s.status === 'active' && !s.pause_collection) ||
      matching.find(s => s.id === row.subscription) || matching[0];
    if (selected) {
      let end = Number(selected.current_period_end || Math.max(0, ...selected.items.data.map(i => i.current_period_end || 0)));
      if (selected.status !== 'active' || selected.pause_collection || !Number.isSafeInteger(end)) end = 0;
      await update('UPDATE licenses SET subscription=?,paid_until=?,billing_status=?,checked_at=? WHERE id=?', selected.id, end, selected.status, this.now(), row.id);
    } else {
      await update("UPDATE licenses SET paid_until=0,billing_status='canceled',checked_at=? WHERE id=?", this.now(), row.id);
    }
    return this.row(row.id);
  }
  async refresh(token) {
    let row = await this.authenticate(token);
    if (row.customer && !row.revoked && this.now() - row.checked_at >= 60) {
      row = await this.withBillingLock(row.id, async (fresh, update) =>
        this.now() - fresh.checked_at >= 60 ? this.syncCustomer(fresh, update) : fresh);
    }
    return this.grant(row);
  }
  async checkout(token) {
    if (!this.configured()) throw new Problem(503, 'Subscriptions are not available yet.');
    const original = await this.authenticate(token);
    return this.withBillingLock(original.id, async (row, update) => {
      if (row.revoked || row.kind === 'developer') throw new Problem(409, 'This license does not need a subscription.');
      if (row.trial_end > this.now()) throw new Problem(409, 'Enjoy your free trial first. Subscribe when it ends.');
      if (row.customer) {
        row = await this.syncCustomer(row, update);
        if (row.subscription && !['canceled', 'incomplete_expired'].includes(row.billing_status)) return this.portalFor(row);
      }
      if (row.checkout) {
        const session = await this.stripe('GET', 'checkout/sessions/' + row.checkout);
        if (session.status === 'open') return { url: session.url };
        // Completed checkout is followed by the canonical customer lookup above.
      }
      const price = await this.stripe('GET', 'prices/' + this.env.STRIPE_PRICE_ID);
      if (!price.active || price.currency !== 'eur' || price.unit_amount !== 400 ||
          price.recurring?.interval !== 'month' || price.recurring.interval_count !== 1) {
        throw new Problem(503, 'The €4 monthly plan is not configured correctly.');
      }
      let customer = row.customer;
      if (!customer) {
        customer = (await this.stripe('POST', 'customers', { 'metadata[luma_license]': row.id }, 'customer-' + row.id)).id;
        await update('UPDATE licenses SET customer=? WHERE id=?', customer, row.id);
      }
      const generation = row.checkout_generation + 1;
      const base = this.env.LUMA_PUBLIC_URL.replace(/\/$/, '');
      const session = await this.stripe('POST', 'checkout/sessions', {
        mode: 'subscription', customer, 'line_items[0][price]': this.env.STRIPE_PRICE_ID,
        'line_items[0][quantity]': '1', success_url: base + '/billing/return', cancel_url: base + '/billing/cancel',
        client_reference_id: row.id, 'subscription_data[metadata][luma_license]': row.id,
        'payment_method_types[0]': 'card'
      }, `checkout-${row.id}-${generation}`);
      await update('UPDATE licenses SET checkout=?,checkout_generation=? WHERE id=?', session.id, generation, row.id);
      return { url: session.url };
    });
  }
  async portalFor(row) {
    if (!row.customer) throw new Problem(409, 'There is no billing account for this license yet.');
    const fields = { customer: row.customer, return_url: this.env.LUMA_PUBLIC_URL.replace(/\/$/, '') + '/billing/return' };
    if (this.env.STRIPE_PORTAL_CONFIGURATION) fields.configuration = this.env.STRIPE_PORTAL_CONFIGURATION;
    return { url: (await this.stripe('POST', 'billing_portal/sessions', fields)).url };
  }
  async portal(token) { return this.portalFor(await this.authenticate(token)); }
  async webhook(raw, signature) {
    if (!this.env.STRIPE_WEBHOOK_SECRET) throw new Problem(503, 'Webhooks are not configured.');
    const parts = signature.split(',').map(p => p.split('='));
    const stampText = parts.find(p => p[0] === 't')?.[1] || '';
    const stamp = /^\d+$/.test(stampText) ? Number(stampText) : NaN;
    if (!Number.isSafeInteger(stamp) || Math.abs(this.now() - stamp) > 300) throw new Problem(400, 'Invalid webhook signature.');
    const key = await crypto.subtle.importKey('raw', encoder.encode(this.env.STRIPE_WEBHOOK_SECRET), { name: 'HMAC', hash: 'SHA-256' }, false, ['verify']);
    const payload = encoder.encode(stampText + '.' + raw);
    let valid = false;
    for (const [name, value] of parts) {
      if (name === 'v1' && /^[a-f0-9]{64}$/.test(value || '')) {
        valid = await crypto.subtle.verify('HMAC', key, Uint8Array.from(value.match(/../g), b => parseInt(b, 16)), payload) || valid;
      }
    }
    if (!valid) throw new Problem(400, 'Invalid webhook signature.');
    let event;
    try { event = JSON.parse(raw); } catch { throw new Problem(400, 'Invalid webhook event.'); }
    if (typeof event?.id !== 'string' || typeof event.type !== 'string' || !event.data?.object ||
        event.livemode !== (this.env.BILLING_MODE === 'live')) throw new Problem(400, 'Invalid webhook event or billing mode.');
    if (await this.statement('SELECT 1 FROM events WHERE id=?', event.id).first()) return { received: true };
    if (event.type.startsWith('customer.subscription.') || ['checkout.session.completed', 'checkout.session.async_payment_succeeded', 'invoice.paid', 'invoice.payment_failed'].includes(event.type)) {
      const customer = event.data.object.customer;
      const row = typeof customer === 'string' ? await this.statement('SELECT * FROM licenses WHERE customer=?', customer).first() : null;
      if (row) await this.withBillingLock(row.id, (fresh, update) => this.syncCustomer(fresh, update));
    }
    await this.statement('INSERT OR IGNORE INTO events VALUES(?,?)', event.id, this.now()).run();
    return { received: true };
  }
}

const routes = ['/v1/trial', '/v1/activate', '/v1/entitlement', '/v1/recovery-key', '/v1/checkout', '/v1/portal'];
export async function handle(request, env) {
  const headers = { 'Content-Type': 'application/json', 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' };
  try {
    const path = new URL(request.url).pathname;
    if (request.method === 'GET' && path === '/health') return Response.json({ ok: true }, { headers });
    if (request.method === 'GET' && ['/billing/return', '/billing/cancel'].includes(path)) {
      return new Response('<!doctype html><html lang="en"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Luma billing</title><body style="background:#0d0f14;color:#fff;font:20px system-ui;padding:10vw"><h1>Return to Luma</h1><p>Open Luma and choose Refresh access. Your subscription activates only after payment is confirmed.</p></body></html>', { headers: { ...headers, 'Content-Type': 'text/html; charset=utf-8', 'Content-Security-Policy': "default-src 'none'; style-src 'unsafe-inline'; frame-ancestors 'none'" } });
    }
    if (request.method !== 'POST' || (!routes.includes(path) && path !== '/v1/stripe/webhook')) throw new Problem(404, 'Not found.');
    if (Number(request.headers.get('content-length')) > 262144) throw new Problem(413, 'Request too large.');
    // Read with a hard limit even when Content-Length is absent or dishonest.
    const reader = request.body?.getReader(); const chunks = []; let size = 0;
    if (reader) while (true) {
      const { value, done } = await reader.read(); if (done) break;
      size += value.length;
      if (size > 262144) { await reader.cancel(); throw new Problem(413, 'Request too large.'); }
      chunks.push(value);
    }
    const bytes = new Uint8Array(size); let offset = 0;
    for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length; }
    const raw = new TextDecoder().decode(bytes), service = new Service(env); let result;
    if (path === '/v1/stripe/webhook') result = await service.webhook(raw, request.headers.get('stripe-signature') || '');
    else {
      await service.rateLimit(request.headers.get('CF-Connecting-IP') || 'local', path);
      let data;
      try { data = JSON.parse(raw || '{}'); } catch { throw new Problem(400, 'Invalid JSON.'); }
      if (!data || typeof data !== 'object' || Array.isArray(data)) throw new Problem(400, 'Invalid request.');
      const auth = request.headers.get('authorization') || '', token = auth.startsWith('Bearer ') ? auth.slice(7) : '';
      if (path === '/v1/trial') result = await service.register(data);
      else if (path === '/v1/activate') result = await service.activate(data);
      else if (path === '/v1/entitlement') result = await service.refresh(token);
      else if (path === '/v1/recovery-key') result = await service.recoveryKey(token);
      else if (path === '/v1/checkout') result = await service.checkout(token);
      else result = await service.portal(token);
    }
    return Response.json(result, { headers });
  } catch (error) {
    return Response.json({ error: error instanceof Problem ? error.message : 'Licensing is temporarily unavailable. Please try again.' }, { status: error instanceof Problem ? error.status : 503, headers });
  }
}
export default {
  fetch: handle,
  async scheduled(_event, env) {
    await env.DB.prepare('DELETE FROM limits WHERE expires < ?').bind(Math.floor(Date.now() / 1000)).run();
  }
};
