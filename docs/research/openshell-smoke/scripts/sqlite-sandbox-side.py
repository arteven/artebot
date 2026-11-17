# runs INSIDE the sandbox. Writer of outbound.db, fresh read-only reader of inbound.db, heartbeat toucher.
import sqlite3, time, os, sys, json
D='/mnt/rw'; N=int(sys.argv[1]); STEP=float(sys.argv[2])
out=sqlite3.connect(f'{D}/outbound.db', timeout=5); out.execute('PRAGMA journal_mode=DELETE')
out.execute('CREATE TABLE IF NOT EXISTS messages_out(seq INTEGER PRIMARY KEY, body TEXT)'); out.commit()
open(f'{D}/outbound.ready','w').close()
def read_inbound():
    c=sqlite3.connect(f'file:{D}/inbound.db?mode=ro', uri=True, timeout=5)
    try:
        c.execute('PRAGMA busy_timeout=5000'); c.execute('PRAGMA mmap_size=0')
        return c.execute('SELECT COALESCE(MAX(seq),0), COUNT(*) FROM messages_in').fetchone()
    finally: c.close()
stats=dict(reads=0, read_errors={}, max_seen=0, writes=0, write_errors=0, last_in_count=0, mono_viol=0)
t_end=time.time()+N*STEP+6
i=0
while time.time()<t_end:
    if i<N:
        i+=1
        try:
            out.execute('INSERT INTO messages_out(seq,body) VALUES(?,?)',(2*i-1,'x'*200)); out.commit(); stats['writes']+=1
        except Exception as e: stats['write_errors']+=1; stats.setdefault('werr',str(e))
    os.utime(f'{D}/.heartbeat') if os.path.exists(f'{D}/.heartbeat') else open(f'{D}/.heartbeat','w').close()
    if os.path.exists(f'{D}/inbound.db'):
        try:
            m,cnt=read_inbound(); stats['reads']+=1
            if m<stats['max_seen']: stats['mono_viol']+=1
            stats['max_seen']=max(stats['max_seen'],m); stats['last_in_count']=cnt
        except Exception as e:
            k=type(e).__name__+': '+str(e); stats['read_errors'][k]=stats['read_errors'].get(k,0)+1
    time.sleep(STEP)
print('SANDBOX_STATS '+json.dumps(stats))
