"""Real core test: killing its UI parent must not kill the background session."""
import hashlib
import json
import os
import pathlib
import signal
import socket
import subprocess
import sys
import time
import urllib.request

root = pathlib.Path(sys.argv[1]).resolve()
root.mkdir(mode=0o700, parents=True, exist_ok=True)
core, guardian = sys.argv[2:4]
path = '/private/tmp/vorssaint-agent-{}-{}.sock'.format(os.getuid(), hashlib.sha256(str(root).replace('/private/tmp/', '/tmp/', 1).encode()).hexdigest()[:24])

def request(command, **fields):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as channel:
        channel.settimeout(15)
        channel.connect(path)
        channel.sendall(json.dumps(dict(command=command, identifier='lifetime-test', **fields)).encode() + b'\n')
        data = b''
        while b'\n' not in data:
            part = channel.recv(8192)
            if not part:
                raise RuntimeError('service lost reply')
            data += part
        result = json.loads(data)
        assert result['success'], result['message']
        return result

# A separate process represents the UI. Kill the actual parent, not merely a socket.
owner = subprocess.Popen([sys.executable, '-c', '''
import subprocess,sys,time
log=open(sys.argv[-1]+'/guardian-test.log','w')
p=subprocess.Popen(sys.argv[1:],stdin=subprocess.DEVNULL,stdout=log,stderr=log)
print(p.pid,flush=True)
while True: time.sleep(1)
''', guardian, str(root)], stdout=subprocess.PIPE, text=True)
guardian_pid = int(owner.stdout.readline())
try:
    for _ in range(100):
        if pathlib.Path(path).exists(): break
        time.sleep(.05)
    assert pathlib.Path(path).exists(), 'guardian did not bind '+path+'; '+(root/'guardian-test.log').read_text()
    work = root / 'runtime'
    work.mkdir(mode=0o700)
    config = work / 'runtime.yaml'
    config.write_text(json.dumps({'mixed-port': 27891, 'external-controller': '127.0.0.1:29091', 'secret': 'local-lifetime-test',
                                 'mode': 'direct', 'proxies': [], 'rules': ['MATCH,DIRECT']}))
    started = request('start', corePath=core, workPath=str(work), configPath=str(config))
    pid = started['corePID']
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    def probe():
        req = urllib.request.Request('http://127.0.0.1:29091/version', headers={'Authorization': 'Bearer local-lifetime-test'})
        with opener.open(req, timeout=2) as response:
            assert response.status == 200
    for _ in range(50):
        try: probe(); break
        except Exception: time.sleep(.1)
    else: raise RuntimeError('core failed to start')
    request('commit')
    owner.kill(); owner.wait(timeout=3)
    time.sleep(1)
    os.kill(pid, 0)
    probe()
    assert request('status')['corePID'] == pid
    assert pathlib.Path(path).stat().st_mode & 0o077 == 0
    print('SIGKILL of UI parent preserved the same live core and private control socket')
    os.kill(pid, signal.SIGKILL)
    for _ in range(100):
        status = request('status')
        if status.get('configPath') is None: break
        time.sleep(.1)
    else: raise RuntimeError('guardian did not observe core crash')
    assert status.get('corePID') is None
    assert not status['committed']
    print('Background supervisor detected core SIGKILL and cleared its session without UI')
finally:
    if owner.poll() is None: owner.kill(); owner.wait()
    try: request('exit')
    except Exception:
        try: os.kill(guardian_pid, signal.SIGTERM)
        except ProcessLookupError: pass
