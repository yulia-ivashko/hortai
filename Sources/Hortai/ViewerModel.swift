import AppKit
import ImageIO
import UniformTypeIdentifiers

@MainActor
final class ViewerModel: ObservableObject {
    @Published private(set) var currentURL: URL?
    @Published private(set) var image: CGImage?
    @Published private(set) var loadFailed = false

    let zoom = ZoomController()
    weak var window: NSWindow?

    private var files: [URL] = []
    private var cache: [URL: CGImage] = [:]
    private var loadTask: Task<Void, Never>?
    private var slideshow: SlideshowController?

    // MARK: Opening and stepping

    func open(_ url: URL) {
        let url = url.standardizedFileURL
        rescan(folderOf: url)
        show(url)
    }

    func step(_ delta: Int) {
        guard let current = currentURL else { return }
        rescan(folderOf: current)
        guard !files.isEmpty else { return }
        let count = files.count
        let target: Int
        if let index = indexOf(current) {
            target = ((index + delta) % count + count) % count
        } else {
            // The current file is gone; continue from where it used to be.
            let next = files.firstIndex { Self.precedes(current, $0) } ?? count
            target = delta > 0 ? next % count : (next - 1 + count) % count
        }
        show(files[target])
    }

    func showFirst() {
        guard let current = currentURL else { return }
        rescan(folderOf: current)
        if let first = files.first { show(first) }
    }

    func showLast() {
        guard let current = currentURL else { return }
        rescan(folderOf: current)
        if let last = files.last { show(last) }
    }

    private func show(_ url: URL) {
        currentURL = url
        window?.title = url.lastPathComponent
        window?.representedURL = url
        loadTask?.cancel()
        if let cached = cache[url] {
            image = cached
            loadFailed = false
            prefetchNeighbors()
            return
        }
        loadTask = Task {
            let decoded = await ImageLoader.load(url)
            guard !Task.isCancelled, currentURL == url else { return }
            image = decoded
            loadFailed = decoded == nil
            if let decoded { cache[url] = decoded }
            prefetchNeighbors()
        }
    }

    private func prefetchNeighbors() {
        guard let current = currentURL, let index = indexOf(current), !files.isEmpty else { return }
        let count = files.count
        let keep = Set([current, files[(index + 1) % count], files[(index - 1 + count) % count]])
        cache = cache.filter { keep.contains($0.key) }
        for url in keep where cache[url] == nil {
            Task {
                guard let decoded = await ImageLoader.load(url) else { return }
                if self.isNeighbor(url) { self.cache[url] = decoded }
            }
        }
    }

    private func isNeighbor(_ url: URL) -> Bool {
        guard let current = currentURL, let index = indexOf(current), !files.isEmpty else { return false }
        let count = files.count
        return [current, files[(index + 1) % count], files[(index - 1 + count) % count]].contains(url)
    }

    private func rescan(folderOf url: URL) {
        let folder = url.deletingLastPathComponent()
        let items = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        files = items
            .filter { Self.isReadableImage($0) }
            .map(\.standardizedFileURL)
            .sorted { Self.precedes($0, $1) }
    }

    private func indexOf(_ url: URL) -> Int? {
        files.firstIndex { $0.path == url.path }
    }

    private static let readableTypes = Set((CGImageSourceCopyTypeIdentifiers() as? [String]) ?? [])

    private static func isReadableImage(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return readableTypes.contains(type.identifier)
    }

    // Finder's order: "photo 2" before "photo 10".
    private static func precedes(_ a: URL, _ b: URL) -> Bool {
        a.lastPathComponent.localizedStandardCompare(b.lastPathComponent) == .orderedAscending
    }

    // MARK: Actions

    func rotate(clockwise: Bool) {
        guard let url = currentURL, image != nil else { return }
        Task {
            let saved = await Task.detached(priority: .userInitiated) {
                (try? ImageRotator.rotate(url, clockwise: clockwise)) != nil
            }.value
            guard saved else {
                showError(L("Couldn’t rotate the photo"))
                return
            }
            cache[url] = nil
            if currentURL == url { show(url) }
        }
    }

    func confirmTrash() {
        guard let url = currentURL, let window, window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = String(format: L("Move “%@” to the Trash?"), url.lastPathComponent)
        alert.addButton(withTitle: L("Move to Trash"))
        alert.addButton(withTitle: L("Cancel"))
        alert.buttons[0].hasDestructiveAction = true
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { self.trash(url) }
        }
    }

    private func trash(_ url: URL) {
        rescan(folderOf: url)
        let index = indexOf(url) ?? 0
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        } catch {
            showError(L("Couldn’t move the photo to the Trash"))
            return
        }
        cache[url] = nil
        rescan(folderOf: url)
        if files.isEmpty {
            loadTask?.cancel()
            currentURL = nil
            image = nil
            window?.title = "Hortai"
            window?.representedURL = nil
        } else {
            show(files[min(index, files.count - 1)])
        }
    }

    func startSlideshow() {
        guard currentURL != nil, slideshow == nil else { return }
        let show = SlideshowController(model: self)
        show.onEnd = { [weak self] in self?.slideshow = nil }
        slideshow = show
        show.start()
    }

    func showInFinder() {
        guard let url = currentURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func open(with app: URL) {
        guard let url = currentURL else { return }
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    func setAsWallpaper() {
        guard let url = currentURL else { return }
        do {
            for screen in NSScreen.screens {
                try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [:])
            }
        } catch {
            showError(L("Couldn’t set the wallpaper"))
        }
    }

    // The file changed on disk; drop the cached copy and show it again.
    func reloadIfShowing(_ url: URL) {
        cache[url] = nil
        if currentURL == url { show(url) }
    }

    func copyPath() {
        guard let url = currentURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
    }

    func copyToPasteboard() {
        guard let url = currentURL, let image else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL, NSImage(cgImage: image, size: .zero)])
    }

    func printPhoto() {
        guard let image, let window else { return }
        let info = NSPrintInfo.shared
        let view = NSImageView(frame: NSRect(origin: .zero, size: info.imageablePageBounds.size))
        view.image = NSImage(cgImage: image, size: .zero)
        view.imageScaling = .scaleProportionallyDown
        NSPrintOperation(view: view, printInfo: info).runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    private func showError(_ text: String) {
        let alert = NSAlert()
        alert.messageText = text
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }
}

enum ImageLoader {
    static func load(_ url: URL) async -> CGImage? {
        await Task.detached(priority: .userInitiated) { decode(url) }.value
    }

    // Full-size decode with the camera's orientation applied.
    nonisolated static func decode(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = props?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = props?[kCGImagePropertyPixelHeight] as? Int ?? 0
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height, 1),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
