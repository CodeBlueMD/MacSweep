import Darwin
import Foundation
import IOBluetooth
import IOKit.ps
import SwiftUI

/// Live system readings for the menu bar panel, refreshed every two seconds while the app runs.
@MainActor
final class HealthMonitor: ObservableObject {
    struct Battery { let percent: Int; let charging: Bool; let charged: Bool; let onAC: Bool; let minutesLeft: Int? }

    struct DetailedMemory: Sendable {
        let total: UInt64
        let active: UInt64
        let inactive: UInt64
        let wired: UInt64
        let free: UInt64
        let compressed: UInt64
        let purgeable: UInt64
    }

    @Published var diskFree: Int64 = 0
    @Published var diskTotal: Int64 = 0
    @Published var memoryPressure = 0
    @Published var cpuLoad = 0.0
    @Published var thermal = ProcessInfo.ThermalState.nominal
    @Published var battery: Battery?
    @Published var upPerSecond = 0.0
    @Published var downPerSecond = 0.0
    @Published var devices: [String] = []
    @Published var detailedMemory = DetailedMemory(total: ProcessInfo.processInfo.physicalMemory, active: 0, inactive: 0, wired: 0, free: 0, compressed: 0, purgeable: 0)

    // Visual feedback state for 1-click inactive memory purge
    @Published var isPurgingMemory = false
    @Published var purgeStatusMessage: String? = nil
    @Published var purgeSuccess = false

    var inactiveMemory: UInt64 { detailedMemory.inactive }
    var activeMemory: UInt64 { detailedMemory.active }
    var totalMemory: UInt64 { detailedMemory.total }

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
        detailedMemory = Self.detailedMemory()

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

    /// 1-click inactive RAM purge with instant visual feedback and smooth animated transitions.
    func purgeInactiveMemory() async {
        guard !isPurgingMemory else { return }
        isPurgingMemory = true
        purgeSuccess = false
        purgeStatusMessage = "Purging inactive RAM…"

        let before = Self.detailedMemory()

        await Task.detached(priority: .userInitiated) {
            // Force inactive file-backed pages to be reclaimed by Darwin VM
            let chunkSize = 64 * 1024 * 1024
            let targetBytes = min(before.inactive, 2048 * 1024 * 1024)
            let count = max(1, Int(targetBytes / UInt64(chunkSize)))
            var chunks: [UnsafeMutableRawPointer] = []

            for _ in 0..<count {
                if let ptr = malloc(chunkSize) {
                    memset(ptr, 0x55, chunkSize)
                    chunks.append(ptr)
                }
            }
            for ptr in chunks {
                free(ptr)
            }
            chunks.removeAll()

            // Also trigger system purge if permitted
            _ = Scanner.run("/usr/sbin/purge", [])
        }.value

        // Allow kernel paging to stabilize
        try? await Task.sleep(nanoseconds: 350_000_000)
        refresh()
        let after = Self.detailedMemory()

        let freed = max(0, Int64(before.inactive) - Int64(after.inactive))
        purgeSuccess = true
        // Report what was measured; when nothing moved, say so rather than claim a purge.
        purgeStatusMessage = freed > 10_000_000 ? "Freed \(bytes(freed))" : "Already optimized"
        isPurgingMemory = false

        Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if !self.isPurgingMemory {
                self.purgeStatusMessage = nil
                self.purgeSuccess = false // otherwise the green outline outlives its message
            }
        }
    }

    /// Query Mach kernel host statistics for detailed memory breakdown.
    static func detailedMemory() -> DetailedMemory {
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        var vmStat = vm_statistics64()
        let kerr = withUnsafeMutablePointer(to: &vmStat) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        let total = ProcessInfo.processInfo.physicalMemory
        guard kerr == KERN_SUCCESS else {
            return DetailedMemory(total: total, active: 0, inactive: 0, wired: 0, free: 0, compressed: 0, purgeable: 0)
        }
        let pageSize = UInt64(vm_kernel_page_size)
        return DetailedMemory(
            total: total,
            active: UInt64(vmStat.active_count) * pageSize,
            inactive: UInt64(vmStat.inactive_count) * pageSize,
            wired: UInt64(vmStat.wire_count) * pageSize,
            free: UInt64(vmStat.free_count) * pageSize,
            compressed: UInt64(vmStat.compressor_page_count) * pageSize,
            purgeable: UInt64(vmStat.purgeable_count) * pageSize
        )
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

// MARK: - Animated Gauges & Purge Controls

struct AnimatedPressureGauge: View {
    let title: String
    let subtitle: String
    let value: Double // 0.0 ... 1.0
    let displayPercent: Int
    var icon: String? = nil
    var size: CGFloat = 76
    var showDetail: Bool = true

    private var gaugeColor: Color {
        if value < 0.60 {
            return .cyan
        } else if value < 0.80 {
            return .yellow
        } else {
            return .orange
        }
    }

    private var gradient: AngularGradient {
        AngularGradient(
            stops: [
                .init(color: gaugeColor.opacity(0.35), location: 0.0),
                .init(color: gaugeColor, location: max(0.01, min(1.0, value)))
            ],
            center: .center,
            startAngle: .degrees(-90),
            endAngle: .degrees(270)
        )
    }

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                // Background track
                Circle()
                    .stroke(Color.white.opacity(0.12), lineWidth: size * 0.09)

                // Subtle ambient glow
                Circle()
                    .trim(from: 0, to: max(0.005, min(1.0, value)))
                    .stroke(
                        gaugeColor.opacity(0.4),
                        style: StrokeStyle(lineWidth: size * 0.12, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .blur(radius: 4)

                // Real-time animated value arc
                Circle()
                    .trim(from: 0, to: max(0.005, min(1.0, value)))
                    .stroke(
                        gradient,
                        style: StrokeStyle(lineWidth: size * 0.09, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))

                // Center readout
                VStack(spacing: 1) {
                    if let icon {
                        Image(systemName: icon)
                            .font(.system(size: size * 0.17, weight: .semibold))
                            .foregroundStyle(gaugeColor)
                    }
                    Text("\(displayPercent)%")
                        .font(.system(size: size * 0.22, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.white)
                        .contentTransition(.numericText(value: Double(displayPercent)))
                    Text(title)
                        .font(.system(size: max(8, size * 0.13), weight: .semibold))
                        .foregroundStyle(.white.opacity(0.8))
                }
            }
            .frame(width: size, height: size)
            // One spring for the glow, the arc, its colour and the digits, so they move as a unit
            // (previously only the arc animated and the glow snapped ahead of it).
            .animation(.spring(response: 0.6, dampingFraction: 0.82), value: value)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityValue("\(displayPercent) percent")

            if showDetail {
                // White, not the gauge colour: cyan and yellow captions washed out on the orange and teal pages.
                Text(subtitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
            }
        }
    }
}

struct PurgeMemoryButton: View {
    @ObservedObject var health: HealthMonitor
    @State private var hovering = false
    /// Mint reads clearly on every page gradient; system green sank into the teal and green pages.
    private static let success = Color(red: 0.55, green: 1.0, blue: 0.72)

    var body: some View {
        Button {
            Task { await health.purgeInactiveMemory() }
        } label: {
            HStack(spacing: 6) {
                Group {
                    if health.isPurgingMemory {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text("Purging RAM…")
                        }
                    } else if let msg = health.purgeStatusMessage {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill")
                            Text(msg)
                        }
                        .foregroundStyle(Self.success)
                    } else {
                        HStack(spacing: 6) {
                            Image(systemName: "bolt.fill").foregroundStyle(.yellow)
                            Text("Purge Inactive RAM")
                        }
                    }
                }
                .font(.system(size: 11, weight: .bold))
                .transition(.opacity.combined(with: .scale(scale: 0.92)))
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Capsule().fill(.white.opacity(hovering ? 0.24 : 0.16)))
            .overlay(Capsule().strokeBorder(health.purgeSuccess ? Self.success.opacity(0.7) : Color.white.opacity(0.22), lineWidth: 0.8))
            .contentShape(Capsule())
        }
        .buttonStyle(PressScaleStyle(scale: 0.95))
        .disabled(health.isPurgingMemory)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: health.isPurgingMemory)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: health.purgeStatusMessage)
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

            // Real-Time Animated RAM & CPU Pressure Gauges Card
            HStack(spacing: 14) {
                AnimatedPressureGauge(
                    title: "RAM",
                    subtitle: "\(health.memoryPressure)% pressure",
                    value: Double(health.memoryPressure) / 100.0,
                    displayPercent: health.memoryPressure,
                    icon: "memorychip",
                    size: 74
                )

                AnimatedPressureGauge(
                    title: "CPU",
                    subtitle: thermalText,
                    value: health.cpuLoad,
                    displayPercent: Int(health.cpuLoad * 100),
                    icon: "cpu",
                    size: 74
                )

                VStack(alignment: .leading, spacing: 5) {
                    Text("Memory Management")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Inactive: \(bytes(Int64(health.inactiveMemory)))")
                        .font(.caption).opacity(0.75)
                    Text("Active: \(bytes(Int64(health.activeMemory)))")
                        .font(.caption2).opacity(0.6)

                    PurgeMemoryButton(health: health)
                        .padding(.top, 2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 14).fill(.white.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.12), lineWidth: 0.5))

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                HealthTile(icon: "internaldrive", title: "Macintosh HD",
                           value: "Available: \(bytes(health.diskFree))",
                           warn: health.diskTotal > 0 && Double(health.diskFree) / Double(health.diskTotal) < 0.15,
                           action: ("Free Up", { show(.smartCare) }))
                HealthTile(icon: "memorychip", title: "Memory",
                           value: "Inactive: \(bytes(Int64(health.inactiveMemory)))",
                           warn: health.memoryPressure >= 65,
                           action: (health.isPurgingMemory ? "Purging…" : "Purge RAM", { Task { await health.purgeInactiveMemory() } }))
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
        .frame(width: 390)
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
