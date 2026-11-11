import AppKit
import SwiftUI

// MARK: - Space Map

/// Browse any folder by size, largest first, drilling into subfolders.
@MainActor
final class SpaceMapModel: ObservableObject {
    struct Entry: Identifiable {
        var id: URL { url }
        let url: URL
        let size: Int64
        let isFolder: Bool
    }

    @Published var path: [URL] = [Scanner.home]
    @Published var entries: [Entry] = []
    @Published var loading = false
    @Published var started = false
    private var cache: [URL: [Entry]] = [:]
    private var generation = 0

    var current: URL { path.last! }
    var total: Int64 { entries.reduce(0) { $0 + $1.size } }

    func load() {
        started = true
        generation += 1
        let gen = generation
        if let cached = cache[current] { entries = cached; loading = false; return }
        let dir = current
        entries = []
        loading = true
        Task {
            // Sized one child at a time so the list fills in while a big folder is still being measured.
            for child in Scanner.children(dir) {
                let entry = await Task.detached(priority: .userInitiated) { () -> Entry in
                    let v = try? child.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
                    return Entry(url: child, size: Scanner.size(of: child),
                                 isFolder: v?.isDirectory == true && v?.isPackage != true)
                }.value
                guard gen == generation else { return }
                if entry.size > 0 { entries.append(entry); entries.sort { $0.size > $1.size } }
            }
            guard gen == generation else { return }
            cache[dir] = entries
            loading = false
        }
    }

    func open(_ entry: Entry) {
        guard entry.isFolder else { return }
        path.append(entry.url)
        load()
    }

    func goBack(to index: Int) {
        path = Array(path.prefix(index + 1))
        load()
    }

    func trash(_ entry: Entry) {
        guard (try? FileManager.default.trashItem(at: entry.url, resultingItemURL: nil)) != nil else { return }
        // Every folder above the removed item now has a stale size.
        cache = cache.filter { !entry.url.path.hasPrefix($0.key.path) }
        entries.removeAll { $0.url == entry.url }
    }
}

struct SpaceMapView: View {
    @ObservedObject var model: SpaceMapModel
    @State private var pendingTrash: SpaceMapModel.Entry?

    private static let palette: [Color] = [.cyan, .pink, .orange, .yellow, .mint, .purple, .blue, .green]

    var body: some View {
        if !model.started {
            IdleState(symbol: "chart.pie", title: "Space Map",
                      subtitle: "See what takes up space in your home folder, largest first, and open any folder to look deeper.",
                      showFDA: false) { model.load() }
        } else {
            VStack(alignment: .leading, spacing: 16) {
                breadcrumbs
                HStack(alignment: .firstTextBaseline) {
                    Text(bytes(model.total)).font(.system(size: 30, weight: .bold, design: .rounded)).monospacedDigit()
                    Text(model.loading ? "measuring…" : "in \(model.entries.count) items").opacity(0.7)
                    if model.loading { ProgressView().controlSize(.small) }
                }
                strip
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(Array(model.entries.enumerated()), id: \.element.id) { index, entry in
                            row(entry, color: Self.palette[index % Self.palette.count])
                        }
                    }
                }
                .scrollIndicators(.never)
            }
            .padding(.horizontal, 32).padding(.top, 44).padding(.bottom, 20)
            .confirmationDialog("Move \(pendingTrash?.url.lastPathComponent ?? "") to the Trash?",
                                isPresented: Binding(get: { pendingTrash != nil }, set: { if !$0 { pendingTrash = nil } })) {
                Button("Move to Trash", role: .destructive) { if let e = pendingTrash { model.trash(e) } }
            }
        }
    }

    private var breadcrumbs: some View {
        HStack(spacing: 4) {
            ForEach(Array(model.path.enumerated()), id: \.offset) { index, url in
                if index > 0 { Image(systemName: "chevron.right").font(.caption).opacity(0.5) }
                Button(index == 0 ? "Home" : url.lastPathComponent) { model.goBack(to: index) }
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: index == model.path.count - 1 ? .bold : .regular))
            }
        }
    }

    /// One proportional bar for the whole folder, coloured by item.
    private var strip: some View {
        GeometryReader { geo in
            HStack(spacing: 2) {
                ForEach(Array(model.entries.prefix(12).enumerated()), id: \.element.id) { index, entry in
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Self.palette[index % Self.palette.count].opacity(0.85))
                        .frame(width: max(2, geo.size.width * CGFloat(entry.size) / CGFloat(max(model.total, 1)) - 2))
                        .help("\(entry.url.lastPathComponent) · \(bytes(entry.size))")
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: 22)
        .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.08)))
    }

    private func row(_ entry: SpaceMapModel.Entry, color: Color) -> some View {
        Card {
            HStack(spacing: 12) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: entry.url.path)).resizable().frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.url.lastPathComponent).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    GeometryReader { geo in
                        Capsule().fill(color.opacity(0.85))
                            .frame(width: max(3, geo.size.width * CGFloat(entry.size) / CGFloat(max(model.total, 1))))
                    }
                    .frame(height: 5)
                }
                Text(bytes(entry.size)).font(.system(size: 13, weight: .semibold).monospacedDigit()).frame(width: 80, alignment: .trailing)
                Button { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) } label: { Image(systemName: "magnifyingglass") }
                    .buttonStyle(.plain).help("Show in Finder")
                Button { pendingTrash = entry } label: { Image(systemName: "trash") }
                    .buttonStyle(.plain).help("Move to Trash")
                Image(systemName: "chevron.right").opacity(entry.isFolder ? 0.6 : 0)
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .contentShape(Rectangle())
            .onTapGesture { model.open(entry) }
        }
    }
}

// MARK: - Maintenance

struct MaintenanceTask: Identifiable {
    let id: String
    let title: String
    let detail: String
    let icon: String
    let command: String
    let needsAdmin: Bool
}

enum Maintenance {
    static let tasks: [MaintenanceTask] = [
        .init(id: "purge", title: "Free Up Memory", detail: "Clears inactive memory so open apps get more room. Takes a few seconds.",
              icon: "memorychip", command: "/usr/sbin/purge", needsAdmin: true),
        .init(id: "dns", title: "Flush DNS Cache", detail: "Fixes websites that won't load or resolve to an old address.",
              icon: "network", command: "/usr/bin/dscacheutil -flushcache; /usr/bin/killall -HUP mDNSResponder", needsAdmin: true),
        .init(id: "snapshots", title: "Thin Time Machine Snapshots",
              detail: "Removes local snapshots macOS keeps on this disk, freeing purgeable space. Backups on your Time Machine drive are not touched.",
              icon: "clock.arrow.circlepath", command: "/usr/bin/tmutil thinlocalsnapshots / 999999999999 4", needsAdmin: true),
        .init(id: "spotlight", title: "Reindex Spotlight", detail: "Rebuilds search when results are missing or wrong. Indexing runs in the background for a while.",
              icon: "magnifyingglass", command: "/usr/bin/mdutil -E /", needsAdmin: true),
        .init(id: "launchservices", title: "Rebuild Launch Services",
              detail: "Fixes duplicate or missing apps in the Open With menu and wrong default apps.",
              icon: "arrow.up.forward.app",
              command: "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -r -domain local -domain system -domain user",
              needsAdmin: false),
        .init(id: "fonts", title: "Clear Font Caches", detail: "Fixes garbled or missing fonts. Log out and back in afterwards.",
              icon: "textformat", command: "/usr/bin/atsutil databases -removeUser", needsAdmin: false),
    ]

    /// Admin tasks go through the standard macOS password prompt; nothing is stored.
    static func run(_ task: MaintenanceTask) -> (ok: Bool, message: String) {
        if task.needsAdmin {
            let escaped = task.command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            var error: NSDictionary?
            NSAppleScript(source: "do shell script \"\(escaped)\" with administrator privileges")?.executeAndReturnError(&error)
            if let error {
                let cancelled = (error[NSAppleScript.errorNumber] as? Int) == -128
                return (false, cancelled ? "Cancelled" : (error[NSAppleScript.errorMessage] as? String ?? "Failed"))
            }
            return (true, "Done")
        }
        return Scanner.run("/bin/sh", ["-c", task.command]) != nil ? (true, "Done") : (false, "Failed")
    }
}

struct MaintenanceView: View {
    @ObservedObject var store: Store
    @State private var results: [String: (ok: Bool, message: String)] = [:]
    @State private var running: String?

    var health: HealthMonitor { store.health }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 16) {
                IconTile(symbol: "wrench.and.screwdriver", colors: [.white.opacity(0.4), .white.opacity(0.1)], size: 58)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Maintenance & Health").font(.system(size: 30, weight: .bold, design: .rounded))
                    Text("Live system pressure gauges and quick performance fixes. Free inactive memory with 1 click.").opacity(0.75)
                }
            }
            .padding(.horizontal, 32).padding(.top, 44).padding(.bottom, 20)

            ScrollView {
                VStack(spacing: 16) {
                    LiveHealthCard(health: health)

                    LazyVStack(spacing: 10) {
                        ForEach(Maintenance.tasks) { task in
                            Card {
                                HStack(spacing: 14) {
                                    IconTile(symbol: task.icon, colors: Page.maintenance.colors, size: 40)
                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack(spacing: 6) {
                                            Text(task.title).font(.system(size: 14, weight: .semibold))
                                            if task.needsAdmin { Image(systemName: "lock.fill").font(.caption).opacity(0.6) }
                                        }
                                        Text(task.detail).font(.caption).opacity(0.7).fixedSize(horizontal: false, vertical: true)
                                    }
                                    Spacer()
                                    if let r = results[task.id] {
                                        Label(r.message, systemImage: r.ok ? "checkmark.circle.fill" : "xmark.circle")
                                            .font(.caption).lineLimit(1).frame(maxWidth: 140, alignment: .trailing)
                                    }
                                    if running == task.id {
                                        ProgressView().controlSize(.small)
                                    } else {
                                        PillButton(title: "Run", icon: "play.fill") { run(task) }
                                            .disabled(running != nil)
                                    }
                                }
                                .padding(14)
                            }
                        }
                    }
                }
                .padding(.horizontal, 32).padding(.bottom, 24)
            }
            .scrollIndicators(.never)
        }
    }

    private func run(_ task: MaintenanceTask) {
        running = task.id
        if task.id == "purge" {
            Task {
                await health.purgeInactiveMemory()
                results[task.id] = (true, health.purgeStatusMessage ?? "Done")
                running = nil
            }
            return
        }
        // NSAppleScript must run on the main thread; let the spinner draw first.
        DispatchQueue.main.async {
            results[task.id] = Maintenance.run(task)
            running = nil
        }
    }
}

/// Live RAM and CPU gauges with the 1-click purge. Observes the monitor directly: `Store` does not
/// republish its readings, so inside `MaintenanceView` this card only refreshed when the page changed.
struct LiveHealthCard: View {
    @ObservedObject var health: HealthMonitor

    var body: some View {
        Card {
            HStack(alignment: .center, spacing: 24) {
                AnimatedPressureGauge(
                    title: "RAM",
                    subtitle: "\(health.memoryPressure)% pressure",
                    value: Double(health.memoryPressure) / 100.0,
                    displayPercent: health.memoryPressure,
                    icon: "memorychip",
                    size: 90
                )

                AnimatedPressureGauge(
                    title: "CPU",
                    subtitle: "\(Int(health.cpuLoad * 100))% load",
                    value: health.cpuLoad,
                    displayPercent: Int(health.cpuLoad * 100),
                    icon: "cpu",
                    size: 90
                )

                VStack(alignment: .leading, spacing: 6) {
                    Text("Real-Time Memory Pressure")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                    Text("Total Physical RAM: \(bytes(Int64(health.totalMemory)))")
                        .font(.caption.weight(.semibold)).opacity(0.85)

                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Active: \(bytes(Int64(health.activeMemory)))")
                                .font(.caption2).opacity(0.75)
                            Text("Inactive: \(bytes(Int64(health.inactiveMemory)))")
                                .font(.caption2.weight(.bold)).foregroundStyle(.yellow)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Wired: \(bytes(Int64(health.detailedMemory.wired)))")
                                .font(.caption2).opacity(0.75)
                            Text("Compressed: \(bytes(Int64(health.detailedMemory.compressed)))")
                                .font(.caption2).opacity(0.75)
                        }
                    }

                    PurgeMemoryButton(health: health)
                        .padding(.top, 4)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(16)
        }
    }
}
