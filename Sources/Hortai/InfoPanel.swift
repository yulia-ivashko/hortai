import AppKit
import Combine
import CoreServices
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

struct InfoSection: Identifiable {
    let id: String
    let rows: [(label: String, value: String)]
    var title: String { L(id) }

    // Labels arrive in English and are translated here.
    init(title: String, rows: [(String, String)]) {
        id = title
        self.rows = rows.map { (L($0.0), $0.1) }
    }
}

// What the right-hand info panel shows; follows the photo as you step.
@MainActor
final class InfoModel: ObservableObject {
    @Published private(set) var sections: [InfoSection] = []
    @Published private(set) var location: (lat: Double, lon: Double)?
    private var watch: AnyCancellable?
    let viewer: ViewerModel

    init(viewer: ViewerModel) {
        self.viewer = viewer
        watch = viewer.$currentURL.sink { [weak self] url in self?.load(url) }
    }

    func confirmStrip() {
        guard let url = viewer.currentURL, let window = viewer.window, window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = String(format: L("Remove all metadata from “%@”?"), url.lastPathComponent)
        alert.informativeText = L("Camera, date taken, location, download source, tags and other details will be deleted for good. File dates will be set to now.")
        alert.addButton(withTitle: L("Remove"))
        alert.addButton(withTitle: L("Cancel"))
        alert.buttons[0].hasDestructiveAction = true
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            Task { @MainActor in
                let done = await Task.detached(priority: .userInitiated) {
                    (try? MetadataStripper.strip(url)) != nil
                }.value
                if done {
                    self.viewer.reloadIfShowing(url)
                    self.load(url)
                } else {
                    let failure = NSAlert()
                    failure.messageText = L("Couldn’t remove the metadata")
                    failure.beginSheetModal(for: window, completionHandler: nil)
                }
            }
        }
    }

    private func load(_ url: URL?) {
        guard let url else {
            sections = []
            location = nil
            return
        }
        Task {
            let result = await Task.detached(priority: .userInitiated) { PhotoInfoReader.read(url) }.value
            guard viewer.currentURL == url else { return }
            sections = result.sections
            location = result.location
        }
    }
}

// Dense like Finder's Get Info and Preview's Inspector, not grouped cards: grey labels on the left, values beside
// them on one line, small section headings. The title sits in the band beside the ⓘ button, the one action at the bottom.
struct InfoView: View {
    @ObservedObject var info: InfoModel

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                Text("Metadata")
                    .font(.headline)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
                    // Clear of the ⓘ button, and centred on it, which sits a little above the band's middle (measured).
                    .padding(.horizontal, 52)
                    .padding(.bottom, 8)
                    .frame(height: geometry.safeAreaInsets.top)
                ScrollView {
                    // One grid for every section, so all values start at the same line.
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 4) {
                        ForEach(Array(info.sections.enumerated()), id: \.element.id) { index, section in
                            GridRow {
                                Text(section.title)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.top, index == 0 ? 0 : 10)
                                    .padding(.bottom, 1)
                                    .gridCellColumns(2)
                            }
                            ForEach(section.rows, id: \.label) { row in
                                GridRow {
                                    Text(row.label)
                                        .foregroundStyle(.secondary)
                                        .gridColumnAlignment(.trailing)
                                    Text(row.value)
                                        .textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .font(.callout)
                            }
                            if section.id == "Location", let location = info.location {
                                GridRow {
                                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                                    Button("Open in Maps") {
                                        NSWorkspace.shared.open(URL(string: "maps://?ll=\(location.lat),\(location.lon)&q=Photo")!)
                                    }
                                    .controlSize(.small)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 4)
                    .padding(.bottom, 16)
                }
                .scrollEdgeEffectHidden(true, for: .top)
                // Rows fade out before the button instead of ending on a hard edge.
                .mask {
                    VStack(spacing: 0) {
                        Color.black
                        LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 20)
                    }
                }
                if !info.sections.isEmpty {
                    Button(role: .destructive) { info.confirmStrip() } label: {
                        Text("Remove All Metadata…").frame(maxWidth: .infinity)
                    }
                    .buttonBorderShape(.capsule)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 14)
                    .padding(.top, 4)
                }
            }
            .ignoresSafeArea(.container, edges: .top)
        }
        .frame(minWidth: 260)
    }
}

enum PhotoInfoReader {
    nonisolated static func read(_ url: URL) -> (sections: [InfoSection], location: (lat: Double, lon: Double)?) {
        var sections: [InfoSection] = []
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey, .contentModificationDateKey, .contentTypeKey])
        // Short dates: the long ones wrapped onto a second line in the panel.
        let dates = Date.FormatStyle(date: .abbreviated, time: .shortened)

        var file: [(String, String)] = []
        // "JPEG", not "JPEG image": every file here is an image.
        if let kind = values?.contentType { file.append(("Kind", (kind.preferredFilenameExtension ?? url.pathExtension).uppercased())) }
        if let size = values?.fileSize { file.append(("Size", ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))) }
        if let created = values?.creationDate { file.append(("Created", created.formatted(dates))) }
        if let modified = values?.contentModificationDate { file.append(("Modified", modified.formatted(dates))) }
        file.append(("Folder", (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath))
        if let tags = (try? url.resourceValues(forKeys: [.tagNamesKey]))?.tagNames, !tags.isEmpty {
            file.append(("Tags", tags.joined(separator: ", ")))
        }
        if let item = MDItemCreateWithURL(nil, url as CFURL) {
            if let opened = MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date {
                file.append(("Last opened", opened.formatted(dates)))
            }
            if let sources = MDItemCopyAttribute(item, kMDItemWhereFroms) as? [String], !sources.isEmpty {
                file.append(("Downloaded from", sources.joined(separator: "\n")))
            }
            if let comment = MDItemCopyAttribute(item, kMDItemFinderComment) as? String, !comment.isEmpty {
                file.append(("Comment", comment))
            }
        }
        sections.append(InfoSection(title: "File", rows: file))

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return (sections, nil)
        }
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any] ?? [:]

        var image: [(String, String)] = []
        if var width = props[kCGImagePropertyPixelWidth] as? Int, var height = props[kCGImagePropertyPixelHeight] as? Int {
            if let orientation = props[kCGImagePropertyOrientation] as? Int, orientation >= 5 { swap(&width, &height) }
            image.append(("Dimensions", "\(width) × \(height)"))
            image.append(("Megapixels", String(format: L("%.1f MP"), Double(width * height) / 1_000_000)))
        }
        if let dpi = props[kCGImagePropertyDPIWidth] as? Double { image.append(("Resolution", "\(Int(dpi.rounded())) dpi")) }
        if let depth = props[kCGImagePropertyDepth] as? Int { image.append(("Color depth", String(format: L("%d-bit"), depth))) }
        if let profile = props[kCGImagePropertyProfileName] as? String { image.append(("Color profile", profile)) }
        if CGImageSourceGetCount(source) > 1 { image.append(("Frames", "\(CGImageSourceGetCount(source))")) }
        if !image.isEmpty { sections.append(InfoSection(title: "Image", rows: image)) }

        var shot: [(String, String)] = []
        if let taken = exif[kCGImagePropertyExifDateTimeOriginal] as? String { shot.append(("Date taken", prettyExifDate(taken))) }
        let camera = [tiff[kCGImagePropertyTIFFMake] as? String, tiff[kCGImagePropertyTIFFModel] as? String]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
        if !camera.isEmpty {
            // "Apple iPhone 15" rather than "Apple Apple iPhone 15".
            let text = camera.count == 2 && camera[1].hasPrefix(camera[0]) ? camera[1] : camera.joined(separator: " ")
            shot.append(("Camera", text))
        }
        if let lens = exif[kCGImagePropertyExifLensModel] as? String { shot.append(("Lens", lens)) }
        if let time = exif[kCGImagePropertyExifExposureTime] as? Double, time > 0 {
            shot.append(("Exposure", time >= 1 ? String(format: L("%g s"), time) : String(format: L("1/%d s"), Int((1 / time).rounded()))))
        }
        if let f = exif[kCGImagePropertyExifFNumber] as? Double { shot.append(("Aperture", String(format: "ƒ/%g", f))) }
        if let iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first { shot.append(("ISO", "\(iso)")) }
        if let focal = exif[kCGImagePropertyExifFocalLength] as? Double {
            var text = String(format: L("%g mm"), focal)
            if let full = exif[kCGImagePropertyExifFocalLenIn35mmFilm] as? Int { text += " " + String(format: L("(%d mm equiv.)"), full) }
            shot.append(("Focal length", text))
        }
        if let flash = exif[kCGImagePropertyExifFlash] as? Int { shot.append(("Flash", flash & 1 == 1 ? L("Fired") : L("Off"))) }
        if let software = tiff[kCGImagePropertyTIFFSoftware] as? String { shot.append(("Software", software)) }
        if !shot.isEmpty { sections.append(InfoSection(title: "Shooting", rows: shot)) }

        var location: (lat: Double, lon: Double)?
        if var lat = gps[kCGImagePropertyGPSLatitude] as? Double, var lon = gps[kCGImagePropertyGPSLongitude] as? Double {
            if (gps[kCGImagePropertyGPSLatitudeRef] as? String) == "S" { lat = -lat }
            if (gps[kCGImagePropertyGPSLongitudeRef] as? String) == "W" { lon = -lon }
            location = (lat, lon)
            var rows = [("Coordinates", String(format: "%.5f, %.5f", lat, lon))]
            if let altitude = gps[kCGImagePropertyGPSAltitude] as? Double { rows.append(("Altitude", String(format: L("%d m"), Int(altitude.rounded())))) }
            sections.append(InfoSection(title: "Location", rows: rows))
        }
        return (sections, location)
    }

    // EXIF writes "2024:07:15 18:42:03".
    private static func prettyExifDate(_ raw: String) -> String {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy:MM:dd HH:mm:ss"
        guard let date = parser.date(from: raw) else { return raw }
        return date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened))
    }
}
