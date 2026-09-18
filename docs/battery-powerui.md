# macOS 27 PowerUI system-limit backend

Reference: BatFi tag 4.0.0, commit 72d4ae0052fcf8d6a004cecefd14962daf81cefa,
`BatFiKit/Sources/Server/PowerUICharging.swift` (MIT, Adam Różyński).
The selector names informed an independently written, ABI-checked adapter.

On the local macOS 27 machine, a read-only runtime inspection reports:

```
isMCLCurrentlyEnabled: Q24@0:8^@16
getMCLLimitWithError: C24@0:8^@16
setMCLLimit:error: B28@0:8C16^@20
enableMCL: B24@0:8^@16
disableMCL: B24@0:8^@16
```

`Q` is an unsigned 64-bit result, not BOOL. This query is unnecessary for
BatFi's standard get/set-limit route. We do not call it or enable/disable the
system feature. The UI advises enabling the feature in System Settings when
needed; reading a limit does not prove the system feature is enabled.

When SMC discovery reports missing keys or unsupported layout, the helper tries
PowerUI's standard-limit path. Transport/readback errors do not silently switch
controllers. Only system-reported values within 80–100 in 5-point increments
are accepted. Unsupported values are rejected, not rounded upward.

The user must separately opt in to system-limit management. There is no sub-80
defaults hack, temporary override, forced discharge, immediate pause, custom
thermal/sleep/resume policy or LED control on this backend. macOS owns these
behaviors. SMC functionality remains on supported machines.

## Recovery

- A shared root lock excludes other Vorssaint release/development controllers.
- Original, previous and requested limits are persisted before attempted writes
  in a root-owned 0700 directory / 0600 regular single-link file.
- Saving uses exclusive temporary files, fsync, atomic rename and directory fsync.
- Unchanged polls never keep writing the target; delayed readback stays pending.
- A successful getter confirms only the setting, not physical enforcement.
- Disconnect, disabling management, shutdown and heartbeat expiry request original
  limit restoration. Startup restores pending journals before accepting an owner.
- Migration refuses retirement when a system-limit journal remains.
- Unexpected external settings stop writes and retain the recovery record.
  Do not run BatFi/other controllers concurrently: there is no cross-vendor lock,
  and identical external writes cannot be distinguished from ours.
- Restoration concerns only the saved limit, not arbitrary macOS power settings.

## Verification

Local read-only macOS 27 query returned `[80, 85, 90, 95, 100]` and current
limit `100`. No setter was invoked during development verification. Framework
access is restricted in the tooling sandbox; the read-only probe ran outside it.

`Tools/test-battery-control.sh` includes mocks for range rejection, journal-before-
write, repeated polling, delayed readback, restart, external edits and setters
that change state before reporting failure. File tests cover persistence,
corrupt records and symlinks.

### Signed live verification — 2026-09-17

Installed development build `20260917193016`, using the existing Apple Development
certificate. The authenticated running helper and embedded helper both reported
CDHash `495067906af6c41763f5b0f6388b941b329d431f`.

A concurrent packaging task subsequently installed build `20260917193153`.
The final installed bundle passed strict signature verification, retained the
same helper CDHash and signing identity, and was confirmed running (PID 31579).
The tested helper binary therefore matches the final installed helper.

`Tools/BatteryLiveTest.swift`, compiled with `VORSSAINT_DEVELOPMENT` and signed
with the same certificate/app identifier, exercised the installed root helper
over authenticated XPC. It is an explicit test, not part of the install script:

- Baseline: system limit 100; helper inactive; no BatFi/AlDente process detected.
- Apply: requested 85; getter returned 85 and helper reported active.
- After asynchronous propagation, powerd policy observation returned 85.
- Restore: helper returned inactive and getter 100; a subsequent independent
  status query showed no remaining 85 policy (policy absent/unknown, not claimed 100).
- Main App was restarted after testing; system-limit opt-in preferences were not
  enabled by the test. Original system limit remains 100.

Battery was already full at 100%, connected to AC and not charging before and
during testing (reported battery current zero). This verifies setting, observed
policy and restore, NOT a charging-to-not-charging physical transition.

Migration also exposed macOS 27 `.notFound` after safe old-helper retirement:
unregister returned EPERM. Registering the current embedded helper directly,
as the existing interactive authorization path already does, completed migration.

The new Helper window explains installation, updating and privileged repair,
requests an explicit continuation, and displays existing live authorization,
connection and compatibility states. Closing the window does not cancel a
system operation already in progress. No installation or registration reset is
added to packaging scripts.

### Explicit helper reinstallation

Battery settings always offers “重新安装充电控制助手…”, including when the
installed version already matches. A confirmation window explains the steps,
system authorization and progress. The app validates its embedded signature,
requests safe retirement from the authenticated old helper, unregisters only
after restoration is acknowledged, then registers the embedded helper and
performs a fresh handshake. Settings and logs are preserved; recovery records
are never forcibly deleted. Missing/unregistered helpers use the normal
registration/approval path. A failed retirement offers a separately confirmed
administrator repair, not an automatic process kill. After safe administrator
retirement, `.notFound`/`.notRegistered` goes directly to registration to avoid
the macOS 27 unregister-EPERM failure. This action does not claim to fix an
unsupported firmware interface or to confirm physical charging behavior.
