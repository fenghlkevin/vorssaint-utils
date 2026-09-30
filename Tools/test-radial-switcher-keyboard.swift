import Foundation
import CoreGraphics
struct GlobalShortcut: Equatable {
 let keyCode: Int64
 let flags: CGEventFlags
 static let radialSwitcherDefault = GlobalShortcut(keyCode: 13, flags: [.maskCommand, .maskAlternate, .maskControl])
 static let switcherDefault = GlobalShortcut(keyCode: 48, flags: .maskCommand)
 func matches(event: CGEvent, allowingExtraShift: Bool) -> Bool {
  var actual = event.flags
  if allowingExtraShift { actual.remove(.maskShift) }
  return event.getIntegerValueField(.keyboardEventKeycode) == keyCode && actual == flags
 }
 func requiredModifiersHeld(in actual: CGEventFlags) -> Bool { actual.intersection(flags) == flags }
}
final class RadialSwitcherService {
 static let shared = RadialSwitcherService()
 var calls: [String] = []
 func commitKeyboardSelection() { calls.append("commit") }
 func keyboardStep(first: Bool, reverse: Bool) { calls.append("step:\(first):\(reverse)") }
 func dismiss() { calls.append("dismiss") }
 func openKeyboardChildren() { calls.append("children") }
}
@main struct Tests {
 static func send(_ type: CGEventType, _ key: Int64, _ flags: CGEventFlags = []) -> Bool {
  let e = CGEvent(source: nil)!
  e.type = type; e.flags = flags; e.setIntegerValueField(.keyboardEventKeycode, value: key)
  return RadialSwitcherKeyboard.route(type: type, event: e)
 }
 static func drain() { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03)) }
 static func main() {
  RadialSwitcherKeyboard.configure(enabled: true, shortcut: .switcherDefault, holdToSelect: false)
  assert(send(.keyDown,48,.maskCommand))
  assert(send(.keyUp,48,.maskCommand))
  drain(); assert(RadialSwitcherService.shared.calls == ["step:true:false"])
  assert(send(.keyDown,48,[.maskCommand,.maskShift]))
  assert(send(.keyUp,48,[.maskCommand,.maskShift]))
  assert(!send(.flagsChanged,56,.maskCommand))
  assert(!send(.flagsChanged,55))
  drain(); assert(RadialSwitcherService.shared.calls == ["step:true:false","step:false:true","commit"])
  RadialSwitcherService.shared.calls=[]
  assert(send(.keyDown,48,.maskCommand))
  assert(!send(.flagsChanged,55))
  drain(); assert(RadialSwitcherService.shared.calls == ["step:true:false","commit"])
  RadialSwitcherService.shared.calls=[]
  assert(send(.keyDown,48,.maskCommand)); assert(send(.keyDown,53,.maskCommand))
  assert(!send(.flagsChanged,55)); drain()
  assert(RadialSwitcherService.shared.calls == ["step:true:false","dismiss"])
  RadialSwitcherKeyboard.configure(enabled: false, shortcut: .switcherDefault, holdToSelect: true)
  assert(!send(.keyDown,48,.maskCommand))
  print("PASS: repeat, reverse, Tab release, Command release, quick flick, Escape, disabled passthrough")
 }
}
