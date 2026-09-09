"""Exercise every public API with the ctypes loader disabled (also installed)."""
import sys
import tempfile
from pathlib import Path

# Call from the checkout, or pass an installed-package root from test_wheel.py.
package_root = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parents[1]
sys.path.insert(0, str(package_root))
sys.modules['libscanio._loader'] = None
import libscanio as s
from libscanio import _native

assert s.build_mode() == 'ReleaseFast'
print('CHECKPOINT 0: import + build_mode ok', flush=True)
with tempfile.TemporaryDirectory() as td:
    path = Path(td) / 'rows.csv'
    path.write_text('id,amount,label\n1,10,alpha\n2,-2,beta\n3,oops,"café, quoted"\n', encoding='utf-8')
    p = str(path)
    names = s.schema(p)
    print('CHECKPOINT 1: schema ok', flush=True)
    expected = [('1', '10', 'alpha'), ('2', '-2', 'beta'), ('3', 'oops', 'café, quoted')]
    dicts = [dict(zip(names, r)) for r in expected]
    assert list(s.scan(p)) == dicts
    print('CHECKPOINT 2: scan ok', flush=True)
    assert s.scan_array(p) == expected
    print('CHECKPOINT 3: scan_array ok', flush=True)
    assert s.scan_array(p, columns=['label','id'], limit=2) == [('alpha','1'),('beta','2')]
    print('CHECKPOINT 4: scan_array columns/limit ok', flush=True)
    assert [r for b in s.scan_batches(p, batch_size=2) for r in b] == dicts
    print('CHECKPOINT 5: scan_batches ok', flush=True)
    assert s.count(p) == 3
    print('CHECKPOINT 6: count() bare ok', flush=True)
    assert s.count(p, where='id >= 2') == 2
    print('CHECKPOINT 7: count() where ok', flush=True)
    assert s.aggregate(p,'amount') == dict(count=2, sum=8., min=-2., max=10., avg=4.)
    print('CHECKPOINT 8: aggregate ok', flush=True)
    assert s.topk(p, 'amount', 1)[0]['id'] == '1'
    print('CHECKPOINT 9: topk ok', flush=True)
    assert s.topk(p, 'amount', 1, where='id = 1')[0]['label']=='alpha'
    print('CHECKPOINT 10: topk where ok', flush=True)
    assert s.order_by(p, 'amount', where='id = 1')[0]==dicts[0]
    print('CHECKPOINT 11: order_by where ok', flush=True)
    assert [r['id'] for r in s.order_by(p,'id',descending=True)] == ['3','2','1']
    print('CHECKPOINT 12: order_by desc ok', flush=True)
    assert s.profile(p)['row_count'] == 3
    print('CHECKPOINT 13: profile ok', flush=True)
    assert s.describe(p)[0]['type'] == 'integer'
    print('CHECKPOINT 14: describe ok', flush=True)
    assert s.infer_schema(p)['id'] == {'type':'integer'}
    print('CHECKPOINT 15: infer_schema ok', flush=True)
    rules = {'amount': {'type':'float','min':0}}
    assert s.validate(p,rules) is False
    print('CHECKPOINT 16: validate ok', flush=True)
    assert len(s.validate(path.read_bytes(),rules,mode='full')) == 2
    print('CHECKPOINT 17: validate full ok', flush=True)
    assert s.validate_report(p,rules).rows_invalid == 2
    print('CHECKPOINT 18: validate_report ok', flush=True)
    stream = list(s.validate_iter(p,rules))
    assert [bool(e) for _,e in stream] == [False,True,True]
    print('CHECKPOINT 19: validate_iter ok', flush=True)
    assert [r for b in s.validate_batches(p,rules,batch_size=2) for r in b] == stream
    print('CHECKPOINT 20: validate_batches ok', flush=True)
    stats=s.validate_to_files(p,rules,str(Path(td)/'good.csv'),str(Path(td)/'bad.jsonl'))
    assert stats == dict(rows_total=3,rows_valid=1,rows_invalid=2,errors_total=2)
    print('CHECKPOINT 21: validate_to_files ok', flush=True)
    # Raw handles cannot be closed twice or consumed after close.
    q=_native.query_open(p.encode(), b'{}');_native.close(q);_native.close(q)
    try:_native.next_batch(q,1,100,False)
    except ValueError:pass
    else:raise AssertionError('closed handle accepted')
    print('CHECKPOINT 22: raw handle double-close ok', flush=True)
    # Scalar and batch construction preserve embedded NULs, including sort paths.
    path.write_bytes(b'id,value\n1,nul\x00tail\n2,plain\n')
    assert next(s.scan(p))['value']=='nul\x00tail'
    print('CHECKPOINT 23: NUL scan ok', flush=True)
    assert s.scan_array(p,limit=1)[0][1]=='nul\x00tail'
    print('CHECKPOINT 24: NUL scan_array limit ok', flush=True)
    assert s.scan_array(p)[0][1]=='nul\x00tail'
    print('CHECKPOINT 25: NUL scan_array ok', flush=True)
    assert s.topk(p,'id',2,descending=False)[0]['value']=='nul\x00tail'
    print('CHECKPOINT 26: NUL topk ok', flush=True)
    assert s.order_by(p,'id')[0]['value']=='nul\x00tail'
    print('CHECKPOINT 27: NUL order_by ok', flush=True)
    path.write_bytes(b'a,b\n,\n,\n')
    assert s.scan_array(p)==[('',''),('','')]
    print('CHECKPOINT 28: empty fields scan_array ok', flush=True)
    assert s.scan_array(p,where='a = absent')==[]
    print('CHECKPOINT 29: empty fields where ok', flush=True)
    path.write_bytes(b'a,b\n')
    assert s.schema(p)==['a','b']
    print('CHECKPOINT 30: header-only schema ok', flush=True)
    assert s.scan_array(p)==[]
    print('CHECKPOINT 31: header-only scan_array ok', flush=True)
print('All 17 public APIs passed without the ctypes loader')
