"""Luma licensing service. No provider credentials or media ever enter this service."""
import contextlib
import hashlib
import hmac
import json
import os
import re
import secrets
import sqlite3
import time
import urllib.error
import urllib.parse
import urllib.request

TRIAL_SECONDS = 72 * 60 * 60
LEASE_SECONDS = 300

class Problem(Exception):
    def __init__(self, status, message): self.status, self.message = status, message

def digest(value): return hashlib.sha256(value.encode()).hexdigest()
def new_key(): return 'LUMA-' + secrets.token_hex(24).upper()
def normalize_key(value): return value.strip().upper()

def validate_identity(data):
    device, token = data.get('device', ''), data.get('token', '')
    if not re.fullmatch(r'[a-f0-9]{64}', device) or not re.fullmatch(r'[a-f0-9]{64}', token):
        raise Problem(400, 'Invalid device identity.')
    return device, digest(token)

class Stripe:
    def __init__(self, key): self.key = key
    def request(self, method, path, fields=None, idempotency=None):
        if not self.key: raise Problem(503, 'Subscriptions are not available yet.')
        headers = {'Authorization': 'Bearer ' + self.key, 'Stripe-Version': '2025-02-24.acacia'}
        if idempotency: headers['Idempotency-Key'] = idempotency
        data = urllib.parse.urlencode(fields).encode() if fields is not None else None
        req = urllib.request.Request('https://api.stripe.com/v1/' + path, data=data, headers=headers, method=method)
        try:
            with urllib.request.urlopen(req, timeout=15) as response: return json.load(response)
        except (urllib.error.URLError, ValueError): raise Problem(503, 'Billing is temporarily unavailable. Please try again.')

class Service:
    def __init__(self, db_path, stripe=None, price_id='', public_url='', webhook_secret='', clock=time.time):
        self.db_path, self.stripe, self.price_id = db_path, stripe or Stripe(''), price_id
        self.public_url, self.webhook_secret, self.clock = public_url.rstrip('/'), webhook_secret, clock
        with self.db() as db:
            db.executescript('''
            CREATE TABLE IF NOT EXISTS licenses (
              id TEXT PRIMARY KEY, key_hash TEXT UNIQUE NOT NULL, kind TEXT NOT NULL,
              trial_end INTEGER NOT NULL, seats INTEGER NOT NULL, revoked INTEGER NOT NULL DEFAULT 0,
              customer TEXT UNIQUE, subscription TEXT, paid_until INTEGER NOT NULL DEFAULT 0,
              billing_status TEXT, checked_at INTEGER NOT NULL DEFAULT 0,
              checkout TEXT, checkout_generation INTEGER NOT NULL DEFAULT 0, label TEXT NOT NULL DEFAULT ''
            );
            CREATE TABLE IF NOT EXISTS devices (
              device TEXT PRIMARY KEY, token_hash TEXT UNIQUE NOT NULL, license_id TEXT NOT NULL REFERENCES licenses(id)
            );
            CREATE TABLE IF NOT EXISTS trial_devices (device TEXT PRIMARY KEY);
            CREATE TABLE IF NOT EXISTS events (id TEXT PRIMARY KEY, received INTEGER NOT NULL);
            CREATE TABLE IF NOT EXISTS limits (bucket TEXT PRIMARY KEY, count INTEGER NOT NULL, expires INTEGER NOT NULL);
            ''')
    @contextlib.contextmanager
    def db(self):
        db = sqlite3.connect(self.db_path, timeout=30); db.row_factory = sqlite3.Row
        db.execute('PRAGMA foreign_keys=ON')
        try:
            db.execute('BEGIN IMMEDIATE')
            yield db
            db.commit()
        except BaseException:
            db.rollback(); raise
        finally: db.close()
    def issue(self, kind='developer', seats=2, label=''):
        if kind != 'developer' or not 1 <= seats <= 100: raise ValueError('Invalid developer license')
        key, lid = new_key(), secrets.token_hex(16)
        with self.db() as db:
            db.execute('INSERT INTO licenses(id,key_hash,kind,trial_end,seats,label) VALUES(?,?,?,?,?,?)',
                       (lid,digest(key),kind,0,seats,label[:120]))
        return lid, key
    def revoke(self, lid):
        with self.db() as db:
            if db.execute('UPDATE licenses SET revoked=1 WHERE id=?',(lid,)).rowcount != 1:
                raise ValueError('License not found')
    def rate_limit(self, peer, route):
        now = int(self.clock()); window = 3600 if route == '/v1/trial' else 60
        cap = 10 if route == '/v1/trial' else (10 if route == '/v1/activate' else 120)
        bucket = digest(peer) + route + str(now // window)
        with self.db() as db:
            db.execute('DELETE FROM limits WHERE expires < ?', (now,))
            row = db.execute('SELECT count FROM limits WHERE bucket=?',(bucket,)).fetchone()
            if row and row['count'] >= cap: raise Problem(429, 'Too many attempts. Please try again later.')
            db.execute('INSERT INTO limits VALUES(?,1,?) ON CONFLICT(bucket) DO UPDATE SET count=count+1', (bucket,now+window))
    def authenticate(self, db, token):
        if not re.fullmatch(r'[a-f0-9]{64}', token): raise Problem(401, 'Activate Luma on this Mac first.')
        row = db.execute('SELECT l.* FROM licenses l JOIN devices d ON d.license_id=l.id WHERE d.token_hash=?',(digest(token),)).fetchone()
        if not row: raise Problem(401, 'Activate Luma on this Mac first.')
        return row
    def grant(self, row):
        now = int(self.clock()); status, end = 'expired', now
        if not row['revoked']:
            if row['kind'] == 'developer': status, end = 'developer', now + LEASE_SECONDS
            elif row['paid_until'] > now: status, end = 'active', row['paid_until']
            elif row['trial_end'] > now: status, end = 'trial', row['trial_end']
        return dict(status=status, serverTime=now, validUntil=min(end, now + LEASE_SECONDS),
                    accessUntil=end, trialEndsAt=row['trial_end'], billingAvailable=bool(self.price_id and self.public_url and row['kind'] != 'developer' and not row['revoked']),
                    hasSubscription=bool(row['subscription']), priceLabel='€4/month')
    def register(self, data):
        device, token_hash = validate_identity(data)
        with self.db() as db:
            existing = db.execute('SELECT * FROM devices WHERE device=?',(device,)).fetchone()
            if existing:
                if existing['token_hash'] != token_hash: raise Problem(409, 'This Mac has already been activated. Enter your product key to restore access.')
                return self.grant(db.execute('SELECT * FROM licenses WHERE id=?',(existing['license_id'],)).fetchone())
            if db.execute('SELECT 1 FROM trial_devices WHERE device=?',(device,)).fetchone():
                raise Problem(409, 'This Mac has already used its trial. Restore access with your product key.')
            key, lid = new_key(), secrets.token_hex(16)
            db.execute('INSERT INTO licenses(id,key_hash,kind,trial_end,seats) VALUES(?,?,?,?,?)',
                       (lid,digest(key),'standard',int(self.clock())+TRIAL_SECONDS,2))
            db.execute('INSERT INTO trial_devices VALUES(?)',(device,))
            db.execute('INSERT INTO devices VALUES(?,?,?)',(device,token_hash,lid))
            result = self.grant(db.execute('SELECT * FROM licenses WHERE id=?',(lid,)).fetchone())
            result['productKey'] = key
            return result
    def activate(self, data):
        device, token_hash = validate_identity(data)
        key = normalize_key(data.get('productKey',''))
        if not re.fullmatch(r'LUMA-[A-F0-9]{48}',key): raise Problem(400,'Enter a valid Luma product key.')
        with self.db() as db:
            row = db.execute('SELECT * FROM licenses WHERE key_hash=?',(digest(key),)).fetchone()
            if not row or row['revoked']: raise Problem(403,'This product key is invalid or has been revoked.')
            old = db.execute('SELECT * FROM devices WHERE device=?',(device,)).fetchone()
            same = old and old['license_id'] == row['id']
            count = db.execute('SELECT COUNT(*) FROM devices WHERE license_id=?',(row['id'],)).fetchone()[0]
            if not same and count >= row['seats']: raise Problem(409,'This product key has reached its Mac limit. Contact support to release an old activation.')
            db.execute('INSERT INTO devices VALUES(?,?,?) ON CONFLICT(device) DO UPDATE SET token_hash=excluded.token_hash,license_id=excluded.license_id',
                       (device,token_hash,row['id']))
            # Activating a key never makes this Mac eligible for a fresh trial later.
            db.execute('INSERT OR IGNORE INTO trial_devices VALUES(?)',(device,))
            return self.grant(row)
    def sync_subscription(self, db, lid, sub_id):
        if not re.fullmatch(r'sub_[A-Za-z0-9]+',sub_id): raise Problem(400,'Invalid subscription.')
        sub = self.stripe.request('GET','subscriptions/'+sub_id)
        row = db.execute('SELECT * FROM licenses WHERE id=?',(lid,)).fetchone()
        if sub.get('customer') != row['customer']: raise Problem(403,'Subscription account mismatch.')
        items = sub.get('items',{}).get('data',[])
        correct = any(i.get('price',{}).get('id') == self.price_id for i in items)
        paid_end = int(sub.get('current_period_end') or max([i.get('current_period_end',0) for i in items] or [0]))
        # No access for unpaid, incomplete, past_due, paused, canceled or a different product.
        if sub.get('status') != 'active' or not correct or sub.get('pause_collection'): paid_end = 0
        db.execute('UPDATE licenses SET subscription=?,paid_until=?,billing_status=?,checked_at=? WHERE id=?',
                   (sub_id,paid_end,sub.get('status'),int(self.clock()),lid))
    def sync_customer(self, db, row):
        # Query current Stripe state, never apply an old webhook snapshot over a new subscription.
        query = urllib.parse.urlencode({'customer':row['customer'],'status':'all','limit':100})
        subscriptions = self.stripe.request('GET','subscriptions?'+query).get('data',[])
        matching = [s for s in subscriptions if any(i.get('price',{}).get('id')==self.price_id for i in s.get('items',{}).get('data',[]))]
        candidates = [s for s in matching if s.get('status')=='active' and not s.get('pause_collection')]
        selected = next(iter(candidates), next((s for s in matching if s.get('id')==row['subscription']),next(iter(matching),None)))
        if selected: self.sync_subscription(db,row['id'],selected['id'])
        else: db.execute('UPDATE licenses SET paid_until=0,billing_status=?,checked_at=? WHERE id=?',('canceled',int(self.clock()),row['id']))
    def recovery_key(self, token):
        with self.db() as db:
            row = self.authenticate(db,token)
            if row['kind'] != 'standard' or row['revoked']: raise Problem(403,'Contact the key issuer to restore this key.')
            key = new_key()
            db.execute('UPDATE licenses SET key_hash=? WHERE id=?',(digest(key),row['id']))
            return {'productKey':key}
    def refresh(self, token):
        with self.db() as db:
            row = self.authenticate(db,token)
            if row['subscription'] and not row['revoked'] and self.clock()-row['checked_at'] >= 60:
                self.sync_customer(db,row)
                row = db.execute('SELECT * FROM licenses WHERE id=?',(row['id'],)).fetchone()
            return self.grant(row)
    def checkout(self, token):
        if not self.price_id or not self.public_url: raise Problem(503,'Subscriptions are not available yet.')
        with self.db() as db:
            row = self.authenticate(db,token)
            if row['revoked'] or row['kind']=='developer': raise Problem(409,'This license does not need a subscription.')
            if row['trial_end'] > self.clock(): raise Problem(409,'Enjoy your free trial first. Subscribe when it ends.')
            if row['subscription']:
                self.sync_customer(db,row)
                row = db.execute('SELECT * FROM licenses WHERE id=?',(row['id'],)).fetchone()
                if row['billing_status'] not in ('canceled','incomplete_expired'):
                    return self.portal_for(row)
            if row['checkout']:
                session = self.stripe.request('GET','checkout/sessions/'+row['checkout'])
                if session.get('status') == 'open': return {'url':session['url']}
                if session.get('status') == 'complete' and session.get('subscription'):
                    self.sync_subscription(db,row['id'],session['subscription'])
                    updated = db.execute('SELECT * FROM licenses WHERE id=?',(row['id'],)).fetchone()
                    if updated['billing_status'] not in ('canceled','incomplete_expired'): return self.portal_for(updated)
            price = self.stripe.request('GET','prices/'+self.price_id)
            if price.get('currency')!='eur' or price.get('unit_amount')!=400 or price.get('recurring',{}).get('interval')!='month' or price.get('recurring',{}).get('interval_count',1)!=1 or not price.get('active'):
                raise Problem(503,'The €4 monthly plan is not configured correctly.')
            customer = row['customer']
            if not customer:
                customer = self.stripe.request('POST','customers',{'metadata[luma_license]':row['id']},'customer-'+row['id'])['id']
                db.execute('UPDATE licenses SET customer=? WHERE id=?',(customer,row['id']))
            gen = row['checkout_generation']+1
            session = self.stripe.request('POST','checkout/sessions',{
                'mode':'subscription','customer':customer,'line_items[0][price]':self.price_id,'line_items[0][quantity]':1,
                'success_url':self.public_url+'/billing/return','cancel_url':self.public_url+'/billing/cancel',
                'client_reference_id':row['id'],'subscription_data[metadata][luma_license]':row['id'],
                'payment_method_types[0]':'card'},'checkout-'+row['id']+'-'+str(gen))
            db.execute('UPDATE licenses SET checkout=?,checkout_generation=? WHERE id=?',(session['id'],gen,row['id']))
            return {'url':session['url']}
    def portal_for(self, row):
        if not row['customer']: raise Problem(409,'There is no billing account for this license yet.')
        return {'url':self.stripe.request('POST','billing_portal/sessions',{'customer':row['customer'],'return_url':self.public_url+'/billing/return'})['url']}
    def portal(self, token):
        with self.db() as db: return self.portal_for(self.authenticate(db,token))
    def webhook(self, raw, signature):
        if not self.webhook_secret: raise Problem(503,'Webhooks are not configured.')
        parts = {}
        for pair in signature.split(','):
            k, sep, v = pair.partition('=')
            if sep: parts.setdefault(k,[]).append(v)
        try: stamp = int(parts['t'][0])
        except (KeyError,ValueError): raise Problem(400,'Invalid webhook signature.')
        expected = hmac.new(self.webhook_secret.encode(),str(stamp).encode()+b'.'+raw,hashlib.sha256).hexdigest()
        if abs(self.clock()-stamp)>300 or not any(hmac.compare_digest(expected,s) for s in parts.get('v1',[])):
            raise Problem(400,'Invalid webhook signature.')
        try: event = json.loads(raw); eid=event['id']; kind=event['type']; obj=event['data']['object']
        except (ValueError,KeyError,TypeError): raise Problem(400,'Invalid webhook event.')
        if not isinstance(eid,str): raise Problem(400,'Invalid webhook event.')
        with self.db() as db:
            if db.execute('SELECT 1 FROM events WHERE id=?',(eid,)).fetchone(): return {'received':True}
            if kind.startswith('customer.subscription.') or kind in ('checkout.session.completed','checkout.session.async_payment_succeeded','invoice.paid','invoice.payment_failed'):
                customer=obj.get('customer')
                row=db.execute('SELECT * FROM licenses WHERE customer=?',(customer if isinstance(customer,str) else '',)).fetchone()
                sid=obj.get('id') if kind.startswith('customer.subscription.') else obj.get('subscription')
                if row: self.sync_customer(db,row)
            db.execute('INSERT INTO events VALUES(?,?)',(eid,int(self.clock())))
        return {'received':True}

class Application:
    def __init__(self, service): self.service=service
    def __call__(self, env, start):
        status, result, content_type = 200, {}, 'application/json'
        try:
            path, method = env.get('PATH_INFO',''), env.get('REQUEST_METHOD','GET')
            if method=='GET' and path=='/health': result={'ok':True}
            elif method=='GET' and path in ('/billing/return','/billing/cancel'):
                content_type='text/html; charset=utf-8'
                result='<!doctype html><html lang="en"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Luma billing</title><body style="background:#0d0f14;color:#fff;font:20px system-ui;padding:10vw"><h1>Return to Luma</h1><p>Open Luma and choose Refresh access. Your subscription is activated only after payment is confirmed.</p></body></html>'
            elif method=='POST':
                size=int(env.get('CONTENT_LENGTH') or 0)
                if size<0 or size>262144: raise Problem(413,'Request too large.')
                raw=env['wsgi.input'].read(size)
                if path=='/v1/stripe/webhook': result=self.service.webhook(raw,env.get('HTTP_STRIPE_SIGNATURE',''))
                else:
                    if path not in ('/v1/trial','/v1/activate','/v1/entitlement','/v1/recovery-key','/v1/checkout','/v1/portal'): raise Problem(404,'Not found.')
                    self.service.rate_limit(env.get('REMOTE_ADDR','unknown'),path)
                    try: data=json.loads(raw or b'{}')
                    except ValueError: raise Problem(400,'Invalid JSON.')
                    if not isinstance(data,dict): raise Problem(400,'Invalid request.')
                    auth=env.get('HTTP_AUTHORIZATION',''); token=auth[7:] if auth.startswith('Bearer ') else ''
                    if path=='/v1/trial': result=self.service.register(data)
                    elif path=='/v1/activate': result=self.service.activate(data)
                    elif path=='/v1/entitlement': result=self.service.refresh(token)
                    elif path=='/v1/recovery-key': result=self.service.recovery_key(token)
                    elif path=='/v1/checkout': result=self.service.checkout(token)
                    elif path=='/v1/portal': result=self.service.portal(token)
                    else: raise Problem(404,'Not found.')
            else: raise Problem(404,'Not found.')
        except Problem as e: status,result=e.status,{'error':e.message}
        except (ValueError,TypeError): status,result=400,{'error':'Invalid request.'}
        except Exception: status,result=503,{'error':'Licensing is temporarily unavailable. Please try again.'}
        body=(json.dumps(result) if content_type=='application/json' else result).encode()
        start(str(status)+' '+{200:'OK',400:'Bad Request',401:'Unauthorized',403:'Forbidden',404:'Not Found',409:'Conflict',413:'Content Too Large',429:'Too Many Requests',503:'Service Unavailable'}.get(status,'Error'),
              [('Content-Type',content_type),('Content-Length',str(len(body))),('Cache-Control','no-store'),('X-Content-Type-Options','nosniff')])
        return [body]

def from_environment():
    public=os.environ.get('LUMA_PUBLIC_URL','')
    if public and not public.startswith('https://'): raise RuntimeError('Production public URL must use HTTPS')
    return Service(os.environ.get('LUMA_DB','luma.sqlite3'),Stripe(os.environ.get('STRIPE_SECRET_KEY','')),
                   os.environ.get('STRIPE_PRICE_ID',''),public,os.environ.get('STRIPE_WEBHOOK_SECRET',''))
