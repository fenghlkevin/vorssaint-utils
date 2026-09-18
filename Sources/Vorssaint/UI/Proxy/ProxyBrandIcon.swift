// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

/// Three interwoven loops, drawn as a vector so the small toolbar icon stays crisp.
struct ProxyBrandIcon: View {
    var size: CGFloat = 22
    var body: some View {
        ProxyLoopShape()
            .stroke(style: StrokeStyle(lineWidth: size * 0.085, lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

private struct ProxyLoopShape: Shape {
    func path(in rect: CGRect) -> Path {
        var result = Path()
        let scale = min(rect.width, rect.height) / 24
        for angle in [0.0, 120.0, 240.0] {
            let loop = Path(ellipseIn: CGRect(x: 7.6, y: 2.0, width: 8.8, height: 15.4))
            let rotation = CGAffineTransform(translationX: 12, y: 12)
                .rotated(by: angle * .pi / 180)
                .translatedBy(x: -12, y: -12)
            let fit = CGAffineTransform(translationX: rect.midX - 12 * scale, y: rect.midY - 12 * scale)
                .scaledBy(x: scale, y: scale)
            result.addPath(loop.applying(rotation).applying(fit))
        }
        return result
    }
}
