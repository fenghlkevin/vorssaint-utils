# Menu bar section implementation

Reference: https://github.com/thaw-app/Thaw/blob/dacd6563f5307a9e4c8aa397aeb20cec420e1012/Thaw/MenuBar/ControlItem/ControlItem.swift

Thaw (GPL-3.0, see its LICENSE and source copyright notices) informed the
nonzero status-item materialization, active horizontal layout constraint,
and invisible/noninteractive collapsed section boundary used here.
Vorssaint uses its existing main icon's right-click action to reveal the section.
No Thaw source files are bundled.

The previous 18 anonymous status items have been removed. Their creation was
not evidence of successful hiding. Likewise a 10,000-point requested length
being clipped by WindowServer does not establish a macOS compatibility failure.
Live verification must compare the target icons before and after toggling,
including restoration and the availability of the main icon.

## macOS 27 investigation result

The default development branch explicitly declares macOS 27 unsupported in
`Thaw/Utilities/MacOSCompatibilityWarning.swift`. Its control-item approach did
not hide the target icons in the local screen check; this migration is incomplete.

The dedicated `macos-27-preview.5` tag (528b9503b051cc1ccccae766014e64404670088b)
instead delegates concealment to PlatformRuntimeKit, using assessment assertions
or a preferred-position backend. Its package lock references
https://github.com/thaw-app/prk-bin at revision
5393880d041080bd22f0bf27cf3aa2e913a8f905 (0.0.11). That repository returned
`Repository not found` during this investigation. The public preview source
does not include the implementation required to port those backends.

## OnlySwitch native backend (2026-09-17)

OnlySwitch published a complete implementation in commit
[`de3bf17`](https://github.com/jacklandrin/OnlySwitch/commit/de3bf17fa8338412a0c9b4d8d36a6b9e19a5952a)
("fix hide menu bar icons on macOS 27"). This removes the need for the
unavailable Thaw runtime source.

Vorssaint adapts its MIT-licensed bridge, accessibility resolver and visibility
applier. Attribution is in the source headers; the full MIT notice is shipped
in the app as `OnlySwitch-LICENSE.txt`.

- macOS 27+: dynamically load MenuBarClientCore and use an
  MBAssessmentModeAssertion with allowed bundle IDs and system item IDs.
- Earlier macOS: retain the existing status-item spacer.
- The same divider determines left/right selection. On macOS 27 it remains
  normal width and clickable while collapsed.
- Resolve MenuBarAgent accessibility groups on the divider's display using
  screen-converted button bounds, not the status window's old geometry.
- Keep Vorssaint's own bundle and apps represented on both sides visible.
  The native API controls application bundles, not individual icons.
- Requires Accessibility and an eligible Apple team signature. Do not silently
  replace the installed signing identity or fall back to a broken spacer.
- Serialize requests, ignore stale UI completions, release on disable/quit,
  and time out native activation after eight seconds.
- Test with `zsh Tools/test-menu-bar-native.sh`.

This is a private beta-system API and may change. Compilation and simulated
tests alone do not establish live hiding; compare actual target icons before
and after toggling, including restoration and the recovery control.

### Local verification

On macOS 27 build 26A428 with the existing Apple Development identity:

- The installed Developer app started collapsed without a manual first click.
- The settings UI reported successful collapse, not a placement/permission error.
- MenuBarAgent's live accessibility tree exposed Codex 最近任务 and PasteMemo
  in the expanded state; their controls disappeared after collapse. The divider,
  Vorssaint main/battery controls, Wi-Fi, Control Center and clock remained.
- Clicking the divider restored the hidden controls.
- Disabling the feature while collapsed restored the application items and
  removed the divider. Re-enabling and restoring the original five-second
  timeout successfully collapsed again.
- Native-bridge simulated tests passed, and installed code signing was verified.

The UI screenshot provider returned blank menu-bar images, so the live
comparison above is accessibility-tree evidence, not a visual screenshot claim.


### 2026-09-18 packaging regression: development signer continuity

A later proxy build used the script's default `Vorssaint Utils Signing` identity,
which produces no TeamIdentifier. This fails the native menu bar bridge's signature
eligibility check even though `codesign --verify` succeeds.

Development packaging now resolves a valid Apple Development identity before
compiling, preserves an existing installed Apple Development signer, and rejects
missing/ambiguous identities instead of falling back to legacy/ad-hoc signatures.
`VORSSAINT_DEV_SIGNING_IDENTITY` accepts an explicit matching name or SHA-1;
the resolved SHA-1 is propagated to install subprocesses. A legacy-signed installed
bundle may migrate to the single available Apple Development identity.

Before installation and after signing, packaging verifies the Apple anchor,
nonempty identical Team IDs, and exact selected leaf certificate for the app,
fan/battery/network helpers, proxy guardian and Mihomo core. Installing a stale
self-signed stage now fails before stopping or replacing the installed app.

Runtime availability is checked before menu bar enumeration. Signature rejection,
AX menu-reading failure and native assertion failure have separate messages.
Signing-selection tests and native menu-bar regression tests cover the new paths.
No TCC database reset or global permission removal is required by this change.

Installed build `20260918155523` was verified with Apple Development Team
`25G6C8X5S8`. Live UI initially retained an Accessibility-denied message, but the
permission page subsequently reported granted; retrying collapse succeeded. The
settings button changed to Expand and the placement-success message appeared.
MenuBarAgent no longer exposed PasteMemo / Codex recent-task icons while retaining
Vorssaint and its divider. Expanding restored both applications' controls.
The existing running battery helper reported a signer mismatch and still requires
its administrator-safe repair flow; it was not force-stopped or silently replaced.
