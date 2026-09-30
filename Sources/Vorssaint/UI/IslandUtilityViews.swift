// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Layout and interaction reference: Atoll's NotchHomeView / NotchTimerView
// https://github.com/Ebullioscopic/Atoll (GPL-3.0-or-later).

import AppKit
import SwiftUI

struct IslandMusicPanel: View {
    let title: String
    let artist: String
    let artwork: NSImage?
    let source: String
    let hasTrack: Bool
    let playing: Bool
    let launching: Bool
    let elapsed: Double
    let duration: Double
    let canSeek: Bool
    let shuffle: Bool
    let repeatMode: String
    let supportsPlaybackModes: Bool
    let volume: Double
    let playPause: () -> Void
    let previous: () -> Void
    let next: () -> Void
    let seek: (Double) -> Void
    let setVolume: (Double) -> Void
    let toggleShuffle: () -> Void
    let cycleRepeat: () -> Void
    let openPlayer: () -> Void
    let setVolumePopoverPresented: (Bool) -> Void
    @State private var scrubPosition: Double?
    @State private var showingVolume = false

    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            Button(action: openPlayer) {
                Group {
                    if let artwork {
                        Image(nsImage: artwork).resizable().scaledToFill()
                    } else {
                        RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.07))
                            .overlay(Image(systemName: "music.note").font(.system(size: 42, weight: .light)).foregroundStyle(.white.opacity(0.35)))
                    }
                }
                .frame(width: 138, height: 138)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .help("打开当前播放器").accessibilityLabel("打开当前播放器")
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(hasTrack ? title : "未在播放")
                        .font(.system(size: 17, weight: .semibold)).lineLimit(1)
                        .help(title)
                    Text(hasTrack ? artist : (launching ? "正在打开 Apple Music…" : "播放以继续 Apple Music"))
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                }
                progress
                HStack(spacing: 4) {
                    control("shuffle", label: "随机播放", active: shuffle, action: toggleShuffle)
                        .disabled(!supportsPlaybackModes).opacity(supportsPlaybackModes ? 1 : 0.25)
                    Spacer(minLength: 0)
                    control("backward.fill", label: "上一首", action: previous).disabled(!hasTrack)
                    Button(action: playPause) {
                        Group {
                            if launching { ProgressView().controlSize(.small).tint(.white) }
                            else { Image(systemName: playing ? "pause.fill" : "play.fill").font(.system(size: 23, weight: .semibold)) }
                        }.frame(width: 46, height: 40)
                    }
                    .buttonStyle(IslandMediaButtonStyle())
                    .disabled(launching).accessibilityLabel(playing ? "暂停播放" : "播放")
                    control("forward.fill", label: "下一首", action: next).disabled(!hasTrack)
                    Spacer(minLength: 0)
                    control(repeatMode == "one" ? "repeat.1" : "repeat", label: "循环播放", active: repeatMode != "off", action: cycleRepeat)
                        .disabled(!supportsPlaybackModes).opacity(supportsPlaybackModes ? 1 : 0.25)
                }
                HStack {
                    Button(action: openPlayer) {
                        Label(source, systemImage: "arrow.up.right").lineLimit(1)
                    }.foregroundStyle(.white.opacity(0.4)).help("打开当前播放器")
                    Spacer()
                    Button {
                        showingVolume.toggle()
                        setVolumePopoverPresented(showingVolume)
                    } label: {
                        Image(systemName: volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .frame(width: 26, height: 22)
                    }
                    .accessibilityLabel("音量")
                    .popover(isPresented: $showingVolume, arrowEdge: .bottom) {
                        HStack {
                            Image(systemName: "speaker.fill")
                            Slider(value: Binding(get: { volume }, set: setVolume), in: 0...1)
                                .accessibilityLabel("系统音量")
                            Image(systemName: "speaker.wave.3.fill")
                        }.padding(14).frame(width: 220)
                    }
                    .onChange(of: showingVolume) { _, isPresented in
                        setVolumePopoverPresented(isPresented)
                    }
                }.font(.system(size: 10, weight: .medium))
            }
        }
        .padding(.horizontal, 24).padding(.top, 42).padding(.bottom, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(.white).buttonStyle(.plain)
        .onChange(of: title) { _, _ in scrubPosition = nil }
    }

    private var progress: some View {
        VStack(spacing: 3) {
            if duration > 0 {
                Slider(value: Binding(get: { scrubPosition ?? min(max(elapsed, 0), duration) },
                                      set: { scrubPosition = $0 }),
                       in: 0...max(duration, 1), onEditingChanged: { editing in
                    if !editing, let position = scrubPosition { seek(position); scrubPosition = nil }
                })
                .tint(.white.opacity(0.8)).controlSize(.mini)
                .disabled(!canSeek).accessibilityLabel("播放进度")
                HStack {
                    Text(IslandUtilityLayout.time(Int(scrubPosition ?? elapsed)))
                    Spacer()
                    Text("−" + IslandUtilityLayout.time(Int(max(duration - (scrubPosition ?? elapsed), 0))))
                }.font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(.white.opacity(0.4))
            } else {
                HStack(spacing: 8) {
                    Capsule().fill(.white.opacity(0.15)).frame(height: 2)
                    Text(hasTrack ? "LIVE" : "--:--").font(.system(size: 9, weight: .medium))
                    Capsule().fill(.white.opacity(0.15)).frame(height: 2)
                }.foregroundStyle(.white.opacity(0.4)).frame(height: 28)
            }
        }
    }

    private func control(_ symbol: String, label: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 16, weight: .semibold))
                .foregroundStyle(active ? Color.orange : Color.white.opacity(0.85))
                .frame(width: 32, height: 36)
        }.buttonStyle(IslandMediaButtonStyle()).help(label).accessibilityLabel(label)
    }
}

private struct IslandMediaButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(.white.opacity(configuration.isPressed ? 0.14 : 0), in: Circle())
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .contentShape(Rectangle())
    }
}

struct IslandTimerPanel: View {
    let running: IslandRunningTimer?
    let start: (String, Int) -> Void
    let pause: () -> Void
    let cancel: () -> Void
    @AppStorage("dynamicIsland.customTimerSeconds") private var savedSeconds = 600
    @State private var hours = 0
    @State private var minutes = 10
    @State private var seconds = 0
    @State private var usesRuler = false
    @State private var rulerStart: Double?
    @FocusState private var editingDuration: Bool
    private var selectedSeconds: Int { hours * 3600 + minutes * 60 + seconds }

    var body: some View {
        Group {
            if let running { active(running) }
            else { composer }
        }
        .padding(.horizontal, 20).padding(.top, 42).padding(.bottom, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(.white).buttonStyle(.plain)
        .onAppear { setDuration(min(max(savedSeconds, 0), 86_399)) }
        .onChange(of: selectedSeconds) { _, value in savedSeconds = value }
    }

    private var composer: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("自定义计时器").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.65))
                    Spacer()
                    Button { editingDuration = false; usesRuler.toggle() } label: {
                        Image(systemName: usesRuler ? "number" : "ruler").frame(width: 26, height: 22)
                    }.help(usesRuler ? "输入时分秒" : "使用分钟刻度尺").accessibilityLabel("切换时长输入方式")
                }
                if usesRuler { ruler }
                else {
                    HStack(spacing: 5) {
                        durationField("时", value: $hours, limit: 23)
                        Text(":").foregroundStyle(.white.opacity(0.4))
                        durationField("分", value: $minutes, limit: 59)
                        Text(":").foregroundStyle(.white.opacity(0.4))
                        durationField("秒", value: $seconds, limit: 59)
                    }
                }
                HStack(spacing: 8) {
                    Button {
                        editingDuration = false
                        start("倒计时", selectedSeconds)
                    } label: {
                        Label("开始", systemImage: "play.fill")
                            .font(.system(size: 12, weight: .semibold)).frame(maxWidth: .infinity).frame(height: 34)
                            .background(.orange.opacity(selectedSeconds > 0 ? 1 : 0.25), in: Capsule())
                    }.disabled(selectedSeconds == 0)
                    Button { editingDuration = false; setDuration(0) } label: {
                        Image(systemName: "arrow.counterclockwise").frame(width: 34, height: 34)
                            .background(.white.opacity(0.09), in: Circle())
                    }.help("重置时长").accessibilityLabel("重置时长")
                }
            }
            .padding(12).frame(maxWidth: .infinity)
            .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
            Rectangle().fill(.white.opacity(0.12)).frame(width: 1)
            VStack(spacing: 8) {
                preset("专注", minutes: 25, color: .orange, symbol: "scope")
                preset("休息", minutes: 5, color: .green, symbol: "cup.and.saucer.fill")
                preset("深度工作", minutes: 45, color: .purple, symbol: "brain.head.profile")
            }.frame(width: 170)
        }.frame(height: 190)
    }

    private func durationField(_ label: String, value: Binding<Int>, limit: Int) -> some View {
        VStack(spacing: 6) {
            TextField("00", text: Binding(get: { String(format: "%02d", value.wrappedValue) }, set: { text in
                value.wrappedValue = min(max(Int(text.filter(\.isNumber)) ?? 0, 0), limit)
            }))
            .textFieldStyle(.plain).multilineTextAlignment(.center)
            .font(.system(size: 27, weight: .semibold, design: .monospaced))
            .frame(maxWidth: .infinity).frame(height: 46)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            .focused($editingDuration).accessibilityLabel(label)
            Text(label).font(.system(size: 10)).foregroundStyle(.white.opacity(0.4))
        }
    }

    private func preset(_ title: String, minutes: Int, color: Color, symbol: String) -> some View {
        Button { editingDuration = false; start(title, minutes * 60) } label: {
            HStack(spacing: 9) {
                Image(systemName: symbol).foregroundStyle(color).frame(width: 18)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 12, weight: .semibold))
                    Text("\(minutes) 分钟").font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
                }
                Spacer(minLength: 0)
                Image(systemName: "play.fill").font(.system(size: 10)).foregroundStyle(color)
                    .frame(width: 26, height: 26).background(color.opacity(0.14), in: Circle())
            }.padding(.horizontal, 10).frame(height: 56)
                .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
        }.accessibilityLabel("开始\(title)，\(minutes)分钟")
    }

    private var ruler: some View {
        VStack(spacing: 2) {
            GeometryReader { proxy in
                Canvas { context, size in
                    let selected = Double(selectedSeconds) / 60
                    for tick in 0...90 {
                        let x = size.width / 2 + (Double(tick) - selected) * 10
                        guard x >= 0, x <= size.width else { continue }
                        let major = tick % 5 == 0
                        context.fill(Path(CGRect(x: x, y: 17, width: major ? 2 : 1, height: major ? 20 : 12)), with: .color(.orange.opacity(major ? 0.9 : 0.45)))
                        if major { context.draw(Text("\(tick)").font(.system(size: 9)).foregroundColor(.orange), at: CGPoint(x: x, y: 7)) }
                    }
                }
                .overlay(alignment: .bottom) { Image(systemName: "arrowtriangle.up.fill").font(.system(size: 8)).foregroundStyle(.orange) }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { event in
                    if rulerStart == nil { rulerStart = Double(selectedSeconds) / 60 }
                    let value = min(max((rulerStart ?? 0) - event.translation.width / 10, 0), 90)
                    setDuration(Int(value.rounded()) * 60)
                }.onEnded { _ in rulerStart = nil })
                .accessibilityElement().accessibilityLabel("分钟刻度尺")
                .accessibilityValue("\(selectedSeconds / 60)分钟")
                .accessibilityAdjustableAction { direction in
                    setDuration(min(max(selectedSeconds + (direction == .increment ? 60 : -60), 0), 5400))
                }
            }.frame(height: 45)
            Text(IslandUtilityLayout.time(selectedSeconds)).font(.system(size: 17, weight: .semibold, design: .monospaced))
        }.frame(height: 65)
        .onAppear { setDuration(min(selectedSeconds, 5400)) }
    }

    private func active(_ timer: IslandRunningTimer) -> some View {
        VStack(spacing: 24) {
            HStack(spacing: 16) {
                Button(action: pause) {
                    Image(systemName: timer.paused ? "play.fill" : "pause.fill")
                        .frame(width: 46, height: 46).background(.orange.opacity(0.3), in: Circle())
                }.accessibilityLabel(timer.paused ? "继续计时" : "暂停计时")
                Button(action: cancel) {
                    Image(systemName: "xmark").frame(width: 46, height: 46)
                        .background(.white.opacity(0.12), in: Circle())
                }.accessibilityLabel("取消计时器")
                VStack(alignment: .leading, spacing: 6) {
                    Text(timer.title).font(.system(size: 18, weight: .semibold)).lineLimit(1)
                    Text(timer.paused ? "已暂停" : "正在倒计时").font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
                }
                Spacer(minLength: 0)
                Text(IslandUtilityLayout.time(timer.remaining))
                    .font(.system(size: 38, weight: .bold, design: .monospaced))
                    .monospacedDigit().lineLimit(1).minimumScaleFactor(0.65)
                    .foregroundStyle(timer.paused ? Color.white.opacity(0.55) : .white)
                    .contentTransition(.numericText())
            }
            GeometryReader { geometry in
                Capsule().fill(.white.opacity(0.12))
                    .overlay(alignment: .leading) {
                        Capsule().fill(.orange)
                            .frame(width: geometry.size.width * min(max(Double(timer.remaining) / Double(max(timer.total, 1)), 0), 1))
                    }
            }.frame(height: 4)
        }.padding(.horizontal, 4).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func setDuration(_ value: Int) { hours = value / 3600; minutes = value / 60 % 60; seconds = value % 60 }
}
