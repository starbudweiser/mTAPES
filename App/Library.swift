// mTAPES — bibliothèque des prises (mode Avancé) : liste à gauche, détail et exports à droite. Maquette 1.
import SwiftUI

struct LibraryItem: Identifiable, Equatable {
    var id: String { url.path }
    var url: URL
    var name: String
    var created: Date
    var seconds: Double
    var rawBytes: Int64
    var origin: String
    var client: String?
    var state: String
    var sourceKind: String
    var windowTitle: String
    var marks: Int
    var exports: [(name: String, bytes: Int64)]
    static func == (a: LibraryItem, b: LibraryItem) -> Bool { a.id == b.id && a.exports.count == b.exports.count && a.state == b.state }
}

@MainActor
final class TakeStore: ObservableObject {
    @Published var items: [LibraryItem] = []

    static var directory: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/mTAPES") }

    func reload() {
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(at: Self.directory, includingPropertiesForKeys: nil)) ?? []
        var out: [LibraryItem] = []
        for url in urls where url.pathExtension == "tape" {
            let package = TapePackage(url: url)
            guard let meta = try? package.readMeta() else { continue }
            let raw = (try? fm.attributesOfItem(atPath: package.rawURL.path)[.size] as? Int64) ?? 0
            let marks = ((try? EventLog.decode(Data(contentsOf: package.eventsURL))) ?? []).filter { $0.source == "declared" && $0.kind != "chapter" }.count
            let files = (try? fm.contentsOfDirectory(at: package.exportsURL, includingPropertiesForKeys: nil)) ?? []
            let exports = files.map { ($0.lastPathComponent, ((try? fm.attributesOfItem(atPath: $0.path)[.size] as? Int64) ?? 0) ?? 0) }.sorted { $0.0 < $1.0 }
            out.append(LibraryItem(url: url, name: meta.name, created: meta.created, seconds: meta.durationSeconds, rawBytes: raw, origin: meta.origin, client: meta.client,
                                   state: meta.state ?? "complete", sourceKind: meta.source.kind, windowTitle: meta.source.windowTitle ?? "", marks: marks, exports: exports))
        }
        items = out.sorted { $0.created > $1.created }
    }

    func trash(_ item: LibraryItem) {
        try? FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
        reload()
    }
}

struct LibraryView: View {
    @StateObject private var store = TakeStore()
    @ObservedObject var model: AppModel
    var preview: [LibraryItem]? = nil                 // rendu sans disque (essais)
    var flat = false                                  // rendu image : pas de ScrollView
    @State private var filter = "all"
    @State private var query = ""
    @State private var selection: String?
    @State private var status: [String: String] = [:]
    @State private var busy: Set<String> = []

    mutating func seed(selection id: String) { _selection = State(initialValue: id) }
    private var all: [LibraryItem] { preview ?? store.items }
    private var shown: [LibraryItem] {
        all.filter { item in
            (filter == "all" || (filter == "ai") == (item.origin == "mcp"))
                && (query.isEmpty || item.name.localizedCaseInsensitiveContains(query) || (item.client ?? "").localizedCaseInsensitiveContains(query))
        }
    }
    private var selected: LibraryItem? { all.first { $0.id == selection } }

    var body: some View {
        ZStack {
            Socle.C.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                topBar
                HStack(alignment: .top, spacing: 0) {
                    list.frame(width: 340)
                    Rectangle().fill(Socle.C.border).frame(width: 1)
                    detail.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
        }
        .frame(minWidth: 760, minHeight: 460)
        .onAppear { if preview == nil { store.reload() } }
    }

    private var topBar: some View {
        VStack(alignment: .leading, spacing: Socle.M.space3) {
            HStack {
                Text(branded: "mTAPES").socle(Socle.T.display).foregroundStyle(Socle.C.textStrong)
                Text(L.t("lib.title")).socle(Socle.T.heading).foregroundStyle(Socle.C.textMuted)
                Spacer()
                Button { model.start() } label: { HStack(spacing: 6) { Image(systemName: "circle.fill").font(.system(size: 9)); Text(L.t("btn.record")) } }
                    .buttonStyle(SocleButtonStyle(.action)).fixedSize().disabled(!model.canRecord || model.isBusy)
            }
            HStack(spacing: Socle.M.space3) {
                SocleSegmented(options: ["all", "manual", "ai"], selection: filter,
                               label: { $0 == "all" ? L.t("lib.all") : ($0 == "ai" ? L.t("lib.ai") : L.t("lib.manual")) }) { filter = $0 == "manual" ? "manual" : $0 }
                Spacer()
                TextField(L.t("lib.search"), text: $query).textFieldStyle(.plain).socle(Socle.T.body).modifier(SocleField(multiline: false)).frame(width: 220)
                    .accessibilityLabel(L.t("lib.search"))
            }
        }
        .padding(Socle.M.space4)
        .background(Socle.C.surface)
    }

    @ViewBuilder private var list: some View {
        if shown.isEmpty {
            Text(L.t("lib.empty")).socle(Socle.T.body).foregroundStyle(Socle.C.textSubtle).padding(Socle.M.space4).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else if flat {
            VStack(spacing: 0) { ForEach(shown) { row($0) } }.frame(maxHeight: .infinity, alignment: .top)
        } else {
            ScrollView { LazyVStack(spacing: 0) { ForEach(shown) { row($0) } } }
        }
    }

    private func row(_ item: LibraryItem) -> some View {
        let on = selection == item.id
        return Button { selection = item.id } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: Socle.M.space2) {
                    Text(item.name).socle(Socle.T.label).foregroundStyle(Socle.C.textStrong).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                HStack(spacing: Socle.M.space2) {
                    if item.origin == "mcp" { SocleChip(text: item.client.map { L.t("lib.badge.ai", $0) } ?? L.t("lib.badge.ai.plain")) }
                    Text(AppModel.clock(item.seconds)).socle(Socle.T.meta).foregroundStyle(Socle.C.textMuted)
                    Text(item.created.formatted(date: .abbreviated, time: .shortened)).socle(Socle.T.meta).foregroundStyle(Socle.C.textSubtle)
                    if item.state != "complete" { Text(item.state == "failed" ? L.t("lib.state.failed") : L.t("lib.state.recording")).socle(Socle.T.meta).foregroundStyle(Socle.C.warning) }
                }
            }
            .padding(.horizontal, Socle.M.space4).padding(.vertical, Socle.M.space2_5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(on ? Socle.C.surfaceSelected : Color.clear)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.name), \(AppModel.clock(item.seconds))")
    }

    @ViewBuilder private var detail: some View {
        if let item = selected {
            VStack(spacing: 0) {
                ScrollView { detailBody(item) }
                HStack(spacing: Socle.M.space2) {
                    Button(L.t("btn.reveal")) { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }.buttonStyle(SocleButtonStyle(.secondary)).fixedSize()
                    Button(L.t("lib.trash")) { store.trash(item); selection = nil }.buttonStyle(SocleButtonStyle(.tertiary)).fixedSize()
                    Spacer()
                }
                .padding(Socle.M.space4)
                .background(Socle.C.surface)
            }
        } else {
            Text(L.t("lib.pick")).socle(Socle.T.body).foregroundStyle(Socle.C.textSubtle).padding(Socle.M.space5)
        }
    }

    private func detailBody(_ item: LibraryItem) -> some View {
        VStack(alignment: .leading, spacing: Socle.M.space4) {
                Text(item.name).socle(Socle.T.heading).foregroundStyle(Socle.C.textStrong).fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: Socle.M.space1_5) {
                    fact(L.t("lib.src"), item.sourceKind == "display" ? L.t("lib.src.display") : L.t("lib.src.window", item.windowTitle.isEmpty ? "—" : item.windowTitle))
                    fact(L.t("lib.duration"), AppModel.clock(item.seconds))
                    fact(L.t("lib.size"), AppModel.megabytes(item.rawBytes))
                    if item.origin == "mcp" { fact(L.t("lib.marks"), "\(item.marks)") }
                }
                Text(L.t("lib.exports")).socle(Socle.T.title).foregroundStyle(Socle.C.textStrong)
                if item.exports.isEmpty { Text(L.t("lib.noexports")).socle(Socle.T.meta).foregroundStyle(Socle.C.textSubtle) }
                ForEach(item.exports, id: \.name) { e in
                    Text("\(e.name) · \(AppModel.megabytes(e.bytes))").socle(Socle.T.mono).foregroundStyle(Socle.C.accentText)
                }
                HStack(spacing: Socle.M.space2) {
                    ForEach(Destination.allCases, id: \.self) { d in
                        Button(L.t("lib.export." + d.rawValue)) { export(item, d) }
                            .buttonStyle(SocleButtonStyle(.primary, height: 30)).fixedSize().disabled(busy.contains(item.id) || item.state != "complete")
                    }
                }
                if busy.contains(item.id) { HStack(spacing: 8) { ProgressView().controlSize(.small); Text(L.t("lib.exporting")).socle(Socle.T.meta).foregroundStyle(Socle.C.textMuted) } }
                else if let s = status[item.id] { Text(s).socle(Socle.T.meta).foregroundStyle(Socle.C.textMuted).fixedSize(horizontal: false, vertical: true) }
                if preview == nil && item.state == "complete" { EditorPanel(url: item.url, seconds: item.seconds).id(item.id) }
            }
            .padding(Socle.M.space5)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func fact(_ k: String, _ v: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(k).socle(Socle.T.meta).foregroundStyle(Socle.C.textSubtle).frame(width: 130, alignment: .leading)
            Text(v).socle(Socle.T.body).foregroundStyle(Socle.C.text).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func export(_ item: LibraryItem, _ d: Destination) {
        busy.insert(item.id); status[item.id] = nil
        Task {
            do {
                let r = try await Exporter.export(TapePackage(url: item.url), destination: d)
                status[item.id] = L.t("lib.exported", URL(fileURLWithPath: r.path).lastPathComponent, String(format: "%.1f", locale: L.locale, r.megabytes))
            } catch {
                status[item.id] = L.t("lib.export.failed", "\(error)")
            }
            busy.remove(item.id)
            store.reload()
        }
    }
}


/// Retouche du montage d'une prise : zooms, accélérations et légendes (finition.json). Le brut n'est jamais touché.
struct EditorPanel: View {
    let url: URL
    let seconds: Double
    @State private var spec: FinishingSpec?
    @State private var error: String?

    private var package: TapePackage { TapePackage(url: url) }

    var body: some View {
        VStack(alignment: .leading, spacing: Socle.M.space3) {
            HStack {
                Text(L.t("ed.title")).socle(Socle.T.title).foregroundStyle(Socle.C.textStrong)
                Spacer()
                Button(L.t("ed.recompute")) { recompute() }.buttonStyle(SocleButtonStyle(.secondary, height: 28)).fixedSize()
            }
            if let error { Text(error).socle(Socle.T.meta).foregroundStyle(Socle.C.danger).fixedSize(horizontal: false, vertical: true) }
            if let spec {
                group(L.t("ed.zooms"), empty: spec.zooms.isEmpty) {
                    ForEach(Array(spec.zooms.enumerated()), id: \.offset) { i, z in
                        row(L.t("ed.zoom.row", fmt(z.scale), time(z.t0), time(z.t1)), by: z.source) { edit { $0.zooms.remove(at: i) } }
                    }
                }
                group(L.t("ed.speeds"), empty: spec.speeds.isEmpty) {
                    ForEach(Array(spec.speeds.enumerated()), id: \.offset) { i, v in
                        row(L.t("ed.speed.row", fmt(v.factor), time(v.t0), time(v.t1)), by: nil) { edit { $0.speeds.remove(at: i) } }
                    }
                }
                group(L.t("ed.captions"), empty: spec.captions.isEmpty) {
                    ForEach(Array(spec.captions.enumerated()), id: \.offset) { i, c in
                        HStack(spacing: Socle.M.space2) {
                            Text(time(c.t0)).socle(Socle.T.mono).foregroundStyle(Socle.C.textMuted).frame(width: 56, alignment: .leading)
                            TextField("", text: Binding(get: { c.text }, set: { v in edit { if $0.captions.indices.contains(i) { $0.captions[i].text = v } } }))
                                .textFieldStyle(.plain).socle(Socle.T.body).modifier(SocleField(multiline: false))
                                .accessibilityLabel(L.t("ed.captions") + " " + time(c.t0))
                            deleteButton { edit { $0.captions.remove(at: i) } }
                        }
                    }
                }
                Text(L.t("ed.hint")).socle(Socle.T.meta).foregroundStyle(Socle.C.textSubtle).fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear(perform: load)
    }

    private func group<C: View>(_ title: String, empty: Bool, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: Socle.M.space1_5) {
            Text(title).socle(Socle.T.label).foregroundStyle(Socle.C.textMuted)
            if empty { Text(L.t("ed.none")).socle(Socle.T.meta).foregroundStyle(Socle.C.textSubtle) } else { content() }
        }
    }

    private func row(_ text: String, by: String?, onDelete: @escaping () -> Void) -> some View {
        HStack(spacing: Socle.M.space2) {
            Text(text).socle(Socle.T.mono).foregroundStyle(Socle.C.text)
            if let by { SocleChip(text: L.t("ed.by." + (["auto", "ai", "manual"].contains(by) ? by : "manual"))) }
            Spacer(minLength: 0)
            deleteButton(onDelete)
        }
    }

    private func deleteButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: "trash") }
            .buttonStyle(SocleButtonStyle(.tertiary, height: 28)).fixedSize().accessibilityLabel(L.t("ed.delete"))
    }

    private func fmt(_ v: Double) -> String { String(format: "%.1f", locale: L.locale, v) }
    private func time(_ t: Double) -> String {
        let m = Int(t) / 60, sec = t - Double(m * 60)
        return "\(m):" + (sec < 10 ? "0" : "") + String(format: "%.1f", locale: L.locale, sec)
    }

    private func load() {
        do { spec = try Finisher.loadOrPlan(package, preset: .release) }
        catch { self.error = L.t("ed.fail", "\(error)") }
    }

    private func edit(_ change: (inout FinishingSpec) -> Void) {
        guard var s = spec else { return }
        change(&s)
        spec = s
        try? Finisher.save(s, to: package)
    }

    private func recompute() {
        do {
            let preset = FinishingPreset(rawValue: spec?.preset ?? "release") ?? .release
            let s = try Finisher.plan(package, preset: preset)
            try Finisher.save(s, to: package)
            spec = s
        } catch { self.error = L.t("ed.fail", "\(error)") }
    }
}
