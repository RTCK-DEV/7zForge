import Cocoa
import FinderSync

/// Finder context-menu extension for 7zForge.
/// Adds "7zForge で圧縮/で解凍" to the top-level contextual menu (Google Drive style).
/// Actions are forwarded to the host app via the z7forge:// URL scheme.
final class FinderSync: FIFinderSync {

    override init() {
        super.init()
        // Observe everywhere so the menu is available on any file/folder.
        FIFinderSyncController.default().directoryURLs =
            [URL(fileURLWithPath: "/"), FileManager.default.homeDirectoryForCurrentUser]
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu {
        let menu = NSMenu(title: "")
        switch menuKind {
        case .contextualMenuForItems, .contextualMenuForContainer,
             .contextualMenuForSidebar, .toolbarItemMenu:
            let comp = NSMenuItem(title: "7zForge で圧縮",
                                  action: #selector(compressAction(_:)), keyEquivalent: "")
            comp.target = self
            comp.image = menuIcon()
            menu.addItem(comp)
            let ext = NSMenuItem(title: "7zForge で解凍",
                                 action: #selector(extractAction(_:)), keyEquivalent: "")
            ext.target = self
            ext.image = menuIcon()
            menu.addItem(ext)
        default:
            break
        }
        return menu
    }

    private func menuIcon() -> NSImage? {
        guard let plugIns = Bundle.main.builtInPlugInsURL else { return nil }
        let appURL = plugIns.deletingLastPathComponent().deletingLastPathComponent()
        let img = NSWorkspace.shared.icon(forFile: appURL.path)
        img.size = NSSize(width: 18, height: 18)
        return img
    }

    @objc func compressAction(_ sender: AnyObject?) { openHost("compress") }
    @objc func extractAction(_ sender: AnyObject?) { openHost("extract") }

    private func openHost(_ mode: String) {
        let urls = FIFinderSyncController.default().selectedItemURLs() ?? []
        var comps = URLComponents()
        comps.scheme = "z7forge"
        comps.host = mode
        comps.queryItems = urls.map { URLQueryItem(name: "file", value: $0.path) }
        if let u = comps.url {
            NSWorkspace.shared.open(u)
        }
    }
}
