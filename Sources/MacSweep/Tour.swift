import AppKit
import SwiftUI

/// `open MacSweep.app --args -tour <dir>` walks every page the way a person would (scan, browse, clean a
/// planted test item, open the health panel), saves a PNG of each step into `<dir>`, logs PASS/FAIL lines
/// to `<dir>/tour.log`, then quits. Nothing outside its own test files is removed.
@MainActor
enum Tour {
    static func run(store: Store, openWindow: OpenWindowAction) async {
        guard let dirPath = UserDefaults.standard.string(forKey: "tour") else { return }
        let dir = URL(fileURLWithPath: dirPath)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var log = ""
        func note(_ line: String) { log += line + "\n"; try? log.write(to: dir.appendingPathComponent("tour.log"), atomically: true, encoding: .utf8) }
        func check(_ name: String, _ ok: Bool, _ detail: String = "") { note("\(ok ? "PASS" : "FAIL")  \(name)\(detail.isEmpty ? "" : " — \(detail)")") }
        func pause(_ s: Double) async { try? await Task.sleep(for: .seconds(s)) }
        func shot(_ name: String, window title: String = "MacSweep") async {
            await pause(0.8) // let animations settle
            guard let window = NSApp.windows.first(where: { $0.title == title && $0.isVisible }), let view = window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { note("FAIL  screenshot \(name): no window"); return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name).png"))
        }
        func waitForScans(_ models: [SectionModel], timeout: Double = 600) async -> Bool {
            let start = Date()
            while models.contains(where: { $0.scanning || !$0.scanned }) {
                if Date().timeIntervalSince(start) > timeout { return false }
                await pause(0.5)
            }
            return true
        }

        await pause(1.5)
        let all = Section.allCases.map(store.model)

        // Smart Care, before and after scanning everything.
        store.page = .smartCare
        await shot("01-smartcare-idle")
        for m in all { m.scan() }
        await pause(1)
        await shot("02-smartcare-scanning")
        check("smart care: all scans finish", await waitForScans(all))
        check("smart care: something selected to clean", all.contains { !$0.selected.isEmpty },
              bytes(all.reduce(0) { $0 + $1.selectedSize }))
        await shot("03-smartcare-results")

        // Each section's results page, and a hover label on the rail.
        for (i, s) in Section.allCases.enumerated() {
            store.page = .area(s)
            store.tourLabel = .area(s)
            let m = store.model(s)
            check("\(s.title): page shows results", m.scanned && !m.scanning,
                  "\(m.groups.count) groups, \(bytes(m.totalSize)) found, \(bytes(m.selectedSize)) selected")
            await shot(String(format: "%02d-%@", 4 + i, s.rawValue))
        }

        // Clean flow: plant a cache, rescan, select only it, press Clean (same call as the button), verify.
        store.tourLabel = nil
        let planted = Scanner.lib("Caches/app.macsweep.tour")
        try? FileManager.default.createDirectory(at: planted, withIntermediateDirectories: true)
        try? Data(count: 2_000_000).write(to: planted.appendingPathComponent("blob.bin"))
        let junk = store.model(.junk)
        store.page = .area(.junk)
        junk.scan()
        await pause(0.5)
        _ = await waitForScans([junk])
        let target = junk.groups.flatMap(\.items).first { $0.url.standardizedFileURL == planted.standardizedFileURL }
        check("clean: planted cache listed", target != nil)
        if let target {
            junk.selected = [target.id]
            junk.clean()
            await pause(1)
            _ = await waitForScans([junk])
            check("clean: file moved to Trash", !FileManager.default.fileExists(atPath: planted.path))
            check("clean: status message shown", junk.status?.contains("Moved") == true, junk.status ?? "none")
            await shot("09-after-clean")
        }

        // Space Map: home, then the largest folder.
        store.page = .spaceMap
        store.spaceMap.load()
        while store.spaceMap.loading { await pause(0.5) }
        check("space map: home measured", !store.spaceMap.entries.isEmpty,
              "\(store.spaceMap.entries.count) items, \(bytes(store.spaceMap.total))")
        await shot("10-spacemap-home")
        if let folder = store.spaceMap.entries.first(where: \.isFolder) {
            store.spaceMap.open(folder)
            while store.spaceMap.loading { await pause(0.5) }
            check("space map: drill into \(folder.url.lastPathComponent)", store.spaceMap.path.count == 2 && !store.spaceMap.entries.isEmpty)
            await shot("11-spacemap-folder")
            store.spaceMap.goBack(to: 0)
            check("space map: back to home (cached)", store.spaceMap.path.count == 1 && !store.spaceMap.loading)
        }

        // Maintenance with the hover label showing (the label used to draw behind the page).
        store.page = .maintenance
        store.tourLabel = .maintenance
        await shot("12-maintenance")
        store.tourLabel = nil

        // Menu bar panel, shown in a window so it can be captured.
        openWindow(id: "healthPreview")
        await pause(3) // two refresh ticks so CPU and network rates exist
        await shot("13-health-panel", window: "Mac Health")

        // Export: the report covers every section.
        let report = Report.markdown(all.map(\.reportPart))
        try? report.write(to: dir.appendingPathComponent("report.md"), atomically: true, encoding: .utf8)
        check("export: report has every section", Section.allCases.allSatisfy { report.contains("## \($0.title):") })

        note("DONE")
        NSApp.terminate(nil)
    }
}
