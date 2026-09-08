"""Build/install a real wheel and exercise it outside the source checkout."""
from pathlib import Path
import subprocess
import sys
import tempfile
import zipfile

root = Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory() as directory:
    work = Path(directory)
    subprocess.check_call([sys.executable, '-m', 'pip', 'wheel', str(root / 'python'),
                           '--no-build-isolation', '--no-deps', '-w', str(work)])
    wheel, = work.glob('*.whl')
    assert not wheel.name.endswith('none-any.whl'), wheel
    with zipfile.ZipFile(wheel) as archive:
        assert any('_native' in n and n.endswith(('.so', '.pyd')) for n in archive.namelist())
    target = work / 'installed'
    subprocess.check_call([sys.executable, '-m', 'pip', 'install', '--no-deps', '--target', str(target), str(wheel)])
    code = '''
import sys
sys.path.insert(0, sys.argv[1])
import libscanio
from libscanio import _native
assert _native.build_mode() == 'ReleaseFast'
assert libscanio.build_mode() == 'ReleaseFast'
assert libscanio.validate(b'a\\n1\\n', {'a': {'min': 0}}) is True
assert libscanio.validate(b'a\\n-1\\n', {'a': {'min': 0}}) is False
r = libscanio.validate(b'a\\n-1\\n', {'a': {'min': 0}}, mode='full')
assert r == [{'values': ['-1'], 'errors': [{'column': 0, 'column_name': 'a', 'rule': 'below_min', 'value': '-1'}]}]
from pathlib import Path
assert Path(libscanio.__file__).resolve().is_relative_to(Path(sys.argv[1]).resolve())
print('Installed wheel: running the complete Python binding suite', flush=True)
import runpy
runpy.run_path(sys.argv[2], run_name='__main__')
'''
    subprocess.check_call([sys.executable, '-I', '-c', code, str(target), str(root / 'python' / 'tests' / 'test_scan.py')], cwd=work)
