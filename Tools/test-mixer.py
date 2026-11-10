#!/usr/bin/env python3
"""Run the real disconnect/restore routines with in-memory HAL devices."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
mixer = (root / 'Sources/Vorssaint/Services/Audio/AppVolumeMixer.swift').read_text()
start = mixer.index('    private struct LoweredOutput {')
end = mixer.index('    /// Teardown path', start)
routines = mixer[start:end].replace('private ', '')
contract = (root / 'Tests/MixerHeadphonesDisconnectTests.swift').read_text()
contract = contract.replace('static func setOutputVolume(_ volume: Float32, for device: AudioObjectID) -> Bool {',
                            'static func setOutputVolume(_ volume: Float32, for device: AudioObjectID, controlsMute: Bool = true) -> Bool {')
contract = contract.replace('            volumes[device] = volume',
                            '            volumes[device] = volume\n            if controlsMute { setOutputMuted(volume == 0, for: device) }')
contract = contract.replace('        typealias MixerOutputDevice', routines + '\n        typealias MixerOutputDevice')
harness = '''
final class TestSuite {
    var checks = 0
    func expect(_ condition: Bool, _ message: String) {
        checks += 1
        precondition(condition, message)
    }
}
@main struct MixerTests {
    static func main() {
        let suite = TestSuite()
        MixerHeadphonesDisconnectContract.run(suite)
        print("Mixer disconnect/restore: \\(suite.checks) checks passed (mock audio devices)")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='vorssaint-mixer-') as directory:
    generated = Path(directory) / 'MixerTests.swift'
    generated.write_text(contract + harness)
    binary = Path(directory) / 'mixer-tests'
    subprocess.run(['swiftc', str(root / 'Sources/Vorssaint/Services/Audio/MixerRoutingSupport.swift'),
                    str(generated), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
