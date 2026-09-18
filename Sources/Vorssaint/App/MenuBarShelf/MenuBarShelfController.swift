// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import SwiftUI

struct MenuBarShelfIcon: Identifiable {
    let target: MenuBarShelfTarget
    let image: NSImage
    var id: String { target.id }
}

/// Short-lived nonactivating utility panel. Monitoring exists only while open.
final class MenuBarShelfController: NSObject, ObservableObject {
    @Published private(set) var isShown = false
    @Published var isPinned = false
    private var panel: NSPanel?
    private var dismissWork: DispatchWorkItem?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var pointerInside = false
    private var delay = 5
    private var anchor = CGRect.zero
    var onSelect: ((MenuBarShelfTarget) -> Void)?
    var onSettings: (() -> Void)?
    var onClose: (() -> Void)?

    func show(icons: [MenuBarShelfIcon], anchor: CGRect, screen: NSScreen,
              delay: Int, showNames: Bool) {
        close()
        self.delay = delay
        self.anchor = anchor
        isPinned = false
        pointerInside = false
        let frame = MenuBarShelfSupport.panelFrame(anchor: anchor, visible: screen.visibleFrame,
                                                   desiredWidth: CGFloat(icons.count) * 40 + 104)
        let window = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        window.level = .popUpMenu
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.setAccessibilityLabel(MenuBarShelfStrings.text("隐藏图标面板", "Hidden menu bar icons"))
        let content = NSHostingView(rootView: MenuBarShelfView(controller: self,
            icons: icons, showNames: showNames, width: frame.width))
        window.contentView = content
        panel = window
        isShown = true
        window.orderFrontRegardless()
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            self?.handle(event)
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            self?.handle(event)
        }
        scheduleDismiss()
    }

    func close() {
        dismissWork?.cancel()
        dismissWork = nil
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
        let wasShown = isShown
        isShown = false
        isPinned = false
        if wasShown { onClose?() }
    }

    func hover(_ inside: Bool) {
        pointerInside = inside
        if inside { dismissWork?.cancel() } else { scheduleDismiss() }
    }

    func togglePin() {
        isPinned.toggle()
        if isPinned { dismissWork?.cancel() } else { scheduleDismiss() }
    }

    private func scheduleDismiss() {
        dismissWork?.cancel()
        guard MenuBarShelfSupport.shouldScheduleDismiss(isShown: isShown, isPinned: isPinned,
            pointerInside: pointerInside, delay: delay) else { return }
        let work = DispatchWorkItem { [weak self] in self?.close() }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(delay), execute: work)
    }

    func updateDelay(_ seconds: Int) {
        delay = seconds
        scheduleDismiss()
    }

    private func handle(_ event: NSEvent) {
        if event.type == .keyDown {
            if event.keyCode == 53 { close() }
        } else if !isPinned, !anchor.contains(NSEvent.mouseLocation),
                  panel?.frame.contains(NSEvent.mouseLocation) != true {
            close()
        }
    }
}

private struct ShelfMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

private struct MenuBarShelfView: View {
    @ObservedObject var controller: MenuBarShelfController
    let icons: [MenuBarShelfIcon]
    let showNames: Bool
    let width: CGFloat
    @State private var hovered: String?

    var body: some View {
        HStack(spacing: 8) {
            if icons.isEmpty {
                Text(MenuBarShelfStrings.text("暂无隐藏图标", "No hidden icons"))
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: 4) {
                        ForEach(icons) { icon in
                            Button {
                                controller.onSelect?(icon.target)
                            } label: {
                                Image(nsImage: icon.image).resizable()
                                    .interpolation(.high).scaledToFit()
                                    .frame(width: 20, height: 20)
                                    .frame(width: 36, height: 36)
                                    .background(hovered == icon.id ? Color.accentColor.opacity(0.13) : .clear,
                                                in: RoundedRectangle(cornerRadius: 7))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(icon.target.name)
                            .help(showNames ? icon.target.name : "")
                            .onHover { hovered = $0 ? icon.id : nil }
                        }
                    }
                }.scrollIndicators(.hidden)
            }
            Divider().frame(height: 20).padding(.horizontal, 2)
            Button { controller.togglePin() } label: {
                Image(systemName: controller.isPinned ? "pin.fill" : "pin")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(controller.isPinned ? Color.accentColor : .primary)
                    .frame(width: 28, height: 36)
            }
            .help(MenuBarShelfStrings.text("临时固定面板", "Pin panel temporarily"))
            .accessibilityLabel(MenuBarShelfStrings.text("临时固定面板", "Pin panel temporarily"))
            Button { controller.onSettings?() } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 16, weight: .regular))
                    .frame(width: 28, height: 36)
            }
            .help(MenuBarShelfStrings.text("菜单栏图标设置", "Menu bar icon settings"))
            .accessibilityLabel(MenuBarShelfStrings.text("菜单栏图标设置", "Menu bar icon settings"))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .frame(width: width, height: 60)
        .background(ShelfMaterial())
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.25)))
        .onHover { controller.hover($0) }
    }
}

enum MenuBarShelfStrings {
    static func text(_ chinese: String, _ english: String) -> String {
        switch L10n.shared.language {
        case .zhHans, .zhTW, .zhHK: return chinese
        default: return english
        }
    }
}
