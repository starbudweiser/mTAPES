// mTAPES — mode Simple : quoi filmer, Enregistrer. Maquette B (Socle standard). Rien n'est tronqué : le contenu défile si la place manque.
import AVFoundation
import SwiftUI

struct SimpleView: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    /// La fenêtre épouse le contenu (pas de zone vide) ; la largeur est fixe, la hauteur suit l'état.
    var body: some View {
        ZStack(alignment: .top) {
            Socle.C.bg.ignoresSafeArea()
            content
        }
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
        .background(WindowCenterer())
    }

    private var content: some View {
        VStack(spacing: Socle.M.space6) {
            header
            switch model.phase {
            case .idle: IdleBody(model: model)
            case .starting: StartingBody()
            case .recording: RecordingBody(model: model)
            case .finishing: FinishingBody()
            case .done(let s): DoneBody(model: model, summary: s)
            case .failed(let message): FailedBody(model: model, message: message)
            }
        }
        .padding(Socle.M.space6)
    }

    private var header: some View {
        HStack {
            Text(branded: "mTAPES").socle(Socle.T.display).foregroundStyle(Socle.C.textStrong)
            Spacer()
            if model.mode == .advanced {
                Button(L.t("lib.title")) { openWindow(id: "library"); NSApp.activate() }.buttonStyle(SocleButtonStyle(.tertiary, height: 28)).fixedSize()
            }
            SocleSegmented(options: [AppModel.UsageMode.simple, .advanced], selection: model.mode,
                           label: { $0 == .simple ? L.t("mode.simple") : L.t("mode.advanced") }) { model.mode = $0 }
        }
    }
}

// MARK: Composants

private struct BigTile: View {
    let symbol: String
    let title: String
    var subtitle: String?
    var selected = false
    var disabled = false

    var body: some View {
        VStack(spacing: Socle.M.space2) {
            Image(systemName: symbol).font(.system(size: 24, weight: .regular)).foregroundStyle(selected ? Socle.C.textStrong : Socle.C.textMuted)
                .accessibilityHidden(true)
            Text(title).socle(Socle.T.label).foregroundStyle(selected ? Socle.C.textStrong : Socle.C.text)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            if let subtitle {
                Text(subtitle).socle(Socle.T.meta).foregroundStyle(Socle.C.textSubtle)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 92)
        .padding(.vertical, Socle.M.space3).padding(.horizontal, Socle.M.space2)
        .background(selected ? Socle.C.surfaceHover : Socle.C.bgSunken, in: RoundedRectangle(cornerRadius: Socle.M.radius))
        .overlay(RoundedRectangle(cornerRadius: Socle.M.radius).stroke(selected ? Socle.C.accent : .clear, lineWidth: 1))
        .opacity(disabled ? Socle.M.opacityDisabled : 1)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct Note: View {
    let text: String
    var body: some View {
        Text(text).socle(Socle.T.body).foregroundStyle(Socle.C.textMuted)
            .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
            .padding(Socle.M.space3)
            .background(Socle.C.surfaceRaised)
            .overlay(alignment: .leading) { Rectangle().fill(Socle.C.infoBorder).frame(width: 2) }
    }
}

// MARK: États

/// Une ligne de réglage : libellé à gauche, interrupteur à droite, sur toute la largeur.
private struct SwitchRow: View {
    let title: String
    @Binding var isOn: Bool
    var body: some View {
        HStack(spacing: Socle.M.space3) {
            Text(title).socle(Socle.T.body).foregroundStyle(Socle.C.text)
            Spacer(minLength: Socle.M.space3)
            Toggle("", isOn: $isOn).toggleStyle(.switch).tint(Socle.C.accentFill).labelsHidden().accessibilityLabel(title)
        }
        .frame(minHeight: 28)
    }
}

/// Son (Mac, micro avec choix de la source et niveau d'entrée) et couleurs : une seule colonne, mêmes marges que les tuiles.
private struct SoundPanel: View {
    @ObservedObject var model: AppModel
    @ObservedObject var monitor: MicMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: Socle.M.space2) {
            Text(L.t("main.audio")).socle(Socle.T.label).foregroundStyle(Socle.C.textMuted)
            VStack(alignment: .leading, spacing: Socle.M.space1) {
                SwitchRow(title: L.t("main.audio.system"), isOn: $model.recordSystemAudio)
                SwitchRow(title: L.t("main.audio.mic"), isOn: $model.recordMic)
                if model.recordMic { micDetail }
            }
            if model.mode == .advanced {
                Text(L.t("main.color")).socle(Socle.T.label).foregroundStyle(Socle.C.textMuted).padding(.top, Socle.M.space2)
                VStack(alignment: .leading, spacing: Socle.M.space1) {
                    SwitchRow(title: L.t("main.color.p3"), isOn: $model.colorP3)
                    Text(L.t("main.color.hint")).socle(Socle.T.meta).foregroundStyle(Socle.C.textSubtle).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .onAppear { model.refreshMics(); model.updateMicMonitor() }
        .onDisappear { model.micMonitor.stop() }
        .onChange(of: model.recordMic) { _, _ in model.updateMicMonitor() }
        .onChange(of: model.micDeviceID) { _, _ in model.updateMicMonitor() }
        .onChange(of: model.phase) { _, _ in model.updateMicMonitor() }
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureDevice.wasConnectedNotification)) { _ in model.refreshMics() }
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureDevice.wasDisconnectedNotification)) { _ in model.refreshMics(); model.updateMicMonitor() }
    }

    /// Source du micro et niveau d'entrée, décalés sous la ligne « Micro ».
    private var micDetail: some View {
        VStack(alignment: .leading, spacing: Socle.M.space2) {
            if model.micDevices.isEmpty {
                Text(L.t("mic.none")).socle(Socle.T.meta).foregroundStyle(Socle.C.textSubtle).fixedSize(horizontal: false, vertical: true)
            } else {
                MenuField(options: [(id: "", label: defaultLabel)] + model.micDevices.map { (id: $0.id, label: $0.name) },
                          selection: Binding(get: { model.micDeviceID ?? "" }, set: { model.micDeviceID = $0.isEmpty ? nil : $0 }),
                          accessibility: L.t("mic.source"))
                HStack(spacing: Socle.M.space3) {
                    Text(L.t("mic.level")).socle(Socle.T.meta).foregroundStyle(Socle.C.textMuted)
                    LevelBar(level: monitor.level)
                        .accessibilityLabel(L.t("mic.level")).accessibilityValue("\(Int(monitor.level * 100)) %")
                }
                if monitor.denied { Text(L.t("err.mic")).socle(Socle.T.meta).foregroundStyle(Socle.C.danger).fixedSize(horizontal: false, vertical: true) }
                else if monitor.quiet { Text(L.t("mic.quiet")).socle(Socle.T.meta).foregroundStyle(Socle.C.textSubtle).fixedSize(horizontal: false, vertical: true) }
            }
        }
        .padding(.leading, Socle.M.space4)
        .padding(.bottom, Socle.M.space1)
    }

    private var defaultLabel: String {
        let name = model.micDevices.first(where: { $0.isDefault })?.name
        return name.map { L.t("mic.default.named", $0) } ?? L.t("mic.default")
    }
}

/// Liste déroulante aux jetons Socle (champ creusé, chevron) : pleine largeur, alignée comme les autres champs.
private struct MenuField<ID: Hashable>: View {
    let options: [(id: ID, label: String)]
    @Binding var selection: ID
    let accessibility: String

    var body: some View {
        Menu {
            ForEach(options, id: \.id) { o in
                Button { selection = o.id } label: {
                    if o.id == selection { Label(o.label, systemImage: "checkmark") } else { Text(o.label) }
                }
            }
        } label: {
            HStack(spacing: Socle.M.space2) {
                Text(options.first { $0.id == selection }?.label ?? "").socle(Socle.T.body).foregroundStyle(Socle.C.textStrong)
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: Socle.M.space2)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(Socle.C.textMuted)
            }
            .padding(.horizontal, Socle.M.space3)
            .frame(maxWidth: .infinity, minHeight: Socle.M.sizeControlLg, alignment: .leading)
            .background(Socle.C.bgSunken)
            .contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
        .accessibilityLabel(accessibility)
    }
}

/// Barre de niveau : vert, puis orange près de la saturation.
private struct LevelBar: View {
    let level: Double
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3).fill(Socle.C.border)
                RoundedRectangle(cornerRadius: 3).fill(level > 0.92 ? Socle.C.danger : Socle.C.success)
                    .frame(width: max(0, g.size.width * level))
            }
        }
        .frame(height: 6)
    }
}

private struct IdleBody: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: Socle.M.space6) {
            if !model.screenAllowed { permission }

            Text(L.t("main.what")).socle(Socle.T.heading).foregroundStyle(Socle.C.textStrong)
            HStack(spacing: Socle.M.space2_5) {
                Button { model.kind = .screen } label: {
                    BigTile(symbol: "display", title: L.t("target.screen"), selected: model.kind == .screen)
                }.buttonStyle(.plain)
                Button { model.kind = .window } label: {
                    BigTile(symbol: "macwindow", title: L.t("target.window"), selected: model.kind == .window)
                }.buttonStyle(.plain)
                BigTile(symbol: "rectangle.dashed", title: L.t("target.zone"), subtitle: L.t("target.zone.soon"), disabled: true)
            }

            if model.kind == .window { windowPicker }

            SoundPanel(model: model, monitor: model.micMonitor)

            VStack(spacing: Socle.M.space3) {
                Button { model.start() } label: {
                    HStack(spacing: Socle.M.space2) {
                        Image(systemName: "circle.fill").font(.system(size: 10))
                        Text(L.t("btn.record"))
                    }
                }
                .buttonStyle(SocleButtonStyle(.action, height: Socle.M.sizeCta))
                .disabled(!model.canRecord)
                .accessibilityLabel(L.t("btn.record"))
                .frame(maxWidth: 320)
                Text(branded: L.t("hint.record", AppModel.shortcutLabel)).socle(Socle.T.meta).foregroundStyle(Socle.C.textSubtle)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var windowPicker: some View {
        VStack(alignment: .leading, spacing: Socle.M.space2) {
            HStack {
                Text(L.t("target.window.pick")).socle(Socle.T.label).foregroundStyle(Socle.C.textMuted)
                Spacer()
                Button(L.t("target.window.refresh")) { Task { await model.refreshWindows() } }.buttonStyle(SocleButtonStyle(.tertiary, height: 28)).fixedSize()
                    .padding(.trailing, -Socle.M.space4)                       // le texte s'aligne sur la marge droite
            }
            if model.windows.isEmpty {
                Text(L.t("target.window.none")).socle(Socle.T.body).foregroundStyle(Socle.C.textSubtle)
            } else {
                MenuField(options: model.windows.map { (id: $0.id, label: windowTitle($0)) },
                          selection: Binding(get: { model.selectedWindow ?? model.windows.first?.id ?? 0 }, set: { model.selectedWindow = $0 }),
                          accessibility: L.t("target.window.pick"))
            }
        }
    }

    private func windowTitle(_ w: TargetInfo) -> String {
        [w.app, w.title.isEmpty ? nil : w.title].compactMap { $0 }.joined(separator: " — ")
    }

    private var permission: some View {
        VStack(alignment: .leading, spacing: Socle.M.space3) {
            Text(L.t("perm.title")).socle(Socle.T.title).foregroundStyle(Socle.C.warning)
            Text(branded: L.t("perm.body")).socle(Socle.T.body).foregroundStyle(Socle.C.text).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Socle.M.space2) {
                Button(L.t("btn.perm.open")) {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                }.buttonStyle(SocleButtonStyle(.primary)).fixedSize()
                Button(L.t("btn.perm.recheck")) { Task { await model.refreshWindows() } }.buttonStyle(SocleButtonStyle(.secondary)).fixedSize()
            }
            .frame(maxWidth: .infinity)
        }
        .padding(Socle.M.space6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Socle.C.warningBg, in: RoundedRectangle(cornerRadius: Socle.M.radius))
        .overlay(RoundedRectangle(cornerRadius: Socle.M.radius).stroke(Socle.C.warningBorder, lineWidth: 1))
    }
}

private struct RecordingBody: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: Socle.M.space5) {
            HStack(spacing: Socle.M.space2) {
                Circle().fill(Socle.C.danger).frame(width: 10, height: 10)
                Text(L.t("rec.title")).socle(Socle.T.heading).foregroundStyle(Socle.C.textStrong)
            }
            Text(AppModel.clock(model.elapsed)).font(.system(size: 56, weight: .bold)).monospacedDigit().foregroundStyle(Socle.C.textStrong)
            Text(model.recordingLabel).socle(Socle.T.body).foregroundStyle(Socle.C.textMuted).multilineTextAlignment(.center)
            if let problem = model.problem {
                Text(problem).socle(Socle.T.body).foregroundStyle(Socle.C.warning)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    .padding(Socle.M.space3).frame(maxWidth: .infinity)
                    .background(Socle.C.warningBg, in: RoundedRectangle(cornerRadius: Socle.M.radius))
            }
            Button { model.stop() } label: {
                HStack(spacing: Socle.M.space2) {
                    Image(systemName: "stop.fill").font(.system(size: 11))
                    Text(L.t("btn.stop"))
                }
            }
            .buttonStyle(SocleButtonStyle(.primary, height: Socle.M.sizeCta)).frame(maxWidth: 320)
            .accessibilityLabel(L.t("btn.stop"))
            Text(L.t("rec.hint")).socle(Socle.T.meta).foregroundStyle(Socle.C.textSubtle).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            Text(AppModel.shortcutLabel).socle(Socle.T.monoSm).foregroundStyle(Socle.C.textSubtle)
        }
        .frame(maxWidth: .infinity).padding(.vertical, Socle.M.space8)
    }
}

private struct StartingBody: View {
    var body: some View {
        VStack(spacing: Socle.M.space4) {
            ProgressView()
            Text(L.t("start.title")).socle(Socle.T.label).foregroundStyle(Socle.C.textMuted)
        }
        .frame(maxWidth: .infinity).padding(.vertical, Socle.M.space8)
    }
}

/// Centre la fenêtre sur l'écran du pointeur à son ouverture (règle Socle « lancement centré »).
private struct WindowCenterer: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { view.window?.socleCenter() }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

private struct FinishingBody: View {
    var body: some View {
        VStack(spacing: Socle.M.space4) {
            ProgressView()
            Text(L.t("fin.title")).socle(Socle.T.label).foregroundStyle(Socle.C.textMuted)
        }
        .frame(maxWidth: .infinity).padding(.vertical, Socle.M.space8)
    }
}

private struct DoneBody: View {
    @ObservedObject var model: AppModel
    let summary: AppModel.TapeSummary
    @State private var busy = false
    @State private var status: String?
    @State private var exported: URL?

    private func export(_ d: Destination) {
        busy = true; status = nil; exported = nil
        let url = summary.url
        Task {
            do {
                let r = try await Exporter.export(TapePackage(url: url), destination: d)
                let file = URL(fileURLWithPath: r.path)
                status = L.t("lib.exported", file.lastPathComponent, String(format: "%.1f", locale: L.locale, r.megabytes))
                exported = file
            } catch { status = L.t("lib.export.failed", "\(error)") }
            busy = false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Socle.M.space5) {
            HStack(spacing: Socle.M.space2) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Socle.C.success)
                Text(L.t("done.title")).socle(Socle.T.heading).foregroundStyle(Socle.C.textStrong)
            }
            Text(L.t("done.stats", AppModel.clock(summary.seconds), AppModel.megabytes(summary.bytes), summary.frames))
                .socle(Socle.T.stat).foregroundStyle(Socle.C.accentText).fixedSize(horizontal: false, vertical: true)
            Text(L.t("done.where", summary.url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~")))
                .socle(Socle.T.mono).foregroundStyle(Socle.C.textMuted).fixedSize(horizontal: false, vertical: true)
            if let why = model.systemStop { Note(text: L.t("done.stoppedby." + why)) }
            Note(text: L.t("done.note"))
            VStack(alignment: .leading, spacing: Socle.M.space2) {
                Text(L.t("done.make")).socle(Socle.T.label).foregroundStyle(Socle.C.textMuted)
                HStack(spacing: Socle.M.space2) {
                    ForEach(Destination.allCases, id: \.self) { d in
                        Button(L.t("lib.export." + d.rawValue)) { export(d) }
                            .buttonStyle(SocleButtonStyle(.primary, height: 32)).disabled(busy)
                    }
                }
                Group {
                    if busy { HStack(spacing: 8) { ProgressView().controlSize(.small); Text(L.t("lib.exporting")).socle(Socle.T.meta).foregroundStyle(Socle.C.textMuted) } }
                    else if let status { Text(status).socle(Socle.T.meta).foregroundStyle(Socle.C.textMuted).fixedSize(horizontal: false, vertical: true) }
                    else { Text(" ").socle(Socle.T.meta) }                      // réserve la ligne : les boutons du bas ne bougent pas
                }
                .frame(maxWidth: .infinity, minHeight: 18, alignment: .leading)
            }
            HStack(spacing: Socle.M.space2) {
                Button(L.t("btn.reveal")) { NSWorkspace.shared.activateFileViewerSelecting([exported ?? summary.url]) }
                    .buttonStyle(SocleButtonStyle(.secondary))
                Button(L.t("btn.again")) { model.reset() }
                    .buttonStyle(SocleButtonStyle(.secondary))
            }
        }
    }
}

private struct FailedBody: View {
    @ObservedObject var model: AppModel
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: Socle.M.space4) {
            Text(L.t("err.title")).socle(Socle.T.heading).foregroundStyle(Socle.C.danger)
            Text(message).socle(Socle.T.body).foregroundStyle(Socle.C.text).fixedSize(horizontal: false, vertical: true)
            Button(L.t("btn.retry")) { model.reset() }.buttonStyle(SocleButtonStyle(.primary)).fixedSize()
                .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
