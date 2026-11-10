#!/usr/bin/env python3
"""Live lifecycle regression; only stops PIDs created by this harness."""
import subprocess, sys, os, signal, time
binary = sys.argv[1]
def alive(pid):
    result = subprocess.run(['/bin/ps','-p',str(pid),'-o','stat='],capture_output=True,text=True)
    return bool(result.stdout.strip()) and not result.stdout.strip().startswith('Z')
def child_of(pid):
    for _ in range(30):
        result = subprocess.run(['/bin/ps','-axo','pid=,ppid=,comm='],capture_output=True,text=True)
        for line in result.stdout.splitlines():
            fields = line.split(None,2)
            if len(fields)==3 and fields[1]==str(pid) and fields[2]=='/usr/bin/nettop':return int(fields[0])
        time.sleep(.02)
    raise AssertionError('nettop child not started')
for mode in ['--lifeline-close','--worker-term','--parent-kill']:
    parent = subprocess.Popen([binary,mode],stdout=subprocess.PIPE,text=True)
    worker = int(parent.stdout.readline())
    sampler = child_of(worker)
    try:
        if mode=='--parent-kill':parent.kill()
        parent.wait(timeout=4)
        deadline=time.monotonic()+3
        while time.monotonic()<deadline and (alive(worker) or alive(sampler)):time.sleep(.05)
        assert not alive(worker),f'{mode}: worker survived'
        assert not alive(sampler),f'{mode}: sampler survived'
        print(mode+': parent / worker / nettop cleanup passed')
    finally:
        for pid in [sampler,worker,parent.pid]:
            if alive(pid):
                try:os.kill(pid,signal.SIGKILL)
                except ProcessLookupError:pass
