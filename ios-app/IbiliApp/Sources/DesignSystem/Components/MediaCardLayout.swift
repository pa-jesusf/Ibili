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
    var showsPubdate = false
    var showsStatWithPubdate = false
    var compactMetadataLines = 2

    // Without an author row, the overflow menu also occupies the trailing
    // metadata space. Leave room for both a play count and an hour-long duration.
    var durationUsesSeparateLine: Bool { showsDuration && width < (showsAuthor || !showsOverflowMenu ? 150 : 180) }
    var menuUsesSeparateLine: Bool { showsOverflowMenu && (width < 110 || (showsPubdate || showsStatWithPubdate) && !showsAuthor) }
    private var menuInset: CGFloat { showsOverflowMenu && !menuUsesSeparateLine ? 30 : 0 }
    private var metadataRowHeight: CGFloat {
        max(showsMetadata ? metadataHeight + 8 : 0,
            showsDuration && !durationUsesSeparateLine ? 30 : 0)
    }
    private var durationRowHeight: CGFloat { durationUsesSeparateLine ? 30 : 0 }
    private var authorRowHeight: CGFloat { showsAuthor ? 24 : 0 }
    var publicationMetadataLines: Int { width < 150 && showsPubdate && showsStatWithPubdate ? 2 : 1 }
    private var pubdateRowHeight: CGFloat {
        showsPubdate || showsStatWithPubdate ? (publicationMetadataLines == 2 ? 28 : 16) + 8 : 0
    }
    private var summaryRowHeight: CGFloat { showsSummary ? 40 : 0 }
    private var secondaryMetadataRowHeight: CGFloat { showsSecondaryMetadata ? 24 : 0 }
    private var metadataHeight: CGFloat { width < 150 ? max(16, CGFloat(compactMetadataLines) * 14) : 16 }

    // Rounding the height before aspect-fit adds a letterbox seam at the edge.
    var coverHeight: CGFloat { showsCover ? width / Self.coverAspectRatio : 0 }
    var horizontalInset: CGFloat { width < 220 ? 10 : 14 }
    var cornerRadius: CGFloat { width < 150 ? 12 : 16 }
    var titleFontSize: CGFloat { width < 150 ? 14 : 15 }
    var infoHeight: CGFloat {
        2 + 40 + 12 + summaryRowHeight + secondaryMetadataRowHeight + metadataRowHeight + durationRowHeight + pubdateRowHeight + authorRowHeight + (menuUsesSeparateLine ? 32 : 0)
    }
    var height: CGFloat { coverHeight + infoHeight }
    var coverFrame: CGRect { CGRect(x: 0, y: 0, width: width, height: coverHeight) }
    var coverTransitionFrame: CGRect {
        let transitionHeight = showsCover
            ? width * ExtendedCoverBackdrop.transitionAspectRatio
            : 0
        return CGRect(x: 0, y: coverHeight - transitionHeight, width: width, height: transitionHeight)
    }
    var backdropFrame: CGRect { CGRect(x: 0, y: coverHeight, width: width, height: infoHeight) }
    var extendedBackdropFrame: CGRect {
        CGRect(x: 0, y: coverTransitionFrame.minY, width: width,
               height: height - coverTransitionFrame.minY)
    }
    var titleFrame: CGRect {
        CGRect(x: horizontalInset, y: coverHeight + 2,
               width: max(1, width - horizontalInset * 2 - (showsAuthor || showsDuration || showsMetadata || showsPubdate || showsStatWithPubdate ? 0 : menuInset)), height: 40)
    }
    var authorFrame: CGRect {
        CGRect(x: horizontalInset + 17, y: titleFrame.maxY + summaryRowHeight + secondaryMetadataRowHeight + metadataRowHeight + durationRowHeight + pubdateRowHeight + 8,
               width: max(1, width - horizontalInset * 2 - 17 - menuInset), height: 16)
    }
    var durationY: CGFloat { titleFrame.maxY + summaryRowHeight + secondaryMetadataRowHeight + 5 + (durationUsesSeparateLine ? metadataRowHeight : 0) }
    var durationTrailingInset: CGFloat { !showsAuthor && showsOverflowMenu && !menuUsesSeparateLine ? 36 : horizontalInset }
    var durationAvailableWidth: CGFloat { max(1, width - horizontalInset - durationTrailingInset) }
    var metadataFrame: CGRect {
        CGRect(x: horizontalInset, y: titleFrame.maxY + summaryRowHeight + secondaryMetadataRowHeight + 8,
               width: max(1, width - horizontalInset * 2 - (showsAuthor || showsDuration ? 0 : menuInset)), height: metadataHeight)
    }
    var pubdateFrame: CGRect {
        CGRect(x: horizontalInset, y: titleFrame.maxY + summaryRowHeight + secondaryMetadataRowHeight + metadataRowHeight + durationRowHeight + 8,
               width: max(1, width - horizontalInset * 2), height: publicationMetadataLines == 2 ? 28 : 16)
    }
    var summaryFrame: CGRect {
        CGRect(x: horizontalInset, y: titleFrame.maxY + 8, width: max(1, width - horizontalInset * 2), height: 32)
    }
    var secondaryMetadataFrame: CGRect {
        CGRect(x: horizontalInset, y: titleFrame.maxY + summaryRowHeight + 8, width: max(1, width - horizontalInset * 2), height: 16)
    }
}
