import AppKit
import Foundation

/// Plain-Markdown scan report, meant to be read by a person or pasted into an AI chat for review.
enum Report {
    struct Part {
        let section: Section
        let groups: [ItemGroup]
        let selected: Set<UUID>
    }

    static func markdown(_ parts: [Part]) -> String {
        let date = Date().formatted(date: .abbreviated, time: .shortened)
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        var out = """
        # MacSweep scan report
        Generated \(date) · macOS \(os) · Full Disk Access: \(Scanner.hasFullDiskAccess ? "yes" : "no")
        Free space: \(Scanner.freeSpace().map(bytes) ?? "unknown")

        `[x]` = selected to move to the Trash, `[ ]` = found but not selected. Sizes are on-disk sizes.
        Paths under your home folder are shown with `~`.

        """
        for part in parts {
            let total = part.groups.reduce(0) { $0 + $1.size }
            let picked = part.groups.flatMap(\.items).filter { part.selected.contains($0.id) }
            out += "\n## \(part.section.title): \(bytes(total)) found, \(bytes(picked.reduce(0) { $0 + $1.size })) selected\n"
            if part.groups.isEmpty { out += "\nNothing found.\n" }
            for group in part.groups {
                out += "\n### \(group.title) (\(group.items.count) items, \(bytes(group.size)))\n\n"
                for item in group.items {
                    let mark = part.selected.contains(item.id) ? "x" : " "
                    let path = Scanner.tilde(item.url)
                    // Only repeat the detail line when it says more than the parent folder.
                    let detail = item.detail == Scanner.tilde(item.url.deletingLastPathComponent()) ? "" : " · \(item.detail)"
                    out += "- [\(mark)] \(bytes(item.size)) · `\(path)`\(detail)\n"
                }
            }
        }
        return out
    }

    static func defaultURL() -> URL {
        let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
            .replacingOccurrences(of: ":", with: "-")
        return Scanner.home.appendingPathComponent("Desktop/MacSweep Report \(stamp).md")
    }

    /// Asks where to save, writes the report, then reveals it in Finder.
    @MainActor
    static func save(_ parts: [Part]) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = defaultURL().lastPathComponent
        panel.directoryURL = defaultURL().deletingLastPathComponent()
        panel.allowedContentTypes = [.init(filenameExtension: "md")!]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? markdown(parts).write(to: url, atomically: true, encoding: .utf8)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
