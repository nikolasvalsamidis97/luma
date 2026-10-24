"""Run on the licensing host. Never put product keys into source control or public issues."""
import argparse
from service import from_environment
p=argparse.ArgumentParser()
sub=p.add_subparsers(dest='command',required=True)
i=sub.add_parser('issue'); i.add_argument('--label',required=True); i.add_argument('--macs',type=int,default=2)
r=sub.add_parser('revoke'); r.add_argument('license_id')
f=sub.add_parser('release-device'); f.add_argument('license_id'); f.add_argument('device_hash')
a=p.parse_args(); service=from_environment()
if a.command=='issue':
    lid,key=service.issue(seats=a.macs,label=a.label)
    print('License ID:',lid); print('Product key (shown only now):',key)
elif a.command=='revoke': service.revoke(a.license_id); print('Revoked. Existing access leases expire within five minutes.')
else:
    with service.db() as db:
        db.execute('DELETE FROM devices WHERE device=? AND license_id=?',(a.device_hash,a.license_id))
    print('Activation released. Trial history retained.')
