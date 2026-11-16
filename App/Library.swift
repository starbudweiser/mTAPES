// mTAPES — bibliothèque des prises (mode Avancé) : liste à gauche, détail et exports à droite. Maquette 1.
import SwiftUI
import AVKit

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
    var audio: [String]
    var color: String
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
                                   state: meta.state ?? "complete", sourceKind: meta.source.kind, windowTitle: meta.source.windowTitle ?? "", marks: marks, audio: (meta.audio ?? []).map { $0.kind }, color: meta.colorSpace ?? "srgb", exports: exports))
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
                    Spacer(minLength: Socle.M.space4)
                    Button(L.t("lib.trash")) { store.trash(item); selection = nil }.buttonStyle(TrashButtonStyle()).fixedSize()
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
                    fact(L.t("lib.color"), item.color == "p3" ? "Display P3" : "sRGB")
                    fact(L.t("lib.audio"), item.audio.isEmpty ? L.t("lib.audio.none") : item.audio.map { L.t("lib.audio." + $0) }.joined(separator: " + "))
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
            .padding(.horizontal, Socle.M.space4)
            .padding(.vertical, Socle.M.space5)
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
    @State private var player: AVPlayer?
    @State private var loadingPreview = false
    @State private var audioKinds: [String] = []

    private var package: TapePackage { TapePackage(url: url) }

    var body: some View {
        VStack(alignment: .leading, spacing: Socle.M.space3) {
            Text(L.t("ed.title")).socle(Socle.T.title).foregroundStyle(Socle.C.textStrong)
            HStack(spacing: Socle.M.space2) {
                if player != nil {
                    Button(L.t("ed.preview.refresh")) { startPreview() }.buttonStyle(SocleButtonStyle(.secondary, height: 28)).fixedSize()
                    Button(L.t("ed.preview.close")) { player?.pause(); player = nil }.buttonStyle(SocleButtonStyle(.secondary, height: 28)).fixedSize()
                } else {
                    Button(L.t("ed.preview")) { startPreview() }.buttonStyle(SocleButtonStyle(.secondary, height: 28)).fixedSize().disabled(loadingPreview || spec == nil)
                }
                Spacer(minLength: Socle.M.space3)
                Button(L.t("ed.recompute")) { recompute() }.buttonStyle(SocleButtonStyle(.secondary, height: 28)).fixedSize()
            }
            if let error { Text(error).socle(Socle.T.meta).foregroundStyle(Socle.C.danger).fixedSize(horizontal: false, vertical: true) }
            if let player {
                PreviewPlayer(player: player)
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: Socle.M.radiusMd, style: .continuous))
            }
            if let spec {
                group(L.t("ed.zooms"), empty: spec.zooms.isEmpty, add: { edit { $0.zooms.append(.init(t0: 0, t1: min(2, seconds), scale: 1.8, fx: 0.5, fy: 0.5, source: "manual")) } }) {
                    ForEach(Array(spec.zooms.enumerated()), id: \.offset) { i, z in
                        HStack(spacing: Socle.M.space2) {
                            num(L.t("ed.f.from"), z.t0) { v in edit { if $0.zooms.indices.contains(i) { $0.zooms[i].t0 = clampT(v, below: $0.zooms[i].t1) ; $0.zooms[i].source = "manual" } } }
                            num(L.t("ed.f.to"), z.t1) { v in edit { if $0.zooms.indices.contains(i) { $0.zooms[i].t1 = clampT(v, above: $0.zooms[i].t0); $0.zooms[i].source = "manual" } } }
                            num(L.t("ed.f.scale"), z.scale) { v in edit { if $0.zooms.indices.contains(i) { $0.zooms[i].scale = min(3, max(1.1, v)); $0.zooms[i].source = "manual" } } }
                            num("x", z.fx) { v in edit { if $0.zooms.indices.contains(i) { $0.zooms[i].fx = min(1, max(0, v)); $0.zooms[i].source = "manual" } } }
                            num("y", z.fy) { v in edit { if $0.zooms.indices.contains(i) { $0.zooms[i].fy = min(1, max(0, v)); $0.zooms[i].source = "manual" } } }
                            SocleChip(text: L.t("ed.by." + (["auto", "ai", "manual"].contains(z.source) ? z.source : "manual")))
                            Spacer(minLength: 0)
                            deleteButton { edit { $0.zooms.remove(at: i) } }
                        }
                    }
                }
                group(L.t("ed.speeds"), empty: spec.speeds.isEmpty, add: { edit { $0.speeds.append(.init(t0: 0, t1: min(2, seconds), factor: 4)) } }) {
                    ForEach(Array(spec.speeds.enumerated()), id: \.offset) { i, v in
                        HStack(spacing: Socle.M.space2) {
                            num(L.t("ed.f.from"), v.t0) { x in edit { if $0.speeds.indices.contains(i) { $0.speeds[i].t0 = clampT(x, below: $0.speeds[i].t1) } } }
                            num(L.t("ed.f.to"), v.t1) { x in edit { if $0.speeds.indices.contains(i) { $0.speeds[i].t1 = clampT(x, above: $0.speeds[i].t0) } } }
                            num(L.t("ed.f.factor"), v.factor) { x in edit { if $0.speeds.indices.contains(i) { $0.speeds[i].factor = min(16, max(0.25, x)) } } }
                            Spacer(minLength: 0)
                            deleteButton { edit { $0.speeds.remove(at: i) } }
                        }
                    }
                }
                group(L.t("ed.captions"), empty: spec.captions.isEmpty, add: { edit { $0.captions.append(.init(t0: 0, t1: min(2, seconds), text: L.t("ed.newcaption"))) } }) {
                    ForEach(Array(spec.captions.enumerated()), id: \.offset) { i, c in
                        VStack(alignment: .leading, spacing: Socle.M.space1_5) {
                            HStack(spacing: Socle.M.space2) {
                                num(L.t("ed.f.from"), c.t0) { x in edit { if $0.captions.indices.contains(i) { $0.captions[i].t0 = clampT(x, below: $0.captions[i].t1) } } }
                                num(L.t("ed.f.to"), c.t1) { x in edit { if $0.captions.indices.contains(i) { $0.captions[i].t1 = clampT(x, above: $0.captions[i].t0) } } }
                                Spacer(minLength: 0)
                                deleteButton { edit { $0.captions.remove(at: i) } }
                            }
                            TextField("", text: Binding(get: { c.text }, set: { v in edit { if $0.captions.indices.contains(i) { $0.captions[i].text = String(v.prefix(80)) } } }))
                                .textFieldStyle(.plain).socle(Socle.T.body).modifier(SocleField(multiline: false))
                                .accessibilityLabel(L.t("ed.captions") + " " + time(c.t0))
                        }
                    }
                }
                if !audioKinds.isEmpty {
                    let a = spec.audio ?? FinishingSpec.Audio()
                    VStack(alignment: .leading, spacing: Socle.M.space1_5) {
                        HStack {
                            Text(L.t("ed.audio")).socle(Socle.T.label).foregroundStyle(Socle.C.textMuted)
                            Spacer()
                        }
                        .overlay(alignment: .trailing) {
                            Toggle("", isOn: Binding(get: { a.enabled }, set: { v in edit { var x = $0.audio ?? .init(); x.enabled = v; $0.audio = x } }))
                                .toggleStyle(.switch).tint(Socle.C.accentFill).labelsHidden().accessibilityLabel(L.t("ed.audio.keep"))
                        }
                        if a.enabled {
                            HStack(spacing: Socle.M.space2) {
                                if audioKinds.contains("mic") { num(L.t("ed.audio.mic"), a.micGain) { v in edit { var x = $0.audio ?? .init(); x.micGain = min(2, max(0, v)); $0.audio = x } } }
                                if audioKinds.contains("system") { num(L.t("ed.audio.system"), a.systemGain) { v in edit { var x = $0.audio ?? .init(); x.systemGain = min(2, max(0, v)); $0.audio = x } } }
                                Spacer(minLength: 0)
                            }
                            Text(L.t("ed.audio.hint")).socle(Socle.T.meta).foregroundStyle(Socle.C.textSubtle).fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text(L.t("ed.audio.off")).socle(Socle.T.meta).foregroundStyle(Socle.C.textSubtle)
                        }
                    }
                }
                Text(L.t("ed.hint")).socle(Socle.T.meta).foregroundStyle(Socle.C.textSubtle).fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear(perform: load)
    }

    private func group<C: View>(_ title: String, empty: Bool, add: @escaping () -> Void, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: Socle.M.space1_5) {
            HStack {
                Text(title).socle(Socle.T.label).foregroundStyle(Socle.C.textMuted)
                Spacer()
                Button(L.t("ed.add")) { add() }.buttonStyle(SocleButtonStyle(.tertiary, height: 26)).fixedSize().accessibilityLabel(L.t("ed.add") + " " + title)
                    .padding(.trailing, -Socle.M.space4)                         // le texte s'aligne sur la marge droite
            }
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
            .padding(.trailing, -Socle.M.space4)
    }

    /// Champ numérique compact (secondes, échelle, facteur…), validé à la fin de la saisie.
    private func num(_ label: String, _ value: Double, _ set: @escaping (Double) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).socle(Socle.T.meta).foregroundStyle(Socle.C.textSubtle)
            NumField(value: value, label: label, set: set)
        }
    }

    private func clampT(_ v: Double, below end: Double? = nil, above start: Double? = nil) -> Double {
        var t = min(max(0, v), seconds)
        if let end { t = min(t, max(0, end - 0.5)) }
        if let start { t = max(t, min(seconds, start + 0.5)) }
        return t
    }

    private func fmt(_ v: Double) -> String { String(format: "%.1f", locale: L.locale, v) }
    private func time(_ t: Double) -> String {
        let m = Int(t) / 60, sec = t - Double(m * 60)
        return "\(m):" + (sec < 10 ? "0" : "") + String(format: "%.1f", locale: L.locale, sec)
    }

    private func startPreview() {
        guard let spec, !loadingPreview else { return }
        loadingPreview = true
        let pkg = package
        Task {
            do {
                let item = try await Finisher.previewItem(pkg, spec: spec)
                await MainActor.run {
                    player?.pause()
                    let p = AVPlayer(playerItem: item)
                    player = p
                    p.play()
                    loadingPreview = false
                }
            } catch {
                await MainActor.run { self.error = L.t("ed.fail", "\(error)"); loadingPreview = false }
            }
        }
    }

    private func load() {
        audioKinds = ((try? package.readMeta())?.audio ?? []).map { $0.kind }
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


private struct NumField: View {
    let value: Double
    let label: String
    let set: (Double) -> Void
    @State private var text = ""
    @State private var generation = 0                // recrée le champ après chaque validation : il relit la valeur réellement retenue (bornée)
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain).socle(Socle.T.mono).modifier(SocleField(multiline: false))
            .frame(width: 62)
            .focused($focused)
            .accessibilityLabel(label)
            .onAppear { text = format(value) }
            .onChange(of: value) { _, v in if !focused { text = format(v) } }
            .onSubmit(commit)
            .onChange(of: focused) { _, f in if !f { commit() } }
            .id(generation)
    }

    private func format(_ v: Double) -> String { String(format: "%.2f", locale: L.locale, v) }
    private func commit() {
        let cleaned = text.replacingOccurrences(of: ",", with: ".")
        if let v = Double(cleaned), format(v) != format(value) { set(v) }
        generation += 1                              // Retour : le champ affiche la valeur retenue, sans la rétablir à l'ancienne au moment de perdre le focus
    }
}

/// Lecteur vidéo natif, commandes en ligne.
private struct PreviewPlayer: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView(); v.controlsStyle = .inline; v.player = player; return v
    }
    func updateNSView(_ v: AVPlayerView, context: Context) { if v.player !== player { v.player = player } }
}

/// Bouton « Mettre à la corbeille » : rouge pastel soutenu (jetons « danger » de Socle), à droite du pied de page.
private struct TrashButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Styled(configuration: configuration)
    }
    private struct Styled: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var enabled
        @State private var hover = false
        var body: some View {
            configuration.label
                .socle(Socle.T.button)
                .foregroundStyle(Socle.C.dangerSoft)
                .padding(.horizontal, Socle.M.space4)
                .frame(minHeight: Socle.M.sizeControlLg)
                .background(Socle.C.dangerFill, in: RoundedRectangle(cornerRadius: Socle.M.radius))
                .overlay(RoundedRectangle(cornerRadius: Socle.M.radius).fill(configuration.isPressed ? Color.black.opacity(0.15) : (hover ? Color.white.opacity(0.08) : Color.clear)))
                .contentShape(Rectangle())
                .opacity(enabled ? 1 : Socle.M.opacityDisabled)
                .onHover { hover = $0 }
                .animation(.easeOut(duration: 0.15), value: hover)
        }
    }
}
