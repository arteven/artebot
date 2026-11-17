# runs on the HOST (guest VM). Writer of inbound.db, fresh read-only reader of outbound.db, heartbeat mtime observer.
import sqlite3, time, os, sys, json
D=sys.argv[1]; N=int(sys.argv[2]); STEP=float(sys.argv[3])
inn=sqlite3.connect(f'{D}/inbound.db', timeout=5); inn.execute('PRAGMA journal_mode=DELETE')
inn.execute('CREATE TABLE IF NOT EXISTS messages_in(seq INTEGER PRIMARY KEY, body TEXT)'); inn.commit()
while not os.path.exists(f'{D}/outbound.ready'): time.sleep(0.1)
def read_out():
    c=sqlite3.connect(f'file:{D}/outbound.db?mode=ro', uri=True, timeout=5)
    try:
        c.execute('PRAGMA busy_timeout=5000'); c.execute('PRAGMA mmap_size=0')
        return c.execute('SELECT COALESCE(MAX(seq),0), COUNT(*) FROM messages_out').fetchone()
    finally: c.close()
stats=dict(reads=0, read_errors={}, max_seen=0, writes=0, write_errors=0, last_out_count=0, mono_viol=0, hb_mtime_changes=0, lag_samples=[])
t_end=time.time()+N*STEP+6; i=0; last_hb=None; prev_cnt=0
while time.time()<t_end:
    if i<N:
        i+=1
        try: inn.execute('INSERT INTO messages_in(seq,body) VALUES(?,?)',(2*i,'y'*200)); inn.commit(); stats['writes']+=1
        except Exception as e: stats['write_errors']+=1; stats.setdefault('werr',str(e))
    try:
        m,cnt=read_out(); stats['reads']+=1
        if m<stats['max_seen']: stats['mono_viol']+=1
        stats['max_seen']=max(stats['max_seen'],m); stats['last_out_count']=cnt
    except Exception as e:
        k=type(e).__name__+': '+str(e); stats['read_errors'][k]=stats['read_errors'].get(k,0)+1
    try:
        mt=os.stat(f'{D}/.heartbeat').st_mtime
        if mt!=last_hb: stats['hb_mtime_changes']+=1; last_hb=mt
        stats['hb_age_s']=round(time.time()-mt,2)
    except FileNotFoundError: pass
    time.sleep(STEP)
c=sqlite3.connect(f'{D}/outbound.db'); stats['integrity_out']=c.execute('PRAGMA integrity_check').fetchone()[0]; c.close()
c=sqlite3.connect(f'{D}/inbound.db'); stats['integrity_in']=c.execute('PRAGMA integrity_check').fetchone()[0]; c.close()
print('HOST_STATS '+json.dumps(stats))
