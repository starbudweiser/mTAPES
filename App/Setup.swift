// mTAPES — assistant de configuration : bienvenue (mode), autorisation d'enregistrer l'écran, raccordement de l'IA, prêt. Maquette A.
// Quatre étapes (trois en mode Simple : pas d'étape IA). Boutons toujours à la même place ; la page n'affirme que ce qui est vrai.
import SwiftUI

struct SetupView: View {
    @ObservedObject var model: AppModel
    var startStep = 0
    var startChoice = "simple"
    var onClose: () -> Void = {}

    @State private var step = 0
    @State private var choice = "simple"          // simple | advanced | both
    @State private var screenOK = Permissions.screenRecording
    @State private var ready = false

    private var withAI: Bool { choice != "simple" }
    private var steps: [(key: String, title: String)] {
        var s = [("welcome", L.t("setup.s1")), ("perm", L.t("setup.s2"))]
        if withAI { s.append(("ai", L.t("setup.s3"))) }
        s.append(("ready", L.t("setup.s4")))
        return s
    }
    private var current: String { steps[min(step, steps.count - 1)].key }

    var body: some View {
        ZStack(alignment: .top) {
            Socle.C.bg.ignoresSafeArea()
            VStack(alignment: .leading, spacing: Socle.M.space5) {
                header
                switch current {
                case "welcome": welcome
                case "perm": permissions
                case "ai": ai
                default: done
                }
                footer
            }
            .padding(Socle.M.space6)
        }
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { if !ready { step = startStep; choice = startChoice; ready = true } }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in screenOK = Permissions.screenRecording }
    }

    // MARK: Parties

    private var header: some View {
        VStack(alignment: .leading, spacing: Socle.M.space3) {
            HStack {
                Text(branded: "mTAPES").socle(Socle.T.display).foregroundStyle(Socle.C.textStrong)
                Spacer()
                Text(L.t("setup.step", min(step, steps.count - 1) + 1, steps.count)).socle(Socle.T.meta).foregroundStyle(Socle.C.textSubtle)
            }
            HStack(spacing: Socle.M.space1_5) {
                ForEach(Array(steps.enumerated()), id: \.offset) { i, s in
                    Text(i < step ? "✓ \(s.title)" : "\(i + 1) \(s.title)")
                        .socle(Socle.T.meta)
                        .foregroundStyle(i == step ? Socle.C.onAccentFill : (i < step ? Socle.C.success : Socle.C.textSubtle))
                        .padding(.horizontal, Socle.M.space2).padding(.vertical, 3)
                        .background(i == step ? Socle.C.accentFill : Socle.C.control, in: Capsule())
                }
            }
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: Socle.M.space4) {
            Text(L.t("setup.welcome")).socle(Socle.T.heading).foregroundStyle(Socle.C.textStrong)
            Text(L.t("setup.welcome.sub")).socle(Socle.T.body).foregroundStyle(Socle.C.textMuted).fixedSize(horizontal: false, vertical: true)
            Text(L.t("setup.how")).socle(Socle.T.title).foregroundStyle(Socle.C.textStrong)
            option("simple", L.t("setup.mode.simple"), L.t("setup.mode.simple.desc"), tag: L.t("setup.mode.simple.tag"))
            option("advanced", L.t("setup.mode.advanced"), L.t("setup.mode.advanced.desc"))
            option("both", L.t("setup.mode.both"), L.t("setup.mode.both.desc"))
            Text(L.t("setup.change")).socle(Socle.T.meta).foregroundStyle(Socle.C.textSubtle).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func option(_ id: String, _ title: String, _ detail: String, tag: String? = nil) -> some View {
        let on = choice == id
        return Button { choice = id } label: {
            HStack(alignment: .top, spacing: Socle.M.space3) {
                Image(systemName: on ? "largecircle.fill.circle" : "circle").foregroundStyle(on ? Socle.C.accentText : Socle.C.textSubtle)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: Socle.M.space2) {
                        Text(title).socle(Socle.T.label).foregroundStyle(Socle.C.textStrong)
                        if let tag { SocleChip(text: tag) }
                    }
                    Text(detail).socle(Socle.T.meta).foregroundStyle(Socle.C.textMuted).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(Socle.M.space3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(on ? Socle.C.surfaceSelected : Socle.C.surface, in: RoundedRectangle(cornerRadius: Socle.M.radius))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title + ". " + detail)
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: Socle.M.space4) {
            Text(L.t("setup.s2")).socle(Socle.T.heading).foregroundStyle(Socle.C.textStrong)
            Text(L.t("setup.perm.sub")).socle(Socle.T.body).foregroundStyle(Socle.C.textMuted).fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: Socle.M.space3) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: Socle.M.space2) {
                        Text(L.t("setup.perm.screen")).socle(Socle.T.label).foregroundStyle(Socle.C.textStrong)
                        SocleChip(text: L.t("setup.perm.required"))
                    }
                    Text(L.t("setup.perm.screen.why")).socle(Socle.T.meta).foregroundStyle(Socle.C.textMuted).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if screenOK {
                    Text("✓ " + L.t("setup.perm.granted")).socle(Socle.T.label).foregroundStyle(Socle.C.success)
                } else {
                    Button(L.t("setup.perm.allow")) { allowScreen() }.buttonStyle(SocleButtonStyle(.primary, height: 28)).fixedSize()
                }
            }
            .padding(Socle.M.space3)
            .background(Socle.C.surface, in: RoundedRectangle(cornerRadius: Socle.M.radius))
            Text(L.t("setup.perm.live")).socle(Socle.T.meta).foregroundStyle(Socle.C.textSubtle).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var ai: some View {
        VStack(alignment: .leading, spacing: Socle.M.space4) {
            Text(L.t("setup.s3")).socle(Socle.T.heading).foregroundStyle(Socle.C.textStrong)
            Text(L.t("setup.ai.sub")).socle(Socle.T.body).foregroundStyle(Socle.C.textMuted).fixedSize(horizontal: false, vertical: true)
            ConnectorRows()
                .padding(Socle.M.space3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Socle.C.surface, in: RoundedRectangle(cornerRadius: Socle.M.radius))
            Text(L.t("setup.ai.safe")).socle(Socle.T.meta).foregroundStyle(Socle.C.textSubtle).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var done: some View {
        VStack(alignment: .leading, spacing: Socle.M.space3) {
            HStack(spacing: Socle.M.space2) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Socle.C.success)
                Text(L.t("setup.ready")).socle(Socle.T.heading).foregroundStyle(Socle.C.textStrong)
            }
            Text(L.t("setup.ready.sub", AppModel.shortcutLabel)).socle(Socle.T.body).foregroundStyle(Socle.C.textMuted).fixedSize(horizontal: false, vertical: true)
            if withAI { Text(L.t("setup.ready.lib")).socle(Socle.T.meta).foregroundStyle(Socle.C.textSubtle).fixedSize(horizontal: false, vertical: true) }
        }
    }

    private var footer: some View {
        HStack(spacing: Socle.M.space2) {
            if step > 0 { Button(L.t("setup.back")) { step -= 1 }.buttonStyle(SocleButtonStyle(.secondary)).fixedSize() }
            Spacer()
            if current != "ready" {
                Button(L.t("setup.skip")) { finish(apply: false) }.buttonStyle(SocleButtonStyle(.tertiary)).fixedSize()
                Button(L.t("setup.next")) { step += 1 }.buttonStyle(SocleButtonStyle(.primary)).fixedSize()
            } else {
                Button(L.t("setup.done")) { finish(apply: true) }.buttonStyle(SocleButtonStyle(.action)).fixedSize()
            }
        }
    }

    // MARK: Actions

    private func allowScreen() {
        _ = CGRequestScreenCaptureAccess()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") { NSWorkspace.shared.open(url) }
    }

    private func finish(apply: Bool) {
        if apply {
            model.mode = choice == "simple" ? .simple : .advanced
            model.mcpEnabled = withAI                     // choix explicite de l'utilisateur ; chaque IA devra encore être autorisée par son nom
        }
        model.setupDone = true
        onClose()
    }
}
