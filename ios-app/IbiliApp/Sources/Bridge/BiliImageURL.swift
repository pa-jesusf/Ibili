import Foundation
import UIKit

/// Builds Bilibili CDN image URLs sized to the actual on-screen pixel area of
/// a cell, so we never download more pixels than the screen will display.
///
/// Bilibili supports a query-string-like suffix on `i*.hdslb.com` covers:
///   `<src>@<width>w_<height>h_<quality>q.webp`
/// Either the size or the quality piece may be omitted. We always request
/// `.webp` for bandwidth, with `_<q>q` only when the user pinned a quality.
enum BiliImageURL {
    /// `pointSize` is in CSS/SwiftUI points; we multiply by screen scale to get
    /// physical pixels — the "fill the actual pixels" rule from upstream.
    /// `quality` is the optional Bilibili @q value (1-100). Pass `nil` for auto.
    static func resized(_ src: String, pointSize: CGSize, quality: Int? = nil) -> String {
        guard !src.isEmpty else { return src }
        let scale = max(UIScreen.main.scale, 2.0)
        let w = max(1, Int((pointSize.width * scale).rounded()))
        let h = max(1, Int((pointSize.height * scale).rounded()))

        // Strip an existing trailing `@...` suffix (PiliPlus's _thumbRegex equivalent).
        let base = src.replacing(/@(?:\d+[a-z]_?)+(?:\.[a-zA-Z0-9]+)?$/, with: "")
        let httpsBase = base.hasPrefix("http://") ? "https://" + base.dropFirst("http://".count) : base

        var suffix = "@\(w)w_\(h)h"
        if let q = quality, q > 0, q <= 100 { suffix += "_\(q)q" }
        suffix += ".webp"
        return httpsBase + suffix
    }
}
