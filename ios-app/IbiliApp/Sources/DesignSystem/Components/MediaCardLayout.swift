import CoreGraphics

/// The original cover owns its entire area; the information panel extends
/// below it. Shared by home, search, live grids and split transitions.
struct MediaCardLayout {
    static let coverAspectRatio: CGFloat = 16 / 9
    let width: CGFloat
    let showsAuthor: Bool
    let showsMetadata: Bool
    var showsDuration = false
    var showsOverflowMenu = true
    var showsCover = true
    var showsSummary = false
    var showsSecondaryMetadata = false
    var compactMetadataLines = 2

    // Without an author row, the overflow menu also occupies the trailing
    // metadata space. Leave room for both a play count and an hour-long duration.
    var durationUsesSeparateLine: Bool { showsDuration && width < (showsAuthor || !showsOverflowMenu ? 150 : 180) }
    var menuUsesSeparateLine: Bool { showsOverflowMenu && width < 110 }
    private var menuInset: CGFloat { showsOverflowMenu && !menuUsesSeparateLine ? 30 : 0 }
    private var metadataRowHeight: CGFloat {
        max(showsMetadata ? metadataHeight + 8 : 0,
            showsDuration && !durationUsesSeparateLine ? 30 : 0)
    }
    private var durationRowHeight: CGFloat { durationUsesSeparateLine ? 30 : 0 }
    private var authorRowHeight: CGFloat { showsAuthor ? 24 : 0 }
    private var summaryRowHeight: CGFloat { showsSummary ? 40 : 0 }
    private var secondaryMetadataRowHeight: CGFloat { showsSecondaryMetadata ? 24 : 0 }
    private var metadataHeight: CGFloat { width < 150 ? CGFloat(compactMetadataLines) * 14 : 16 }

    // Rounding the height before aspect-fit adds a letterbox seam at the edge.
    var coverHeight: CGFloat { showsCover ? width / Self.coverAspectRatio : 0 }
    var horizontalInset: CGFloat { width < 220 ? 10 : 14 }
    var cornerRadius: CGFloat { width < 150 ? 12 : 16 }
    var titleFontSize: CGFloat { width < 150 ? 14 : 15 }
    var infoHeight: CGFloat {
        14 + 40 + 12 + summaryRowHeight + secondaryMetadataRowHeight + metadataRowHeight + durationRowHeight + authorRowHeight + (menuUsesSeparateLine ? 32 : 0)
    }
    var height: CGFloat { coverHeight + infoHeight }
    var coverFrame: CGRect { CGRect(x: 0, y: 0, width: width, height: coverHeight) }
    var backdropFrame: CGRect { CGRect(x: 0, y: coverHeight, width: width, height: infoHeight) }
    var titleFrame: CGRect {
        CGRect(x: horizontalInset, y: coverHeight + 14,
               width: max(1, width - horizontalInset * 2 - (showsAuthor || showsDuration || showsMetadata ? 0 : menuInset)), height: 40)
    }
    var authorFrame: CGRect {
        CGRect(x: horizontalInset + 17, y: titleFrame.maxY + summaryRowHeight + secondaryMetadataRowHeight + metadataRowHeight + durationRowHeight + 8,
               width: max(1, width - horizontalInset * 2 - 17 - menuInset), height: 16)
    }
    var durationY: CGFloat { titleFrame.maxY + summaryRowHeight + secondaryMetadataRowHeight + 5 + (durationUsesSeparateLine ? metadataRowHeight : 0) }
    var durationTrailingInset: CGFloat { !showsAuthor && showsOverflowMenu && !menuUsesSeparateLine ? 36 : horizontalInset }
    var durationAvailableWidth: CGFloat { max(1, width - horizontalInset - durationTrailingInset) }
    var metadataFrame: CGRect {
        CGRect(x: horizontalInset, y: titleFrame.maxY + summaryRowHeight + secondaryMetadataRowHeight + 8,
               width: max(1, width - horizontalInset * 2 - (showsAuthor || showsDuration ? 0 : menuInset)), height: metadataHeight)
    }
    var summaryFrame: CGRect {
        CGRect(x: horizontalInset, y: titleFrame.maxY + 8, width: max(1, width - horizontalInset * 2), height: 32)
    }
    var secondaryMetadataFrame: CGRect {
        CGRect(x: horizontalInset, y: titleFrame.maxY + summaryRowHeight + 8, width: max(1, width - horizontalInset * 2), height: 16)
    }
}
