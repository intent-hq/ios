import SwiftUI

struct ImageLightboxView: View {
    private enum LoadedImage {
        case image(UIImage, Data?)
        case failed
    }

    let items: [ImageLightboxItem]
    var onHydrate: ((ImageLightboxItem) -> Void)?
    @Environment(\.dismiss) private var dismiss
    @Environment(BackendSession.self) private var session: BackendSession?
    @ScaledMetric(relativeTo: .body) private var actionIconSide: CGFloat = 17

    @State private var currentID: String
    @State private var loadedImages: [String: LoadedImage] = [:]
    @State private var scale: CGFloat = 1
    @State private var gestureScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var dragTranslation: CGSize = .zero
    @State private var pageDrag: CGFloat = 0
    @State private var dragAxis: Axis?
    @State private var viewportSize: CGSize = .zero

    private static let minScale: CGFloat = 1
    private static let maxScale: CGFloat = 5
    private static let doubleTapScale: CGFloat = 2.5
    private static let dismissDragThreshold: CGFloat = 120
    private static let zoomPercentageMultiplier: CGFloat = 100
    private static let accessibilityPanDistance: CGFloat = 50
    private static let pageSpacing: CGFloat = 24
    private static let pageCommitFraction: CGFloat = 0.25
    private static let pageEdgeResistance: CGFloat = 0.3

    init(
        items: [ImageLightboxItem],
        initialID: String,
        initialImage: (image: UIImage, data: Data?)? = nil,
        onHydrate: ((ImageLightboxItem) -> Void)? = nil
    ) {
        self.items = items
        self.onHydrate = onHydrate
        _currentID = State(initialValue: initialID)
        if let initialImage, let initialItem = items.first(where: { $0.id == initialID }) {
            _loadedImages = State(initialValue: [initialItem.loadKey: .image(initialImage.image, initialImage.data)])
        }
    }

    init(image: UIImage, data: Data? = nil) {
        self.init(
            items: [ImageLightboxItem(id: "image", source: .loaded(image, data))],
            initialID: "image",
            initialImage: (image, data)
        )
    }

    private var currentIndex: Int {
        items.firstIndex { $0.id == currentID } ?? 0
    }

    private var currentItem: ImageLightboxItem? {
        items.indices.contains(currentIndex) ? items[currentIndex] : nil
    }

    private var windowItems: ArraySlice<ImageLightboxItem> {
        guard !items.isEmpty else { return [] }
        let index = currentIndex
        return items[max(0, index - 1)...min(items.count - 1, index + 1)]
    }

    private var currentImage: (image: UIImage, data: Data?)? {
        guard let currentItem, case let .image(image, data) = loadedImages[currentItem.loadKey] else { return nil }
        return (image, data)
    }

    private var pageStride: CGFloat {
        viewportSize.width + Self.pageSpacing
    }

    var body: some View {
        ZStack {
            backdrop
            ForEach(windowItems) { item in
                page(for: item)
            }
        }
        .contentShape(Rectangle())
        .gesture(dragGesture)
        .simultaneousGesture(magnifyGesture)
        .onGeometryChange(for: CGSize.self) { proxy in
            proxy.size
        } action: { size in
            if size.width > 0, size.height > 0 {
                viewportSize = size
            }
        }
        .overlay(alignment: .topTrailing) {
            HStack(spacing: Constants.Conversation.ImageLightbox.actionSpacing) {
                if let currentImage, currentItem?.isTruncated == false {
                    actionsMenu(image: currentImage.image, data: currentImage.data)
                }
                closeButton
            }
            .padding(Constants.Conversation.ImageLightbox.actionContainerPadding)
        }
        .task(id: windowItems.map(\.loadKey)) {
            await loadWindow()
        }
        .onChange(of: currentItem?.loadKey, initial: true) {
            if let currentItem, currentItem.isTruncated { onHydrate?(currentItem) }
        }
        .imageSaveAlert()
    }

    private var backdrop: some View {
        Color.black
            .ignoresSafeArea()
            .onTapGesture { dismiss() }
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func page(for item: ImageLightboxItem) -> some View {
        let position = CGFloat((items.firstIndex { $0.id == item.id } ?? 0) - currentIndex)
        let isCurrent = item.id == currentItem?.id
        pageContent(for: item, isCurrent: isCurrent)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .offset(x: position * pageStride + pageDrag)
            .accessibilityHidden(!isCurrent)
    }

    @ViewBuilder
    private func pageContent(for item: ImageLightboxItem, isCurrent: Bool) -> some View {
        switch loadedImages[item.loadKey] {
        case let .image(image, _):
            if isCurrent {
                zoomableImage(image)
            } else {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .accessibilityHidden(true)
            }
        case .failed:
            ImageDecodeFailureView()
                .environment(\.colorScheme, .dark)
        case nil:
            ProgressView()
                .tint(.white)
        }
    }

    private func zoomableImage(_ image: UIImage) -> some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .scaleEffect(scale * gestureScale)
            .offset(
                x: offset.width + dragTranslation.width,
                y: offset.height + dragTranslation.height
            )
            .accessibilityLabel("Image preview")
            .accessibilityValue(accessibilityValue)
            .accessibilityAdjustableAction { direction in
                adjustZoom(direction)
            }
            .accessibilityActions {
                imageAccessibilityActions
            }
            .gesture(doubleTapGesture)
    }

    private var accessibilityValue: String {
        let zoom = "\(Int(scale * Self.zoomPercentageMultiplier)) percent zoom"
        guard items.count > 1 else { return zoom }
        return "Image \(currentIndex + 1) of \(items.count), \(zoom)"
    }

    @ViewBuilder
    private var imageAccessibilityActions: some View {
        if currentIndex > 0 {
            Button("Previous Image") { showPage(currentIndex - 1) }
        }
        if currentIndex < items.count - 1 {
            Button("Next Image") { showPage(currentIndex + 1) }
        }
        if scale > Self.minScale {
            Button("Pan Left") {
                panImage(by: CGSize(width: -Self.accessibilityPanDistance, height: 0))
            }
            Button("Pan Right") {
                panImage(by: CGSize(width: Self.accessibilityPanDistance, height: 0))
            }
            Button("Pan Up") {
                panImage(by: CGSize(width: 0, height: -Self.accessibilityPanDistance))
            }
            Button("Pan Down") {
                panImage(by: CGSize(width: 0, height: Self.accessibilityPanDistance))
            }
            Button("Reset Zoom") {
                resetZoom()
            }
        }
    }

    private func actionsMenu(image: UIImage, data: Data?) -> some View {
        Menu {
            ImageActionMenuItems(image: image, originalData: data)
        } label: {
            Image(.more)
                .resizable()
                .scaledToFit()
                .accessibilityHidden(true)
                .frame(width: actionIconSide, height: actionIconSide)
                .foregroundStyle(.white)
                .padding(Constants.Conversation.ImageLightbox.actionButtonPadding)
                .background(.white.opacity(Constants.Conversation.ImageLightbox.actionButtonBackgroundOpacity), in: Circle())
                .frame(
                    minWidth: Constants.Accessibility.minimumTapTarget,
                    minHeight: Constants.Accessibility.minimumTapTarget
                )
        }
        .buttonStyle(IntentContentButtonStyle())
        .accessibilityLabel("Image actions")
    }

    private var closeButton: some View {
        Button { dismiss() } label: {
            Image(.close)
                .resizable()
                .scaledToFit()
                .accessibilityHidden(true)
                .frame(width: actionIconSide, height: actionIconSide)
                .foregroundStyle(.white)
                .padding(Constants.Conversation.ImageLightbox.actionButtonPadding)
                .background(.white.opacity(Constants.Conversation.ImageLightbox.actionButtonBackgroundOpacity), in: Circle())
                .frame(
                    minWidth: Constants.Accessibility.minimumTapTarget,
                    minHeight: Constants.Accessibility.minimumTapTarget
                )
        }
        .buttonStyle(IntentContentButtonStyle())
        .accessibilityLabel("Close image")
    }
}

extension ImageLightboxView {
    // MARK: - Loading

    private func loadWindow() async {
        let window = Array(windowItems)
        let keys = Set(window.map(\.loadKey))
        loadedImages = loadedImages.filter { keys.contains($0.key) }
        let ordered = window.filter { $0.id == currentID } + window.filter { $0.id != currentID }
        for item in ordered where loadedImages[item.loadKey] == nil {
            let loaded = await load(item)
            guard !Task.isCancelled else { return }
            loadedImages[item.loadKey] = loaded
        }
    }

    private func load(_ item: ImageLightboxItem) async -> LoadedImage {
        switch item.source {
        case let .loaded(image, data):
            return .image(image, data)
        case let .inline(block):
            guard let data = ContentBlockView.decodeImageData(block), let image = UIImage(data: data) else { return .failed }
            return .image(image, data)
        case let .attachment(workspaceId, attachmentId):
            let loader = session?.attachmentImageLoader ?? .shared
            guard let image = try? await loader.image(workspaceId: workspaceId, attachmentId: attachmentId) else { return .failed }
            return .image(image, nil)
        case let .markdown(url, workspaceId, _):
            guard let image = await loadMarkdownImage(url, workspaceId: workspaceId) else { return .failed }
            return .image(image, nil)
        }
    }

    private func loadMarkdownImage(_ url: URL, workspaceId: String) async -> UIImage? {
        let fileLoader = session?.workspaceFileImageLoader ?? .shared
        switch MarkdownImageRoute.route(for: url) {
        case let .workspaceAsset(link?):
            guard case let .image(image) = try? await fileLoader.assetMedia(
                workspaceId: link.workspaceId,
                assetId: link.assetId
            ) else { return nil }
            return image
        case let .intentFile(link):
            return try? await fileLoader.image(workspaceId: link.workspaceId ?? workspaceId, path: link.path)
        case .remote:
            return try? await RemoteImageLoader.shared.image(for: url)
        case .workspaceAsset(nil), .fallback:
            return nil
        }
    }

    // MARK: - Paging

    private func showPage(_ index: Int) {
        guard items.indices.contains(index) else { return }
        withAnimation(.spring(duration: Constants.Conversation.ImageLightbox.springAnimationDuration)) {
            pageDrag = 0
            currentID = items[index].id
            resetZoom()
        }
    }

    private func resistedPageDrag(_ translation: CGFloat) -> CGFloat {
        let atStart = currentIndex == 0 && translation > 0
        let atEnd = currentIndex == items.count - 1 && translation < 0
        return atStart || atEnd ? translation * Self.pageEdgeResistance : translation
    }

    private func finishPaging(_ value: DragGesture.Value) {
        let threshold = viewportSize.width * Self.pageCommitFraction
        let travel = abs(value.translation.width) > threshold ? value.translation.width : value.predictedEndTranslation.width
        var target = currentIndex
        if travel < -threshold, currentIndex < items.count - 1 {
            target += 1
        } else if travel > threshold, currentIndex > 0 {
            target -= 1
        }
        showPage(target)
    }

    // MARK: - Gestures

    private var doubleTapGesture: some Gesture {
        TapGesture(count: 2).onEnded {
            withAnimation(.spring(duration: Constants.Conversation.ImageLightbox.springAnimationDuration)) {
                if scale > Self.minScale {
                    scale = Self.minScale
                    offset = .zero
                } else {
                    scale = Self.doubleTapScale
                }
            }
        }
    }

    private func resetZoom() {
        scale = Self.minScale
        gestureScale = 1
        offset = .zero
        dragTranslation = .zero
    }

    private func adjustZoom(_ direction: AccessibilityAdjustmentDirection) {
        let step: CGFloat = 0.5
        switch direction {
        case .increment:
            scale = min(scale + step, Self.maxScale)
        case .decrement:
            scale = max(scale - step, Self.minScale)
            offset = clampedOffset(offset)
        @unknown default:
            break
        }
    }

    private func panImage(by delta: CGSize) {
        offset = clampedOffset(
            CGSize(width: offset.width + delta.width, height: offset.height + delta.height)
        )
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                guard currentImage != nil else { return }
                gestureScale = value.magnification
            }
            .onEnded { value in
                guard currentImage != nil else { return }
                scale = min(max(scale * value.magnification, Self.minScale), Self.maxScale)
                gestureScale = 1
                withAnimation(.spring(duration: Constants.Conversation.ImageLightbox.springAnimationDuration)) {
                    offset = clampedOffset(offset)
                }
            }
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                if scale > Self.minScale {
                    dragTranslation = value.translation
                    return
                }
                let axis = dragAxis ?? (abs(value.translation.width) > abs(value.translation.height) ? .horizontal : .vertical)
                dragAxis = axis
                switch axis {
                case .horizontal:
                    pageDrag = resistedPageDrag(value.translation.width)
                case .vertical:
                    dragTranslation = CGSize(width: 0, height: max(0, value.translation.height))
                }
            }
            .onEnded { value in
                let axis = dragAxis
                dragAxis = nil
                if scale > Self.minScale {
                    let raw = CGSize(
                        width: offset.width + value.translation.width,
                        height: offset.height + value.translation.height
                    )
                    dragTranslation = .zero
                    withAnimation(.spring(duration: Constants.Conversation.ImageLightbox.springAnimationDuration)) {
                        offset = clampedOffset(raw)
                    }
                } else if axis == .horizontal {
                    finishPaging(value)
                } else if value.translation.height > Self.dismissDragThreshold {
                    dismiss()
                } else {
                    withAnimation(.spring(duration: Constants.Conversation.ImageLightbox.springAnimationDuration)) {
                        dragTranslation = .zero
                    }
                }
            }
    }

    private func clampedOffset(_ proposed: CGSize) -> CGSize {
        let container = viewportSize
        guard scale > Self.minScale, let image = currentImage?.image, image.size.width > 0, image.size.height > 0,
              container.width > 0, container.height > 0 else { return .zero }
        let fitRatio = min(container.width / image.size.width, container.height / image.size.height)
        let fitted = CGSize(width: image.size.width * fitRatio, height: image.size.height * fitRatio)
        let maxX = max(0, (fitted.width * scale - container.width) / 2)
        let maxY = max(0, (fitted.height * scale - container.height) / 2)
        return CGSize(
            width: min(max(proposed.width, -maxX), maxX),
            height: min(max(proposed.height, -maxY), maxY)
        )
    }
}
