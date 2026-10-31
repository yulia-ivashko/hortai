import AppKit
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controllers: [ViewerWindowController] = []

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build()
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if let show = SlideshowController.active {
                return show.handle(event) ? nil : event
            }
            guard let controller = NSApp.keyWindow?.windowController as? ViewerWindowController else {
                return event
            }
            return controller.handleKey(event) ? nil : event
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Files opened from Finder arrive before this; show an empty window only on a bare launch.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            if self.controllers.isEmpty { self.openWindow(with: nil) }
        }
        NSApp.activate()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { openWindow(with: url) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { openWindow(with: nil) }
        return true
    }

    func openWindow(with url: URL?) {
        if let url, let empty = controllers.first(where: { $0.model.currentURL == nil }) {
            empty.model.open(url)
            empty.showWindow(nil)
            return
        }
        let controller = ViewerWindowController(url: url)
        controller.onClose = { [weak self, weak controller] in
            self?.controllers.removeAll { $0 === controller }
        }
        controllers.append(controller)
        controller.showWindow(nil)
    }

    @objc func openDocument(_ sender: Any?) {
        if let url = Self.runOpenPanel() { openWindow(with: url) }
    }

    static func runOpenPanel() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }
}
