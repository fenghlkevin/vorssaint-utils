// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
enum AppFeature { case networkProxy; var isAvailable: Bool { true } }
enum PrivateFileStore { static var containerURL: URL? { nil } }
