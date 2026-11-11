import AppKit
import SwiftUI

enum Page: Hashable {
    case smartCare
    case area(Section)
    case spaceMap
    case maintenance

    /// Rail order; `nil` draws a divider.
    static let rail: [Page?] = [.smartCare, nil, .area(.junk), .area(.apps), .area(.agents), .maintenance, nil,
                                .area(.large), .area(.duplicates), .spaceMap]

    var title: String {
        switch self {
        case .smartCare: "Smart Care"
        case .area(let s): s.title
        case .spaceMap: "Space Map"
        case .maintenance: "Maintenance"
        }
    }

    var icon: String {
        switch self {
        case .smartCare: "sparkles"
        case .area(let s): s.icon
        case .spaceMap: "chart.pie"
        case .maintenance: "wrench.and.screwdriver"
        }
    }

    var colors: [Color] {
        switch self {
        case .smartCare: [Color(red: 0.62, green: 0.30, blue: 0.85), Color(red: 0.10, green: 0.12, blue: 0.42)]
        case .area(let s): s.colors
        case .spaceMap: [Color(red: 0.20, green: 0.55, blue: 0.95), Color(red: 0.08, green: 0.10, blue: 0.36)]
        case .maintenance: [Color(red: 0.95, green: 0.62, blue: 0.20), Color(red: 0.42, green: 0.16, blue: 0.20)]
        }
    }
}

// MARK: - Shell

struct ContentView: View {
    @ObservedObject var store: Store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 0) {
            Rail(store: store)
                .frame(width: 84)
                .background(.black.opacity(0.22))
                .zIndex(1) // hover labels extend over the page, so the rail draws on top
            Group {
                switch store.page {
                case .smartCare:
                    SmartCareView(store: store, page: $store.page)
                case .area(let s):
                    SectionView(model: store.model(s)).id(s)
                case .spaceMap:
                    SpaceMapView(model: store.spaceMap)
                case .maintenance:
                    MaintenanceView(store: store)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background {
            LinearGradient(colors: store.page.colors, startPoint: .topLeading, endPoint: .bottomTrailing)
                .overlay(RadialGradient(colors: [.white.opacity(0.12), .clear], center: .top, startRadius: 0, endRadius: 600))
                .animation(.easeInOut(duration: 0.5), value: store.page)
        }
        .ignoresSafeArea()
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .onAppear {
            // `-startPage <name>` opens a page (and scans it, for sections); used for screenshots.
            switch UserDefaults.standard.string(forKey: "startPage") {
            case "spaceMap": store.page = .spaceMap; store.spaceMap.load()
            case "maintenance": store.page = .maintenance
            case let raw?:
                if let s = Section(rawValue: raw) { store.page = .area(s); store.model(s).scan() }
            case nil: break
            }
            if UserDefaults.standard.string(forKey: "tour") != nil {
                Task { await Tour.run(store: store, openWindow: openWindow) }
            }
        }
    }
}

/// Icon-only navigation rail; titles appear in a hover label.
struct Rail: View {
    @ObservedObject var store: Store

    var body: some View {
        VStack(spacing: 6) {
            ForEach(Array(Page.rail.enumerated()), id: \.offset) { _, page in
                if let page {
                    if case .area(let s) = page {
                        RailAreaButton(page: page, model: store.model(s), selected: $store.page,
                                       forceLabel: store.tourLabel == page)
                    } else {
                        RailButton(page: page, selected: $store.page, forceLabel: store.tourLabel == page)
                    }
                } else {
                    Capsule().fill(.white.opacity(0.15)).frame(width: 28, height: 1).padding(.vertical, 6)
                }
            }
            Spacer()
            RailSystemGauges(store: store).padding(.bottom, 18)
        }
        .padding(.top, 52) // room for the window's traffic lights
    }
}

struct RailAreaButton: View {
    let page: Page
    @ObservedObject var model: SectionModel
    @Binding var selected: Page
    var forceLabel = false

    var body: some View {
        RailButton(page: page, selected: $selected, busy: model.scanning,
                   badge: model.scanned && model.selectedSize > 0, forceLabel: forceLabel)
    }
}

struct RailButton: View {
    let page: Page
    @Binding var selected: Page
    var busy = false
    var badge = false
    /// Shows the hover label without a pointer; used by the UI tour.
    var forceLabel = false
    @State private var hovering = false

    var body: some View {
        let isSelected = selected == page
        Button { selected = page } label: {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isSelected ? AnyShapeStyle(.white.opacity(0.22)) : AnyShapeStyle(.white.opacity(hovering ? 0.1 : 0)))
                    .frame(width: 52, height: 52)
                    .overlay(
                        Image(systemName: page.icon)
                            .font(.system(size: 21, weight: .semibold))
                            .foregroundStyle(isSelected
                                ? AnyShapeStyle(LinearGradient(colors: [.white, page.colors[0].opacity(0.9)], startPoint: .top, endPoint: .bottom))
                                : AnyShapeStyle(.white.opacity(0.85)))
                            .shadow(color: isSelected ? page.colors[0].opacity(0.8) : .clear, radius: 8)
                    )
                if busy {
                    ProgressView().controlSize(.mini).offset(x: 4, y: -4)
                } else if badge {
                    Circle().fill(page.colors[0]).overlay(Circle().strokeBorder(.white, lineWidth: 1.5))
                        .frame(width: 11, height: 11).offset(x: 2, y: -2)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .overlay(alignment: .leading) {
            if hovering || forceLabel {
                Text(page.title)
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(.black.opacity(0.75)))
                    .fixedSize()
                    .offset(x: 62)
                    .allowsHitTesting(false)
            }
        }
        .zIndex(hovering || forceLabel ? 1 : 0)
    }
}

/// Ring showing how full the startup disk is.
struct DiskGauge: View {
    var body: some View {
        let v = try? Scanner.home.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
        let total = Int64(v?.volumeTotalCapacity ?? 0)
        let free = v?.volumeAvailableCapacityForImportantUsage ?? 0
        let used = total > 0 ? Double(total - free) / Double(total) : 0
        VStack(spacing: 3) {
            ZStack {
                Circle().stroke(.white.opacity(0.15), lineWidth: 3.5)
                Circle().trim(from: 0, to: used).stroke(.white.opacity(0.85), style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: "internaldrive").font(.system(size: 11))
            }
            .frame(width: 34, height: 34)
            Text(bytes(free)).font(.system(size: 8, weight: .semibold).monospacedDigit()).opacity(0.75)
            Text("free").font(.system(size: 8)).opacity(0.55)
        }
        .help("\(bytes(free)) available of \(bytes(total))")
    }
}

/// Rail status gauges displaying real-time Disk, RAM pressure, and CPU load.
struct RailSystemGauges: View {
    @ObservedObject var store: Store

    var body: some View {
        Button {
            store.page = .maintenance
        } label: {
            VStack(spacing: 10) {
                DiskGauge()

                // Real-time animated RAM mini gauge
                AnimatedPressureGauge(
                    title: "RAM",
                    subtitle: "",
                    value: Double(store.health.memoryPressure) / 100.0,
                    displayPercent: store.health.memoryPressure,
                    size: 34,
                    showDetail: false
                )
                .help("RAM Memory Pressure: \(store.health.memoryPressure)%. Click to open Maintenance.")

                // Real-time animated CPU mini gauge
                AnimatedPressureGauge(
                    title: "CPU",
                    subtitle: "",
                    value: store.health.cpuLoad,
                    displayPercent: Int(store.health.cpuLoad * 100),
                    size: 34,
                    showDetail: false
                )
                .help("CPU Load: \(Int(store.health.cpuLoad * 100))%. Click to open Maintenance.")
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Building blocks

struct IconTile: View {
    let symbol: String
    let colors: [Color]
    var size: CGFloat = 28

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
            .overlay(Image(systemName: symbol).font(.system(size: size * 0.5, weight: .semibold)).foregroundStyle(.white))
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.25), radius: size * 0.08, y: size * 0.04)
    }
}

/// The large glowing emblem shown at the centre of each page.
struct HeroIcon: View {
    let symbol: String
    var size: CGFloat = 150
    var spinning = false
    @State private var angle = 0.0
    @State private var breathe = false

    var body: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [.white.opacity(0.35), .clear], center: .center, startRadius: 0, endRadius: size))
                .frame(width: size * 2, height: size * 2)
                .scaleEffect(breathe ? 1.08 : 0.94)
                .animation(.easeInOut(duration: 2.4).repeatForever(), value: breathe)
            RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                .fill(LinearGradient(colors: [.white.opacity(0.45), .white.opacity(0.12)], startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: size * 0.3, style: .continuous).strokeBorder(.white.opacity(0.5), lineWidth: 1))
                .frame(width: size, height: size)
                .shadow(color: .black.opacity(0.3), radius: 20, y: 12)
            Image(systemName: symbol)
                .font(.system(size: size * 0.46, weight: .semibold))
                .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
            if spinning {
                Circle()
                    .trim(from: 0, to: 0.72)
                    .stroke(AngularGradient(colors: [.clear, .white], center: .center), style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .frame(width: size * 1.45, height: size * 1.45)
                    .rotationEffect(.degrees(angle))
                    .animation(.linear(duration: 1.1).repeatForever(autoreverses: false), value: angle)
            }
        }
        .frame(width: size * 1.6, height: size * 1.6)
        // Animations are attached to the glow and ring only; a withAnimation here would also
        // loop any layout change made during the first frame.
        .onAppear {
            breathe = true
            angle = 360
        }
    }
}

/// Round primary action button, used for Scan and Clean.
struct BigButton: View {
    let title: String
    var subtitle: String? = nil
    var enabled = true
    let action: () -> Void
    @State private var hovering = false
    @State private var pulse = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .stroke(.white.opacity(pulse ? 0 : 0.35), lineWidth: 2)
                    .scaleEffect(pulse ? 1.35 : 1)
                    .animation(.easeOut(duration: 1.8).repeatForever(autoreverses: false), value: pulse)
                Circle().fill(.white.opacity(hovering ? 0.26 : 0.18))
                Circle().strokeBorder(LinearGradient(colors: [.white.opacity(0.9), .white.opacity(0.25)], startPoint: .top, endPoint: .bottom),
                                      lineWidth: 2.5)
                VStack(spacing: 2) {
                    Text(title).font(.system(size: 20, weight: .bold, design: .rounded))
                    if let subtitle { Text(subtitle).font(.caption.monospacedDigit()).opacity(0.8) }
                }
            }
            .frame(width: 108, height: 108)
            .shadow(color: .white.opacity(hovering ? 0.35 : 0.15), radius: hovering ? 22 : 12)
            .scaleEffect(hovering && enabled ? 1.05 : 1)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .onHover { h in withAnimation(.spring(duration: 0.25)) { hovering = h } }
        .onAppear { pulse = true }
    }
}

struct PillButton: View {
    let title: String
    var icon: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label { Text(title) } icon: { if let icon { Image(systemName: icon) } }
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(Capsule().fill(.white.opacity(0.16)))
                .overlay(Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }
}

enum CheckState { case on, off, mixed }

struct CheckCircle: View {
    let state: CheckState
    var size: CGFloat = 20

    var body: some View {
        ZStack {
            Circle().strokeBorder(.white.opacity(0.7), lineWidth: 1.5)
            if state != .off {
                Circle().fill(.white)
                Image(systemName: state == .on ? "checkmark" : "minus")
                    .font(.system(size: size * 0.5, weight: .heavy))
                    .foregroundStyle(.black.opacity(0.75))
            }
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
    }
}

struct Card<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white.opacity(0.09)))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
    }
}

struct FullDiskAccessBanner: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.shield.fill")
            Text("Allow Full Disk Access to also clean app containers.").font(.callout)
            PillButton(title: "Open Settings") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Capsule().fill(.black.opacity(0.22)))
    }
}

// MARK: - Section page

struct SectionView: View {
    @ObservedObject var model: SectionModel
    @State private var confirming = false

    var body: some View {
        Group {
            if model.scanning {
                ScanningState(symbol: model.section.icon, title: "Scanning \(model.section.title)…")
            } else if !model.scanned {
                IdleState(symbol: model.section.icon, title: model.section.title, subtitle: model.section.subtitle,
                          showFDA: model.section.needsFullDiskAccess && !Scanner.hasFullDiskAccess) { model.scan() }
            } else if model.groups.isEmpty {
                IdleState(symbol: "checkmark.seal.fill", title: "All clear", subtitle: model.status ?? "Nothing to clean here right now.",
                          buttonTitle: "Rescan", showFDA: false) { model.scan() }
            } else {
                results
            }
        }
        .transition(.opacity)
        .animation(.easeInOut(duration: 0.3), value: model.scanning)
        .confirmationDialog("Move \(model.selectedItems.count) item(s), \(bytes(model.selectedSize)), to the Trash?",
                            isPresented: $confirming) {
            Button("Move to Trash", role: .destructive) { model.clean() }
        } message: {
            Text("You can restore them from the Trash until you empty it. Quit affected apps first.")
        }
    }

    private var results: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                IconTile(symbol: model.section.icon, colors: [.white.opacity(0.4), .white.opacity(0.1)], size: 58)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.section.title).font(.headline).opacity(0.8)
                    Text("\(bytes(model.totalSize)) found")
                        .font(.system(size: 30, weight: .bold, design: .rounded)).monospacedDigit()
                    Text("\(model.groups.flatMap(\.items).count) items in \(model.groups.count) groups").font(.callout).opacity(0.7)
                }
                Spacer()
                // Selecting every app at once is never what anyone wants from an uninstaller.
                if model.section != .apps {
                    PillButton(title: "Select All", icon: "checklist") {
                        model.selected = Set(model.groups.flatMap(\.items).filter { $0.tier != .protected }.map(\.id))
                    }
                }
                PillButton(title: "Deselect", icon: "circle") { model.selected = [] }
                PillButton(title: "Rescan", icon: "arrow.clockwise") { model.scan() }
                PillButton(title: "Export", icon: "square.and.arrow.up") { Report.save([model.reportPart]) }
            }
            .padding(.horizontal, 32).padding(.top, 44).padding(.bottom, 16)

            if model.section.needsFullDiskAccess && !Scanner.hasFullDiskAccess {
                FullDiskAccessBanner().padding(.bottom, 10)
            }

            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(model.groups) { GroupCard(group: $0, model: model) }
                }
                .padding(.horizontal, 32).padding(.bottom, 20)
            }
            .scrollIndicators(.never)
            .mask(LinearGradient(stops: [.init(color: .black, location: 0.92), .init(color: .clear, location: 1)],
                                 startPoint: .top, endPoint: .bottom))

            VStack(spacing: 8) {
                if let status = model.status {
                    Label(status, systemImage: "checkmark.circle.fill").font(.callout)
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        .background(Capsule().fill(.black.opacity(0.22)))
                }
                BigButton(title: "Clean", subtitle: bytes(model.selectedSize), enabled: !model.selected.isEmpty) {
                    confirming = true
                }
            }
            .padding(.vertical, 18)
        }
    }
}

struct IdleState: View {
    let symbol: String
    let title: String
    let subtitle: String
    var buttonTitle = "Scan"
    let showFDA: Bool
    let action: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            HeroIcon(symbol: symbol)
            Text(title).font(.system(size: 36, weight: .bold, design: .rounded)).padding(.top, 4)
            Text(subtitle).font(.title3).multilineTextAlignment(.center).opacity(0.8)
                .frame(maxWidth: 520).padding(.top, 8)
            if showFDA { FullDiskAccessBanner().padding(.top, 18) }
            Spacer()
            BigButton(title: buttonTitle, action: action)
            Spacer().frame(height: 48)
        }
        .padding(.horizontal, 32)
    }
}

struct ScanningState: View {
    let symbol: String
    let title: String

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            HeroIcon(symbol: symbol, spinning: true)
            Text(title).font(.system(size: 28, weight: .bold, design: .rounded)).padding(.top, 8)
            Text("This can take a minute on a full disk.").opacity(0.7).padding(.top, 6)
            Spacer()
            Spacer().frame(height: 156)
        }
    }
}

struct GroupCard: View {
    let group: ItemGroup
    @ObservedObject var model: SectionModel
    @State private var expanded = false

    private var state: CheckState {
        let n = group.items.filter { model.selected.contains($0.id) }.count
        return n == 0 ? .off : n == group.items.count ? .on : .mixed
    }

    var body: some View {
        Card {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    CheckCircle(state: state).onTapGesture { toggleAll() }
                    if let path = group.iconPath {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().frame(width: 34, height: 34)
                    } else {
                        IconTile(symbol: group.icon, colors: [.white.opacity(0.35), .white.opacity(0.1)], size: 34)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(group.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                            if group.tier == .protected {
                                Text("Protected")
                                    .font(.system(size: 9, weight: .bold))
                                    .padding(.horizontal, 5).padding(.vertical, 1.5)
                                    .background(Capsule().fill(.orange.opacity(0.2)))
                                    .foregroundStyle(.orange)
                            } else if group.tier == .costlyToRebuild {
                                Text("Costly to Rebuild")
                                    .font(.system(size: 9, weight: .semibold))
                                    .padding(.horizontal, 5).padding(.vertical, 1.5)
                                    .background(Capsule().fill(.purple.opacity(0.25)))
                                    .foregroundStyle(.purple.opacity(0.95))
                            }
                        }
                        Text("\(group.items.count) item\(group.items.count == 1 ? "" : "s")").font(.caption).opacity(0.65)
                    }
                    Spacer()
                    Text(bytes(group.size)).font(.system(size: 14, weight: .semibold).monospacedDigit())
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .bold)).opacity(0.6)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                .contentShape(Rectangle())
                .onTapGesture { withAnimation(.spring(duration: 0.3)) { expanded.toggle() } }

                if expanded {
                    Divider().overlay(.white.opacity(0.15))
                    VStack(spacing: 0) {
                        ForEach(group.items) { ItemRow(item: $0, model: model) }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private func toggleAll() {
        let ids = group.items.filter { $0.tier != .protected }.map(\.id)
        if state == .on { model.selected.subtract(ids) } else { model.selected.formUnion(ids) }
    }
}

struct ItemRow: View {
    let item: CleanItem
    @ObservedObject var model: SectionModel
    @State private var hovering = false

    var body: some View {
        let on = model.selected.contains(item.id)
        HStack(spacing: 12) {
            CheckCircle(state: on ? .on : .off, size: 16)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.title).font(.system(size: 13)).lineLimit(1)
                    if let app = item.inUseBy {
                        Text("In Use by \(app)")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill(.orange.opacity(0.2)))
                    } else if item.tier == .costlyToRebuild {
                        Text("Costly to Rebuild")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.purple.opacity(0.95))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill(.purple.opacity(0.22)))
                    }
                }
                Text(item.detail).font(.caption).opacity(0.6).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
            } label: {
                Image(systemName: "magnifyingglass").opacity(hovering ? 0.9 : 0)
            }
            .buttonStyle(.plain)
            .help("Show in Finder")
            Text(bytes(item.size)).font(.system(size: 12).monospacedDigit()).opacity(0.8)
        }
        .padding(.horizontal, 16).padding(.leading, 30).padding(.vertical, 6)
        .background(hovering ? Color.white.opacity(0.06) : .clear)
        .contentShape(Rectangle())
        .onTapGesture {
            if on { model.selected.remove(item.id) } else if item.tier != .protected { model.selected.insert(item.id) }
        }
        .onHover { hovering = $0 }
    }
}

// MARK: - Smart Care

struct SmartCareView: View {
    let store: Store
    @Binding var page: Page
    @ObservedObject private var junk: SectionModel
    @ObservedObject private var large: SectionModel
    @ObservedObject private var apps: SectionModel
    @ObservedObject private var agents: SectionModel
    @ObservedObject private var duplicates: SectionModel
    @State private var confirming = false

    init(store: Store, page: Binding<Page>) {
        self.store = store
        _page = page
        junk = store.model(.junk)
        large = store.model(.large)
        apps = store.model(.apps)
        agents = store.model(.agents)
        duplicates = store.model(.duplicates)
    }

    private var all: [SectionModel] { [junk, apps, agents, large, duplicates] }
    private var scanning: Bool { all.contains(where: \.scanning) }
    private var scanned: Bool { all.allSatisfy(\.scanned) }
    private var selectedSize: Int64 { all.reduce(0) { $0 + $1.selectedSize } }
    private var selectedCount: Int { all.reduce(0) { $0 + $1.selectedItems.count } }

    var body: some View {
        Group {
            if scanning {
                ScanningState(symbol: "sparkles", title: "Running Smart Care…")
            } else if !scanned {
                IdleState(symbol: "sparkles", title: "Smart Care",
                          subtitle: "Scan junk, apps, login helpers, large files and duplicates in one go, then clean the safe items with one click.",
                          showFDA: !Scanner.hasFullDiskAccess) { scanAll() }
            } else {
                results
            }
        }
        .animation(.easeInOut(duration: 0.3), value: scanning)
        .confirmationDialog("Move \(selectedCount) item(s), \(bytes(selectedSize)), to the Trash?", isPresented: $confirming) {
            Button("Move to Trash", role: .destructive) {
                for m in all where !m.selected.isEmpty { m.clean() }
            }
        } message: {
            Text("This cleans what is selected in each section. You can restore items from the Trash.")
        }
    }

    private func scanAll() { for m in all { m.scan() } }

    private var results: some View {
        VStack(spacing: 0) {
            VStack(spacing: 4) {
                Text("Smart Care").font(.headline).opacity(0.8)
                Text("\(bytes(selectedSize)) ready to clean")
                    .font(.system(size: 34, weight: .bold, design: .rounded)).monospacedDigit()
                Text("Large files, duplicates and apps are never selected for you. Open them to review.").font(.callout).opacity(0.7)
            }
            .padding(.top, 48).padding(.bottom, 24)

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)], spacing: 16) {
                ForEach(all, id: \.section) { m in
                    Tile(model: m) { page = .area(m.section) }
                }
            }
            .padding(.horizontal, 40)

            Spacer()
            HStack(spacing: 24) {
                PillButton(title: "Rescan", icon: "arrow.clockwise") { scanAll() }
                BigButton(title: "Clean", subtitle: bytes(selectedSize), enabled: selectedSize > 0) { confirming = true }
                PillButton(title: "Export Report", icon: "square.and.arrow.up") { Report.save(all.map(\.reportPart)) }
            }
            .padding(.bottom, 36)
        }
    }

    struct Tile: View {
        @ObservedObject var model: SectionModel
        let open: () -> Void
        @State private var hovering = false

        var body: some View {
            Button(action: open) {
                Card {
                    HStack(spacing: 14) {
                        IconTile(symbol: model.section.icon, colors: model.section.colors, size: 48)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(model.section.title).font(.system(size: 15, weight: .semibold))
                            Text(model.groups.isEmpty ? "Nothing found" : "\(bytes(model.totalSize)) found")
                                .font(.callout).opacity(0.75)
                            Text(model.selected.isEmpty ? "Nothing selected" : "\(bytes(model.selectedSize)) selected")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 8).padding(.vertical, 2)
                                .background(Capsule().fill(.white.opacity(model.selected.isEmpty ? 0.08 : 0.22)))
                        }
                        Spacer()
                        Image(systemName: "chevron.right").opacity(hovering ? 0.9 : 0.4)
                    }
                    .padding(16)
                }
                .scaleEffect(hovering ? 1.015 : 1)
            }
            .buttonStyle(.plain)
            .onHover { h in withAnimation(.spring(duration: 0.25)) { hovering = h } }
        }
    }
}
