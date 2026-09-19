"""Regression: launchd BundleProgram uses a relative argv[0] and unrelated cwd."""
import pathlib
import shutil
import subprocess
import sys
import tempfile

with tempfile.TemporaryDirectory(prefix='vorssaint-bundle-path-', dir='/private/tmp') as directory:
    contents = pathlib.Path(directory) / 'Fixture.app' / 'Contents'
    helper = contents / 'Helpers' / 'VorssaintProxyGuardian'
    core = contents / 'Resources' / 'ProxyCore' / 'mihomo-darwin-arm64'
    helper.parent.mkdir(parents=True)
    core.parent.mkdir(parents=True)
    shutil.copy2(sys.argv[1], helper)
    core.touch()
    for argv0 in ('Contents/Helpers/VorssaintProxyGuardian', str(helper)):
        accepted = subprocess.run([argv0, '--check-bundled-core', str(core)], executable=str(helper), cwd='/')
        assert accepted.returncode == 0, 'bundled core rejected with argv0=' + argv0
        rejected = subprocess.run([argv0, '--check-bundled-core', '/private/tmp/mihomo-darwin-arm64'], executable=str(helper), cwd='/')
        assert rejected.returncode == 1, 'external core accepted'
print('Bundled core accepted for relative/absolute argv0; external core rejected')
