import AppKit
import RCloneKit
import SwiftUI

/// The menu bar icon and its popover. An NSPopover (rather than a
/// MenuBarExtra window) so the popover hangs from the icon with an arrow,
/// like the system's own menu bar popovers.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    static let shared = StatusItemController()

    private var item: NSStatusItem?
    private let popover = NSPopover()
    private var env: AppEnvironment { .shared }

    func start() {
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        let host = NSHostingController(rootView: MenuBarView()
            .environment(env.model)
            .environment(env.prefs)
            .environment(env.router)
            .environment(\.layoutDirection, env.prefs.layoutDirection))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        trackVisibility()
        trackIcon()
    }

    /// Shows or hides the icon when the "Show in the menu bar" setting changes.
    private func trackVisibility() {
        withObservationTracking {
            setVisible(env.prefs.showMenuBarIcon)
        } onChange: {
            Task { @MainActor [weak self] in self?.trackVisibility() }
        }
    }

    private func trackIcon() {
        withObservationTracking {
            item?.button?.image = env.icon.image
            item?.button?.setAccessibilityLabel(env.icon.accessibilityLabel)
        } onChange: {
            Task { @MainActor [weak self] in self?.trackIcon() }
        }
    }

    private func setVisible(_ visible: Bool) {
        if visible, item == nil {
            let i = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            i.button?.image = env.icon.image
            i.button?.setAccessibilityLabel(env.icon.accessibilityLabel)
            i.button?.target = self
            i.button?.action = #selector(toggle(_:))
            item = i
        } else if !visible, let i = item {
            close()
            NSStatusBar.system.removeStatusItem(i)
            item = nil
        }
    }

    @objc private func toggle(_ sender: NSStatusBarButton) {
        if popover.isShown {
            close()
            return
        }
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        sender.highlight(true)
    }

    func close() {
        if popover.isShown { popover.performClose(nil) }
    }

    func popoverDidClose(_ notification: Notification) {
        item?.button?.highlight(false)
    }
}
