import { test, before, after, beforeEach } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { build } from 'esbuild';
import { createHmac } from 'node:crypto';
import { Miniflare, convertV4MiniflareOptions } from 'miniflare';
import { Service, Problem, TRIAL_SECONDS, digest, random, handle } from '../src/worker.js';
let mf, db, s, now, env, stripe, ident;
before(async () => {
  const bundle=await build({entryPoints:[fileURLToPath(new URL('../src/index.js', import.meta.url))],bundle:true,write:false,format:'esm',platform:'browser'});
  mf = new Miniflare(convertV4MiniflareOptions({ modules: true, script: bundle.outputFiles[0].text, compatibilityDate: '2026-10-01', d1Databases: ['DB'] }));
  db = await mf.getD1Database('DB');
  const sql = await readFile(new URL('../migrations/0001_licenses.sql', import.meta.url), 'utf8');
  for (const statement of sql.replace(/^--.*$/gm, '').match(/CREATE (?:TABLE|INDEX|TRIGGER)[\s\S]*?(?=\nCREATE |$)/g)) await db.prepare(statement.trim()).run();
});
after(async () => { await mf?.dispose(); });
beforeEach(async () => {
  for (const table of ['devices','trial_devices','licenses','events','limits']) await db.prepare('DELETE FROM '+table).run();
  now = 1800000000; ident = { device: 'a'.repeat(64), token: 'b'.repeat(64) };
  env = { DB: db, STRIPE_PRICE_ID: 'price_monthly', STRIPE_SECRET_KEY: 'sk_test_fixture', LUMA_PUBLIC_URL: 'https://licenses.example.com', BILLING_MODE: 'test', STRIPE_WEBHOOK_SECRET: 'fixture_secret' };
  stripe = { calls: [], subs: [], sessions: {}, fail: false, amount: 400, cache: new Map() };
  s = new Service(env, { clock: () => now, stripe: async (method,path,fields,idempotency) => {
    stripe.calls.push({method,path,fields,idempotency});
    if (stripe.fail) throw new Problem(503,'Billing unavailable');
    if (idempotency && stripe.cache.has(idempotency)) return stripe.cache.get(idempotency);
    let result;
    if (path.startsWith('subscriptions?')) result = {data:stripe.subs};
    else if (path.startsWith('prices/')) result = {active:true,currency:'eur',unit_amount:stripe.amount,recurring:{interval:'month',interval_count:1}};
    else if (path==='customers') result = {id:'cus_one'};
    else if (path==='checkout/sessions') {
      const id='cs_'+Object.keys(stripe.sessions).length;
      result={id,status:'open',url:'https://checkout.stripe.com/'+id}; stripe.sessions[id]=result;
    } else if (path.startsWith('checkout/sessions/')) result=stripe.sessions[path.split('/').at(-1)];
    else if (path==='billing_portal/sessions') result={url:'https://billing.stripe.com/test'};
    else throw new Error(path);
    if (idempotency) stripe.cache.set(idempotency,result);
    return result;
  }});
});
const reject = (promise,status) => assert.rejects(promise,e=> e instanceof Problem && e.status===status);
const trial = () => s.register(ident);
const current = () => s.authenticate(ident.token);
async function checkout() { await trial(); now += TRIAL_SECONDS; return s.checkout(ident.token); }
function paid(status='active', id='sub_one', price='price_monthly') {
  const sub={id,customer:'cus_one',status,current_period_end:now+86400,items:{data:[{price:{id:price}}]}};
  stripe.subs=stripe.subs.filter(s=>s.id!==id).concat(sub); return sub;
}
function event({id='evt_one',type='customer.subscription.updated',stamp=now,signature,livemode=false,customer='cus_one'}={}) {
  const raw=JSON.stringify({id,type,livemode,data:{object:{id:'sub_one',customer}}});
  const sig=signature || createHmac('sha256',env.STRIPE_WEBHOOK_SECRET).update(stamp+'.'+raw).digest('hex');
  return s.webhook(raw,`t=${stamp},v1=${sig}`);
}
async function developer(seats=2) {
  const key='LUMA-'+random(24).toUpperCase(),id=random(16);
  await db.prepare("INSERT INTO licenses(id,key_hash,kind,trial_end,seats) VALUES(?,?,'developer',0,?)").bind(id,await digest(key),seats).run();
  return {id,key};
}
test('72-hour trial, retry, exact expiry and no Stripe/card calls',async()=>{
  const first=await trial(); assert.equal(first.accessUntil-now,TRIAL_SECONDS); assert.equal(stripe.calls.length,0);
  now+=42; assert.equal((await trial()).accessUntil,first.accessUntil);
  await reject(s.checkout(ident.token),409); assert.equal(stripe.calls.length,0);
  now=first.accessUntil-1; assert.equal((await s.refresh(ident.token)).validUntil,now+1);
  now++; assert.equal((await s.refresh(ident.token)).status,'expired');
});
test('parallel registrations create only one trial, no orphan license',async()=>{
  const results=await Promise.all(Array.from({length:12},()=>trial()));
  assert.equal(results.filter(r=>r.productKey).length,1);
  for (const table of ['licenses','devices','trial_devices']) assert.equal(await db.prepare('SELECT count(*) AS n FROM '+table).first('n'),1);
});
test('reinstall cannot reset trial; key restores identity and invalidates old token',async()=>{
  const first=await trial(); now+=TRIAL_SECONDS;
  await reject(s.register({...ident,token:'c'.repeat(64)}),409);
  assert.equal((await s.activate({...ident,token:'c'.repeat(64),productKey:first.productKey})).status,'expired');
  await reject(s.refresh(ident.token),401);
});
test('released device remains in trial history',async()=>{
  await trial(); await db.prepare('DELETE FROM devices').run(); await reject(trial(),409);
});
test('concurrent developer activations obey seat limit atomically',async()=>{
  const {id,key}=await developer(2);
  const results=await Promise.allSettled(Array.from({length:8},()=>s.activate({device:random(),token:random(),productKey:key.toLowerCase()})));
  assert.equal(results.filter(r=>r.status==='fulfilled').length,2);
  assert.equal(await db.prepare('SELECT count(*) AS n FROM devices WHERE license_id=?').bind(id).first('n'),2);
  assert.ok(results.filter(r=>r.status==='rejected').every(r=>r.reason.status===409));
});
test('restoring same developer Mac at seat limit succeeds; revocation expires access',async()=>{
  const {id,key}=await developer(1);
  assert.equal((await s.activate({...ident,productKey:key})).status,'developer');
  await s.activate({...ident,productKey:key});
  await db.prepare('UPDATE licenses SET revoked=1 WHERE id=?').bind(id).run();
  assert.equal((await s.refresh(ident.token)).status,'expired'); await reject(s.activate({...ident,productKey:key}),403);
});
test('unknown key/auth fail and database contains only key/token hashes',async()=>{
  await reject(s.activate({...ident,productKey:'LUMA-'+'A'.repeat(48)}),403);
  const first=await trial(); await reject(s.refresh('c'.repeat(64)),401);
  const row=await current(); assert.equal(row.key_hash,await digest(first.productKey));
  assert.equal(await db.prepare('SELECT token_hash FROM devices').first('token_hash'),await digest(ident.token));
});
test('lost key response recovery rotates old key',async()=>{
  const first=await trial(), replacement=await s.recoveryKey(ident.token);
  await reject(s.activate({...ident,productKey:first.productKey}),403);
  assert.equal((await s.activate({...ident,productKey:replacement.productKey})).status,'trial');
});
test('checkout uses fixed server price, reuses open session, and does not unlock access',async()=>{
  const one=await checkout(), two=await s.checkout(ident.token); assert.deepEqual(one,two);
  const calls=stripe.calls.filter(c=>c.method==='POST'&&c.path==='checkout/sessions');
  assert.equal(calls.length,1); assert.equal(calls[0].fields['line_items[0][price]'],'price_monthly');
  assert.equal((await s.refresh(ident.token)).status,'expired');
});
test('parallel checkout requests serialize and recover by retry',async()=>{
  await trial(); now+=TRIAL_SECONDS;
  const results=await Promise.allSettled(Array.from({length:6},()=>s.checkout(ident.token)));
  assert.equal(results.filter(r=>r.status==='fulfilled').length,1);
  await s.checkout(ident.token);
  assert.equal(stripe.calls.filter(c=>c.method==='POST'&&c.path==='checkout/sessions').length,1);
});
test('billing mode mismatch and wrong price block checkout',async()=>{
  await trial(); now+=TRIAL_SECONDS; env.STRIPE_SECRET_KEY='sk_live_wrong';
  assert.equal((await s.refresh(ident.token)).billingAvailable,false); await reject(s.checkout(ident.token),503);
  env.STRIPE_SECRET_KEY='sk_test_fixture'; stripe.amount=499; await reject(s.checkout(ident.token),503);
});
test('signed webhook activates, deduplicates, and cancellation revokes',async()=>{
  await checkout(); paid(); await event(); assert.equal((await s.refresh(ident.token)).status,'active');
  const count=stripe.calls.length; await event(); assert.equal(stripe.calls.length,count);
  paid('canceled'); await event({id:'evt_cancel'}); assert.equal((await s.refresh(ident.token)).status,'expired');
});
test('unpaid, past_due, paused, wrong-price and collection pause never unlock',async()=>{
  await checkout();
  for (const status of ['incomplete','past_due','unpaid','paused','canceled']) {
    paid(status); await event({id:'evt_'+status}); assert.equal((await s.refresh(ident.token)).status,'expired');
  }
  paid('active','sub_one','wrong'); await event({id:'evt_wrong'}); assert.equal((await s.refresh(ident.token)).status,'expired');
  paid().pause_collection={behavior:'void'}; await event({id:'evt_pause'}); assert.equal((await s.refresh(ident.token)).status,'expired');
});
test('cancel at period end retains access until paid boundary; renewal extends it',async()=>{
  await checkout(); const sub=paid(); sub.cancel_at_period_end=true; await event();
  const first=(await s.refresh(ident.token)).accessUntil;
  sub.current_period_end+=86400; await event({id:'evt_renew',type:'invoice.paid'});
  assert.equal((await s.refresh(ident.token)).accessUntil,first+86400);
  now=first+86400; assert.equal((await s.refresh(ident.token)).status,'expired');
});
test('stale cancellation does not replace newer active subscription',async()=>{
  await checkout(); paid('canceled','sub_old'); paid('active','sub_new'); await event();
  assert.equal((await current()).subscription,'sub_new'); assert.equal((await s.refresh(ident.token)).status,'active');
});
test('invalid signature, old timestamp, wrong mode rejected; failed processing remains retryable',async()=>{
  await checkout(); paid();
  await reject(event({signature:'a'.repeat(64)}),400); await reject(event({stamp:now-301}),400); await reject(event({livemode:true}),400);
  stripe.fail=true; await reject(event(),503); assert.equal(await db.prepare('SELECT count(*) n FROM events').first('n'),0);
  stripe.fail=false; await event(); assert.equal((await s.refresh(ident.token)).status,'active');
});
test('paid customer gets portal, canceled customer can resubscribe',async()=>{
  await checkout(); paid(); await event(); assert.match((await s.checkout(ident.token)).url,/billing.stripe.com/);
  paid('canceled'); await event({id:'evt_cancel'}); stripe.sessions.cs_0.status='complete';
  assert.match((await s.checkout(ident.token)).url,/checkout.stripe.com/);
  const calls=stripe.calls.filter(c=>c.method==='POST'&&c.path==='checkout/sessions');
  assert.equal(calls.length,2); assert.notEqual(calls[0].idempotency,calls[1].idempotency);
});
test('polling discovers completed payment even if webhook is delayed',async()=>{
  await checkout(); paid(); now+=61; assert.equal((await s.refresh(ident.token)).status,'active');
});
test('billing lock expires after interrupted request',async()=>{
  await trial(); const row=await current();
  await db.prepare('UPDATE licenses SET billing_lock_until=?,billing_lock_token=? WHERE id=?').bind(now+120,'old',row.id).run();
  await reject(s.withBillingLock(row.id,()=>true),503);
  now+=121; assert.equal(await s.withBillingLock(row.id,()=>true),true);
});
test('rate limiting is atomic; entitlement checks do not write buckets',async()=>{
  const results=await Promise.allSettled(Array.from({length:12},()=>s.rateLimit('peer','/v1/activate')));
  assert.equal(results.filter(r=>r.status==='fulfilled').length,10);
  await s.rateLimit('peer','/v1/entitlement'); assert.equal(await db.prepare('SELECT count(*) n FROM limits').first('n'),1);
  now+=61; await s.rateLimit('peer','/v1/activate');
});
test('HTTP validates body size/types/auth and hides internal errors',async()=>{
  for (const [body,status] of [['[]',400],['{',400],['x'.repeat(262145),413]]) {
    const response=await handle(new Request('https://local/v1/trial',{method:'POST',body}),env);
    assert.equal(response.status,status); assert.equal(response.headers.get('Cache-Control'),'no-store');
  }
  assert.equal((await handle(new Request('https://local/v1/entitlement',{method:'POST',body:'{}'}),env)).status,401);
  assert.equal((await handle(new Request('https://local/health'),env)).status,200);
  const broken=await handle(new Request('https://local/v1/trial',{method:'POST',body:JSON.stringify(ident)}),{DB:{}});
  assert.equal(broken.status,503); assert.doesNotMatch(await broken.text(),/TypeError|stack|prepare/);
});
test('deployed Worker entry point runs in workerd and returns the Swift grant contract',async()=>{
  const response=await mf.dispatchFetch('https://local/v1/trial',{method:'POST',body:JSON.stringify(ident)});
  assert.equal(response.status,200); const grant=await response.json();
  assert.equal(grant.status,'trial'); assert.equal(grant.accessUntil-grant.serverTime,TRIAL_SECONDS);
  assert.equal(grant.validUntil-grant.serverTime,300); assert.equal(grant.billingAvailable,false);
  assert.match(grant.productKey,/^LUMA-[A-F0-9]{48}$/);
  const refreshed=await mf.dispatchFetch('https://local/v1/entitlement',{method:'POST',headers:{Authorization:'Bearer '+ident.token},body:'{}'});
  assert.equal((await refreshed.json()).trialEndsAt,grant.trialEndsAt);
});
test('lost checkout database write retries the same Stripe idempotency key',async()=>{
  await trial(); now+=TRIAL_SECONDS;
  const original=s.statement.bind(s); let fail=true;
  s.statement=(sql,...args)=>{
    if (sql.startsWith('UPDATE licenses SET checkout=') && fail) {
      fail=false; return {run:async()=>{throw new Error('simulated database failure');}};
    }
    return original(sql,...args);
  };
  await assert.rejects(s.checkout(ident.token));
  const result=await s.checkout(ident.token);
  assert.match(result.url,/checkout.stripe.com/); assert.equal(Object.keys(stripe.sessions).length,1);
  const calls=stripe.calls.filter(c=>c.method==='POST'&&c.path==='checkout/sessions');
  assert.equal(calls.length,2); assert.equal(calls[0].idempotency,calls[1].idempotency);
});
