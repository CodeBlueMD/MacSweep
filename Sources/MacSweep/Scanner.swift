import AppKit
import Foundation
import Security

struct CleanItem: Identifiable, Hashable, Sendable {
    let id = UUID()
    let url: URL
    let title: String
    let detail: String
    let size: Int64
    /// Simulator devices are removed through `simctl` so CoreSimulator stays consistent.
    var simulatorUDID: String? = nil
}

struct ItemGroup: Identifiable, Sendable {
    let id: String
    let title: String
    let icon: String
    var iconPath: String? = nil
    var preselect = false
    var items: [CleanItem]
    var size: Int64 { items.reduce(0) { $0 + $1.size } }
}

/// All filesystem scanning and cleanup. Nothing here deletes permanently:
/// cleanup moves items to the Trash so every action can be undone.
enum Scanner {
    static let fm = FileManager.default
    static let home = fm.homeDirectoryForCurrentUser
    static let rootLibrary = URL(fileURLWithPath: "/Library")

    static func lib(_ path: String) -> URL { home.appendingPathComponent("Library/\(path)") }
    static func dev(_ path: String) -> URL { lib("Developer/\(path)") }

    static func tilde(_ url: URL) -> String {
        url.path.replacingOccurrences(of: home.path, with: "~")
    }

    static func children(_ dir: URL) -> [URL] {
        (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
    }

    static func exists(_ url: URL) -> Bool { fm.fileExists(atPath: url.path) }

    static func fileSize(_ url: URL) -> Int64 {
        let v = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
        return Int64(v?.totalFileAllocatedSize ?? v?.fileAllocatedSize ?? 0)
    }

    static func size(of url: URL) -> Int64 {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        guard isDir.boolValue else { return fileSize(url) }
        var total: Int64 = 0
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        if let e = fm.enumerator(at: url, includingPropertiesForKeys: keys, errorHandler: { _, _ in true }) {
            for case let f as URL in e { total += fileSize(f) }
        }
        return total
    }

    static func item(_ url: URL, title: String? = nil) -> CleanItem {
        CleanItem(url: url, title: title ?? url.lastPathComponent, detail: tilde(url.deletingLastPathComponent()), size: size(of: url))
    }

    /// Other apps' sandbox containers are only readable with Full Disk Access; without it
    /// macOS prompts once per app, so container scans are skipped instead.
    static var hasFullDiskAccess: Bool {
        FileHandle(forReadingAtPath: lib("Application Support/com.apple.TCC/TCC.db").path) != nil
    }

    static func group(_ id: String, _ title: String, _ icon: String, preselect: Bool = true, _ items: [CleanItem]) -> ItemGroup? {
        let kept = items.filter { $0.size > 0 }.sorted { $0.size > $1.size }
        return kept.isEmpty ? nil : ItemGroup(id: id, title: title, icon: icon, preselect: preselect, items: kept)
    }

    /// One item per entry inside `dir`.
    static func contents(_ id: String, _ title: String, _ icon: String, _ dir: URL, preselect: Bool = true) -> ItemGroup? {
        group(id, title, icon, preselect: preselect, children(dir).map { item($0) })
    }

    // MARK: System junk

    static func scanJunk() -> [ItemGroup] {
        let fda = hasFullDiskAccess
        let caches = children(lib("Caches")).map { item($0) }
        var groups: [ItemGroup?] = [
            group("caches", "App Caches", "archivebox", caches.filter { !isAppleCache($0.url.lastPathComponent) }),
            // macOS rebuilds these at once, so clearing them frees little and can trigger iCloud re-syncs.
            group("appleCaches", "Apple System Caches", "apple.logo", preselect: false,
                  caches.filter { isAppleCache($0.url.lastPathComponent) }),
            fda ? group("containerCaches", "Sandboxed App Caches", "shippingbox", containerCaches()) : nil,
            group("electron", "Electron & Web App Caches", "globe", electronCaches()),
            contents("logs", "User Logs", "doc.text", lib("Logs")),
            contents("gradle", "Gradle Caches", "cube", home.appendingPathComponent(".gradle/caches")),
            group("brokenPrefs", "Broken Preference Files", "exclamationmark.triangle", brokenPreferences()),
        ]
        groups += xcodeJunk()
        return holdBackRunningApps(groups.compactMap { $0 })
    }

    /// Apple caches that are not named `com.apple.*`.
    static let appleCacheNames: Set<String> = ["CloudKit", "GeoServices", "PassKit", "Animoji", "familycircled", "FamilyCircle",
                                               "PHTPhenotype", "Metadata", "SpeechModels", "SiriTTS", "Maps", "Safari",
                                               "AMPLibraryAgent", "MobileSync", "iCloud", "Photos"]

    static func isAppleCache(_ name: String) -> Bool {
        name.hasPrefix("com.apple.") || name.hasPrefix("PFScene") || appleCacheNames.contains(name)
    }

    struct RunningApp { let name: String; let bundleID: String }

    static func runningApps() -> [RunningApp] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy != .prohibited }
            .compactMap { app in
                guard let id = app.bundleIdentifier, !id.hasPrefix("com.apple.") else { return nil }
                return RunningApp(name: app.localizedName ?? "", bundleID: id)
            }
    }

    /// The running app an item belongs to, judged by the folder directly inside its Library category
    /// (`Caches/com.anthropic.claudefordesktop`, `Application Support/Claude/Cache` and `Developer/Xcode/…` all count).
    static func owner(of url: URL, among apps: [RunningApp]) -> RunningApp? {
        let libraryPath = lib("").path + "/"
        guard url.path.hasPrefix(libraryPath) else { return nil }
        let parts = url.path.dropFirst(libraryPath.count).split(separator: "/")
        guard parts.count >= 2 else { return nil }
        let folder = parts[1].lowercased()
        return apps.first { app in
            let id = app.bundleID.lowercased()
            let name = app.name.lowercased()
            // "Google Chrome" keeps its cache in Caches/Google, so the first word of the name counts too.
            let firstWord = name.split(separator: " ").first.map(String.init) ?? name
            return folder == id || folder.hasPrefix(id + ".")
                || (!name.isEmpty && (folder == name || (firstWord.count > 2 && folder == firstWord)))
        }
    }

    /// Moves items owned by open apps into their own unselected group: clearing a running app's cache
    /// can make it misbehave until it is restarted.
    static func holdBackRunningApps(_ groups: [ItemGroup]) -> [ItemGroup] {
        let apps = runningApps()
        var inUse: [CleanItem] = []
        var kept: [ItemGroup] = []
        for var g in groups {
            guard g.preselect else { kept.append(g); continue }
            g.items = g.items.filter { item in
                guard let app = owner(of: item.url, among: apps) else { return true }
                inUse.append(CleanItem(url: item.url, title: item.title, detail: "\(app.name) is open: quit it first · \(item.detail)",
                                       size: item.size, simulatorUDID: item.simulatorUDID))
                return false
            }
            if !g.items.isEmpty { kept.append(g) }
        }
        if let held = group("inUse", "In Use by Open Apps", "lock.app.dashed", preselect: false, inUse) {
            kept.insert(held, at: 0)
        }
        return kept
    }

    /// `~/Library/Containers/<app>/Data/Library/Caches`, one item per app.
    static func containerCaches() -> [CleanItem] {
        children(lib("Containers")).compactMap { container in
            let caches = container.appendingPathComponent("Data/Library/Caches")
            guard exists(caches) else { return nil }
            return CleanItem(url: caches, title: container.lastPathComponent, detail: tilde(caches), size: size(of: caches))
        }
    }

    /// Chromium-based apps keep their caches in Application Support rather than Caches.
    static func electronCaches() -> [CleanItem] {
        let names = ["Cache", "Code Cache", "GPUCache", "DawnCache", "DawnGraphiteCache", "DawnWebGPUCache",
                     "Service Worker/CacheStorage", "Service Worker/ScriptCache"]
        return children(lib("Application Support")).flatMap { app in
            names.map { app.appendingPathComponent($0) }
                .filter(exists)
                .map { item($0, title: "\(app.lastPathComponent) · \($0.lastPathComponent)") }
        }
    }

    /// Third-party preference plists that no longer parse. Apple's own are left alone.
    static func brokenPreferences() -> [CleanItem] {
        children(lib("Preferences"))
            .filter { $0.pathExtension == "plist" && !$0.lastPathComponent.hasPrefix("com.apple.") }
            .filter { url in
                guard let data = try? Data(contentsOf: url) else { return false }
                return data.isEmpty || (try? PropertyListSerialization.propertyList(from: data, format: nil)) == nil
            }
            .map { item($0) }
    }

    static func xcodeJunk() -> [ItemGroup?] {
        let xcode = dev("Xcode")
        let deviceSupport = ["iOS", "macOS", "watchOS", "tvOS", "visionOS"].flatMap { children(xcode.appendingPathComponent("\($0) DeviceSupport")) }
        let archives = children(xcode.appendingPathComponent("Archives")).flatMap(children).filter { $0.pathExtension == "xcarchive" }
        return [
            contents("derived", "Xcode DerivedData", "hammer", xcode.appendingPathComponent("DerivedData")),
            contents("xcodeDocs", "Xcode Documentation Cache", "book", xcode.appendingPathComponent("DocumentationCache")),
            contents("deviceLogs", "Xcode Device Logs", "doc.text.magnifyingglass", xcode.appendingPathComponent("iOS Device Logs")),
            // Re-downloaded automatically the next time a device of that version is connected.
            group("deviceSupport", "Xcode Device Support", "iphone.and.arrow.forward", preselect: false, deviceSupport.map { item($0) }),
            // Archives hold the symbols needed to read crash reports for shipped builds.
            group("archives", "Xcode Archives", "archivebox.fill", preselect: false, archives.map { item($0) }),
            contents("simcaches", "Simulator Caches", "iphone", dev("CoreSimulator/Caches")),
            group("simulators", "Unavailable Simulators", "iphone.slash", unavailableSimulators()),
        ]
    }

    static func unavailableSimulators() -> [CleanItem] {
        // Only call xcrun when simulators exist, so Macs without Xcode never see an install prompt.
        guard exists(dev("CoreSimulator/Devices")),
              let output = run("/usr/bin/xcrun", ["simctl", "list", "devices", "unavailable", "-j"]),
              let json = try? JSONSerialization.jsonObject(with: output) as? [String: Any],
              let byRuntime = json["devices"] as? [String: [[String: Any]]] else { return [] }
        return byRuntime.flatMap { runtime, devices in
            devices.compactMap { device -> CleanItem? in
                guard let udid = device["udid"] as? String else { return nil }
                let dir = dev("CoreSimulator/Devices/\(udid)")
                let os = runtime.components(separatedBy: "SimRuntime.").last ?? runtime
                return CleanItem(url: dir, title: device["name"] as? String ?? udid, detail: "\(os) · runtime no longer installed",
                                 size: size(of: dir), simulatorUDID: udid)
            }
        }
    }

    @discardableResult
    static func run(_ tool: String, _ args: [String]) -> Data? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? data : nil
    }

    // MARK: Large files

    static func scanLargeFiles(minBytes: Int64 = 500_000_000) -> [ItemGroup] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .contentModificationDateKey]
        guard let e = fm.enumerator(at: home, includingPropertiesForKeys: keys, options: [.skipsPackageDescendants],
                                    errorHandler: { _, _ in true }) else { return [] }
        let dateFormat = DateFormatter()
        dateFormat.dateStyle = .medium
        var byFolder: [String: [CleanItem]] = [:]

        for case let f as URL in e {
            // Library and Trash hold app data and already-deleted files; leave them out.
            if f.deletingLastPathComponent().path == home.path, ["Library", ".Trash"].contains(f.lastPathComponent) {
                e.skipDescendants()
                continue
            }
            guard let v = try? f.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            let s = Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
            guard s >= minBytes else { continue }
            let modified = v.contentModificationDate.map { " · modified \(dateFormat.string(from: $0))" } ?? ""
            let top = f.path.dropFirst(home.path.count + 1).split(separator: "/").first.map(String.init) ?? "Home"
            byFolder[top, default: []].append(
                CleanItem(url: f, title: f.lastPathComponent, detail: tilde(f.deletingLastPathComponent()) + modified, size: s))
        }
        return byFolder
            .map { ItemGroup(id: $0.key, title: $0.key, icon: "folder", items: $0.value.sorted { $0.size > $1.size }) }
            .sorted { $0.size > $1.size }
    }

    // MARK: Apps and leftovers

    struct InstalledApp {
        let url: URL
        let name: String
        let bundleID: String
        let appGroups: [String]
    }

    static func vendor(_ bundleID: String) -> String {
        bundleID.lowercased().split(separator: ".").prefix(2).joined(separator: ".")
    }

    /// App-group identifiers from the app's code signature, which name its `~/Library/Group Containers` folders.
    static func appGroups(_ app: URL) -> [String] {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else { return [] }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any],
              let entitlements = dict[kSecCodeInfoEntitlementsDict as String] as? [String: Any] else { return [] }
        return entitlements["com.apple.security.application-groups"] as? [String] ?? []
    }

    static func installedApps() -> [InstalledApp] {
        [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")]
            .flatMap(children)
            .filter { $0.pathExtension == "app" }
            .map { app in
                InstalledApp(url: app, name: app.deletingPathExtension().lastPathComponent,
                             bundleID: Bundle(url: app)?.bundleIdentifier ?? "", appGroups: appGroups(app))
            }
    }

    static func scanApps() -> [ItemGroup] {
        let apps = installedApps()
        let fda = hasFullDiskAccess
        let plugins = audioPlugins()
        // A group container shared by several apps (Office, for example) belongs to none of them alone.
        var groupOwners: [String: Int] = [:]
        for app in apps { for g in app.appGroups { groupOwners[g, default: 0] += 1 } }

        var groups = apps
            .filter { !$0.bundleID.hasPrefix("com.apple.") }
            .map { app -> ItemGroup in
                var items = [CleanItem(url: app.url, title: app.url.lastPathComponent,
                                       detail: "Application · \(tilde(app.url.deletingLastPathComponent()))", size: size(of: app.url))]
                items += leftovers(bundleID: app.bundleID, name: app.name, includeContainers: fda)
                if fda {
                    items += app.appGroups.filter { groupOwners[$0] == 1 }
                        .map { lib("Group Containers/\($0)") }.filter(exists).map { item($0) }
                }
                let v = vendor(app.bundleID)
                if !app.bundleID.isEmpty, !["com.apple", "com.yourcompany"].contains(v) {
                    items += plugins.filter { vendor($0.bundleID) == v }.map { item($0.url) }
                }
                return ItemGroup(id: app.url.path, title: app.name, icon: "app", iconPath: app.url.path, items: items)
            }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }

        groups += orphanedLeftovers(installed: apps, includeContainers: fda)
        return groups
    }

    /// Folders keyed by bundle ID; entries match the ID exactly or as a `<id>.` prefix (helpers, plists, saved state).
    static let bundleIDFolders = ["Application Support", "Caches", "Logs", "Preferences", "Preferences/ByHost", "HTTPStorages",
                                  "WebKit", "Cookies", "Saved Application State", "LaunchAgents"]
    /// Folders where apps also use their display name.
    static let nameFolders = ["Application Support", "Caches", "Logs"]

    static func leftovers(bundleID: String, name: String, includeContainers: Bool) -> [CleanItem] {
        var paths: [URL] = []
        let roots = [lib(""), rootLibrary]
        if !bundleID.isEmpty {
            var folders = bundleIDFolders
            if includeContainers { folders.append("Containers") }
            for root in roots {
                for folder in folders + ["LaunchDaemons"] {
                    paths += children(root.appendingPathComponent(folder)).filter {
                        $0.lastPathComponent == bundleID || $0.lastPathComponent.hasPrefix(bundleID + ".")
                    }
                }
            }
        }
        for root in roots {
            paths += nameFolders.map { root.appendingPathComponent("\($0)/\(name)") }
        }
        var seen = Set<String>()
        return paths.filter { exists($0) && seen.insert($0.path).inserted }.map { item($0) }
    }

    struct AudioPlugin { let url: URL; let bundleID: String }

    static func audioPlugins() -> [AudioPlugin] {
        [lib("Audio/Plug-Ins"), rootLibrary.appendingPathComponent("Audio/Plug-Ins")]
            .flatMap { root in ["Components", "VST", "VST3", "MAS"].flatMap { children(root.appendingPathComponent($0)) } }
            .compactMap { url in Bundle(url: url)?.bundleIdentifier.map { AudioPlugin(url: url, bundleID: $0) } }
    }

    /// Vendors of developer tools and frameworks embedded in many apps; their files never mean an app was removed.
    static let sharedComponentVendors: Set<String> = ["org.swift", "com.crashlytics", "io.branch", "org.sparkle-project",
                                                       "com.google.firebase", "io.sentry", "com.microsoft.appcenter"]

    /// Bundle-ID-named support files whose app is no longer installed anywhere.
    static func orphanedLeftovers(installed: [InstalledApp], includeContainers: Bool) -> [ItemGroup] {
        let installedVendors = Set(installed.map { vendor($0.bundleID) })
        let ownID = Bundle.main.bundleIdentifier ?? "app.macsweep"
        var folders = bundleIDFolders.filter { $0 != "LaunchAgents" }
        if includeContainers { folders.append("Containers") }

        var byID: [String: [URL]] = [:]
        for folder in folders {
            for url in children(lib(folder)) {
                var id = url.lastPathComponent
                for ext in [".plist", ".savedState", ".binarycookies"] where id.hasSuffix(ext) { id = String(id.dropLast(ext.count)) }
                let groupless = id.hasPrefix("group.") ? String(id.dropFirst(6)) : id
                guard id.range(of: #"^[a-z][a-z0-9-]*\.[A-Za-z0-9-]+\.[A-Za-z0-9.-]+$"#, options: .regularExpression) != nil,
                      !groupless.hasPrefix("com.apple."), !id.hasPrefix("systemgroup."), id != ownID,
                      !sharedComponentVendors.contains(vendor(groupless)),
                      !installedVendors.contains(vendor(groupless)),
                      NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) == nil else { continue }
                byID[id, default: []].append(url)
            }
        }
        return byID
            .map { id, urls in
                ItemGroup(id: "orphan:\(id)", title: "\(id) — app not installed", icon: "questionmark.app",
                          items: urls.map { item($0) }.sorted { $0.size > $1.size })
            }
            .filter { $0.size > 0 }
            .sorted { $0.size > $1.size }
    }

    // MARK: Launch agents

    static func scanLaunchAgents() -> [ItemGroup] {
        var broken: [CleanItem] = []
        var working: [CleanItem] = []
        for url in children(lib("LaunchAgents")) where url.pathExtension == "plist" {
            let dict = NSDictionary(contentsOf: url) as? [String: Any]
            let program = dict?["Program"] as? String ?? (dict?["ProgramArguments"] as? [String])?.first
            let label = dict?["Label"] as? String ?? url.lastPathComponent
            // Only absolute paths can be checked; bare command names are resolved by launchd.
            let isBroken = dict == nil || program == nil || (program!.hasPrefix("/") && !exists(URL(fileURLWithPath: program!)))
            let detail = dict == nil ? "Unreadable plist" : program == nil ? "No program set, so it can never run" : isBroken ? "Missing: \(program!)" : program!
            let entry = CleanItem(url: url, title: label, detail: detail, size: fileSize(url))
            if isBroken { broken.append(entry) } else { working.append(entry) }
        }
        return [
            broken.isEmpty ? nil : ItemGroup(id: "broken", title: "Broken (program missing)", icon: "exclamationmark.triangle",
                                             preselect: true, items: broken.sorted { $0.title < $1.title }),
            working.isEmpty ? nil : ItemGroup(id: "agents", title: "Your Launch Agents", icon: "power",
                                              items: working.sorted { $0.title < $1.title }),
        ].compactMap { $0 }
    }

    // MARK: Cleanup

    static func moveToTrash(_ items: [CleanItem]) -> (freed: Int64, failures: [CleanItem]) {
        var freed: Int64 = 0
        var failures: [CleanItem] = []
        for item in items {
            if let udid = item.simulatorUDID {
                if run("/usr/bin/xcrun", ["simctl", "delete", udid]) != nil { freed += item.size } else { failures.append(item) }
                continue
            }
            do {
                try fm.trashItem(at: item.url, resultingItemURL: nil)
                freed += item.size
            } catch {
                failures.append(item)
            }
        }
        return (freed, failures)
    }

    static func freeSpace() -> Int64? {
        let v = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return v?.volumeAvailableCapacityForImportantUsage
    }
}
