import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

binary = sys.argv[1]
with tempfile.TemporaryDirectory(prefix='codex-island-bridge-') as directory:
    root = Path(directory)
    env = dict(os.environ, VORSSAINT_ISLAND_TEST_ROOT=directory)
    payload = json.dumps({'hook_event_name': 'PermissionRequest', 'session_id': 'same-session',
                          'cwd': '/project/demo', 'tool_name': 'Bash',
                          'tool_input': {'command': 'fixture-only-no-execution'}}).encode()
    # Absent app must leave the native Codex approval prompt in charge immediately.
    result = subprocess.run([binary], input=payload, env=env, capture_output=True, timeout=3)
    assert result.returncode == 0 and result.stdout == b'' and not (root / 'inbox').exists()
    heartbeat = root / 'heartbeat'
    heartbeat.touch()
    children = []
    try:
        for _ in range(2):
            child = subprocess.Popen([binary], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
            child.stdin.write(payload)
            child.stdin.close()
            children.append(child)
        deadline = time.monotonic() + 5
        events = []
        while time.monotonic() < deadline:
            events = [json.loads(p.read_text()) for p in (root / 'inbox').glob('*.json')]
            if len(events) >= 2:
                break
            time.sleep(.05)
        ids = [event['approvalID'] for event in events if event['event'] == 'PermissionRequest']
        assert len(set(ids)) == 2, events
        responses = root / 'responses'
        responses.mkdir()
        for request_id, decision in zip(ids, ['allow', 'deny']):
            (responses / (request_id + '.response')).write_text(decision)
        outcomes = []
        for child in children:
            child.wait(timeout=3)
            reply = json.loads(child.stdout.read())
            outcomes.append(reply['hookSpecificOutput']['decision']['behavior'])
            assert child.returncode == 0
        assert sorted(outcomes) == ['allow', 'deny']
        events = [json.loads(p.read_text()) for p in (root / 'inbox').glob('*.json')]
        assert len([e for e in events if e['event'] == 'ApprovalResolved']) == 2
        assert not list(responses.glob('*.response'))
        # Losing the receiver must release a waiting hook without making an approval decision.
        child = subprocess.Popen([binary], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
        children.append(child)
        child.stdin.write(payload)
        child.stdin.close()
        time.sleep(.3)
        os.utime(heartbeat, (1, 1))
        child.wait(timeout=3)
        assert child.stdout.read() == b'' and child.returncode == 0
    finally:
        for child in children:
            if child.poll() is None:
                child.kill()
                child.wait()
print('Codex bridge subprocess tests passed: fail-open, simultaneous approvals, allow/deny correlation, acknowledgment, cleanup and receiver loss.')

# Native routing must never produce an allow/deny decision or an island request.
with tempfile.TemporaryDirectory(prefix='codex-island-routing-') as directory:
    root = Path(directory)
    env = dict(os.environ, VORSSAINT_ISLAND_TEST_ROOT=directory)
    (root / 'heartbeat').touch()
    routing = root / 'approval-destination'
    routing.write_text('codex')
    result = subprocess.run([binary], input=payload, env=env, capture_output=True, timeout=3)
    assert result.returncode == 0 and result.stdout == b''
    assert not list((root / 'inbox').glob('*.json'))
    routing.write_text('island')
    child = subprocess.Popen([binary], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
    try:
        child.stdin.write(payload)
        child.stdin.close()
        deadline = time.monotonic() + 3
        while not list((root / 'inbox').glob('*.json')) and time.monotonic() < deadline:
            time.sleep(.05)
        assert list((root / 'inbox').glob('*.json'))
        routing.write_text('codex')
        child.wait(timeout=3)
        assert child.returncode == 0 and child.stdout.read() == b''
        events = [json.loads(p.read_text()) for p in (root / 'inbox').glob('*.json')]
        assert any(e['event'] == 'ApprovalHandedOff' for e in events)
    finally:
        if child.poll() is None:
            child.kill()
            child.wait()
print('Approval routing tests passed: native pass-through and pending handoff without approval.')
