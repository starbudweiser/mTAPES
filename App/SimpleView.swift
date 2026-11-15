// mTAPES — mode Simple : quoi filmer, Enregistrer. Maquette B (Socle standard). Rien n'est tronqué : le contenu défile si la place manque.
import SwiftUI

struct SimpleView: View {
    @ObservedObject var model: AppModel

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
            }
            if model.windows.isEmpty {
                Text(L.t("target.window.none")).socle(Socle.T.body).foregroundStyle(Socle.C.textSubtle)
            } else {
                Picker("", selection: Binding(get: { model.selectedWindow ?? 0 }, set: { model.selectedWindow = $0 })) {
                    ForEach(model.windows, id: \.id) { w in
                        Text(windowTitle(w)).tag(w.id)
                    }
                }
                .labelsHidden()
                .accessibilityLabel(L.t("target.window.pick"))
                .frame(maxWidth: .infinity)
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
            Note(text: L.t("done.note"))
            HStack(spacing: Socle.M.space2) {
                Button(L.t("btn.reveal")) { NSWorkspace.shared.activateFileViewerSelecting([summary.url]) }
                    .buttonStyle(SocleButtonStyle(.secondary)).fixedSize()
                Button(L.t("btn.again")) { model.reset() }
                    .buttonStyle(SocleButtonStyle(.primary)).fixedSize()
            }
            .frame(maxWidth: .infinity)
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
