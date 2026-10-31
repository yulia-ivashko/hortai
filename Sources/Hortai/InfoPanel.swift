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

// The floating "Info" panel of one viewer window; follows the photo as you step.
@MainActor
final class InfoPanelController: ObservableObject {
    @Published private(set) var sections: [InfoSection] = []
    @Published private(set) var location: (lat: Double, lon: Double)?
    private let panel: NSPanel
    private var watch: AnyCancellable?
    private weak var model: ViewerModel?

    init(model: ViewerModel) {
        self.model = model
        panel = EscPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 560),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered, defer: true
        )
        panel.title = L("Info")
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = true
        panel.contentView = NSHostingView(rootView: InfoView(controller: self))
        if let frame = model.window?.frame {
            panel.setFrameTopLeftPoint(NSPoint(x: frame.maxX + 12, y: frame.maxY))
        }
        watch = model.$currentURL.sink { [weak self] url in self?.load(url) }
    }

    var isVisible: Bool { panel.isVisible }
    func show() { panel.orderFront(nil) }
    func close() { panel.close() }

    func confirmStrip() {
        guard let url = model?.currentURL, panel.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = String(format: L("Remove all metadata from “%@”?"), url.lastPathComponent)
        alert.informativeText = L("Camera, date taken, location, download source, tags and other details will be deleted for good. File dates will be set to now.")
        alert.addButton(withTitle: L("Remove"))
        alert.addButton(withTitle: L("Cancel"))
        alert.buttons[0].hasDestructiveAction = true
        alert.beginSheetModal(for: panel) { response in
            guard response == .alertFirstButtonReturn else { return }
            Task { @MainActor in
                let done = await Task.detached(priority: .userInitiated) {
                    (try? MetadataStripper.strip(url)) != nil
                }.value
                if done {
                    self.model?.reloadIfShowing(url)
                    self.load(url)
                } else {
                    let failure = NSAlert()
                    failure.messageText = L("Couldn’t remove the metadata")
                    failure.beginSheetModal(for: self.panel, completionHandler: nil)
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
            sections = result.sections
            location = result.location
        }
    }
}

private final class EscPanel: NSPanel {
    override func cancelOperation(_ sender: Any?) { close() }
}

private struct InfoView: View {
    @ObservedObject var controller: InfoPanelController

    var body: some View {
        Form {
            ForEach(controller.sections) { section in
                Section(section.title) {
                    ForEach(section.rows, id: \.label) { row in
                        LabeledContent(row.label) {
                            Text(row.value).textSelection(.enabled).multilineTextAlignment(.trailing)
                        }
                    }
                    if section.id == "Location", let location = controller.location {
                        Button("Open in Maps") {
                            NSWorkspace.shared.open(URL(string: "maps://?ll=\(location.lat),\(location.lon)&q=Photo")!)
                        }
                    }
                }
            }
            if !controller.sections.isEmpty {
                Section {
                    Button(role: .destructive) { controller.confirmStrip() } label: {
                        Label("Remove All Metadata", systemImage: "eraser")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 300, minHeight: 300)
    }
}

enum PhotoInfoReader {
    nonisolated static func read(_ url: URL) -> (sections: [InfoSection], location: (lat: Double, lon: Double)?) {
        var sections: [InfoSection] = []
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey, .contentModificationDateKey, .contentTypeKey])
        let dates = Date.FormatStyle(date: .long, time: .shortened)

        var file: [(String, String)] = [("Name", url.lastPathComponent)]
        if let type = values?.contentType { file.append(("Kind", type.localizedDescription ?? type.identifier)) }
        if let size = values?.fileSize { file.append(("Size", ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))) }
        if let created = values?.creationDate { file.append(("Created", created.formatted(dates))) }
        if let modified = values?.contentModificationDate { file.append(("Modified", modified.formatted(dates))) }
        file.append(("Folder", url.deletingLastPathComponent().path))
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
        return date.formatted(Date.FormatStyle(date: .long, time: .shortened))
    }
}
