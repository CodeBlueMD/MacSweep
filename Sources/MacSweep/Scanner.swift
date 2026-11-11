import AppKit
import Darwin
import Foundation
import Security

enum SafetyTier: String, Sendable, CaseIterable {
    case junk = "Tier 1: Junk"
    case costlyToRebuild = "Tier 2: Costly to Rebuild"
    case protected = "Tier 3: Protected"
}

struct CleanItem: Identifiable, Hashable, Sendable {
    let id = UUID()
    let url: URL
    var title: String
    var detail: String
    let size: Int64
    /// Simulator devices are removed through `simctl` so CoreSimulator stays consistent.
    var simulatorUDID: String? = nil
    var tier: SafetyTier = .junk
    var inUseBy: String? = nil
}

struct ItemGroup: Identifiable, Sendable {
    let id: String
    let title: String
    let icon: String
    var iconPath: String? = nil
    var preselect = false
    var tier: SafetyTier = .junk
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

    static func item(_ url: URL, title: String? = nil, tier: SafetyTier = .junk, inUseBy: String? = nil) -> CleanItem {
        let detailText: String
        if let inUseBy {
            detailText = "In Use by \(inUseBy) · \(tilde(url.deletingLastPathComponent()))"
        } else {
            detailText = tilde(url.deletingLastPathComponent())
        }
        return CleanItem(url: url, title: title ?? url.lastPathComponent, detail: detailText, size: size(of: url), tier: tier, inUseBy: inUseBy)
    }

    /// Other apps' sandbox containers are only readable with Full Disk Access; without it
    /// macOS prompts once per app, so container scans are skipped instead.
    static var hasFullDiskAccess: Bool {
        FileHandle(forReadingAtPath: lib("Application Support/com.apple.TCC/TCC.db").path) != nil
    }

    static func group(_ id: String, _ title: String, _ icon: String, preselect: Bool = true, tier: SafetyTier = .junk, _ items: [CleanItem]) -> ItemGroup? {
        let kept = items.filter { $0.size > 0 }.sorted { $0.size > $1.size }
        guard !kept.isEmpty else { return nil }
        var tagged = kept
        for i in 0..<tagged.count {
            if tagged[i].tier != tier && tagged[i].tier == .junk {
                tagged[i].tier = tier
            }
        }
        return ItemGroup(id: id, title: title, icon: icon, preselect: preselect, tier: tier, items: tagged)
    }

    /// One item per entry inside `dir`.
    static func contents(_ id: String, _ title: String, _ icon: String, _ dir: URL, preselect: Bool = true, tier: SafetyTier = .junk) -> ItemGroup? {
        group(id, title, icon, preselect: preselect, tier: tier, children(dir).map { item($0, tier: tier) })
    }

    // MARK: - 3-Tier Safety System (Mole's Rule)

    static func scanJunk() -> [ItemGroup] {
        let fda = hasFullDiskAccess
        let caches = children(lib("Caches")).map { item($0, tier: .junk) }
        let appCaches = caches.filter { !isAppleCache($0.url.lastPathComponent) }
        let appleCaches = caches.filter { isAppleCache($0.url.lastPathComponent) }

        var groups: [ItemGroup?] = [
            // Tier 1 (Junk): Safe app caches where owner is closed -> Pre-selected
            group("caches", "App Caches", "archivebox", preselect: true, tier: .junk, appCaches),
            // Tier 2 (Costly to Rebuild): Apple system caches -> Never preselected
            group("appleCaches", "Apple System Caches", "apple.logo", preselect: false, tier: .costlyToRebuild, appleCaches),
            // Tier 1 (Junk): Container caches (if FDA granted)
            fda ? group("containerCaches", "Sandboxed App Caches", "shippingbox", preselect: true, tier: .junk, containerCaches()) : nil,
            // Tier 1 (Junk): Electron & web app caches
            group("electron", "Electron & Web App Caches", "globe", preselect: true, tier: .junk, electronCaches()),
            // Tier 1 (Junk): User Logs
            contents("logs", "User Logs", "doc.text", lib("Logs"), preselect: true, tier: .junk),
            // Tier 1 (Junk): Gradle Caches
            contents("gradle", "Gradle Caches", "cube", home.appendingPathComponent(".gradle/caches"), preselect: true, tier: .junk),
            // Tier 1 (Junk): Broken Preferences
            group("brokenPrefs", "Broken Preference Files", "exclamationmark.triangle", preselect: true, tier: .junk, brokenPreferences()),
            // Tier 1 (Junk): Broken Launch Agents
            group("brokenAgents", "Broken Launch Agents", "exclamationmark.triangle", preselect: true, tier: .junk, brokenLaunchAgents()),
            // Tier 2 (Costly to Rebuild): AI Models (~/.ollama, Hugging Face) -> Visible, NEVER pre-selected
            group("aiModels", "AI Models & Cache (Ollama, Hugging Face)", "brain", preselect: false, tier: .costlyToRebuild, aiModels()),
        ]

        groups += xcodeJunk()

        // Tier 3 (Protected): Files in use by open apps held back with clear 'In Use by <AppName>' tags
        return holdBackRunningApps(groups.compactMap { $0 })
    }

    /// Apple caches that are not named `com.apple.*`.
    static let appleCacheNames: Set<String> = ["CloudKit", "GeoServices", "PassKit", "Animoji", "familycircled", "FamilyCircle",
                                               "PHTPhenotype", "Metadata", "SpeechModels", "SiriTTS", "Maps", "Safari",
                                               "AMPLibraryAgent", "MobileSync", "iCloud", "Photos"]

    static func isAppleCache(_ name: String) -> Bool {
        name.hasPrefix("com.apple.") || name.hasPrefix("PFScene") || appleCacheNames.contains(name)
    }

    // MARK: - Process and In-Use Inspection (Tier 3)

    struct RunningAppInfo {
        let name: String
        let bundleID: String
        let bundleURL: URL?
        let pid: pid_t
    }

    static func runningAppInfos() -> [RunningAppInfo] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy != .prohibited }
            .compactMap { app in
                guard let id = app.bundleIdentifier else { return nil }
                let name = app.localizedName ?? (id.split(separator: ".").last.map(String.init) ?? id)
                return RunningAppInfo(name: name, bundleID: id, bundleURL: app.bundleURL, pid: app.processIdentifier)
            }
    }

    /// Open file paths for running applications, mapped to the app name.
    static func openFilesByRunningApps(apps: [RunningAppInfo]) -> [String: String] {
        var map: [String: String] = [:]
        for app in apps {
            let pid = app.pid
            let bufferSize = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
            guard bufferSize > 0 else { continue }
            let count = Int(bufferSize) / MemoryLayout<proc_fdinfo>.stride
            var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: count)
            guard proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, bufferSize) > 0 else { continue }
            for fd in fds where fd.proc_fdtype == PROX_FDTYPE_VNODE {
                var vnodeInfo = vnode_fdinfowithpath()
                let vnodeSize = Int32(MemoryLayout<vnode_fdinfowithpath>.stride)
                if proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &vnodeInfo, vnodeSize) > 0 {
                    withUnsafePointer(to: &vnodeInfo.pvip.vip_path) { ptr in
                        let path = String(cString: UnsafeRawPointer(ptr).assumingMemoryBound(to: CChar.self))
                        if !path.isEmpty {
                            map[path] = app.name
                        }
                    }
                }
            }
        }
        return map
    }

    /// Checks if a file or directory is actively in use by a running application.
    static func inUseByApp(for url: URL, apps: [RunningAppInfo], openFiles: [String: String]) -> String? {
        let itemPath = url.standardizedFileURL.path

        // 1. Direct open file handle
        if let direct = openFiles[itemPath] { return direct }
        for (filePath, appName) in openFiles {
            if filePath.hasPrefix(itemPath + "/") { return appName }
        }

        // 2. Binary execution path (e.g. app running directly from DerivedData)
        for app in apps {
            guard let bundlePath = app.bundleURL?.standardizedFileURL.path else { continue }
            if bundlePath.hasPrefix(itemPath) || itemPath.hasPrefix(bundlePath) {
                return app.name
            }
        }

        // 3. Category ownership for open apps
        let libraryPath = lib("").path + "/"
        if itemPath.hasPrefix(libraryPath) {
            let subpath = itemPath.dropFirst(libraryPath.count)
            let parts = subpath.split(separator: "/")
            if parts.count >= 2 {
                let category = parts[0].lowercased()
                let folder = parts[1].lowercased()

                for app in apps {
                    let id = app.bundleID.lowercased()
                    let name = app.name.lowercased()
                    let firstWord = name.split(separator: " ").first.map(String.init) ?? name

                    if category == "caches" || category == "containers" || category == "application support" {
                        if folder == id || folder.hasPrefix(id + ".") || (!name.isEmpty && (folder == name || (firstWord.count > 2 && folder == firstWord))) {
                            return app.name
                        }
                    } else if category == "developer" {
                        if app.bundleID == "com.apple.dt.Xcode" {
                            return "Xcode"
                        }
                    }
                }
            }
        }

        return nil
    }

    /// Tier 3 Safety Rule: Moves all items actively in use by open apps into a protected, unselected group
    /// and tags each item clearly with 'In Use by <AppName>'.
    static func holdBackRunningApps(_ groups: [ItemGroup]) -> [ItemGroup] {
        let apps = runningAppInfos()
        let openFiles = openFilesByRunningApps(apps: apps)

        var inUseItems: [CleanItem] = []
        var updatedGroups: [ItemGroup] = []

        for var group in groups {
            var keptItems: [CleanItem] = []
            for item in group.items {
                if let appName = inUseByApp(for: item.url, apps: apps, openFiles: openFiles) {
                    var protectedItem = item
                    protectedItem.tier = .protected
                    protectedItem.inUseBy = appName
                    protectedItem.detail = "In Use by \(appName) · Quit app to clean · \(item.detail)"
                    inUseItems.append(protectedItem)
                } else {
                    keptItems.append(item)
                }
            }
            if !keptItems.isEmpty {
                group.items = keptItems
                updatedGroups.append(group)
            }
        }

        if !inUseItems.isEmpty {
            let sortedInUse = inUseItems.sorted { $0.size > $1.size }
            if let heldGroup = ItemGroup(id: "inUse",
                                         title: "In Use by Open Apps",
                                         icon: "lock.shield.fill",
                                         preselect: false,
                                         tier: .protected,
                                         items: sortedInUse) as ItemGroup? {
                updatedGroups.insert(heldGroup, at: 0)
            }
        }

        return updatedGroups
    }

    // MARK: - AI Models Scanner (Tier 2: Costly to Rebuild)

    static func aiModels() -> [CleanItem] {
        var results: [CleanItem] = []

        // 1. Ollama models: ~/.ollama/models
        let ollamaDir = home.appendingPathComponent(".ollama")
        let ollamaModels = ollamaDir.appendingPathComponent("models")
        if exists(ollamaModels) {
            let manifestsDir = ollamaModels.appendingPathComponent("manifests")
            var manifestFound = false
            if exists(manifestsDir) {
                let keys: [URLResourceKey] = [.isRegularFileKey]
                if let enumerator = fm.enumerator(at: manifestsDir, includingPropertiesForKeys: keys, errorHandler: { _, _ in true }) {
                    for case let manifestURL as URL in enumerator {
                        guard let v = try? manifestURL.resourceValues(forKeys: [.isRegularFileKey]), v.isRegularFile == true else { continue }
                        let tag = manifestURL.lastPathComponent
                        let model = manifestURL.deletingLastPathComponent().lastPathComponent
                        guard let data = try? Data(contentsOf: manifestURL),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let layers = json["layers"] as? [[String: Any]] else { continue }

                        var modelSize: Int64 = 0
                        for layer in layers {
                            if let s = layer["size"] as? Int64 { modelSize += s }
                            else if let s = layer["size"] as? Int { modelSize += Int64(s) }
                        }
                        manifestFound = true
                        let modelName = (tag == "latest" || tag.isEmpty) ? model : "\(model):\(tag)"
                        results.append(CleanItem(
                            url: manifestURL,
                            title: "Ollama: \(modelName)",
                            detail: "AI Model in ~/.ollama · Costly to re-download",
                            size: modelSize > 0 ? modelSize : size(of: manifestURL),
                            tier: .costlyToRebuild
                        ))
                    }
                }
            }
            if !manifestFound {
                let blobsDir = ollamaModels.appendingPathComponent("blobs")
                if exists(blobsDir) {
                    for blob in children(blobsDir) where fileSize(blob) > 50_000_000 {
                        results.append(CleanItem(
                            url: blob,
                            title: "Ollama Model Blob: \(blob.lastPathComponent.prefix(19))…",
                            detail: "AI Weights in ~/.ollama/models/blobs · Costly to re-download",
                            size: fileSize(blob),
                            tier: .costlyToRebuild
                        ))
                    }
                }
            }
        }

        // 2. Hugging Face caches: ~/.cache/huggingface/hub and ~/Library/Caches/huggingface/hub
        let hfLocations = [
            home.appendingPathComponent(".cache/huggingface/hub"),
            lib("Caches/huggingface/hub")
        ]
        for hubDir in hfLocations where exists(hubDir) {
            for modelDir in children(hubDir) where modelDir.lastPathComponent.hasPrefix("models--") {
                let displayName = modelDir.lastPathComponent
                    .replacingOccurrences(of: "models--", with: "")
                    .replacingOccurrences(of: "--", with: "/")
                let s = size(of: modelDir)
                if s > 0 {
                    results.append(CleanItem(
                        url: modelDir,
                        title: "Hugging Face: \(displayName)",
                        detail: "\(tilde(modelDir.deletingLastPathComponent())) · Costly to re-download",
                        size: s,
                        tier: .costlyToRebuild
                    ))
                }
            }
        }

        return results.sorted { $0.size > $1.size }
    }

    /// `~/Library/Containers/<app>/Data/Library/Caches`, one item per app.
    static func containerCaches() -> [CleanItem] {
        children(lib("Containers")).compactMap { container in
            let caches = container.appendingPathComponent("Data/Library/Caches")
            guard exists(caches) else { return nil }
            return CleanItem(url: caches, title: container.lastPathComponent, detail: tilde(caches), size: size(of: caches), tier: .junk)
        }
    }

    /// Chromium-based apps keep their caches in Application Support rather than Caches.
    static func electronCaches() -> [CleanItem] {
        let names = ["Cache", "Code Cache", "GPUCache", "DawnCache", "DawnGraphiteCache", "DawnWebGPUCache",
                     "Service Worker/CacheStorage", "Service Worker/ScriptCache"]
        return children(lib("Application Support")).flatMap { app in
            names.map { app.appendingPathComponent($0) }
                .filter(exists)
                .map { item($0, title: "\(app.lastPathComponent) · \($0.lastPathComponent)", tier: .junk) }
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
            .map { item($0, tier: .junk) }
    }

    /// Launch agents whose program executable is missing.
    static func brokenLaunchAgents() -> [CleanItem] {
        var broken: [CleanItem] = []
        for url in children(lib("LaunchAgents")) where url.pathExtension == "plist" {
            let dict = NSDictionary(contentsOf: url) as? [String: Any]
            let program = dict?["Program"] as? String ?? (dict?["ProgramArguments"] as? [String])?.first
            let label = dict?["Label"] as? String ?? url.lastPathComponent
            let isBroken = dict == nil || program == nil || (program!.hasPrefix("/") && !exists(URL(fileURLWithPath: program!)))
            if isBroken {
                let detail = dict == nil ? "Unreadable plist" : program == nil ? "No program set, so it can never run" : "Missing: \(program!)"
                broken.append(CleanItem(url: url, title: label, detail: detail, size: fileSize(url), tier: .junk))
            }
        }
        return broken.sorted { $0.title < $1.title }
    }

    // MARK: - Developer & Xcode Inspection (Mole's Rule)

    static func scanDerivedData() -> (active: [CleanItem], orphaned: [CleanItem]) {
        let derivedRoot = dev("Xcode/DerivedData")
        guard exists(derivedRoot) else { return ([], []) }

        var active: [CleanItem] = []
        var orphaned: [CleanItem] = []

        for folder in children(derivedRoot) {
            let s = size(of: folder)
            guard s > 0 else { continue }

            let infoPlist = folder.appendingPathComponent("info.plist")
            var workspacePath: String? = nil
            if exists(infoPlist),
               let dict = NSDictionary(contentsOf: infoPlist) as? [String: Any],
               let wp = dict["WorkspacePath"] as? String {
                workspacePath = wp
            }

            if let wp = workspacePath {
                let projectExists = fm.fileExists(atPath: wp)
                let projName = URL(fileURLWithPath: wp).deletingPathExtension().lastPathComponent
                if projectExists {
                    active.append(CleanItem(
                        url: folder,
                        title: "\(projName) DerivedData",
                        detail: "Active project: \(tilde(URL(fileURLWithPath: wp))) · Costly to recompile",
                        size: s,
                        tier: .costlyToRebuild
                    ))
                } else {
                    orphaned.append(CleanItem(
                        url: folder,
                        title: "\(projName.isEmpty ? folder.lastPathComponent : projName) (Orphaned)",
                        detail: "Project no longer exists (\(wp)) · Safe to clean",
                        size: s,
                        tier: .junk
                    ))
                }
            } else {
                let isCache = folder.lastPathComponent.hasSuffix(".noindex") || folder.lastPathComponent.hasPrefix("SDK")
                if isCache {
                    orphaned.append(CleanItem(
                        url: folder,
                        title: folder.lastPathComponent,
                        detail: "\(tilde(derivedRoot)) · Xcode re-creates as needed",
                        size: s,
                        tier: .junk
                    ))
                } else {
                    orphaned.append(CleanItem(
                        url: folder,
                        title: folder.lastPathComponent,
                        detail: "Untracked build cache · \(tilde(derivedRoot))",
                        size: s,
                        tier: .junk
                    ))
                }
            }
        }
        return (active.sorted { $0.size > $1.size }, orphaned.sorted { $0.size > $1.size })
    }

    static func scanSimulatorRuntimes() -> [CleanItem] {
        var items: [CleanItem] = []
        let runtimeDirs = [
            dev("CoreSimulator/Caches"),
            dev("CoreSimulator/Profiles/Runtimes"),
            URL(fileURLWithPath: "/Library/Developer/CoreSimulator/Profiles/Runtimes")
        ]
        for dir in runtimeDirs where exists(dir) {
            for child in children(dir) {
                let s = size(of: child)
                if s > 0 {
                    items.append(CleanItem(
                        url: child,
                        title: child.lastPathComponent,
                        detail: "\(tilde(dir)) · Simulator Runtime / Cache",
                        size: s,
                        tier: .costlyToRebuild
                    ))
                }
            }
        }
        return items.sorted { $0.size > $1.size }
    }

    static func xcodeJunk() -> [ItemGroup?] {
        let xcode = dev("Xcode")
        let deviceSupport = ["iOS", "macOS", "watchOS", "tvOS", "visionOS"].flatMap { children(xcode.appendingPathComponent("\($0) DeviceSupport")) }
        let archives = children(xcode.appendingPathComponent("Archives")).flatMap(children).filter { $0.pathExtension == "xcarchive" }
        let (activeDerived, orphanedDerived) = scanDerivedData()
        let simulatorRuntimes = scanSimulatorRuntimes()

        return [
            // Tier 2: Active project DerivedData -> Visible, NEVER pre-selected
            group("activeDerived", "Active Project DerivedData", "hammer.fill", preselect: false, tier: .costlyToRebuild, activeDerived),
            // Tier 1: Orphaned DerivedData -> Pre-selected
            group("orphanedDerived", "Orphaned DerivedData", "hammer", preselect: true, tier: .junk, orphanedDerived),
            // Tier 1: Xcode Documentation Cache
            contents("xcodeDocs", "Xcode Documentation Cache", "book", xcode.appendingPathComponent("DocumentationCache"), preselect: true, tier: .junk),
            // Tier 1: Device Logs
            contents("deviceLogs", "Xcode Device Logs", "doc.text.magnifyingglass", xcode.appendingPathComponent("iOS Device Logs"), preselect: true, tier: .junk),
            // Tier 2: Simulator Runtimes & Caches -> Costly to rebuild, NEVER pre-selected
            group("simRuntimes", "Simulator Runtimes & Caches", "iphone.badge.play", preselect: false, tier: .costlyToRebuild, simulatorRuntimes),
            // Tier 2: Device Support -> Re-downloaded automatically, NEVER pre-selected
            group("deviceSupport", "Xcode Device Support", "iphone.and.arrow.forward", preselect: false, tier: .costlyToRebuild, deviceSupport.map { item($0, tier: .costlyToRebuild) }),
            // Tier 2: Archives -> Hold symbolication symbols, NEVER pre-selected
            group("archives", "Xcode Archives", "archivebox.fill", preselect: false, tier: .costlyToRebuild, archives.map { item($0, tier: .costlyToRebuild) }),
            // Tier 1: Unavailable Simulators -> Runtime missing, safe junk
            group("simulators", "Unavailable Simulators", "iphone.slash", preselect: true, tier: .junk, unavailableSimulators()),
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
                                 size: size(of: dir), simulatorUDID: udid, tier: .junk)
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
