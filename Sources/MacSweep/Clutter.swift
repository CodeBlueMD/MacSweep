import CryptoKit
import Foundation

extension Scanner {
    static let codeFolders: Set<String> = ["node_modules", ".git", ".venv", "venv", "site-packages", "Pods", ".build",
                                           "DerivedData", "build", "dist", "target", ".gradle", "vendor"]

    /// Identical files (same size, then same SHA-256) in your personal folders. Each group lists only the
    /// extra copies; the oldest copy is kept and named in the group title, so ticking a whole group is safe.
    static func scanDuplicates(minBytes: Int = 1_000_000) -> [ItemGroup] {
        struct Candidate { let url: URL; let created: Date; let cloneID: Int64? }
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .creationDateKey, .fileContentIdentifierKey]
        let roots = ["Desktop", "Documents", "Downloads", "Pictures", "Movies", "Music"].map { home.appendingPathComponent($0) }

        var bySize: [Int: [Candidate]] = [:]
        for root in roots {
            guard let e = fm.enumerator(at: root, includingPropertiesForKeys: keys,
                                        options: [.skipsPackageDescendants, .skipsHiddenFiles], errorHandler: { _, _ in true }) else { continue }
            for case let f as URL in e {
                // Identical files inside code dependencies are expected; removing one breaks the project.
                if codeFolders.contains(f.lastPathComponent) { e.skipDescendants(); continue }
                guard let v = try? f.resourceValues(forKeys: Set(keys)), v.isRegularFile == true,
                      let size = v.fileSize, size >= minBytes else { continue }
                bySize[size, default: []].append(Candidate(url: f, created: v.creationDate ?? .distantPast, cloneID: v.fileContentIdentifier))
            }
        }

        var groups: [ItemGroup] = []
        for (size, files) in bySize where files.count > 1 {
            var byHash: [String: [Candidate]] = [:]
            for f in files { if let h = sha256(f.url) { byHash[h, default: []].append(f) } }
            for (hash, same) in byHash where same.count > 1 {
                let sorted = same.sorted { $0.created < $1.created }
                let original = sorted[0]
                // APFS clones share their data blocks, so trashing one frees nothing; leave them out.
                var seenClones = Set([original.cloneID].compactMap { $0 })
                let copies = sorted.dropFirst().filter { c in
                    guard let id = c.cloneID else { return true }
                    return seenClones.insert(id).inserted
                }
                guard !copies.isEmpty else { continue }
                groups.append(ItemGroup(
                    id: "dup:\(hash)",
                    title: "\(original.url.lastPathComponent) — keeping \(tilde(original.url.deletingLastPathComponent()))",
                    icon: "doc.on.doc",
                    items: copies.map {
                        CleanItem(url: $0.url, title: $0.url.lastPathComponent,
                                  detail: "Copy in \(tilde($0.url.deletingLastPathComponent()))", size: Int64(size))
                    }))
            }
        }
        return groups.sorted { $0.size > $1.size }
    }

    static func sha256(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
