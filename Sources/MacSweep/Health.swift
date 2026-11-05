import Darwin
import Foundation
import IOBluetooth
import IOKit.ps
import SwiftUI

/// Live system readings for the menu bar panel, refreshed every two seconds while the app runs.
@MainActor
final class HealthMonitor: ObservableObject {
    struct Battery { let percent: Int; let charging: Bool; let charged: Bool; let onAC: Bool; let minutesLeft: Int? }

    @Published var diskFree: Int64 = 0
    @Published var diskTotal: Int64 = 0
    @Published var memoryPressure = 0
    @Published var cpuLoad = 0.0
    @Published var thermal = ProcessInfo.ThermalState.nominal
    @Published var battery: Battery?
    @Published var upPerSecond = 0.0
    @Published var downPerSecond = 0.0
    @Published var devices: [String] = []

    private var timer: Timer?
    private var lastCPU: host_cpu_load_info?
    private var lastNet: (sent: UInt64, received: UInt64, at: Date)?
    private var ticks = 0
    private let readsBluetooth: Bool

    /// Pass `readsBluetooth: false` when started from a terminal: macOS checks the Bluetooth permission
    /// against the launching process (the shell), which has no usage description, and terminates.
    init(readsBluetooth: Bool = true) {
        self.readsBluetooth = readsBluetooth
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    enum Status: String { case excellent = "Excellent", good = "Good", attention = "Needs Attention" }

    var status: Status {
        let freeRatio = diskTotal > 0 ? Double(diskFree) / Double(diskTotal) : 1
        if freeRatio < 0.05 || memoryPressure >= 85 || thermal == .serious || thermal == .critical { return .attention }
        if freeRatio < 0.15 || memoryPressure >= 65 || thermal == .fair { return .good }
        return .excellent
    }

    func refresh() {
        let v = try? Scanner.home.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
        diskTotal = Int64(v?.volumeTotalCapacity ?? 0)
        diskFree = v?.volumeAvailableCapacityForImportantUsage ?? 0
        memoryPressure = Self.memoryPressure()
        thermal = ProcessInfo.processInfo.thermalState
        battery = Self.battery()

        if let now = Self.cpuTicks() {
            if let last = lastCPU {
                func delta(_ a: UInt32, _ b: UInt32) -> Double { Double(a &- b) }
                let user = delta(now.cpu_ticks.0, last.cpu_ticks.0), system = delta(now.cpu_ticks.1, last.cpu_ticks.1)
                let idle = delta(now.cpu_ticks.2, last.cpu_ticks.2), nice = delta(now.cpu_ticks.3, last.cpu_ticks.3)
                let total = user + system + idle + nice
                cpuLoad = total > 0 ? (user + system + nice) / total : 0
            }
            lastCPU = now
        }

        let net = Self.networkBytes()
        if let last = lastNet {
            let seconds = max(Date().timeIntervalSince(last.at), 0.1)
            // The interface counters are 32-bit and wrap; a wrapped sample is dropped rather than shown as a spike.
            upPerSecond = net.sent >= last.sent ? Double(net.sent - last.sent) / seconds : upPerSecond
            downPerSecond = net.received >= last.received ? Double(net.received - last.received) / seconds : downPerSecond
        }
        lastNet = (net.sent, net.received, Date())

        // Bluetooth changes slowly; poll it every 10 seconds.
        if readsBluetooth && ticks % 5 == 0 { devices = Self.connectedBluetoothDevices() }
        ticks += 1
    }

    /// Same figure as Activity Monitor's memory pressure: 100 minus the kernel's free-memory level.
    static func memoryPressure() -> Int {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_level", &level, &size, nil, 0) == 0 else { return 0 }
        return max(0, min(100, 100 - Int(level)))
    }

    static func cpuTicks() -> host_cpu_load_info? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info : nil
    }

    /// Bytes through physical network interfaces (`en*`), so VPN tunnels are not counted twice.
    static func networkBytes() -> (sent: UInt64, received: UInt64) {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return (0, 0) }
        defer { freeifaddrs(head) }
        var sent: UInt64 = 0, received: UInt64 = 0
        var cursor = head
        while let a = cursor {
            if String(cString: a.pointee.ifa_name).hasPrefix("en"),
               a.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_LINK),
               let data = a.pointee.ifa_data?.assumingMemoryBound(to: if_data.self) {
                sent += UInt64(data.pointee.ifi_obytes)
                received += UInt64(data.pointee.ifi_ibytes)
            }
            cursor = a.pointee.ifa_next
        }
        return (sent, received)
    }

    static func battery() -> Battery? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            let minutes = d[kIOPSTimeToEmptyKey] as? Int
            return Battery(percent: current * 100 / max, charging: d[kIOPSIsChargingKey] as? Bool ?? false,
                           charged: d[kIOPSIsChargedKey] as? Bool ?? false,
                           onAC: d[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue,
                           minutesLeft: (minutes ?? -1) > 0 ? minutes : nil)
        }
        return nil
    }

    static func connectedBluetoothDevices() -> [String] {
        // Reading Bluetooth without the usage description in Info.plist terminates the process (e.g. under `swift run`).
        guard Bundle.main.object(forInfoDictionaryKey: "NSBluetoothAlwaysUsageDescription") != nil,
              let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else { return [] }
        return paired.filter { $0.isConnected() }.compactMap(\.name).sorted()
    }
}

// MARK: - Menu bar panel

struct HealthPanel: View {
    @ObservedObject var health: HealthMonitor
    @ObservedObject var store: Store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("Mac Health:")
                        Text(health.status.rawValue).foregroundStyle(statusColor)
                    }
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    Text(Host.current().localizedName ?? "This Mac").font(.callout).opacity(0.7)
                }
                Spacer()
                Image(systemName: "laptopcomputer").font(.system(size: 38)).foregroundStyle(.cyan)
            }

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                HealthTile(icon: "internaldrive", title: "Macintosh HD",
                           value: "Available: \(bytes(health.diskFree))",
                           warn: health.diskTotal > 0 && Double(health.diskFree) / Double(health.diskTotal) < 0.15,
                           action: ("Free Up", { show(.smartCare) }))
                HealthTile(icon: "memorychip", title: "Memory", value: "Pressure: \(health.memoryPressure)%",
                           warn: health.memoryPressure >= 65, action: ("Free Up", { show(.maintenance) }))
                HealthTile(icon: batteryIcon, title: "Battery", value: batteryText, trailing: health.battery.map { "\($0.percent)%" })
                HealthTile(icon: "cpu", title: "CPU", value: "Load: \(Int(health.cpuLoad * 100))%", trailing: thermalText,
                           warn: health.thermal == .serious || health.thermal == .critical)
                HealthTile(icon: "wifi", title: "Network",
                           value: "↑ \(rate(health.upPerSecond))   ↓ \(rate(health.downPerSecond))")
                HealthTile(icon: "dot.radiowaves.left.and.right", title: "Bluetooth",
                           value: health.devices.isEmpty ? "No devices connected" : health.devices.joined(separator: ", "))
            }

            Divider().overlay(.white.opacity(0.2))
            HStack {
                Button("Open MacSweep") { show(store.page) }
                    .buttonStyle(.plain).font(.callout.weight(.semibold))
                Spacer()
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                    .buttonStyle(.plain).help("Quit MacSweep")
            }
        }
        .padding(16)
        .frame(width: 380)
        .foregroundStyle(.white)
        .background(LinearGradient(colors: Page.smartCare.colors, startPoint: .topLeading, endPoint: .bottomTrailing))
        .environment(\.colorScheme, .dark)
    }

    private func show(_ page: Page) {
        store.page = page
        openWindow(id: "main")
        NSApp.activate()
    }

    private var statusColor: Color {
        switch health.status {
        case .excellent: .cyan
        case .good: .yellow
        case .attention: .orange
        }
    }

    private var batteryIcon: String {
        guard let b = health.battery else { return "powerplug" }
        if b.charging || b.onAC { return "battery.100.bolt" }
        return b.percent > 60 ? "battery.75" : b.percent > 25 ? "battery.50" : "battery.25"
    }

    private var batteryText: String {
        guard let b = health.battery else { return "No battery" }
        if b.charged || (b.onAC && b.percent >= 100) { return "Fully charged" }
        if b.charging { return "Charging" }
        if let m = b.minutesLeft { return "\(m / 60)h \(m % 60)m left" }
        return b.onAC ? "On power adapter" : "On battery"
    }

    private var thermalText: String {
        switch health.thermal {
        case .nominal: "Cool"
        case .fair: "Warm"
        case .serious: "Hot"
        case .critical: "Very hot"
        @unknown default: ""
        }
    }

    private func rate(_ perSecond: Double) -> String { "\(bytes(Int64(perSecond)))/s" }
}

struct HealthTile: View {
    let icon: String
    let title: String
    let value: String
    var trailing: String? = nil
    var warn = false
    var action: (String, () -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: icon).font(.system(size: 16)).frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(value).font(.caption).foregroundStyle(warn ? .orange : .white.opacity(0.75)).lineLimit(2)
                }
                Spacer(minLength: 0)
                if let trailing { Text(trailing).font(.caption.weight(.semibold)).foregroundStyle(warn ? .orange : .white) }
            }
            if let action {
                HStack {
                    Spacer()
                    Button(action.0, action: action.1).buttonStyle(.plain)
                        .font(.caption.weight(.bold)).foregroundStyle(.cyan)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.09)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
    }
}
