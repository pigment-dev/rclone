import AppKit
import CoreWLAN
import Foundation
import IOKit.ps
import Network
import Observation
import RCloneKit

/// Relays platform signals the daemon can't read itself (docs/PROTOCOL.md `system.state`):
/// network path (interface, expensive, constrained, VPN), Wi-Fi SSID, battery / Low Power Mode, free disk, sleep.
/// Event-driven; the only timer is a 10-minute free-disk refresh.
@MainActor
@Observable
final class SystemMonitor {
    private(set) var state = SystemState()

    @ObservationIgnored private let client: DaemonClient
    @ObservationIgnored private let pathMonitor = NWPathMonitor()
    @ObservationIgnored private var lastPushed: SystemState?
    @ObservationIgnored private var pushTask: Task<Void, Never>?
    @ObservationIgnored private var diskTimer: Timer?
    @ObservationIgnored private var powerSource: CFRunLoopSource?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var autoPaused = false

    init(client: DaemonClient) { self.client = client }

    func start() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let net = Self.network(from: path)
            Task { @MainActor in
                guard let self else { return }
                self.state.network = net
                self.state.network.ssid = net.interface == .wifi ? Self.currentSSID() : nil
                self.schedulePush()
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "com.pigmentdev.rclone.path"))

        refreshPower()
        refreshDisk()

        let ctx = Unmanaged.passUnretained(self).toOpaque()
        if let src = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            let me = Unmanaged<SystemMonitor>.fromOpaque(ctx).takeUnretainedValue()
            MainActor.assumeIsolated { me.refreshPower(); me.schedulePush() }
        }, ctx)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
            powerSource = src
        }

        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPower(); self?.applyLowPowerPolicy(); self?.schedulePush() }
        })
        let ws = NSWorkspace.shared.notificationCenter
        observers.append(ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.state.sleeping = true; self?.pushNow() }
        })
        observers.append(ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.state.sleeping = false
                self?.refreshDisk(); self?.refreshPower()
                self?.state.network.ssid = self?.state.network.interface == .wifi ? Self.currentSSID() : nil
                self?.pushNow()
            }
        })
        let t = Timer(timeInterval: 600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshDisk(); self?.schedulePush() }
        }
        t.tolerance = 60
        RunLoop.main.add(t, forMode: .common)
        diskTimer = t
    }

    /// Re-read SSID (e.g. after Location permission is granted).
    func refreshSSID() {
        state.network.ssid = state.network.interface == .wifi ? Self.currentSSID() : nil
        schedulePush()
    }

    // MARK: Push

    private func schedulePush() {
        pushTask?.cancel()
        pushTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            await push(force: false)
        }
    }

    /// Push immediately (on connect and before sleep).
    func pushNow() {
        pushTask?.cancel()
        Task { @MainActor in await push(force: true) }
    }

    private func push(force: Bool) async {
        let s = state
        guard force || s != lastPushed else { return }
        do {
            try await client.send("system.state", s, timeout: 10)
            lastPushed = s
        } catch {
            // Not connected yet: the connect handler calls pushNow().
        }
    }

    // MARK: Readers

    nonisolated static func network(from path: NWPath) -> SystemState.Network {
        let iface: SystemState.Network.Interface
        if path.status != .satisfied { iface = .none }
        else if path.usesInterfaceType(.wifi) { iface = .wifi }
        else if path.usesInterfaceType(.wiredEthernet) { iface = .ethernet }
        else if path.usesInterfaceType(.cellular) { iface = .cellular }
        else { iface = .other }
        let vpn = path.availableInterfaces.contains { i in ["utun", "ipsec", "ppp", "tap", "tun"].contains { i.name.hasPrefix($0) } }
        return SystemState.Network(status: path.status == .satisfied ? .satisfied : .unsatisfied, interface: iface,
                                   expensive: path.isExpensive, constrained: path.isConstrained, ssid: nil, vpn: vpn)
    }

    /// Needs Location authorization on macOS 14+, otherwise returns nil.
    nonisolated static func currentSSID() -> String? {
        CWWiFiClient.shared().interface()?.ssid()
    }

    private func refreshPower() {
        var onBattery = false
        var percent: Int?
        if let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] {
            for ps in list {
                guard let d = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any] else { continue }
                if (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType {
                    onBattery = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSBatteryPowerValue
                    if let cur = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 {
                        percent = Int((Double(cur) / Double(max) * 100).rounded())
                    }
                }
            }
        }
        state.power = SystemState.Power(onBattery: onBattery, batteryPercent: percent, lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled)
    }

    private func refreshDisk() {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        if let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage {
            state.disk.freeBytes = v
        }
    }

    /// Global "pause in Low Power Mode" preference: pauses all jobs while LPM is on and resumes afterwards
    /// (only if we were the ones who paused).
    private func applyLowPowerPolicy() {
        let env = AppEnvironment.shared
        guard env.prefs.pauseOnLowPower else { return }
        if state.power.lowPowerMode, !env.model.allPaused {
            autoPaused = true
            Task { await env.model.pauseAll(.untilResumed) }
        } else if !state.power.lowPowerMode, autoPaused {
            autoPaused = false
            Task { await env.model.resumeAll() }
        }
    }
}
