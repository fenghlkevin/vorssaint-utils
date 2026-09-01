// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import SwiftUI
import UniformTypeIdentifiers

/// Contents of the floating shelf panel: a header (a move handle plus actions)
/// and the item tiles. Dropping onto the card adds items; the tiles themselves
/// are AppKit, so they can drag several selected items out at once.
struct ShelfView: View {
    /// The top-right button. The floating shelf closes; the docked shelf
    /// collapses to its pill instead of vanishing.
    var dismissSystemImage: String = "xmark"
    var dismissHelp: String? = nil
    var onDismiss: (() -> Void)? = nil
    /// Called with the provider count after a drop is accepted, so the docked
    /// shelf can flash and settle back to its pill.
    var onAccept: ((Int) -> Void)? = nil
    /// The docked shelf shows the brand mark as a quiet watermark, so it reads
    /// as the app's own tray rather than a plain floating card.
    var brandWatermark: Bool = false
    /// Nil keeps the compact floating card. An edge-opened Shelf supplies a
    /// tall target size, turning the tile area into a vertical working strip.
    var edgePanelSize: CGSize? = nil

    @EnvironmentObject private var shelf: ShelfService
    @ObservedObject private var l10n = L10n.shared
    @Environment(\.colorScheme) private var colorScheme
    @State private var targeted = false
    @State private var clearButtonHovered = false
    @State private var pinButtonHovered = false
    @State private var closeButtonHovered = false

    private static let dropTypes: [UTType] = [.fileURL, .image, .url, .text, .plainText]
    private static let panelWidth: CGFloat = 304
    private static let tileAreaHeight: CGFloat = 188

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            header
            tiles
            if !shelf.items.isEmpty {
                bottomBar
            }
        }
        .padding(14)
        .frame(width: panelWidth)
        .background(
            ZStack {
                HUDBackdrop(cornerRadius: 18)
                if brandWatermark { brandWatermarkLayer }
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(isDropTargeted ? Color.accentColor : Color.white.opacity(0.12),
                              lineWidth: isDropTargeted ? 2 : 1)
        )
        .overlay(alignment: .topLeading) {
            topMoveHandle
        }
        .animation(.easeOut(duration: 0.15), value: isDropTargeted)
        .animation(.easeOut(duration: 0.18), value: shelf.items)
        .onHover { inside in
            shelf.setPointerInsidePanel(inside)
        }
        .onChange(of: targeted) { _, isTargeted in
            shelf.setDropTargeted(isTargeted)
        }
        .onDrop(of: Self.dropTypes, isTargeted: $targeted) { providers in
            let accepted = shelf.accept(providers: providers)
            if accepted {
                shelf.noteInteraction()
                onAccept?(providers.count)
            }
            return accepted
        }
    }

    private var isDropTargeted: Bool {
        targeted || shelf.dropTargeted
    }

    private var panelWidth: CGFloat {
        edgePanelSize?.width ?? Self.panelWidth
    }

    /// The fixed chrome above/below the scroll area is 69 points for an empty
    /// shelf and 110 points once the bottom bar appears. Subtracting it keeps
    /// the whole edge panel at the requested height rather than adding the
    /// requested height to the title bar and padding.
    private var tileAreaHeight: CGFloat {
        guard let edgePanelSize else { return Self.tileAreaHeight }
        let chrome: CGFloat = shelf.items.isEmpty ? 69 : 110
        return max(Self.tileAreaHeight, edgePanelSize.height - chrome)
    }

    /// The official mark, large and faint in the corner: unmistakably ours,
    /// never loud enough to fight the tiles.
    private var brandWatermarkLayer: some View {
        BrandMark(width: 128, tint: colorScheme == .light ? Color.black : Color.white)
            .opacity(colorScheme == .light ? 0.05 : 0.08)
            .rotationEffect(.degrees(-8))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .offset(x: 34, y: 26)
            .allowsHitTesting(false)
    }

    private var header: some View {
        HStack(spacing: 7) {
            // Drag this region to move the panel; the tiles below stay free to
            // start item drags.
            HStack(spacing: 7) {
                Image(systemName: "tray.full")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !shelf.items.isEmpty {
                    Text("\(shelf.itemCount)")
                        .font(.system(size: 11, weight: .bold))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(Color.secondary.opacity(0.18)))
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .overlay(WindowMoveHandle())

            if !brandWatermark { pinButton }
            closeButton
        }
    }

    private var topMoveHandle: some View {
        WindowMoveHandle(acceptsDrops: true)
            .frame(width: panelWidth - (brandWatermark ? 58 : 96), height: 55)
    }

    private var pinButton: some View {
        Button { shelf.togglePin() } label: {
            Image(systemName: shelf.isPinned ? "pin.fill" : "pin")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 30, height: 30)
                .background(
                    Circle().fill(shelf.isPinned
                                  ? Color.accentColor.opacity(pinButtonHovered ? 0.30 : 0.20)
                                  : Color.white.opacity(pinButtonHovered ? 0.18 : 0.11))
                )
                .overlay(
                    Circle().strokeBorder(shelf.isPinned
                                          ? Color.accentColor.opacity(0.65)
                                          : Color.white.opacity(pinButtonHovered ? 0.75 : 0.32),
                                          lineWidth: 1)
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(shelf.isPinned ? Color.accentColor : Color.secondary)
        .onHover { pinButtonHovered = $0 }
        .help(shelf.isPinned ? l10n.s.shelfUnpin : l10n.s.shelfPin)
        .accessibilityLabel(shelf.isPinned ? l10n.s.shelfUnpin : l10n.s.shelfPin)
    }

    private var closeButton: some View {
        Button { (onDismiss ?? { shelf.hide() })() } label: {
            Image(systemName: dismissSystemImage)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 30, height: 30)
                .background(
                    Circle()
                        .fill(Color.white.opacity(closeButtonHovered ? 0.18 : 0.11))
                )
                .overlay(
                    Circle()
                        .strokeBorder(Color.white.opacity(closeButtonHovered ? 0.75 : 0.32), lineWidth: 1)
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .onHover { closeButtonHovered = $0 }
        .help(dismissHelp ?? l10n.s.menuClose)
    }

    private var bottomBar: some View {
        HStack(spacing: 8) {
            Text(l10n.s.shelfHint)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Spacer(minLength: 8)
            clearButton
        }
        .frame(minHeight: 30)
    }

    private var clearButton: some View {
        Button(action: trashAction) {
            Image(systemName: shelf.selection.isEmpty ? "trash" : "trash.fill")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 42, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.red.opacity(clearButtonHovered ? 0.20 : 0.07))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.red.opacity(clearButtonHovered ? 0.34 : 0.12), lineWidth: 0.8)
                )
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(clearButtonHovered ? Color.red.opacity(0.82) : Color.secondary)
        .onHover { clearButtonHovered = $0 }
        .help(shelf.selection.isEmpty ? l10n.s.shelfClearAll : l10n.s.shelfRemoveSelected)
    }

    private var title: String {
        shelf.selection.isEmpty
            ? l10n.s.shelfTitle
            : String(format: l10n.s.shelfSelectedFormat, shelf.selection.count)
    }

    @ViewBuilder
    private var tiles: some View {
        if shelf.items.isEmpty {
            emptyState
        } else {
                ShelfTilesView(items: shelf.visibleItems,
                           contentRevision: shelf.contentRevision,
                           selection: shelf.selection,
                           expandedBatches: shelf.expandedBatches,
                           revealID: shelf.revealTargetID,
                           revealSerial: shelf.addSerial)
                .frame(height: tileAreaHeight)
        }
    }

    private var emptyState: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
            .foregroundStyle(.secondary.opacity(0.4))
            .frame(height: tileAreaHeight)
            .overlay(
                VStack(spacing: 8) {
                    Image(systemName: "arrow.down.to.line")
                        .font(.system(size: 21))
                        .foregroundStyle(.secondary)
                    Text(l10n.s.shelfEmpty)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                }
            )
            .overlay(WindowMoveHandle(acceptsDrops: true))
    }

    private func trashAction() {
        if shelf.selection.isEmpty {
            shelf.clear()
        } else {
            shelf.removeItems(Array(shelf.selection))
        }
    }
}

/// The edge-drag preview is a real narrow window rather than a full card moved
/// mostly outside one display. At a shared display seam there is no off-screen
/// space, so the old approach spilled across the neighboring monitor. This
/// strip stays wholly inside the target display and expands only after a drop.
struct ShelfEdgePeekView: View {
    let edge: ShelfEdge
    let size: CGSize

    @EnvironmentObject private var shelf: ShelfService
    @State private var targeted = false

    private static let dropTypes: [UTType] = [.fileURL, .image, .url, .text, .plainText]

    var body: some View {
        ZStack {
            HUDBackdrop(cornerRadius: 16)
            VStack(spacing: 10) {
                Image(systemName: "tray.and.arrow.down.fill")
                    .font(.system(size: 22, weight: .semibold))
                Image(systemName: edge == .left ? "arrow.right" : "arrow.left")
                    .font(.system(size: 17, weight: .bold))
            }
            .foregroundStyle(targeted ? Color.accentColor : Color.secondary)
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(targeted ? Color.accentColor : Color.white.opacity(0.18),
                              lineWidth: targeted ? 2 : 1)
        )
        .contentShape(Rectangle())
        .animation(.easeOut(duration: 0.15), value: targeted)
        .onHover { shelf.setPointerInsidePanel($0) }
        .onChange(of: targeted) { _, value in shelf.setDropTargeted(value) }
        .onDrop(of: Self.dropTypes, isTargeted: $targeted) { providers in
            let accepted = shelf.accept(providers: providers)
            if accepted { shelf.noteInteraction() }
            return accepted
        }
    }
}
