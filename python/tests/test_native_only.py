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
with tempfile.TemporaryDirectory() as td:
    path = Path(td) / 'rows.csv'
    path.write_text('id,amount,label\n1,10,alpha\n2,-2,beta\n3,oops,"café, quoted"\n', encoding='utf-8')
    p = str(path)
    names = s.schema(p)
    expected = [('1', '10', 'alpha'), ('2', '-2', 'beta'), ('3', 'oops', 'café, quoted')]
    dicts = [dict(zip(names, r)) for r in expected]
    assert list(s.scan(p)) == dicts
    assert s.scan_array(p) == expected
    assert s.scan_array(p, columns=['label','id'], limit=2) == [('alpha','1'),('beta','2')]
    assert [r for b in s.scan_batches(p, batch_size=2) for r in b] == dicts
    assert s.count(p) == 3 and s.count(p, where='id >= 2') == 2
    assert s.aggregate(p,'amount') == dict(count=2, sum=8., min=-2., max=10., avg=4.)
    assert s.topk(p, 'amount', 1)[0]['id'] == '1'
    assert s.topk(p, 'amount', 1, where='id = 1')[0]['label']=='alpha'
    assert s.order_by(p, 'amount', where='id = 1')[0]==dicts[0]
    assert [r['id'] for r in s.order_by(p,'id',descending=True)] == ['3','2','1']
    assert s.profile(p)['row_count'] == 3
    assert s.describe(p)[0]['type'] == 'integer'
    assert s.infer_schema(p)['id'] == {'type':'integer'}
    rules = {'amount': {'type':'float','min':0}}
    assert s.validate(p,rules) is False
    assert len(s.validate(path.read_bytes(),rules,mode='full')) == 2
    assert s.validate_report(p,rules).rows_invalid == 2
    stream = list(s.validate_iter(p,rules))
    assert [bool(e) for _,e in stream] == [False,True,True]
    assert [r for b in s.validate_batches(p,rules,batch_size=2) for r in b] == stream
    stats=s.validate_to_files(p,rules,str(Path(td)/'good.csv'),str(Path(td)/'bad.jsonl'))
    assert stats == dict(rows_total=3,rows_valid=1,rows_invalid=2,errors_total=2)
    # Raw handles cannot be closed twice or consumed after close.
    q=_native.query_open(p.encode(), b'{}');_native.close(q);_native.close(q)
    try:_native.next_batch(q,1,100,False)
    except ValueError:pass
    else:raise AssertionError('closed handle accepted')
    # Scalar and batch construction preserve embedded NULs, including sort paths.
    path.write_bytes(b'id,value\n1,nul\x00tail\n2,plain\n')
    assert next(s.scan(p))['value']=='nul\x00tail'
    assert s.scan_array(p,limit=1)[0][1]=='nul\x00tail'
    assert s.scan_array(p)[0][1]=='nul\x00tail'
    assert s.topk(p,'id',2,descending=False)[0]['value']=='nul\x00tail'
    assert s.order_by(p,'id')[0]['value']=='nul\x00tail'
    path.write_bytes(b'a,b\n,\n,\n')
    assert s.scan_array(p)==[('',''),('','')]
    assert s.scan_array(p,where='a = absent')==[]
    path.write_bytes(b'a,b\n')
    assert s.schema(p)==['a','b']
    assert s.scan_array(p)==[]
print('All 17 public APIs passed without the ctypes loader')
