"""Extract the fixed comparison source from this repository's preserved history."""
import argparse
import io
from pathlib import Path
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[1]
REVISION = '82ad185fad98bcebf191df047494a9561ffb043b'
SOURCE = ROOT / 'build/c-baseline'


def source():
    if not SOURCE.exists():
        archive = subprocess.check_output(['git', 'archive', REVISION], cwd=ROOT)
        SOURCE.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix='c-baseline-', dir=SOURCE.parent) as temporary:
            prepared = Path(temporary) / 'source'
            prepared.mkdir()
            with tarfile.open(fileobj=io.BytesIO(archive)) as files:
                files.extractall(prepared, filter='data')
            (prepared / '.baseline-revision').write_text(REVISION + '\n')
            prepared.rename(SOURCE)
    assert (SOURCE / '.baseline-revision').read_text().strip() == REVISION
    return SOURCE


def build():
    subprocess.run(['make'], cwd=source(), check=True)
    return SOURCE / 'build/kiln'


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build', action='store_true')
    args = parser.parse_args()
    print(build() if args.build else source())
