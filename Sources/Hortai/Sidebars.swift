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
        }
        // The × floats over the row's end, so its empty slot never squeezes the name.
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.trailing, hovering ? 24 : 0)
        .overlay(alignment: .trailing) {
            if hovering {
                Button(action: remove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(.primary.opacity(0.1)))
                }
                .buttonStyle(.plain)
                .help(L("Remove from Sidebar"))
            }
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
        // The + sits under the list, not over it; the list fades out just above it.
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: style == .names ? 0 : 6) {
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
                    .padding(.leading, style == .names ? 8 : 14)
                    .padding(.trailing, style == .names ? 12 : 18)
                    .padding(.vertical, style == .names ? 8 : 10)
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
            .mask {
                VStack(spacing: 0) {
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 24)
                }
            }
            // Like the + under Mail's mailboxes: adds another folder to the panel.
            HStack {
                Button {
                    if let url = AppDelegate.runOpenPanel() { model.add(url) }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .regular))
                }
                .buttonStyle(RoundButtonStyle())
                .help(L("Add Folder…") + " (⇧⌘O)")
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .frame(minWidth: 200)
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
                .padding(.vertical, style == .images ? 10 : 12)
                .padding(.horizontal, 12)
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
// Each level of the path opens that folder; an empty folder shows its own name over its parent's path.
struct TitleView: View {
    @ObservedObject var model: ViewerModel

    var body: some View {
        if let url = model.currentURL {
            title(url.lastPathComponent, path: url.deletingLastPathComponent())
                .help(url.path)
        } else if let folder = model.groups.first?.folder {
            title(folder.lastPathComponent, path: folder.deletingLastPathComponent())
                .help(folder.path)
        } else {
            Text("Hortai").font(.headline).padding(.leading, ImageScrollView.sideMargin)
        }
    }

    private func title(_ name: String, path: URL) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(name)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
            PathLine(levels: Self.levels(of: path)) { model.jump(to: $0) }
        }
        .frame(minWidth: 60, alignment: .leading)
        // Lines up with the photo's left edge instead of hugging the sidebar; next to back and forward it sits
        // as close as Finder's title does.
        .padding(.leading, model.hasJumped ? 3 : ImageScrollView.sideMargin)
    }

    // ~/Pictures/From Orbit as [~, Pictures, From Orbit], each with the folder it stands for.
    private static func levels(of folder: URL) -> [(name: String, url: URL)] {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        var url = folder.standardizedFileURL
        var levels: [(name: String, url: URL)] = []
        while true {
            if url.path == home { levels.append(("~", url)); break }
            if url.path == "/" { levels.append(("/", url)); break }
            levels.append((url.lastPathComponent, url))
            url = url.deletingLastPathComponent()
        }
        return levels.reversed()
    }
}

private struct PathLine: View {
    let levels: [(name: String, url: URL)]
    let open: (URL) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(levels.enumerated()), id: \.offset) { index, level in
                // The root is itself the slash, so nothing goes between it and the next level.
                if index > 0, levels[index - 1].name != "/" {
                    Text("/").foregroundStyle(.tertiary)
                }
                PathLevel(name: level.name, isLast: index == levels.count - 1) { open(level.url) }
                    // When the path doesn't fit, the levels nearest the root give way first.
                    .layoutPriority(Double(index))
            }
        }
        .font(.caption)
        .lineLimit(1)
    }
}

private struct PathLevel: View {
    let name: String
    let isLast: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(name)
                .underline(hovering)
                .foregroundStyle(hovering ? AnyShapeStyle(.primary) : isLast ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .onHover { hovering = $0 }
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
        thumbnails = NSSplitViewItem(sidebarWithViewController: Self.host(ThumbnailList(model: model)))
        thumbnails.isCollapsed = true
        thumbnails.minimumThickness = 200
        thumbnails.maximumThickness = 320
        // A plain item, not an inspector: an inspector starts under an empty toolbar band; this one runs to the top edge.
        let infoView = InfoView(info: infoModel).background { WindowGlass().ignoresSafeArea() }
        info = NSSplitViewItem(viewController: Self.host(infoView))
        info.canCollapse = true
        info.isCollapsed = true
        // Below the priority of a dragged divider, so the panel can be resized by hand; above the photo, so it keeps its width when the window does.
        info.holdingPriority = NSLayoutConstraint.Priority(260)
        info.minimumThickness = 260
        // Wide enough for long camera and path values: up to a third of the screen.
        info.maximumThickness = max(420, (NSScreen.main?.visibleFrame.width ?? 1440) / 3)
        super.init(nibName: nil, bundle: nil)
        let viewer = NSSplitViewItem(viewController: Self.host(ViewerView(model: model, zoom: model.zoom)))
        viewer.minimumThickness = 360
        // The floating sidebar sits over the viewer's background, not beside it; the photo stays clear of it.
        viewer.automaticallyAdjustsSafeAreaInsets = true
        splitViewItems = [thumbnails, viewer, info]
        // Thumbnails need an open folder, even an empty one; info needs a photo.
        watch = model.$groups.map { !$0.isEmpty }.removeDuplicates()
            .combineLatest(model.$currentURL.map { $0 != nil }.removeDuplicates())
            .sink { [weak self] hasFolders, hasPhoto in self?.showPanels(hasFolders: hasFolders, hasPhoto: hasPhoto) }
    }

    required init?(coder: NSCoder) { fatalError() }

    // By default a hosting view pins its width to what its content would like, so a panel can't be dragged
    // wider or narrower and only snaps open or shut. Only the minimum is passed on; the split view sets the rest.
    private static func host<V: View>(_ view: V) -> NSHostingController<V> {
        let controller = NSHostingController(rootView: view)
        controller.sizingOptions = []
        return controller
    }

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

// A round grey button, like the ? in System Settings (measured there: fill 8% black, glyph near black);
// no hover change, as there; a shade stronger when pressed.
private struct RoundButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        RoundButton(configuration: configuration)
    }

    private struct RoundButton: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.colorScheme) private var scheme

        var body: some View {
            // Plain colours: .primary on the sidebar's glass turns vibrant and the circle all but vanished.
            let ink: Color = scheme == .dark ? .white : .black
            configuration.label
                .foregroundStyle(ink.opacity(0.9))
                .frame(width: 26, height: 26)
                .background(Circle().fill(ink.opacity(configuration.isPressed ? 0.18 : 0.08)))
                .contentShape(Circle())
        }
    }
}
