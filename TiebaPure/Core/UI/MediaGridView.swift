import SwiftUI

struct ReaderMediaItem: Identifiable, Equatable, Sendable {
    enum Kind: Sendable {
        case image
        case video
    }

    var id: String
    var kind: Kind
    var thumbnailURL: URL?
    var image: ImageContent?
    var video: VideoContent?
    var aspectRatio: CGFloat
    var accessibilityLabel: String

    init(
        id: String,
        kind: Kind,
        thumbnailURL: URL?,
        image: ImageContent? = nil,
        video: VideoContent? = nil,
        aspectRatio: CGFloat = 1,
        accessibilityLabel: String
    ) {
        self.id = id
        self.kind = kind
        self.thumbnailURL = thumbnailURL
        self.image = image
        self.video = video
        // Clamp matches ForumFeedMediaLayoutPolicy's single-image bounds so a
        // single photo fills its feed row exactly instead of letterboxing
        // inside it (2.4 = widest shown, 1/1.5 = tallest shown).
        self.aspectRatio = max(
            1 / ForumFeedMediaLayoutPolicy.maximumSingleImageHeightRatio,
            min(aspectRatio, ForumFeedMediaLayoutPolicy.maximumSingleImageAspectRatio)
        )
        self.accessibilityLabel = accessibilityLabel
    }

    var previewSourceIdentity: String {
        [
            id,
            kind == .image ? "image" : "video",
            thumbnailURL?.absoluteString ?? "",
            image?.originalURL?.absoluteString ?? ""
        ].joined(separator: "|")
    }
}

struct MediaGridView: View {
    let items: [ReaderMediaItem]
    let maxItemHeight: CGFloat?
    let totalItemCount: Int
    let usesCompactFeedLayout: Bool
    let isInteractive: Bool
    let destinationAccessibilityLabel: String?
    let destinationAccessibilityHint: String?
    let onTap: (ReaderMediaItem, CGRect?, UIImage?, ImagePreviewSourceAnchor?) -> Void

    init(
        items: [ReaderMediaItem],
        maxItemHeight: CGFloat? = nil,
        totalItemCount: Int? = nil,
        usesCompactFeedLayout: Bool = false,
        isInteractive: Bool = true,
        destinationAccessibilityLabel: String? = nil,
        destinationAccessibilityHint: String? = nil,
        onTap: @escaping (ReaderMediaItem, CGRect?, UIImage?, ImagePreviewSourceAnchor?) -> Void = { _, _, _, _ in }
    ) {
        self.items = items
        self.maxItemHeight = maxItemHeight
        self.totalItemCount = max(totalItemCount ?? items.count, items.count)
        self.usesCompactFeedLayout = usesCompactFeedLayout
        self.isInteractive = isInteractive
        self.destinationAccessibilityLabel = destinationAccessibilityLabel
        self.destinationAccessibilityHint = destinationAccessibilityHint
        self.onTap = onTap
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if usesCompactFeedLayout {
                Color.clear
                    .frame(maxWidth: .infinity)
                    .aspectRatio(compactContainerAspectRatio, contentMode: .fit)
                    .overlay {
                        HStack(spacing: TiebaPureTheme.Spacing.xs) {
                            ForEach(items) { item in
                                mediaButton(item)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                            }
                        }
                    }
            } else {
                standardGrid
            }

            if ForumFeedMediaLayoutPolicy.showsMoreBadge(
                totalCount: totalItemCount,
                visibleCount: items.count
            ) {
                Label("\(totalItemCount)", systemImage: "photo.on.rectangle")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(.black.opacity(0.55), in: Capsule())
                    .padding(TiebaPureTheme.Spacing.xs)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var standardGrid: some View {
        let columns = Array(
            repeating: GridItem(.flexible(), spacing: TiebaPureTheme.Spacing.xs),
            count: columnCount
        )
        return LazyVGrid(columns: columns, alignment: .leading, spacing: TiebaPureTheme.Spacing.xs) {
            ForEach(items) { item in
                mediaButton(item)
            }
        }
    }

    private func mediaButton(_ item: ReaderMediaItem) -> some View {
        Group {
            if isInteractive {
                MediaItemButton(
                    item: item,
                    maxHeight: usesCompactFeedLayout ? nil : maxItemHeight,
                    aspectRatioOverride: usesCompactFeedLayout ? nil : thumbnailAspectRatio,
                    totalItemCount: totalItemCount,
                    destinationAccessibilityLabel: destinationAccessibilityLabel,
                    destinationAccessibilityHint: destinationAccessibilityHint,
                    onTap: onTap
                )
            } else {
                MediaThumbnailView(
                    item: item,
                    maxHeight: usesCompactFeedLayout ? nil : maxItemHeight,
                    aspectRatioOverride: usesCompactFeedLayout ? nil : thumbnailAspectRatio,
                    retryTrigger: 0,
                    isManualLoadAuthorized: false,
                    explicitOriginalAuthorization: nil,
                    showsManualLoadIndicator: false,
                    onLoadStateChange: { _ in }
                )
                .accessibilityHidden(true)
            }
        }
    }

    private var columnCount: Int {
        if usesCompactFeedLayout {
            return max(1, items.count)
        }
        switch items.count {
        case 0, 1:
            return 1
        case 2, 4:
            return 2
        default:
            return 3
        }
    }

    private var thumbnailAspectRatio: CGFloat? {
        guard usesCompactFeedLayout else { return nil }
        return ForumFeedMediaLayoutPolicy.thumbnailAspectRatio(
            totalCount: totalItemCount,
            visibleCount: items.count
        )
    }

    /// Feed row ratio. A single image follows the post's own aspect ratio so
    /// the photo is not cropped; multi-image posts keep the uniform tile grid.
    private var compactContainerAspectRatio: CGFloat {
        ForumFeedMediaLayoutPolicy.containerAspectRatio(
            totalCount: totalItemCount,
            visibleCount: items.count,
            aspectRatios: items.map(\.aspectRatio)
        )
    }
}

private struct MediaItemButton: View {
    @Environment(\.readingPreferences) private var readingPreferences

    let item: ReaderMediaItem
    let maxHeight: CGFloat?
    let aspectRatioOverride: CGFloat?
    let totalItemCount: Int
    let destinationAccessibilityLabel: String?
    let destinationAccessibilityHint: String?
    let onTap: (ReaderMediaItem, CGRect?, UIImage?, ImagePreviewSourceAnchor?) -> Void

    @State private var loadState: TiebaRemoteImageLoadState = .empty
    @State private var retryTrigger = 0
    @State private var manualLoadAuthorization: String?
    @State private var explicitFallbackAuthorization: String?
    @StateObject private var previewSource: ImagePreviewSourceAnchor

    init(
        item: ReaderMediaItem,
        maxHeight: CGFloat?,
        aspectRatioOverride: CGFloat?,
        totalItemCount: Int,
        destinationAccessibilityLabel: String?,
        destinationAccessibilityHint: String?,
        onTap: @escaping (ReaderMediaItem, CGRect?, UIImage?, ImagePreviewSourceAnchor?) -> Void
    ) {
        self.item = item
        self.maxHeight = maxHeight
        self.aspectRatioOverride = aspectRatioOverride
        self.totalItemCount = totalItemCount
        self.destinationAccessibilityLabel = destinationAccessibilityLabel
        self.destinationAccessibilityHint = destinationAccessibilityHint
        self.onTap = onTap
        _previewSource = StateObject(
            wrappedValue: ImagePreviewSourceAnchor(
                sourceIdentity: item.previewSourceIdentity
            )
        )
    }

    var body: some View {
        Button(action: activate) {
            MediaThumbnailView(
                item: item,
                maxHeight: maxHeight,
                aspectRatioOverride: aspectRatioOverride,
                retryTrigger: retryTrigger,
                isManualLoadAuthorized: isManualLoadAuthorized,
                explicitOriginalAuthorization: explicitFallbackAuthorization,
                showsManualLoadIndicator: true,
                previewSource: previewSource,
                onTransitionTap: activate,
                onLoadStateChange: { state in
                    guard loadState != state else { return }
                    loadState = state
                },
                onImageResolved: {
                    previewSource.store(
                        image: $0,
                        sourceIdentity: item.previewSourceIdentity
                    )
                }
            )
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(
            cornerRadius: TiebaPureTheme.Radius.media,
            style: .continuous
        ))
        .minTouchTarget()
        .accessibilityIdentifier("media-item-\(item.id)")
        .accessibilityLabel(mediaAccessibilityLabel)
        .accessibilityHint(mediaAccessibilityHint)
    }

    private func activate() {
        if loadState == .failure {
            if item.kind == .video {
                openDestination()
                return
            }
            if shouldOfferExplicitFallback {
                explicitFallbackAuthorization = item.previewSourceIdentity
            }
            retryTrigger += 1
        } else if item.thumbnailURL != nil,
                  loadState == .empty,
                  mediaRequestPolicy.loadsAutomatically == false {
            if isManualLoadAuthorized == false {
                manualLoadAuthorization = item.previewSourceIdentity
            }
            return
        } else if loadState == .loading,
                  ReaderMediaActivationPolicy.blocksWhileLoading(
                    requestPolicy: mediaRequestPolicy
                  ) {
            return
        } else {
            openDestination()
        }
    }

    private func openDestination() {
        onTap(
            item,
            ImagePreviewSourceRegistry.shared
                .frameInWindow(for: item.previewSourceIdentity)
                ?? previewSource.frameInWindow,
            previewSource.image,
            previewSource
        )
    }

    private var mediaAccessibilityLabel: String {
        let base: String
        if loadState == .failure {
            if item.kind == .video {
                base = "\(destinationAccessibilityLabel ?? item.accessibilityLabel)，封面加载失败"
            } else {
                base = shouldOfferExplicitFallback
                ? "\(item.accessibilityLabel)预览加载失败，加载原图"
                : "\(item.accessibilityLabel)加载失败，重新加载"
            }
        } else if item.thumbnailURL != nil,
                  loadState == .empty,
                  mediaRequestPolicy.loadsAutomatically == false,
                  isManualLoadAuthorized == false {
            base = "加载\(item.accessibilityLabel)"
        } else if loadState == .loading,
                  ReaderMediaActivationPolicy.blocksWhileLoading(
                    requestPolicy: mediaRequestPolicy
                  ) {
            base = "正在加载\(item.accessibilityLabel)"
        } else {
            base = destinationAccessibilityLabel ?? item.accessibilityLabel
        }
        return "\(base)，共\(totalItemCount)项媒体"
    }

    private var mediaAccessibilityHint: String {
        if loadState == .failure {
            if item.kind == .video {
                return destinationAccessibilityHint ?? "打开媒体，封面加载失败不影响内容"
            }
            return shouldOfferExplicitFallback
                ? "明确请求当前媒体原图"
                : "重新请求当前媒体缩略图"
        }
        if item.thumbnailURL != nil,
           loadState == .empty,
           mediaRequestPolicy.loadsAutomatically == false,
           isManualLoadAuthorized == false {
            return "加载当前媒体缩略图"
        }
        if loadState == .loading,
           ReaderMediaActivationPolicy.blocksWhileLoading(
            requestPolicy: mediaRequestPolicy
           ) {
            return "请等待媒体缩略图加载完成"
        }
        return destinationAccessibilityHint ?? "打开媒体"
    }

    private var mediaRequestPolicy: ReaderMediaRequestPolicy {
        ReaderMediaRequestPolicy.resolve(readingPreferences.mediaLoading)
    }

    private var isManualLoadAuthorized: Bool {
        mediaRequestPolicy.allowsLoading(
            sourceIdentity: item.previewSourceIdentity,
            manualAuthorization: manualLoadAuthorization
        )
    }

    private var hasExplicitOriginalAuthorization: Bool {
        mediaRequestPolicy.allowsFallback(
            sourceIdentity: item.previewSourceIdentity,
            explicitAuthorization: explicitFallbackAuthorization
        )
    }

    private var shouldOfferExplicitFallback: Bool {
        guard readingPreferences.mediaLoading == .dataSaving,
              hasExplicitOriginalAuthorization == false,
              let originalURL = item.image?.originalURL else {
            return false
        }
        return originalURL != item.thumbnailURL
    }
}

private struct MediaThumbnailView: View {
    @Environment(\.readingPreferences) private var readingPreferences
    @Environment(\.displayScale) private var displayScale

    let item: ReaderMediaItem
    let maxHeight: CGFloat?
    let aspectRatioOverride: CGFloat?
    let retryTrigger: Int
    let isManualLoadAuthorized: Bool
    let explicitOriginalAuthorization: String?
    let showsManualLoadIndicator: Bool
    var previewSource: ImagePreviewSourceAnchor? = nil
    var onTransitionTap: (() -> Void)? = nil
    let onLoadStateChange: (TiebaRemoteImageLoadState) -> Void
    var onImageResolved: ((UIImage) -> Void)? = nil
    var onDebugImageObserverResolved: ((UIView, UIImage) -> Void)? = nil
    @State private var internalLoadState: TiebaRemoteImageLoadState = .empty

    var body: some View {
        thumbnailContent
            // aspectFit, not fill: a thumbnail now keeps its own proportions
            // inside the tile and letterboxes against the theme surface rather
            // than being stretched and clipped. 贴吧 likewise shows the whole
            // photo in the feed instead of cropping it to a fixed slot.
            .aspectRatio(aspectRatioOverride ?? item.aspectRatio, contentMode: .fit)
            .frame(maxHeight: maxHeight)
            .contentShape(RoundedRectangle(cornerRadius: TiebaPureTheme.Radius.media, style: .continuous))
    }

    private var thumbnailContent: some View {
        ZStack {
            Rectangle()
                .fill(TiebaPureTheme.ColorToken.readerTertiarySurface)

            if item.thumbnailURL != nil {
                GeometryReader { proxy in
                    TiebaRemoteImage(
                        primaryURL: requestSources.primaryURL,
                        fallbackURL: requestSources.fallbackURL,
                        targetPixelSize: TiebaImageDecodePolicy.previewTargetPixelSize(
                            for: proxy.size,
                            displayScale: displayScale
                        ),
                        contentMode: .fill,
                        retryTrigger: retryTrigger,
                        showsRetryButton: false,
                        showsResolvedImage: previewSource == nil,
                        loadsAutomatically: isManualLoadAuthorized,
                        onLoadStateChange: { state in
                            if internalLoadState != state {
                                internalLoadState = state
                            }
                            onLoadStateChange(state)
                            if state == .failure {
                                previewSource?.clearImage(
                                    sourceIdentity: item.previewSourceIdentity
                                )
                            }
                        },
                        onImageResolved: onImageResolved,
                        onDebugImageObserverResolved: onDebugImageObserverResolved
                    )
                }

                if let previewSource {
                    ImagePreviewSourceAnchorReader(
                        anchor: previewSource,
                        sourceIdentity: item.previewSourceIdentity,
                        onTransitionTap: onTransitionTap
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
                }

                if showsManualLoadIndicator,
                   requestPolicy.loadsAutomatically == false,
                   isManualLoadAuthorized == false,
                   internalLoadState == .empty {
                    manualLoadIndicator
                }
            } else {
                placeholder
            }

            if item.kind == .video, waitsForManualLoad == false {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: TiebaPureTheme.IconSize.play))
                    .foregroundStyle(.white)
                    .shadow(radius: 3)
                .accessibilityHidden(true)
            }
        }
    }

    private var placeholder: some View {
        Image(systemName: item.kind == .video ? "play.rectangle.fill" : "photo")
            .font(.system(size: 28))
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
    }

    private var manualLoadIndicator: some View {
        Image(systemName: "arrow.down.circle")
            .font(.system(size: 28, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: 44, height: 44)
            .background(.regularMaterial, in: Circle())
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private var requestPolicy: ReaderMediaRequestPolicy {
        ReaderMediaRequestPolicy.resolve(readingPreferences.mediaLoading)
    }

    private var requestSources: ReaderImageRequestSources {
        ReaderImageRequestSourcePolicy.resolve(
            previewURL: item.thumbnailURL,
            originalURL: item.image?.originalURL,
            requestPolicy: requestPolicy,
            sourceIdentity: item.previewSourceIdentity,
            explicitOriginalAuthorization: explicitOriginalAuthorization
        )
    }

    private var waitsForManualLoad: Bool {
        item.thumbnailURL != nil
            && requestPolicy.loadsAutomatically == false
            && isManualLoadAuthorized == false
            && internalLoadState == .empty
    }
}

/// Feed thumbnail sizing, tuned to match the official 百度贴吧 client's behaviour.
///
/// Two cases, because 贴吧 itself treats them differently:
///
/// - **Single image** — shown at the post's real aspect ratio instead of being
///   forced into a 2:1 slot. The original code stretched a 4:3 photo across a
///   2:1 tile and clipped the overflow, which cut the top and bottom off most
///   photos in the feed. The ratio is clamped so a very tall or very wide image
///   cannot eat the whole screen.
/// - **Two or more images** — a uniform grid of square tiles, the way 贴吧
///   lays out multi-image posts. Uniform tiles keep the row aligned; each
///   thumbnail is aspect-*fit* inside its tile so nothing is cropped.
enum ForumFeedMediaLayoutPolicy {
    /// Widest ratio a single image may show at (2.4:1). Wider images are
    /// letterboxed into this so one panorama cannot become a thin sliver.
    static let maximumSingleImageAspectRatio: CGFloat = 2.4
    /// Tallest single image shown, as a multiple of the feed width. A 9:16
    /// screenshot is clamped here rather than pushing the next post off screen.
    static let maximumSingleImageHeightRatio: CGFloat = 1.5

    static func visibleItemCount(totalCount: Int) -> Int {
        min(max(totalCount, 0), 3)
    }

    /// Uniform tile ratio for multi-image posts (square tiles, 3 across).
    static func containerAspectRatio(totalCount: Int) -> CGFloat {
        totalCount <= 1 ? 2 : 3
    }

    static func containerHeight(containerWidth: CGFloat, totalCount: Int) -> CGFloat {
        containerWidth / containerAspectRatio(totalCount: totalCount)
    }

    static func thumbnailAspectRatio(totalCount: Int, visibleCount: Int) -> CGFloat {
        let visibleCount = max(visibleCount, 1)
        return containerAspectRatio(totalCount: totalCount) / CGFloat(visibleCount)
    }

    /// Aspect ratio of the feed row that holds `visibleCount` images.
    ///
    /// A single image keeps its own ratio (clamped); multi-image posts use the
    /// uniform tile ratio so the grid stays aligned.
    static func containerAspectRatio(
        totalCount: Int,
        visibleCount: Int,
        aspectRatios: [CGFloat]
    ) -> CGFloat {
        guard isSingleImageLayout(totalCount: totalCount, visibleCount: visibleCount) else {
            return containerAspectRatio(totalCount: totalCount)
        }
        let ratio = aspectRatios.first ?? containerAspectRatio(totalCount: totalCount)
        return min(
            max(ratio, 1 / maximumSingleImageHeightRatio),
            maximumSingleImageAspectRatio
        )
    }

    static func containerHeight(
        containerWidth: CGFloat,
        totalCount: Int,
        visibleCount: Int,
        aspectRatios: [CGFloat]
    ) -> CGFloat {
        containerWidth / containerAspectRatio(
            totalCount: totalCount,
            visibleCount: visibleCount,
            aspectRatios: aspectRatios
        )
    }

    static func isSingleImageLayout(totalCount: Int, visibleCount: Int) -> Bool {
        totalCount == 1 && visibleCount == 1
    }

    static func showsMoreBadge(totalCount: Int, visibleCount: Int) -> Bool {
        totalCount > visibleCount
    }
}
