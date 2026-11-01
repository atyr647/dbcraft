#!/usr/bin/env python3
"""dbcraft database comparison harness.  Usage: python3 -I run_bench.py [engine ...]
Engines: pg mariadb firebird sqlite duckdb.  Writes results.json next to this file.
Every row gets different input (no constant folding).  See ../../../docs/DATABASE-COMPARISON.md."""
import sys, os, io, json, time, random, statistics, subprocess, multiprocessing as mp
HERE = os.path.dirname(os.path.abspath(__file__))
FF = int(os.environ.get('DB_FF', '100'))   # PostgreSQL fillfactor for the main tables (60 = tuned)
N, M = 10_000, 200_000          # players, varints
FB_LIB = '/usr/lib/x86_64-linux-gnu/libfbclient.so.2'

def split_sql(name, **subs):
    text = open(os.path.join(HERE, 'sql', name + '.sql')).read()
    for k, v in subs.items(): text = text.replace('@%s@' % k, str(v))
    out = []
    for part in text.split('--;;'):
        lines = [l for l in part.strip().splitlines() if not l.startswith('-- ')]
        s = '\n'.join(lines).strip().rstrip(';')
        if s: out.append(s)
    return out

def ms(fn):
    t = time.perf_counter(); r = fn(); return (time.perf_counter() - t) * 1000, r

def gen_players(): 
    r = random.Random(1); return [(i, 0, r.random()*1000, 64.0, r.random()*1000, 0) for i in range(N)]
def gen_varints():
    r = random.Random(2); return [(i, bytes([128+r.randrange(127), 128+r.randrange(127), r.randrange(100)])) for i in range(M)]
def gen_inbox():
    r = random.Random(3); return [(i, i, 0x30, bytes(r.getrandbits(8) for _ in range(33))) for i in range(N)]

def varint_expr(byte, band, bor, shl):
    b0, b1, b2 = byte(0), byte(1), byte(2)
    return ("case when %s<128 then %s when %s<128 then %s else %s end" % (
        b0, b0, b1, bor(band(b0,127), shl(b1,7)),
        bor(bor(band(b0,127), shl(band(b1,127),7)), shl(b2,14))))
INFIX = dict(band=lambda a,b:'(%s&%s)'%(a,b), bor=lambda a,b:'(%s|%s)'%(a,b), shl=lambda a,b:'(%s<<%s)'%(a,b))
FBOPS = dict(band=lambda a,b:'bin_and(%s,%s)'%(a,b), bor=lambda a,b:'bin_or(%s,%s)'%(a,b), shl=lambda a,b:'bin_shl(%s,%s)'%(a,b))
def hexbyte(k): 
    h = lambda j: "(instr('0123456789ABCDEF',upper(substr(hex(b),%d,1)))-1)" % j
    return "(%s*16+%s)" % (h(2*k+1), h(2*k+2))

class Engine:
    name = ''; ph = '?'; loop_sql = None; fcall_sql = None
    def setup(self, ff=100, extra_index=False):
        for s in split_sql(self.sqlfile, FF=ff):
            try: self.run(s)
            except Exception as e:
                if not s.lower().startswith('drop'): raise
        if extra_index: self.run('create index players_tick on players(tick)')
    def insert_players(self, rows): self.many('insert into players(id,region,x,y,z,tick) values (%s)' % ','.join([self.ph]*6), rows)
    def churn_sql(self, region=None):
        return 'update players set x=x+0.1, z=z+0.1, tick=tick+1' + ('' if region is None else ' where region=%s' % self.ph)
    def snapshot_reader(self): return None

# ---------------------------------------------------------------- PostgreSQL
class PG(Engine):
    name='pg'; sqlfile='pg'; ph='%s'
    loop_sql='select loopmove()'; fcall_sql='select sum(vdec(b)) from pk_varint'
    expr = 'sum(%s)' % varint_expr(lambda k:'get_byte(b,%d)'%k, **INFIX)
    def __init__(self):
        import psycopg2; self.m = psycopg2
        self.c = psycopg2.connect(host='/tmp', port=54329, dbname='dbcraft', user='postgres'); self.c.autocommit = True
        self.cur = self.c.cursor(); self.cur.execute('set jit=off')
    def run(self, s, p=None): self.cur.execute(s, p); return self.cur.fetchall() if self.cur.description else None
    def many(self, s, rows):
        import psycopg2.extras
        psycopg2.extras.execute_batch(self.cur, s, rows, page_size=1000)
    def insert_players(self, rows):
        f = io.StringIO(''.join('%d\t%d\t%r\t%r\t%r\t%d\n' % r for r in rows)); self.cur.copy_expert('copy players from stdin', f)
    def load_varints(self, rows):
        f = io.StringIO(''.join('%d\t\\\\x%s\n' % (i, b.hex()) for i, b in rows)); self.cur.copy_expert('copy pk_varint from stdin', f)
    def bulk_inbox(self, rows):
        f = io.StringIO(''.join('%d\t%d\t%d\t\\\\x%s\n' % (a, b, c, d.hex()) for a, b, c, d in rows)); self.cur.copy_expert('copy inbox from stdin', f)
    def clear_inbox(self): self.run('truncate inbox')
    def after_load(self): self.run('vacuum analyze players'); self.run('vacuum analyze pk_varint')
    def size(self): return self.run("select pg_total_relation_size('players')")[0][0]
    def snapshot_reader(self):
        c = self.m.connect(host='/tmp', port=54329, dbname='dbcraft', user='postgres'); cu = c.cursor()
        cu.execute('begin isolation level repeatable read'); cu.execute('select count(*) from inbox'); return c
    def wal_note(self): return self.run('show autovacuum')[0][0]

# ---------------------------------------------------------------- MariaDB
class Maria(Engine):
    name='mariadb'; sqlfile='mariadb'; ph='%s'
    loop_sql='call loopmove()'; fcall_sql='select sum(vdec(b)) from pk_varint'
    expr = 'sum(%s)' % varint_expr(lambda k:'ord(substr(b,%d,1))'%(k+1), **INFIX)
    def __init__(self):
        import pymysql; self.m = pymysql
        self.c = pymysql.connect(unix_socket='/tmp/mdb/sock', user='root', database='dbc', autocommit=True, local_infile=True)
        self.cur = self.c.cursor()
        if os.environ.get('DB_MARIA_RC'): self.cur.execute('set session transaction isolation level read committed')
    def run(self, s, p=None): self.cur.execute(s, p); return self.cur.fetchall() if self.cur.description else None
    def many(self, s, rows): self.cur.executemany(s, rows)
    def insert_players(self, rows): self.many('insert into players(id,region,x,y,z,tick) values (%s,%s,%s,%s,%s,%s)', rows)
    def load_varints(self, rows):
        for i in range(0, len(rows), 20000): self.many('insert into pk_varint values (%s,%s)', rows[i:i+20000])
    def bulk_inbox(self, rows): self.many('insert into inbox values (%s,%s,%s,%s)', rows)
    def bulk_inbox_loaddata(self, rows):
        p = '/tmp/mdb/inbox.tsv'; open(p, 'w').write(''.join('%d\t%d\t%d\t%s\n' % (a, b, c, d.hex()) for a, b, c, d in rows))
        self.run("load data local infile '%s' into table inbox (conn_id,seq,packet_id,@h) set body=unhex(@h)" % p)
    def clear_inbox(self): self.run('truncate table inbox')
    def after_load(self): self.run('analyze table players')
    def size(self):
        self.run('analyze table players')
        return int(self.run("select data_length+index_length from information_schema.tables where table_schema='dbc' and table_name='players'")[0][0])
    def datadir_bytes(self): return int(subprocess.check_output(['du', '-sb', '/tmp/mdb/data']).split()[0])
    def snapshot_reader(self):
        c = self.m.connect(unix_socket='/tmp/mdb/sock', user='root', database='dbc', autocommit=False); cu = c.cursor()
        cu.execute('start transaction with consistent snapshot'); cu.execute('select count(*) from inbox'); return c

# ---------------------------------------------------------------- Firebird
class Firebird(Engine):
    name='firebird'; sqlfile='firebird'; ph='?'
    loop_sql='execute procedure loopmove'; fcall_sql='select sum(vdec(b)) from pk_varint'
    expr = 'sum(%s)' % varint_expr(lambda k:'ascii_val(substring(b from %d for 1))'%(k+1), **FBOPS)
    DSN='127.0.0.1:/tmp/fb/bench.fdb'
    def __init__(self):
        import firebird.driver as fd; self.fd = fd
        fd.driver_config.fb_client_library.value = FB_LIB
        self.c = fd.connect(self.DSN, user='SYSDBA', password='masterkey'); self.cur = self.c.cursor()
    def run(self, s, p=None):
        self.cur.execute(s, p); r = self.cur.fetchall() if self.cur.description else None; self.c.commit(); return r
    def many(self, s, rows): self.cur.executemany(s, rows); self.c.commit()
    def load_varints(self, rows): self.many('insert into pk_varint values (?,?)', rows)
    def bulk_inbox(self, rows): self.many('insert into inbox values (?,?,?,?)', rows)
    def clear_inbox(self): self.run('delete from inbox')
    def after_load(self): pass
    def size(self): return os.path.getsize('/tmp/fb/bench.fdb')
    def snapshot_reader(self):
        c = self.fd.connect(self.DSN, user='SYSDBA', password='masterkey'); cu = c.cursor()
        cu.execute('select count(*) from inbox'); cu.fetchall(); return c   # transaction stays open (SNAPSHOT)

# ---------------------------------------------------------------- SQLite
class SQLite(Engine):
    name='sqlite'; sqlfile='sqlite'; ph='?'
    expr = 'sum(%s)' % varint_expr(hexbyte, **INFIX)
    PATH='/tmp/sqlite-bench.db'
    def __init__(self):
        import sqlite3; self.m = sqlite3
        self.c = sqlite3.connect(self.PATH, isolation_level=None, timeout=60); self.cur = self.c.cursor()
        self.cur.execute('pragma journal_mode=wal'); self.cur.execute('pragma synchronous=off')
    def run(self, s, p=None): self.cur.execute(s, p or ()); return self.cur.fetchall() if self.cur.description else None
    def many(self, s, rows): self.cur.execute('begin'); self.cur.executemany(s, rows); self.cur.execute('commit')
    def load_varints(self, rows): self.many('insert into pk_varint values (?,?)', rows)
    def bulk_inbox(self, rows): self.many('insert into inbox values (?,?,?,?)', rows)
    def clear_inbox(self): self.run('delete from inbox')
    def after_load(self): self.run('analyze')
    def size(self):
        return sum(os.path.getsize(self.PATH + s) for s in ('', '-wal') if os.path.exists(self.PATH + s))
    def snapshot_reader(self):
        c = self.m.connect(self.PATH, isolation_level=None, timeout=60); c.execute('begin'); c.execute('select count(*) from inbox').fetchall(); return c

# ---------------------------------------------------------------- DuckDB
class Duck(SQLite):
    name='duckdb'; sqlfile='duckdb'; PATH='/tmp/duck-bench.db'
    expr = 'sum(%s)' % varint_expr(lambda k:"(instr('0123456789ABCDEF',upper(substr(hex(b),%d,1)))-1)*16+(instr('0123456789ABCDEF',upper(substr(hex(b),%d,1)))-1)" % (2*k+1, 2*k+2), **INFIX)
    def __init__(self):
        import duckdb; self.c = duckdb.connect(self.PATH); self.cur = self.c
    def run(self, s, p=None):
        r = self.c.execute(s, p or []); return r.fetchall() if r.description else None
    def many(self, s, rows): self.c.executemany(s, rows)
    def load_varints(self, rows):
        p = '/tmp/duck-var.csv'; open(p, 'w').write(''.join('%d,%s\n' % (i, b.hex()) for i, b in rows))
        self.run("insert into pk_varint select i, from_hex(h) from read_csv('%s', columns={'i':'INT','h':'VARCHAR'})" % p)
    def after_load(self): pass
    def size(self): self.run('checkpoint'); return os.path.getsize(self.PATH)
    def snapshot_reader(self): return None

ENGINES = dict(pg=PG, mariadb=Maria, firebird=Firebird, sqlite=SQLite, duckdb=Duck)

def median_ms(fn, runs, warm=1):
    for _ in range(warm): fn()
    return round(statistics.median(ms(fn)[0] for _ in range(runs)), 2)

def churn(E, ff=None, extra_index=False, snapshot=False, rounds=100):
    ff = FF if ff is None else ff
    e = E(); e.setup(ff, extra_index); e.insert_players(gen_players()); e.after_load()
    reader = e.snapshot_reader() if snapshot else None
    s0 = e.size(); d0 = e.datadir_bytes() if hasattr(e, 'datadir_bytes') else None
    times = [ms(lambda: e.run(e.churn_sql()))[0] for _ in range(rounds)]
    r = dict(round1=round(times[0],1), round50=round(times[49],1), round100=round(times[-1],1), total_s=round(sum(times)/1000,2),
             size_before_kb=s0//1024, size_after_kb=e.size()//1024)
    if d0 is not None: r['datadir_growth_kb'] = (e.datadir_bytes() - d0)//1024
    if reader is not None: reader.close()
    return r

def _worker(name, region, rounds, barrier, q):
    e = ENGINES[name](); barrier.wait()
    t = time.perf_counter()
    for _ in range(rounds): e.run(e.churn_sql(region), (region,))
    q.put((time.perf_counter() - t) * 1000)

def parallel(name, workers=4, rounds=20):
    E = ENGINES[name]; e = E(); e.setup(FF)
    rows = []; r = random.Random(5)
    for g in range(workers): rows += [(g*N+i, g, r.random()*1000, 64.0, r.random()*1000, 0) for i in range(N)]
    e.insert_players(rows); e.after_load(); e.c.close()
    out = {}
    for w in (1, workers):
        ctx = mp.get_context('fork'); b = ctx.Barrier(w); q = ctx.Queue()
        ps = [ctx.Process(target=_worker, args=(name, g, rounds, b, q)) for g in range(w)]
        for p in ps: p.start()
        t = [q.get() for _ in ps]
        for p in ps: p.join()
        out['workers%d_wall_ms' % w] = round(max(t), 1)
    out['throughput_speedup'] = round(workers * out['workers1_wall_ms'] / out['workers%d_wall_ms' % workers], 2)
    return out

def bench(name):
    E = ENGINES[name]; res = {}; e = E(); print('==', name, flush=True)
    e.setup(FF); e.insert_players(gen_players()); e.after_load()
    res['a_set_update_10k_ms'] = median_ms(lambda: e.run(e.churn_sql()), 7); print(' a', res['a_set_update_10k_ms'], flush=True)
    if e.loop_sql: res['b_loop_update_10k_ms'] = median_ms(lambda: e.run(e.loop_sql), 3); print(' b', res['b_loop_update_10k_ms'], flush=True)
    else:
        def clientloop():
            for i in range(N): e.run('update players set x=x+0.1 where id=?', (i,))
        res['b_client_loop_not_in_db_ms'] = median_ms(clientloop, 3, warm=0)
    t, _ = ms(lambda: e.load_varints(gen_varints())); res['load_200k_varints_s'] = round(t/1000, 2); print(' load varints s', res['load_200k_varints_s'], flush=True)
    e.after_load()
    ref = None
    if e.fcall_sql:
        res['c1_stored_fn_200k_ms'] = median_ms(lambda: e.run(e.fcall_sql), 3); ref = e.run(e.fcall_sql)[0][0]; print(' c1', res['c1_stored_fn_200k_ms'], flush=True)
    res['c3_inline_expr_200k_ms'] = median_ms(lambda: e.run('select %s from pk_varint' % e.expr), 3)
    chk = e.run('select %s from pk_varint' % e.expr)[0][0]; res['checksum'] = int(chk); print(' c3', res['c3_inline_expr_200k_ms'], 'checksum', chk, flush=True)
    if ref is not None: assert int(ref) == int(chk), (ref, chk)
    rows = gen_inbox(); d = []
    for _ in range(5): e.clear_inbox(); d.append(ms(lambda: e.bulk_inbox(rows))[0])
    res['d_bulk_load_10k_ms'] = round(statistics.median(d), 1); print(' d', res['d_bulk_load_10k_ms'], flush=True)
    if hasattr(e, 'bulk_inbox_loaddata'):
        e.clear_inbox(); res['d_loaddata_10k_ms'] = round(ms(lambda: e.bulk_inbox_loaddata(rows))[0], 1)
    try: e.c.close()
    except Exception: pass
    variants = {'default': {}, 'open_snapshot': dict(snapshot=True)}
    if name == 'pg' and FF == 100: variants = {'ff100': {}, 'ff60': dict(ff=60), 'ff60_index_on_tick': dict(ff=60, extra_index=True), 'ff100_open_snapshot': dict(snapshot=True)}
    res['e_churn'] = {}
    for k, kw in variants.items():
        if kw.get('snapshot') and name == 'duckdb': continue
        res['e_churn'][k] = churn(E, **kw); print(' e', k, res['e_churn'][k], flush=True)
    if name != 'duckdb':
        res['parallel_4_regions'] = parallel(name); print(' par', res['parallel_4_regions'], flush=True)
    return res

if __name__ == '__main__':
    names = sys.argv[1:] or list(ENGINES)
    path = os.path.join(HERE, 'results.json')
    allres = json.load(open(path)) if os.path.exists(path) else {}
    for n in names:
        allres[n + ('' if FF == 100 or n != 'pg' else '_ff%d' % FF) + ('_rc' if os.environ.get('DB_MARIA_RC') and n == 'mariadb' else '')] = bench(n); json.dump(allres, open(path, 'w'), indent=1)
