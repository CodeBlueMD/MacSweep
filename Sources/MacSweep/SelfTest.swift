import Foundation

/// `MacSweep --self-test`: plants known junk, checks each scanner finds it (and only the right copies),
/// cleans it through the real Trash code path, and confirms it is gone. Only touches files it created.
enum SelfTest {
    @MainActor
    static func run() -> Bool {
        let fm = FileManager.default
        var passed = 0, failed = 0
        func check(_ name: String, _ ok: Bool, _ note: String = "") {
            print("\(ok ? "PASS" : "FAIL")  \(name)\(note.isEmpty ? "" : " — \(note)")")
            if ok { passed += 1 } else { failed += 1 }
        }
        func blob(_ n: Int) -> Data { Data((0..<n).map { _ in UInt8.random(in: 0...255) }) }
        func trash(_ items: [CleanItem]) -> Bool { Scanner.moveToTrash(items).failures.isEmpty }

        // 1. A cache folder is found in App Caches, selected, and cleaned (Tier 1: Junk).
        let cache = Scanner.lib("Caches/app.macsweep.selftest")
        try? fm.createDirectory(at: cache, withIntermediateDirectories: true)
        try? blob(3_000_000).write(to: cache.appendingPathComponent("blob.bin"))
        let junk = Scanner.scanJunk()
        let cacheGroup = junk.first { $0.items.contains { $0.url.standardizedFileURL == cache.standardizedFileURL } }
        check("junk: planted cache found", cacheGroup != nil, cacheGroup.map { "in \($0.title)" } ?? "")
        check("junk: planted cache preselected (Tier 1)", cacheGroup?.preselect == true)
        if let item = cacheGroup?.items.first(where: { $0.url.standardizedFileURL == cache.standardizedFileURL }) {
            check("junk: size measured", item.size >= 3_000_000, bytes(item.size))
            check("junk: moved to Trash", trash([item]) && !fm.fileExists(atPath: cache.path))
        }
        // Apple logs are fine to clear; Apple caches are not selected by default (Tier 2: Costly to Rebuild).
        check("junk: no Apple cache preselected (Tier 2)",
              !junk.filter(\.preselect).flatMap(\.items).contains {
                  $0.url.path.hasPrefix(Scanner.lib("Caches").path) && Scanner.isAppleCache($0.url.lastPathComponent)
              })

        // 1b. 3-Tier Safety Rules (Mole's Rule) verification:
        // Tier 2: Costly to Rebuild (Active DerivedData & AI models) are NEVER preselected by default.
        let testActiveDerived = Scanner.dev("Xcode/DerivedData/MacSweepSelfTestActive")
        let activeInfo = testActiveDerived.appendingPathComponent("info.plist")
        try? fm.createDirectory(at: testActiveDerived, withIntermediateDirectories: true)
        let activeWorkspace = URL(fileURLWithPath: #file) // Valid file that exists on disk
        (["WorkspacePath": activeWorkspace.path] as NSDictionary).write(to: activeInfo, atomically: true)
        try? blob(1_000_000).write(to: testActiveDerived.appendingPathComponent("data.bin"))

        let testOrphanDerived = Scanner.dev("Xcode/DerivedData/MacSweepSelfTestOrphan")
        let orphanInfo = testOrphanDerived.appendingPathComponent("info.plist")
        try? fm.createDirectory(at: testOrphanDerived, withIntermediateDirectories: true)
        (["WorkspacePath": "/nonexistent/test.xcodeproj"] as NSDictionary).write(to: orphanInfo, atomically: true)
        try? blob(1_000_000).write(to: testOrphanDerived.appendingPathComponent("data.bin"))

        let testHfModel = Scanner.home.appendingPathComponent(".cache/huggingface/hub/models--macsweep--selftest")
        try? fm.createDirectory(at: testHfModel, withIntermediateDirectories: true)
        try? blob(2_000_000).write(to: testHfModel.appendingPathComponent("model.safetensors"))

        let junkWithTiers = Scanner.scanJunk()

        let activeGroup = junkWithTiers.first { $0.id == "activeDerived" }
        check("tier 2: active project DerivedData NOT preselected",
              activeGroup != nil && activeGroup?.preselect == false)

        let orphanDerivedGroup = junkWithTiers.first { $0.id == "orphanedDerived" }
        check("tier 1: orphaned DerivedData IS preselected",
              orphanDerivedGroup != nil && orphanDerivedGroup?.preselect == true)

        let aiGroup = junkWithTiers.first { $0.id == "aiModels" }
        check("tier 2: AI models NOT preselected",
              aiGroup != nil && aiGroup?.preselect == false)

        // Tier 3: In Use by Open Apps
        let inUseGroup = junkWithTiers.first { $0.id == "inUse" }
        if let inUseGroup {
            check("tier 3: in-use items held back and NOT preselected", inUseGroup.preselect == false)
            check("tier 3: in-use items tagged with owner app", inUseGroup.items.allSatisfy { $0.inUseBy != nil })
        }

        // Clean up tier test artifacts
        try? fm.removeItem(at: testActiveDerived)
        try? fm.removeItem(at: testOrphanDerived)
        try? fm.removeItem(at: testHfModel)

        // 2. Duplicates: a real copy is offered, an APFS clone is not, and the original is kept.
        let dupDir = Scanner.home.appendingPathComponent("Downloads/MacSweep Self-Test")
        try? fm.createDirectory(at: dupDir, withIntermediateDirectories: true)
        let data = blob(2_000_000)
        let original = dupDir.appendingPathComponent("original.bin")
        let copy = dupDir.appendingPathComponent("copy.bin")
        let clone = dupDir.appendingPathComponent("clone.bin")
        try? data.write(to: original)
        Thread.sleep(forTimeInterval: 1.1) // distinct creation dates, so "oldest" is well defined
        try? data.write(to: copy)
        try? fm.copyItem(at: original, to: clone) // APFS makes this a clone
        let dupGroup = Scanner.scanDuplicates().first { g in g.items.contains { $0.url.lastPathComponent == "copy.bin" && $0.url.path.contains("MacSweep Self-Test") } }
        check("duplicates: copy found", dupGroup != nil)
        check("duplicates: original kept out of the list", dupGroup?.items.contains { $0.url == original } == false)
        check("duplicates: APFS clone skipped", dupGroup?.items.contains { $0.url.lastPathComponent == "clone.bin" } == false)
        if let dupGroup { check("duplicates: copy trashed, original remains", trash(dupGroup.items) && fm.fileExists(atPath: original.path)) }
        try? fm.removeItem(at: dupDir) // only our own test files

        // 3. A launch agent whose program is missing is flagged as broken.
        let agent = Scanner.lib("LaunchAgents/app.macsweep.selftest.plist")
        (["Label": "app.macsweep.selftest", "Program": "/nonexistent/macsweep-selftest"] as NSDictionary).write(to: agent, atomically: true)
        let broken = Scanner.scanLaunchAgents().first { $0.id == "broken" }?.items.first { $0.url == agent }
        check("agents: broken agent flagged", broken != nil, broken?.detail ?? "")
        if let broken { check("agents: broken agent trashed", trash([broken])) }

        // 4. Files left by a removed app are listed as leftovers.
        let orphan = Scanner.lib("Application Support/com.macsweepselftest.removedapp")
        try? fm.createDirectory(at: orphan, withIntermediateDirectories: true)
        try? blob(100_000).write(to: orphan.appendingPathComponent("data.db"))
        let orphanGroup = Scanner.scanApps().first { $0.id == "orphan:com.macsweepselftest.removedapp" }
        check("uninstaller: removed-app leftover found", orphanGroup != nil)
        if let orphanGroup { check("uninstaller: leftover trashed", trash(orphanGroup.items)) }

        // 5. Health readings are within sensible ranges.
        let health = HealthMonitor(readsBluetooth: false)
        Thread.sleep(forTimeInterval: 1)
        health.refresh()
        check("health: disk reading", health.diskTotal > 0 && health.diskFree > 0, "\(bytes(health.diskFree)) free")
        check("health: memory pressure 0–100", (0...100).contains(health.memoryPressure), "\(health.memoryPressure)%")
        check("health: CPU load 0–1", (0...1).contains(health.cpuLoad), "\(Int(health.cpuLoad * 100))%")
        check("health: battery", health.battery != nil, health.battery.map { "\($0.percent)%" } ?? "no battery")
        check("health: total memory", health.totalMemory > 0, "\(bytes(Int64(health.totalMemory)))")
        check("health: active memory measured", health.activeMemory > 0, "\(bytes(Int64(health.activeMemory)))")

        // Test 1-click inactive RAM purge
        var purgeFinished = false
        Task {
            await health.purgeInactiveMemory()
            purgeFinished = true
        }
        let purgeTimeout = Date().addingTimeInterval(5.0)
        while !purgeFinished && Date() < purgeTimeout {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        check("health: 1-click RAM purge completed", health.purgeSuccess, health.purgeStatusMessage ?? "Done")

        // 6. Every maintenance task's command exists on this macOS version (tasks are not run).
        for task in Maintenance.tasks {
            let tools = task.command.components(separatedBy: ";").compactMap { $0.split(separator: " ").first.map(String.init) }
            let missing = tools.filter { !fm.isExecutableFile(atPath: $0) }
            check("maintenance: \(task.title) command available", missing.isEmpty, missing.joined(separator: ", "))
        }

        print("\n\(passed) passed, \(failed) failed. Cleaned test files are in the Trash.")
        return failed == 0
    }
}
