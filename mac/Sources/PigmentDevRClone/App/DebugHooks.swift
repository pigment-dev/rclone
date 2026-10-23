import AppKit
import RCloneKit
import SwiftUI

/// Developer/screenshot hooks driven by environment variables (no effect in normal use):
///  PDRCLONE_SHOW=dashboard|jobs|job:<id>|accounts|actions|logs|settings|wizard|menu
///  PDRCLONE_DUMP_ICONS=<dir>   writes the menu bar icon states as PNGs and continues.
@MainActor
enum DebugHooks {
    private static var menuWindow: NSWindow?

    static func apply(_ env: AppEnvironment) {
        let e = ProcessInfo.processInfo.environment
        if let dir = e["PDRCLONE_DUMP_ICONS"] { dumpIcons(to: dir) }
        guard let show = e["PDRCLONE_SHOW"] else { return }
        let r = env.router
        switch show {
        case "jobs": r.selection = .jobs
        case "accounts": r.selection = .accounts
        case "actions": r.selection = .actions
        case "logs": r.selection = .logs
        case "settings": r.selection = .settings
        case "wizard": DispatchQueue.main.asyncAfter(deadline: .now() + 1) { r.wizardFirstRun = true; r.showWizard = true }
        case "menu": DispatchQueue.main.asyncAfter(deadline: .now() + 1) { showMenuWindow(env) }
        default:
            if show.hasPrefix("job:") { r.selection = .jobs; r.selectedJobID = String(show.dropFirst(4)) }
        }
    }

    /// The popover content in a plain window, so it can be captured with `screencapture -l`.
    private static func showMenuWindow(_ env: AppEnvironment) {
        let root = MenuBarView().environment(env.model).environment(env.prefs).environment(env.router)
        let host = NSHostingView(rootView: root)
        let w = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 380, height: 560), styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.title = "Menu preview"
        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.state = .active
        host.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(host)
        NSLayoutConstraint.activate([host.leadingAnchor.constraint(equalTo: effect.leadingAnchor), host.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
                                     host.topAnchor.constraint(equalTo: effect.topAnchor), host.bottomAnchor.constraint(equalTo: effect.bottomAnchor)])
        w.contentView = effect
        w.setContentSize(host.fittingSize)
        w.orderFront(nil)
        menuWindow = w
    }

    private static func dumpIcons(to dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let states: [(String, MenuIconState, String?)] = [
            ("idle", MenuIconState(), nil),
            ("syncing-0", MenuIconState(running: true, percent: 5), nil),
            ("syncing-62", MenuIconState(running: true, percent: 62, speed: 3_100_000), "62%"),
            ("attention", MenuIconState(attention: true), nil),
            ("paused", MenuIconState(paused: true), nil),
            ("offline", MenuIconState(offline: true), nil),
        ]
        for (name, s, text) in states {
            for (suffix, dark) in [("light", false), ("dark", true)] {
                let img = MenuIconRenderer.image(state: s, rotation: s.running ? .pi / 6 : 0, text: text)
                let scale: CGFloat = 8
                let size = NSSize(width: img.size.width * scale + 16, height: img.size.height * scale + 16)
                let out = NSImage(size: size, flipped: false) { rect in
                    (dark ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill()
                    rect.fill()
                    let tinted = NSImage(size: img.size, flipped: false) { r in
                        img.draw(in: r)
                        (dark ? NSColor.white : NSColor.black).set()
                        r.fill(using: .sourceAtop)
                        return true
                    }
                    tinted.draw(in: NSRect(x: 8, y: 8, width: img.size.width * scale, height: img.size.height * scale))
                    return true
                }
                if let tiff = out.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("icon-\(name)-\(suffix).png"))
                }
            }
        }
    }
}
