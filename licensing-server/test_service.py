import hashlib, hmac, io, json, tempfile, unittest
from concurrent.futures import ThreadPoolExecutor
from service import Application, Service, Problem, TRIAL_SECONDS, digest

class FakeStripe:
    def __init__(self): self.subs={}; self.calls=[]; self.sessions={}; self.fail=False
    def request(self, method, path, fields=None, idempotency=None):
        self.calls.append((method,path,fields,idempotency))
        if self.fail: raise Problem(503,'Billing unavailable')
        if path.startswith('subscriptions?'): return {'data':list(self.subs.values())}
        if path.startswith('subscriptions/'): return self.subs[path.split('/')[-1]]
        if path.startswith('prices/'): return {'active':True,'currency':'eur','unit_amount':400,'recurring':{'interval':'month','interval_count':1}}
        if path=='customers': return {'id':'cus_one'}
        if path=='checkout/sessions':
            s={'id':'cs_one','status':'open','url':'https://checkout.stripe.com/test'}; self.sessions[s['id']]=s; return s
        if path.startswith('checkout/sessions/'): return self.sessions[path.split('/')[-1]]
        if path=='billing_portal/sessions': return {'url':'https://billing.stripe.com/test'}
        raise AssertionError(path)

class Checks(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(); self.now=1800000000; self.stripe=FakeStripe()
        self.s=Service(self.tmp.name+'/db.sqlite3',self.stripe,'price_monthly','https://licenses.example.com','secret',lambda:self.now)
        self.ident={'device':'a'*64,'token':'b'*64}
    def tearDown(self): self.tmp.cleanup()
    def trial(self): return self.s.register(self.ident)
    def row(self):
        with self.s.db() as db: return self.s.authenticate(db,self.ident['token'])
    def expired_checkout(self):
        self.trial(); self.now+=TRIAL_SECONDS; return self.s.checkout(self.ident['token'])
    def paid(self,status='active',sid='sub_one',price='price_monthly'):
        self.stripe.subs[sid]={'id':sid,'customer':'cus_one','status':status,'current_period_end':self.now+86400,'items':{'data':[{'price':{'id':price}}]}}
    def event(self,kind='customer.subscription.updated',sid='sub_one',eid='evt_one',bad=False,stamp=None):
        raw=json.dumps({'id':eid,'type':kind,'data':{'object':{'id':sid,'customer':'cus_one'}}}).encode()
        stamp=self.now if stamp is None else stamp
        sig=hmac.new(b'secret',str(stamp).encode()+b'.'+raw,hashlib.sha256).hexdigest()
        return self.s.webhook(raw,f't={stamp},v1={"bad" if bad else sig}')
    def test_exact_trial_and_retry(self):
        first=self.trial(); self.assertEqual(first['accessUntil']-self.now,TRIAL_SECONDS)
        self.now+=42; self.assertEqual(self.trial()['accessUntil'],first['accessUntil'])
        self.now=first['accessUntil']-1; self.assertEqual(self.s.refresh('b'*64)['validUntil'],self.now+1)
        self.now+=1; self.assertEqual(self.s.refresh('b'*64)['status'],'expired')
    def test_reinstall_and_keychain_removal_do_not_reset_trial(self):
        first=self.trial(); self.now+=TRIAL_SECONDS
        self.assertEqual(self.s.register(self.ident)['status'],'expired')
        with self.assertRaises(Problem): self.s.register(dict(self.ident,token='c'*64))
        restored=self.s.activate(dict(self.ident,token='c'*64,productKey=first['productKey']))
        self.assertEqual(restored['status'],'expired')
        with self.assertRaises(Problem): self.s.refresh('b'*64)
    def test_concurrent_trial_registration(self):
        with ThreadPoolExecutor(max_workers=8) as pool: results=list(pool.map(lambda _:self.trial(),range(8)))
        self.assertEqual(len({r['accessUntil'] for r in results}),1)
        self.assertEqual(sum('productKey' in r for r in results),1)
    def test_developer_key_seats_revocation(self):
        lid,key=self.s.issue(seats=1)
        self.assertEqual(self.s.activate(dict(self.ident,productKey=key.lower()))['status'],'developer')
        with self.assertRaises(Problem): self.s.activate({'device':'d'*64,'token':'e'*64,'productKey':key})
        self.s.revoke(lid); self.assertEqual(self.s.refresh('b'*64)['status'],'expired')
        with self.assertRaises(Problem): self.s.activate(dict(self.ident,productKey=key))
    def test_key_unknown_and_authentication(self):
        with self.assertRaises(Problem): self.s.activate(dict(self.ident,productKey='LUMA-'+'A'*48))
        self.trial()
        with self.assertRaises(Problem): self.s.refresh('f'*64)
    def test_keys_and_tokens_are_hashed(self):
        first=self.trial()
        with self.s.db() as db:
            dump='\n'.join(db.iterdump())
            self.assertNotIn(first['productKey'],dump); self.assertNotIn('b'*64,dump)
    def test_recovery_after_lost_response(self):
        first=self.trial(); replacement=self.s.recovery_key('b'*64)['productKey']
        self.assertNotEqual(first['productKey'],replacement)
        with self.assertRaises(Problem): self.s.activate(dict(self.ident,productKey=first['productKey']))
        self.assertEqual(self.s.activate(dict(self.ident,productKey=replacement))['status'],'trial')
    def test_no_card_or_stripe_call_during_trial(self):
        self.trial(); self.assertEqual(self.stripe.calls,[])
        with self.assertRaises(Problem): self.s.checkout('b'*64)
        self.assertEqual(self.stripe.calls,[])
    def test_checkout_server_price_and_idempotency(self):
        one=self.expired_checkout(); two=self.s.checkout('b'*64); self.assertEqual(one,two)
        calls=[c for c in self.stripe.calls if c[0]=='POST' and c[1]=='checkout/sessions']; self.assertEqual(len(calls),1)
        self.assertEqual(calls[0][2]['line_items[0][price]'],'price_monthly')
        self.assertEqual(self.s.refresh('b'*64)['status'],'expired')
    def test_no_checkout_when_unconfigured(self):
        self.trial(); self.now+=TRIAL_SECONDS; self.s.price_id=''
        with self.assertRaises(Problem): self.s.checkout('b'*64)
    def test_webhook_paid_dedup_and_cancellation(self):
        self.expired_checkout(); self.paid(); self.event()
        self.assertEqual(self.s.refresh('b'*64)['status'],'active')
        count=len(self.stripe.calls); self.event(); self.assertEqual(len(self.stripe.calls),count)
        self.paid(status='canceled'); self.event(eid='evt_cancel')
        self.assertEqual(self.s.refresh('b'*64)['status'],'expired')
    def test_failed_payment_wrong_price_and_pause_do_not_unlock(self):
        self.expired_checkout()
        for status in ('incomplete','past_due','unpaid','paused','canceled'):
            self.paid(status=status); self.event(eid='evt_'+status)
            self.assertEqual(self.s.refresh('b'*64)['status'],'expired')
        self.paid(price='wrong'); self.event(eid='evt_wrong'); self.assertEqual(self.s.refresh('b'*64)['status'],'expired')
        self.paid(); self.stripe.subs['sub_one']['pause_collection']={'behavior':'void'}
        self.event(eid='evt_pause'); self.assertEqual(self.s.refresh('b'*64)['status'],'expired')
    def test_cancel_at_period_end_keeps_paid_access(self):
        self.expired_checkout(); self.paid(); self.stripe.subs['sub_one']['cancel_at_period_end']=True; self.event()
        self.assertEqual(self.s.refresh('b'*64)['status'],'active')
        self.now+=86401; self.assertEqual(self.s.refresh('b'*64)['status'],'expired')
    def test_stale_old_webhook_does_not_revoke_new_subscription(self):
        self.expired_checkout(); self.paid(status='canceled',sid='sub_old'); self.paid(sid='sub_new')
        self.event(sid='sub_old'); self.assertEqual(self.row()['subscription'],'sub_new')
        self.assertEqual(self.s.refresh('b'*64)['status'],'active')
    def test_signature_tampering_replay_and_retry(self):
        self.expired_checkout(); self.paid()
        with self.assertRaises(Problem): self.event(bad=True)
        with self.assertRaises(Problem): self.event(stamp=self.now-301)
        self.stripe.fail=True
        with self.assertRaises(Problem): self.event()
        self.stripe.fail=False; self.event(); self.assertEqual(self.s.refresh('b'*64)['status'],'active')
    def test_no_duplicate_subscription_for_paying_user(self):
        self.expired_checkout(); self.paid(); self.event()
        self.assertIn('billing.stripe.com',self.s.checkout('b'*64)['url'])
    def test_canceled_subscription_can_subscribe_again(self):
        self.expired_checkout(); self.paid(status='canceled'); self.event()
        self.stripe.sessions['cs_one'].update(status='complete',subscription='sub_one')
        result=self.s.checkout('b'*64)
        self.assertIn('checkout.stripe.com',result['url'])
        calls=[c for c in self.stripe.calls if c[0]=='POST' and c[1]=='checkout/sessions']
        self.assertEqual(len(calls),2)
        self.assertNotEqual(calls[0][3],calls[1][3])
    def test_released_mac_cannot_get_a_new_trial(self):
        self.trial()
        with self.s.db() as db: db.execute('DELETE FROM devices WHERE device=?',(self.ident['device'],))
        with self.assertRaises(Problem): self.trial()
    def test_renewal_extends_paid_period(self):
        self.expired_checkout(); self.paid(); self.event()
        first=self.s.refresh('b'*64)['accessUntil']
        self.stripe.subs['sub_one']['current_period_end']+=86400
        self.event(kind='invoice.paid',eid='evt_renew')
        self.assertEqual(self.s.refresh('b'*64)['accessUntil'],first+86400)
    def test_incorrect_price_amount_blocks_checkout(self):
        self.trial(); self.now+=TRIAL_SECONDS
        original=self.stripe.request
        def request(method,path,fields=None,idempotency=None):
            result=original(method,path,fields,idempotency)
            if path.startswith('prices/'): result['unit_amount']=499
            return result
        self.stripe.request=request
        with self.assertRaises(Problem): self.s.checkout('b'*64)
        self.assertFalse(any(c[1]=='checkout/sessions' for c in self.stripe.calls))
    def test_rate_limit(self):
        for _ in range(10): self.s.rate_limit('peer','/v1/activate')
        with self.assertRaises(Problem): self.s.rate_limit('peer','/v1/activate')
        self.now+=61; self.s.rate_limit('peer','/v1/activate')
    def test_http_bad_input_limits_and_no_secret_echo(self):
        app=Application(self.s)
        for raw,size,status in [(b'[]',2,400),(b'{',1,400),(b'',300000,413)]:
            statuses=[]; result=app({'PATH_INFO':'/v1/trial','REQUEST_METHOD':'POST','CONTENT_LENGTH':str(size),'wsgi.input':io.BytesIO(raw)},lambda s,h:statuses.append(s))
            self.assertTrue(statuses[0].startswith(str(status))); self.assertNotIn(b'Traceback',b''.join(result))

if __name__=='__main__': unittest.main(verbosity=2)
