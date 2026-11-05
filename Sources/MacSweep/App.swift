import AppKit
import SwiftUI

@main
struct MacSweepApp: App {
    init() {
        // `MacSweep --scan-report` prints what each scan finds, without opening a window or removing anything.
        if CommandLine.arguments.contains("--scan-report") {
            for area in Section.allCases {
                print("== \(area.title)")
                for g in area.run() {
                    print("  \(g.preselect ? "[x]" : "[ ]") \(g.title): \(g.items.count) item(s), \(bytes(g.size))")
                }
            }
            exit(0)
        }
        // `MacSweep --make-iconset <dir>` writes the app icon images (used by make-app.sh).
        if let i = CommandLine.arguments.firstIndex(of: "--make-iconset"), i + 1 < CommandLine.arguments.count {
            do { try Brand.writeIconset(to: URL(fileURLWithPath: CommandLine.arguments[i + 1])); exit(0) }
            catch { print(error.localizedDescription); exit(1) }
        }
        if CommandLine.arguments.contains("--self-test") {
            exit(MainActor.assumeIsolated { SelfTest.run() } ? 0 : 1)
        }
        // `MacSweep --report [file.md]` writes the full Markdown report (default selection) and exits.
        if let i = CommandLine.arguments.firstIndex(of: "--report") {
            let args = CommandLine.arguments
            let url = i + 1 < args.count ? URL(fileURLWithPath: args[i + 1]) : Report.defaultURL()
            let parts = Section.allCases.map { s -> Report.Part in
                let groups = s.run()
                return Report.Part(section: s, groups: groups, selected: Set(groups.filter(\.preselect).flatMap(\.items).map(\.id)))
            }
            do {
                try Report.markdown(parts).write(to: url, atomically: true, encoding: .utf8)
                print(url.path)
                exit(0)
            } catch {
                print("Could not write \(url.path): \(error.localizedDescription)")
                exit(1)
            }
        }
        // Lets `swift run` show a normal foreground window too.
        NSApplication.shared.setActivationPolicy(.regular)
    }

    @StateObject private var store = Store()
    @StateObject private var health = HealthMonitor()

    var body: some Scene {
        Window("MacSweep", id: "main") {
            ContentView(store: store).frame(minWidth: 1000, minHeight: 660)
        }
        .windowStyle(.hiddenTitleBar)

        // The menu bar panel in a regular window; opened only by the UI tour so it can be captured.
        Window("Mac Health", id: "healthPreview") {
            HealthPanel(health: health, store: store)
        }
        .windowResizability(.contentSize)

        MenuBarExtra {
            HealthPanel(health: health, store: store)
        } label: {
            Image(nsImage: Brand.menuBarIcon)
        }
        .menuBarExtraStyle(.window)
    }
}

func bytes(_ n: Int64) -> String {
    let f = ByteCountFormatter()
    f.countStyle = .file
    f.allowsNonnumericFormatting = false // "0 KB", not "Zero KB"
    return f.string(fromByteCount: n)
}

enum Section: String, CaseIterable, Identifiable {
    case junk, large, duplicates, apps, agents
    var id: String { rawValue }

    var title: String {
        switch self {
        case .junk: "System Junk"
        case .large: "Large Files"
        case .duplicates: "Duplicates"
        case .apps: "Uninstaller"
        case .agents: "Launch Agents"
        }
    }

    var icon: String {
        switch self {
        case .junk: "trash.circle"
        case .large: "externaldrive"
        case .duplicates: "doc.on.doc"
        case .apps: "square.grid.2x2"
        case .agents: "power.circle"
        }
    }

    var subtitle: String {
        switch self {
        case .junk: "Caches, logs, broken preferences and developer data that apps recreate as needed."
        case .large: "Files of 500 MB or more in your home folder (Library excluded)."
        case .duplicates: "Identical copies of files (1 MB or more) in Desktop, Documents, Downloads, Pictures, Movies and Music. The oldest copy is always kept."
        case .apps: "Remove an app with its support files, containers and plug-ins, or clear files left by apps you already deleted."
        case .agents: "Background helpers that start when you log in. Removal takes effect after logout."
        }
    }

    /// Background gradient, light to dark.
    var colors: [Color] {
        switch self {
        case .junk: [Color(red: 0.07, green: 0.62, blue: 0.70), Color(red: 0.06, green: 0.16, blue: 0.45)]
        case .large: [Color(red: 0.95, green: 0.45, blue: 0.25), Color(red: 0.45, green: 0.10, blue: 0.38)]
        case .duplicates: [Color(red: 0.92, green: 0.30, blue: 0.55), Color(red: 0.32, green: 0.08, blue: 0.40)]
        case .apps: [Color(red: 0.42, green: 0.36, blue: 0.95), Color(red: 0.14, green: 0.08, blue: 0.42)]
        case .agents: [Color(red: 0.18, green: 0.72, blue: 0.50), Color(red: 0.04, green: 0.24, blue: 0.32)]
        }
    }

    var needsFullDiskAccess: Bool { self == .junk || self == .apps }

    func run() -> [ItemGroup] {
        switch self {
        case .junk: Scanner.scanJunk()
        case .large: Scanner.scanLargeFiles()
        case .duplicates: Scanner.scanDuplicates()
        case .apps: Scanner.scanApps()
        case .agents: Scanner.scanLaunchAgents()
        }
    }
}

@MainActor
final class SectionModel: ObservableObject {
    let section: Section
    @Published var groups: [ItemGroup] = []
    @Published var selected: Set<UUID> = []
    @Published var scanning = false
    @Published var scanned = false
    @Published var status: String?

    init(_ section: Section) { self.section = section }

    var selectedItems: [CleanItem] { groups.flatMap(\.items).filter { selected.contains($0.id) } }
    var selectedSize: Int64 { selectedItems.reduce(0) { $0 + $1.size } }
    var totalSize: Int64 { groups.reduce(0) { $0 + $1.size } }
    var reportPart: Report.Part { Report.Part(section: section, groups: groups, selected: selected) }

    func scan() {
        scanning = true
        let section = section
        Task {
            let found = await Task.detached(priority: .userInitiated) { section.run() }.value
            groups = found
            selected = Set(found.filter(\.preselect).flatMap(\.items).map(\.id))
            scanning = false
            scanned = true
        }
    }

    func clean() {
        let items = selectedItems
        Task {
            let result = await Task.detached { Scanner.moveToTrash(items) }.value
            var msg = "Moved \(bytes(result.freed)) to the Trash."
            let needsAdmin = result.failures.filter { !$0.url.path.hasPrefix(Scanner.home.path) }.count
            if needsAdmin > 0 { msg += " \(needsAdmin) system item(s) need your password: use Show in Finder." }
            if result.failures.count > needsAdmin { msg += " \(result.failures.count - needsAdmin) item(s) were protected or in use." }
            status = msg
            scan()
        }
    }
}

@MainActor
final class Store: ObservableObject {
    @Published var page: Page = .smartCare
    /// Rail label to show as if hovered; set only by the UI tour.
    @Published var tourLabel: Page?
    let models = Dictionary(uniqueKeysWithValues: Section.allCases.map { ($0, SectionModel($0)) })
    let spaceMap = SpaceMapModel()

    func model(_ section: Section) -> SectionModel { models[section]! }
}
