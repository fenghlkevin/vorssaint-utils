// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation
import Darwin

/// Resolve the same system Now Playing commands used by Atoll at runtime.
/// Missing private API symbols disable seeking and retain the media-key fallback.
final class IslandMediaCommands {
    private typealias Command = @convention(c) (Int, AnyObject?) -> Void
    private typealias Seek = @convention(c) (Double) -> Void
    private let handle: UnsafeMutableRawPointer?
    private let command: Command?
    private let setElapsed: Seek?
    var canSeek: Bool { setElapsed != nil }

    init() {
        let handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY)
        self.handle = handle
        command = handle.flatMap { dlsym($0, "MRMediaRemoteSendCommand") }.map { unsafeBitCast($0, to: Command.self) }
        setElapsed = handle.flatMap { dlsym($0, "MRMediaRemoteSetElapsedTime") }.map { unsafeBitCast($0, to: Seek.self) }
    }
    deinit { if let handle { dlclose(handle) } }
    @discardableResult func send(_ value: Int) -> Bool {
        guard let command else { return false }
        command(value, nil)
        return true
    }
    @discardableResult func seek(to seconds: Double) -> Bool {
        guard let setElapsed else { return false }
        setElapsed(seconds)
        return true
    }
}
