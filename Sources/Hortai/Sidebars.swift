import AppKit
import Combine
import ImageIO
import SwiftUI

// Small previews, decoded once and kept while the app runs.
@MainActor
enum ThumbnailCache {
    private static let cache = NSCache<NSURL, CGImage>()

    static func image(for url: URL, side: CGFloat) async -> CGImage? {
        if let hit = cache.object(forKey: url as NSURL) { return hit }
        // One size for every place a thumbnail shows, so the cache never hands a tiny one to a big cell.
        let pixels = Int(220 * (NSScreen.main?.backingScaleFactor ?? 2) * 2)
        let made = await Task.detached(priority: .utility) { () -> CGImage? in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: pixels,
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }.value
        if let made { cache.setObject(made, forKey: url as NSURL) }
        return made
    }

    // A photo changed on disk (rotated, metadata removed).
    static func forget(_ url: URL) { cache.removeObject(forKey: url as NSURL) }
}

struct Thumbnail: View {
    let url: URL
    let side: CGFloat
    var revision = 0
    @State private var image: CGImage?

    var body: some View {
        // Hugs the photo's shape, so landscape thumbnails don't leave empty bands in the list.
        Group {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                RoundedRectangle(cornerRadius: 4).fill(.quaternary).aspectRatio(1.5, contentMode: .fit)
            }
        }
        .frame(maxWidth: side, maxHeight: side)
        .task(id: "\(revision) \(url.path)") { image = await ThumbnailCache.image(for: url, side: side) }
    }
}

// What the left panel shows for each photo; right-click in the panel or the View menu switches it.
enum ThumbnailStyle: String, CaseIterable {
    case images, imagesAndNames, names
    static let key = "ThumbnailStyle"

    var title: String {
        switch self {
        case .images: L("Thumbnails")
        case .imagesAndNames: L("Thumbnails and Names")
        case .names: L("List")
        }
    }
}

// A folder's name over its photos: click folds it, × on hover takes it out of the panel.
private struct FolderHeader: View {
    let folder: URL
    let isCollapsed: Bool
    let toggle: () -> Void
    let remove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                .frame(width: 10)
            Image(systemName: "folder")
            Text(FileManager.default.displayName(atPath: folder.path))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            Button(action: remove) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(.primary.opacity(0.1)))
            }
            .buttonStyle(.plain)
            .opacity(hovering ? 1 : 0)
            .help(L("Remove from Sidebar"))
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
        .onHover { hovering = $0 }
        .help((folder.path as NSString).abbreviatingWithTildeInPath)
    }
}

// Left panel, like Preview's: the folders' photos, the shown one selected.
struct ThumbnailList: View {
    @ObservedObject var model: ViewerModel
    @AppStorage(ThumbnailStyle.key) private var style: ThumbnailStyle = .imagesAndNames
    @State private var collapsed: Set<URL> = []

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: style == .names ? 0 : 4) {
                    ForEach(model.groups) { group in
                        FolderHeader(folder: group.folder, isCollapsed: collapsed.contains(group.folder)) {
                            withAnimation(.snappy) {
                                if collapsed.contains(group.folder) { collapsed.remove(group.folder) } else { collapsed.insert(group.folder) }
                            }
                        } remove: {
                            model.remove(group.folder)
                        }
                        if !collapsed.contains(group.folder) {
                            if group.files.isEmpty {
                                Text("No Photos")
                                    .font(.callout)
                                    .foregroundStyle(.tertiary)
                                    .padding(.horizontal, 28)
                                    .padding(.vertical, 6)
                            }
                            ForEach(group.files, id: \.self) { url in
                                cell(url)
                            }
                        }
                    }
                }
                .padding(style == .names ? 8 : 10)
            }
            // A folder dropped here joins the ones already open.
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                for provider in providers {
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        guard let url else { return }
                        DispatchQueue.main.async { model.add(url) }
                    }
                }
                return true
            }
            .contextMenu {
                Picker(selection: $style) {
                    ForEach(ThumbnailStyle.allCases, id: \.self) { Text($0.title) }
                } label: { EmptyView() }
                .pickerStyle(.inline)
            }
            .onChange(of: model.currentURL, initial: true) { _, url in
                guard let url else { return }
                // Arrows can walk into a folded group; open it so the shown photo is visible.
                if let group = model.groups.first(where: { $0.files.contains(url) }), collapsed.contains(group.folder) {
                    collapsed.remove(group.folder)
                }
                withAnimation { proxy.scrollTo(url, anchor: .center) }
            }
        }
        .frame(minWidth: 150)
    }

    // Drawn by hand: the system list's selection is inset and came out narrower than the panel.
    private func cell(_ url: URL) -> some View {
        let selected = url == model.currentURL
        let name = Text(url.lastPathComponent)
            .foregroundStyle(selected ? .primary : .secondary)
            .lineLimit(1)
            .truncationMode(.middle)
        return Group {
            switch style {
            case .names:
                HStack(spacing: 8) {
                    Thumbnail(url: url, side: 20, revision: model.revision).frame(width: 20, height: 20)
                    name.font(.callout)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 5)
                .padding(.horizontal, 8)
            case .images, .imagesAndNames:
                VStack(spacing: 6) {
                    Thumbnail(url: url, side: 220, revision: model.revision)
                    if style == .imagesAndNames { name.font(.caption) }
                }
                .padding(.vertical, style == .images ? 6 : 8)
                .padding(.horizontal, 6)
            }
        }
        .frame(maxWidth: .infinity)
        .background {
            if selected { RoundedRectangle(cornerRadius: style == .names ? 6 : 10, style: .continuous).fill(.primary.opacity(0.12)) }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.select(url) }
        .help(url.lastPathComponent)
        .id(url)
    }
}

// The window title: the photo's name, and under it the folder path, faint except for the folder itself.
struct TitleView: View {
    @ObservedObject var model: ViewerModel

    var body: some View {
        if let url = model.currentURL {
            let folder = url.deletingLastPathComponent()
            let parent = (folder.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
            VStack(alignment: .leading, spacing: 1) {
                Text(url.lastPathComponent)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(Text(parent == "/" ? "/" : parent + "/").foregroundStyle(.tertiary))\(Text(folder.lastPathComponent).foregroundStyle(.secondary))")
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            .help(url.path)
        } else {
            Text("Hortai").font(.headline)
        }
    }
}

// Thumbnails | photo | info, like Preview and Finder. Both stay hidden while there is no photo;
// with one, each comes back as it was last left.
@MainActor
final class ViewerSplitController: NSSplitViewController {
    let thumbnails: NSSplitViewItem
    let info: NSSplitViewItem
    private let model: ViewerModel
    private var watch: AnyCancellable?
    private static let thumbnailsKey = "ShowsThumbnails", infoKey = "ShowsInfo"

    init(model: ViewerModel, info infoModel: InfoModel) {
        self.model = model
        thumbnails = NSSplitViewItem(sidebarWithViewController: NSHostingController(rootView: ThumbnailList(model: model)))
        thumbnails.isCollapsed = true
        thumbnails.minimumThickness = 150
        thumbnails.maximumThickness = 260
        info = NSSplitViewItem(inspectorWithViewController: NSHostingController(rootView: InfoView(info: infoModel)))
        info.isCollapsed = true
        info.minimumThickness = 260
        info.maximumThickness = 420
        super.init(nibName: nil, bundle: nil)
        let viewer = NSSplitViewItem(viewController: NSHostingController(rootView: ViewerView(model: model, zoom: model.zoom)))
        viewer.minimumThickness = 360
        splitViewItems = [thumbnails, viewer, info]
        // Thumbnails need an open folder, even an empty one; info needs a photo.
        watch = model.$groups.map { !$0.isEmpty }.removeDuplicates()
            .combineLatest(model.$currentURL.map { $0 != nil }.removeDuplicates())
            .sink { [weak self] hasFolders, hasPhoto in self?.showPanels(hasFolders: hasFolders, hasPhoto: hasPhoto) }
    }

    required init?(coder: NSCoder) { fatalError() }

    private func showPanels(hasFolders: Bool, hasPhoto: Bool) {
        let defaults = UserDefaults.standard
        thumbnails.isCollapsed = !(hasFolders && defaults.bool(forKey: Self.thumbnailsKey))
        info.isCollapsed = !(hasPhoto && defaults.bool(forKey: Self.infoKey))
    }

    override func toggleSidebar(_ sender: Any?) {
        guard model.currentURL != nil else { return }
        let show = thumbnails.isCollapsed
        super.toggleSidebar(sender)
        UserDefaults.standard.set(show, forKey: Self.thumbnailsKey)
    }

    func toggleInfo() {
        guard model.currentURL != nil else { return }
        let show = info.isCollapsed
        info.animator().isCollapsed = !show
        UserDefaults.standard.set(show, forKey: Self.infoKey)
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(toggleSidebar(_:)) { return !model.groups.isEmpty }
        return super.validateUserInterfaceItem(item)
    }

    var openPanelsWidth: CGFloat {
        [thumbnails, info].filter { !$0.isCollapsed }.reduce(0) { $0 + $1.viewController.view.frame.width }
    }
}
