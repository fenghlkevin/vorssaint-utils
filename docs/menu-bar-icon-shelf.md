# Independent menu-bar icon panel

The existing native macOS 27 visibility backend is unchanged. Settings adds two
reveal modes: `menuBar` (the default for existing users) and `shelf` (opt-in).
The independent panel currently requires macOS 27; earlier systems retain their
original spacer-based behavior.

## Interaction

- Click the divider or right-click Vorssaint while collapsed to toggle the panel.
- Optional hover opens after 350 ms over the divider.
- The nonactivating 60-point-high material panel anchors below the divider and
  clamps to its display's visible frame. Long rows scroll horizontally.
- Icon name tooltips can be disabled. Pin is temporary, reset on close.
- The existing delay preference controls automatic dismissal. Hovering inside
  or pinning cancels dismissal. Escape or an outside click closes the panel.
- The gear opens the existing menu-bar settings page, not another window type.

## Data and activation

Before a native collapse, cache the actual hidden-side items from MenuBarAgent.
The list uses the SAME bundle/system allowlist as hiding, so own icons and
applications represented on both sides are not incorrectly listed as hidden.
Never include unidentified groups as actionable buttons.

Use original application artwork, preserving its colors and transparency, with
adaptive template symbols for system or unavailable applications. Do not capture
screen pixels: the previous screen crops included wallpaper/menu-bar backgrounds
and produced visible square patches. This panel does not require Screen Recording
permission. Images fit a 20-point box inside a 36-point hit target; pin and gear
use consistent 16-point symbols. These are app icons, not live status indicators.
Refresh on the next open after display or running-app changes; refresh may briefly
reveal the original items to obtain current target data.

An icon click closes the panel, releases the hiding assertion, resolves the live
item again by owner and current frame, and issues **one AXPress**. The original
menu opens at its original menu-bar location, not a reimplemented menu in the
panel. There is no coordinate-based synthetic click fallback. Ambiguous
multi-icon owners or unsupported AX actions remain visible for manual use.
AX cannotComplete is not retried because a menu's tracking loop may block the
reply after opening successfully. This return value is not independent evidence
that a menu opened; live verification is required.

Mouse-up/Return/Escape after the interaction releases temporary expansion and
rehides after 400 ms. Changing mode, disabling, quitting, or a newer request
invalidates pending panel operations. Monitoring is active only while the panel
or a selected external control is being used. A dropped menu without an input
event can leave the original items expanded; the divider remains the recovery
control.

## Verification

`zsh Tools/test-menu-bar-native.sh` covers original backend routing and errors,
shelf membership, own/mixed-owner protection, unknown targets, multi-display
edge clamping, and all pin/hover/timeout dismissal-policy combinations.

Live checklist: both reveal modes; first launch; panel contents; selecting a
safe menu-only item; Escape/outside click; pin/unpin; five-second dismissal;
disable while open; screen changes; no Screen Recording permission fallback.

Settings uses native SwiftUI grouped controls and selectable mini-preview cards,
following the approved design while keeping the existing settings sidebar.

### 2026-09-17 local integration check

On macOS 27 with the existing Apple Development-signed Developer build:

- Both mode cards and the panel settings were exercised in the real settings UI.
- The live panel contained Codex 最近任务 and PasteMemo, with functional pin and
  settings buttons. Pin changed to `pin.fill` and persisted across observations.
- A test-only status app (`Tools/MenuBarShelfFixture.swift`) was placed to the
  left of the divider. Clicking its **panel** button opened its actual NSMenu,
  displaying “面板点击联动验证成功”. The target process independently emitted
  `SHELF_FIXTURE_MENU_OPEN` from NSMenuDelegate, confirming delivery beyond an
  AX return code. The fixture was then quit via its menu.
- The five-second setting was restored and the normal settings window closed;
  the Developer app remains running in shelf mode, hover disabled by default.
- Fixed an actual macOS 27 difference discovered during this check: direct
  MenuBarAgent item containers may have AXUnknown roles. Shelf enumeration now
  shares the same normalization as the working hiding path instead of dropping
  these items and showing an empty panel.

No claim is made that every third-party icon supports AXPress. Failed or
ambiguous targets deliberately fall back to manual activation in the original
menu bar. Visual screenshot inspection was limited by the UI provider choosing
the app's other floating window; panel contents were verified through live AX.

When rebuilding the fixture, explicitly pass `-target arm64-apple-macosx14.0`:
the installed Swift toolchain otherwise defaults to macOS 28, which prevents
LaunchServices from opening the test bundle on this machine.
