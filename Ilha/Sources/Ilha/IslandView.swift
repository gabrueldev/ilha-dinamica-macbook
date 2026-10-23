import SwiftUI
import UniformTypeIdentifiers

extension Color {
    static let ink = Color.white.opacity(0.9)
    static let inkSecondary = Color.white.opacity(0.55)
}

struct IslandView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var ask: AskModel

    private let spring = Animation.spring(response: 0.35, dampingFraction: 0.8)

    var body: some View {
        let mode = store.mode
        let size = store.islandSize
        let shape = NotchShape(topRadius: SessionStore.topRadius, bottomRadius: mode == .collapsed ? 10 : 24)
        let hidden = mode == .collapsed && store.sessions.isEmpty && store.timer == nil

        ZStack(alignment: .top) {
            if mode == .permission || mode == .finished || mode == .dropTarget {
                RainbowGlow(shape: shape, intensity: mode == .finished ? 0.7 : 1)
                    .transition(.opacity)
            }
            shape.fill(Color.black)
            content(mode)
                .id(mode)
                .transition(.opacity.animation(.easeOut(duration: 0.15)))
                .frame(width: size.width, height: size.height, alignment: .top)
                .clipShape(shape)
        }
        .frame(width: size.width, height: size.height)
        .opacity(hidden ? 0 : 1)
        .onDrop(of: [UTType.fileURL], isTargeted: nil, perform: handleDrop)
        .frame(width: SessionStore.panelSize.width, height: SessionStore.panelSize.height, alignment: .top)
        .animation(spring, value: mode)
        .animation(spring, value: size)
        .environment(\.colorScheme, .dark)
        .tint(.white)
    }

    @ViewBuilder
    private func content(_ mode: IslandMode) -> some View {
        switch mode {
        case .collapsed:
            CollapsedView(store: store)
        case .hover:
            HoverView(store: store)
        case .permission:
            if let permission = store.pending.first {
                PermissionView(store: store, permission: permission)
            }
        case .finished:
            if let info = store.finished {
                FinishedView(store: store, info: info)
            }
        case .dropTarget:
            DropView(store: store)
        case .ask:
            AskView(store: store, ask: ask)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else {
            return false
        }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { SessionStore.shared.dropFile(url) }
            }
        }
        return true
    }
}

// MARK: - Recolhido

struct CollapsedView: View {
    @ObservedObject var store: SessionStore

    var body: some View {
        HStack(spacing: 0) {
            Mascot(mood: store.overallStatus.mood, size: 18)
                .frame(width: 36, height: store.notchHeight)
            Spacer(minLength: 0)
            if let timer = store.timer {
                TimerBadge(timer: timer)
                    .frame(width: 76, height: store.notchHeight)
            } else {
                StatusIndicator(status: store.overallStatus, count: store.sessions.count)
                    .frame(width: 36, height: store.notchHeight)
            }
        }
        .padding(.horizontal, SessionStore.topRadius)
        .frame(height: store.notchHeight)
    }
}

// MARK: - Timer

struct TimerRing: View {
    let progress: Double
    var size: CGFloat = 11

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.2), lineWidth: 2)
            Circle()
                .trim(from: 0, to: 1 - progress)
                .stroke(Color.white, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
    }
}

/// Orelha direita do notch recolhido: anel + "24:59".
struct TimerBadge: View {
    let timer: IslandTimer

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { timeline in
            HStack(spacing: 6) {
                TimerRing(progress: timer.progress(at: timeline.date))
                Text(IslandTimer.clock(timer.remaining(at: timeline.date)))
                    .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundColor(.ink)
                    .lineLimit(1)
            }
        }
    }
}

/// Cartão do timer na lista do hover.
struct TimerCard: View {
    @ObservedObject var store: SessionStore
    let timer: IslandTimer

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { timeline in
            let progress = timer.progress(at: timeline.date)
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 10) {
                    Image(systemName: "timer")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.ink)
                    Text(timer.label)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.ink)
                    Text("·").foregroundColor(.inkSecondary)
                    Text(IslandTimer.clock(timer.remaining(at: timeline.date)))
                        .font(.system(size: 12, design: .rounded).monospacedDigit())
                        .foregroundColor(.inkSecondary)
                    Spacer(minLength: 0)
                    Button("Cancelar") { store.cancelTimer() }
                        .buttonStyle(PillButtonStyle(kind: .text, height: 20))
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.12))
                        Capsule().fill(Color.white).frame(width: geo.size.width * progress)
                    }
                }
                .frame(height: 3)
            }
            .padding(.horizontal, 10)
            .frame(height: 50)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.05)))
        }
    }
}

struct StatusIndicator: View {
    let status: SessionStatus
    var count: Int = 1

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let pulse = (sin(t * 4) + 1) / 2
            HStack(spacing: 3) {
                switch status {
                case .working:
                    Circle().fill(Color.white)
                        .frame(width: 7, height: 7)
                        .scaleEffect(0.7 + 0.3 * pulse)
                        .opacity(0.5 + 0.5 * pulse)
                case .waitingPermission:
                    Circle().fill(Rainbow.angular(t, speed: 180))
                        .frame(width: 9, height: 9)
                        .scaleEffect(0.75 + 0.35 * pulse)
                        .shadow(color: .white.opacity(0.5 * pulse), radius: 4)
                case .done:
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundColor(.white)
                case .idle:
                    Circle().fill(Color.white.opacity(0.35))
                        .frame(width: 6, height: 6)
                }
                if count > 1 {
                    Text("\(count)")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundColor(.ink)
                }
            }
        }
    }
}

// MARK: - Hover (lista de sessões)

struct HoverView: View {
    @ObservedObject var store: SessionStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Mascot(mood: store.overallStatus.mood, size: 28)
                Text("Ilha")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.ink)
                Spacer()
                Text(countLabel)
                    .font(.system(size: 12))
                    .foregroundColor(.inkSecondary)
            }
            .frame(height: 40)

            if let timer = store.timer {
                TimerCard(store: store, timer: timer)
            }

            if store.sessions.isEmpty {
                Text("Nenhuma sessão do Claude Code agora.")
                    .font(.system(size: 12))
                    .foregroundColor(.inkSecondary)
                    .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 8) {
                        ForEach(store.sessions) { SessionRow(session: $0) }
                    }
                }
            }

            Spacer(minLength: 0)

            HStack(spacing: 6) {
                Image(systemName: "arrow.down.doc")
                Text("Arraste um arquivo aqui")
                    .lineLimit(1)
                Spacer(minLength: 4)
                Button("Perguntar ao Claude…") { store.openAsk() }
                    .buttonStyle(PillButtonStyle(kind: .secondary, height: 22))
            }
            .font(.system(size: 11))
            .foregroundColor(.inkSecondary)
        }
        .padding(.top, store.notchHeight + 6)
        .padding(.horizontal, 22)
        .padding(.bottom, 12)
    }

    private var countLabel: String {
        let n = store.sessions.count
        return n == 1 ? "1 sessão" : "\(n) sessões"
    }
}

struct SessionRow: View {
    let session: Session
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 10) {
            StatusIndicator(status: session.status)
                .frame(width: 14)
            Text(session.project)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.ink)
                .lineLimit(1)
                .layoutPriority(1)
            Text("·").foregroundColor(.inkSecondary)
            Text(session.status.label)
                .font(.system(size: 12))
                .foregroundColor(.inkSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            Image(systemName: "arrow.up.forward.app")
                .font(.system(size: 11))
                .foregroundColor(.inkSecondary)
                .opacity(hovered ? 1 : 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(hovered ? 0.1 : 0.05)))
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture { TerminalActivator.activate() }
    }
}

// MARK: - Permissão

struct PermissionView: View {
    @ObservedObject var store: SessionStore
    let permission: PendingPermission

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Mascot(mood: .waiting, size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    (Text(permission.project).fontWeight(.semibold) + Text(" quer rodar"))
                        .font(.system(size: 13))
                        .foregroundColor(.ink)
                    Text(ToolSummary.displayName(permission.toolName))
                        .font(.system(size: 11))
                        .foregroundColor(.inkSecondary)
                }
                Spacer()
                if store.pending.count > 1 {
                    Text("1/\(store.pending.count)")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundColor(.ink)
                        .padding(.horizontal, 8)
                        .frame(height: 20)
                        .background(Capsule().fill(Color.white.opacity(0.12)))
                }
            }

            Text(permission.summary)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.ink)
                .lineLimit(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.08)))

            HStack(spacing: 8) {
                Button("Ver no terminal") {
                    store.resolve(permission.id, .terminal)
                    TerminalActivator.activate()
                }
                .buttonStyle(PillButtonStyle(kind: .text))
                Spacer()
                Button { store.resolve(permission.id, .deny) } label: {
                    HStack(spacing: 6) { Text("Negar"); KeyHint(key: "esc") }
                }
                .buttonStyle(PillButtonStyle(kind: .secondary))
                Button { store.resolve(permission.id, .allow) } label: {
                    HStack(spacing: 6) { Text("Permitir"); KeyHint(key: "⏎", dark: true) }
                }
                .buttonStyle(PillButtonStyle(kind: .primary))
            }
        }
        .padding(.top, store.notchHeight + 8)
        .padding(.horizontal, 22)
        .padding(.bottom, 14)
    }
}

// MARK: - Concluído

struct FinishedView: View {
    @ObservedObject var store: SessionStore
    let info: FinishedInfo

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Mascot(mood: .done, size: 30)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .heavy))
                    (Text(info.project).fontWeight(.semibold) + Text(" terminou"))
                        .font(.system(size: 13))
                }
                .foregroundColor(.ink)
                if !info.message.isEmpty {
                    Text(info.message)
                        .font(.system(size: 12))
                        .foregroundColor(.inkSecondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.top, store.notchHeight + 12)
        .padding(.horizontal, 22)
        .padding(.bottom, 12)
        .contentShape(Rectangle())
        .onTapGesture { store.dismissFinished() }
    }
}

// MARK: - Soltar arquivo

struct DropView: View {
    @ObservedObject var store: SessionStore

    var body: some View {
        HStack(spacing: 14) {
            Mascot(mood: .eating, size: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text("Solte aqui")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.ink)
                Text("PDF · Imagens · Textos · Docs")
                    .font(.system(size: 12))
                    .foregroundColor(.inkSecondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.white.opacity(0.35), style: StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
        )
        .padding(.top, store.notchHeight + 8)
        .padding(.horizontal, 20)
        .padding(.bottom, 14)
    }
}

// MARK: - Perguntar ao Claude

struct AskView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var ask: AskModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Mascot(mood: ask.streaming ? .working : .idle, size: 24)
                if let file = ask.file {
                    FileChip(file: file) { ask.removeFile() }
                } else if ask.loadingFile {
                    ProgressView().controlSize(.small)
                    Text("Lendo arquivo…")
                        .font(.system(size: 12))
                        .foregroundColor(.inkSecondary)
                } else {
                    Text("Perguntar ao Claude")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.ink)
                }
                Spacer()
                Button { store.closeAsk() } label: { Image(systemName: "xmark") }
                    .buttonStyle(PillButtonStyle(kind: .text))
            }
            .frame(height: 26)

            if ask.needsKey {
                keyEntry
            } else {
                questionField
            }

            if let error = ask.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundColor(.ink)
                    .lineLimit(1)
            } else if let info = ask.info {
                Label(info, systemImage: "arrow.up.forward.app")
                    .font(.system(size: 11))
                    .foregroundColor(.inkSecondary)
                    .lineLimit(1)
            } else if let note = ask.file?.note {
                Text(note)
                    .font(.system(size: 11))
                    .foregroundColor(.inkSecondary)
            }

            if ask.streaming || !ask.answer.isEmpty {
                answerArea
            }
        }
        .padding(.top, store.notchHeight + 12)
        .padding(.horizontal, 22)
        .padding(.bottom, 14)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { focused = true }
        }
        .onChange(of: ask.needsKey) { _ in
            DispatchQueue.main.async { focused = true }
        }
    }

    private var questionField: some View {
        HStack(spacing: 8) {
            TextField(ask.file == nil ? "Pergunte algo, “abrir app”, “pomodoro” ou um link…" : "Pergunte algo sobre o arquivo…", text: $ask.question)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundColor(.ink)
                .focused($focused)
                .onSubmit { ask.send() }
            if ask.streaming {
                Button("Parar") { ask.stop() }
                    .buttonStyle(PillButtonStyle(kind: .secondary, height: 24))
            } else {
                Button { ask.send() } label: { Image(systemName: "arrow.up").font(.system(size: 11, weight: .bold)) }
                    .buttonStyle(PillButtonStyle(kind: .primary, height: 24))
                    .disabled(ask.question.trimmingCharacters(in: .whitespaces).isEmpty || ask.loadingFile)
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 5)
        .frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.08)))
    }

    private var keyEntry: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Para perguntar, a Ilha usa a API da Anthropic. A chave é cobrada à parte da assinatura do Claude e fica guardada no Keychain.")
                .font(.system(size: 11))
                .foregroundColor(.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                SecureField("Cole sua chave da API (console.anthropic.com)", text: $ask.keyDraft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($focused)
                    .onSubmit { ask.saveKey() }
                Button("Salvar") { ask.saveKey() }
                    .buttonStyle(PillButtonStyle(kind: .primary, height: 24))
            }
            .padding(.leading, 12)
            .padding(.trailing, 5)
            .frame(height: 34)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.08)))
        }
    }

    private var answerArea: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !ask.lastQuestion.isEmpty {
                Text(ask.lastQuestion)
                    .font(.system(size: 11))
                    .foregroundColor(.inkSecondary)
                    .lineLimit(1)
            }
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    Text(ask.answer.isEmpty ? "…" : ask.answer)
                        .font(.system(size: 13))
                        .foregroundColor(.ink)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Color.clear.frame(height: 1).id("fim")
                }
                .onChange(of: ask.answer) { _ in
                    if ask.streaming { proxy.scrollTo("fim", anchor: .bottom) }
                }
            }
            HStack {
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(ask.answer, forType: .string)
                } label: {
                    Label("Copiar", systemImage: "doc.on.doc")
                }
                .buttonStyle(PillButtonStyle(kind: .text, height: 20))
                .disabled(ask.answer.isEmpty)
            }
        }
    }
}

struct FileChip: View {
    let file: LoadedFile
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: file.symbol)
                .font(.system(size: 11))
            Text(file.name)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 260, alignment: .leading)
            Button(action: onRemove) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundColor(.inkSecondary)
        }
        .foregroundColor(.ink)
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(Capsule().fill(Color.white.opacity(0.1)))
    }
}

// MARK: - Botões

struct PillButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, text }
    var kind: Kind
    var height: CGFloat = 28
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(foreground)
            .padding(.horizontal, kind == .text ? 6 : 12)
            .frame(height: height)
            .background(Capsule().fill(background))
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.7 : (isEnabled ? 1 : 0.4))
    }

    private var foreground: Color {
        switch kind {
        case .primary: return .black
        case .secondary: return .ink
        case .text: return .inkSecondary
        }
    }

    private var background: Color {
        switch kind {
        case .primary: return .white
        case .secondary: return .white.opacity(0.12)
        case .text: return .clear
        }
    }
}

struct KeyHint: View {
    let key: String
    var dark = false

    var body: some View {
        Text(key)
            .font(.system(size: 9, weight: .medium, design: .rounded))
            .padding(.horizontal, 4)
            .frame(height: 15)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke((dark ? Color.black : Color.white).opacity(0.3)))
            .opacity(0.8)
    }
}
