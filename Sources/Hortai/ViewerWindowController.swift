import AppKit
import SwiftUI

@MainActor
final class ViewerWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    let model = ViewerModel()
    var onClose: (() -> Void)?

    init(url: URL?) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Hortai"
        window.minSize = NSSize(width: 520, height: 380)
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        super.init(window: window)

        window.delegate = self
        window.contentView = NSHostingView(rootView: ViewerView(model: model, zoom: model.zoom))
        model.window = window
        if !window.setFrameUsingName("HortaiViewer") { window.center() }
        window.setFrameAutosaveName("HortaiViewer")
        if let url { model.open(url) }
    }

    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) {
        infoPanel?.close()
        onClose?()
    }

    // Plain keys the Windows viewer answered to; menu shortcuts handle the rest.
    func handleKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard modifiers.isEmpty else { return false }
        if event.keyCode == 53, let window {
            // Esc leaves full screen first, then closes the window.
            if window.styleMask.contains(.fullScreen) {
                window.toggleFullScreen(nil)
            } else {
                window.performClose(nil)
            }
            return true
        }
        guard model.currentURL != nil else { return false }
        switch event.keyCode {
        case 123: model.step(-1)
        case 124: model.step(1)
        case 115: model.showFirst()
        case 119: model.showLast()
        case 51, 117: model.confirmTrash()
        default: return false
        }
        return true
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(openWith(_:)):
            return true
        case #selector(showNext(_:)), #selector(showPrevious(_:)), #selector(showInFinder(_:)), #selector(moveToTrash(_:)),
             #selector(showInfo(_:)), #selector(copyPath(_:)):
            return model.currentURL != nil
        default:
            return model.image != nil
        }
    }

    @objc func showNext(_ sender: Any?) { model.step(1) }
    @objc func showPrevious(_ sender: Any?) { model.step(-1) }
    @objc func rotateLeft(_ sender: Any?) { model.rotate(clockwise: false) }
    @objc func rotateRight(_ sender: Any?) { model.rotate(clockwise: true) }
    @objc func moveToTrash(_ sender: Any?) { model.confirmTrash() }
    @objc func startSlideshow(_ sender: Any?) { model.startSlideshow() }
    @objc func zoomIn(_ sender: Any?) { model.zoom.zoom(by: 1.25) }
    @objc func zoomOut(_ sender: Any?) { model.zoom.zoom(by: 0.8) }
    @objc func actualSize(_ sender: Any?) { model.zoom.actualSize() }
    @objc func fitToWindow(_ sender: Any?) { model.zoom.fit() }
    @objc func showInFinder(_ sender: Any?) { model.showInFinder() }
    @objc func copy(_ sender: Any?) { model.copyToPasteboard() }
    @objc func printPhoto(_ sender: Any?) { model.printPhoto() }
    @objc func setAsWallpaper(_ sender: Any?) { model.setAsWallpaper() }
    @objc func openWith(_ sender: NSMenuItem) {
        if let app = sender.representedObject as? URL { model.open(with: app) }
    }

    func contextMenu() -> NSMenu? {
        guard let url = model.currentURL else { return nil }
        let openWith = NSMenuItem("Open With", nil, symbol: "arrow.up.forward.app")
        let apps = NSMenu()
        let defaultApp = NSWorkspace.shared.urlForApplication(toOpen: url)
        for app in NSWorkspace.shared.urlsForApplications(toOpen: url) where app != Bundle.main.bundleURL {
            var name = FileManager.default.displayName(atPath: app.path)
            if name.hasSuffix(".app") { name.removeLast(4) }
            if app == defaultApp { name += " " + L("(default)") }
            let item = NSMenuItem(title: name, action: #selector(openWith(_:)), keyEquivalent: "")
            item.representedObject = app
            let icon = NSWorkspace.shared.icon(forFile: app.path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            apps.addItem(item)
        }
        openWith.submenu = apps

        let menu = NSMenu()
        let items: [NSMenuItem] = [
            openWith,
            NSMenuItem("Show in Finder", #selector(showInFinder(_:)), symbol: "finder", modifiers: []),
            NSMenuItem("Get Info", #selector(showInfo(_:)), symbol: "info.circle", modifiers: []),
            .separator(),
            NSMenuItem("Copy", #selector(copy(_:)), symbol: "doc.on.doc", modifiers: []),
            NSMenuItem("Copy Path", #selector(copyPath(_:)), symbol: "document.on.clipboard", modifiers: []).alternate(),
            NSMenuItem("Rotate Left", #selector(rotateLeft(_:)), symbol: "rotate.left", modifiers: []),
            NSMenuItem("Rotate Right", #selector(rotateRight(_:)), symbol: "rotate.right", modifiers: []),
            .separator(),
            NSMenuItem("Set as Wallpaper", #selector(setAsWallpaper(_:)), symbol: "photo.on.rectangle", modifiers: []),
            NSMenuItem("Print…", #selector(printPhoto(_:)), symbol: "printer", modifiers: []),
            .separator(),
            NSMenuItem("Move to Trash", #selector(moveToTrash(_:)), symbol: "trash", modifiers: []),
        ]
        for item in items {
            if item.action != nil { item.target = self }
            menu.addItem(item)
        }
        return menu
    }

    // MARK: Info panel

    private var infoPanel: InfoPanelController?

    @objc func showInfo(_ sender: Any?) {
        if let infoPanel, infoPanel.isVisible {
            infoPanel.close()
            return
        }
        let panel = infoPanel ?? InfoPanelController(model: model)
        infoPanel = panel
        panel.show()
    }

    @objc func copyPath(_ sender: Any?) { model.copyPath() }
}
