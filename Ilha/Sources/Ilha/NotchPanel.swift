import AppKit
import Combine
import SwiftUI

/// Painel sem borda, transparente, por cima da barra de menus.
final class NotchPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(origin: .zero, size: SessionStore.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isMovable = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        ignoresMouseEvents = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) não é usado")
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Aceita o primeiro clique mesmo sem o painel estar em foco.
final class IslandHostingView: NSHostingView<IslandView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

struct NotchGeometry {
    let screen: NSScreen
    let hasNotch: Bool
    let notchWidth: CGFloat
    let notchHeight: CGFloat

    static func current() -> NotchGeometry {
        let screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens[0]
        let hasNotch = screen.safeAreaInsets.top > 0
        var notchHeight = NSStatusBar.system.thickness
        if hasNotch {
            notchHeight = screen.safeAreaInsets.top
        } else {
            let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
            if menuBar > 0 { notchHeight = menuBar }
        }
        var notchWidth: CGFloat = 200
        if hasNotch, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            notchWidth = screen.frame.width - left.width - right.width
        }
        return NotchGeometry(screen: screen, hasNotch: hasNotch, notchWidth: notchWidth, notchHeight: notchHeight)
    }
}

/// Posiciona o painel, deixa os cliques passarem fora da ilha e detecta hover e arrasto de arquivo.
@MainActor
final class NotchController {
    let panel = NotchPanel()
    private let store: SessionStore
    private var geometry: NotchGeometry
    private var timer: Timer?
    private var keyMonitor: Any?
    private var bag = Set<AnyCancellable>()
    private var previousApp: NSRunningApplication?

    private var insideSince: Date?
    private var outsideSince: Date?
    private var mouseWasDown = false
    private var dragStartCount = 0
    private var dragInProgress = false

    init(store: SessionStore) {
        self.store = store
        geometry = .current()

        let hosting = IslandHostingView(rootView: IslandView(store: store, ask: store.ask))
        hosting.sizingOptions = []
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = .clear
        panel.contentView = hosting
        applyGeometry()
        panel.orderFrontRegardless()

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.geometry = .current()
                self.applyGeometry()
            }
        }

        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        store.$askActive.removeDuplicates().sink { [weak self] active in
            if active { self?.focusPanel() } else { self?.releaseFocus() }
        }
        .store(in: &bag)

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handleKey(event) ? nil : event
        }
    }

    private func applyGeometry() {
        let frame = geometry.screen.frame
        let size = SessionStore.panelSize
        panel.setFrame(NSRect(x: frame.midX - size.width / 2, y: frame.maxY - size.height,
                              width: size.width, height: size.height), display: true)
        store.notchWidth = geometry.notchWidth
        store.notchHeight = geometry.notchHeight
        store.hasNotch = geometry.hasNotch
    }

    // MARK: - Foco do teclado

    private func focusPanel() {
        if let front = NSWorkspace.shared.frontmostApplication, front != NSRunningApplication.current {
            previousApp = front
        }
        panel.makeKey()
    }

    private func releaseFocus() {
        guard panel.isKeyWindow else { return }
        panel.resignKey()
        if store.restoreFocusOnClose { previousApp?.activate(options: []) }
        previousApp = nil
    }

    /// ⏎ permite, ⎋ nega (permissão); ⎋ fecha (pergunta).
    private func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard flags.isEmpty else { return false }
        switch store.mode {
        case .permission:
            // Evita aprovar sem querer com um ⏎ que era para outra coisa.
            guard Date().timeIntervalSince(store.permissionShownAt) > 0.6 else { return true }
            if event.keyCode == 36 || event.keyCode == 76 {
                store.resolveFront(.allow)
                return true
            }
            if event.keyCode == 53 {
                store.resolveFront(.deny)
                return true
            }
            return false
        case .ask:
            if event.keyCode == 53 {
                store.closeAsk()
                return true
            }
            return false
        default:
            return false
        }
    }

    // MARK: - Timer (~30 Hz)

    private func tick() {
        let now = Date()
        let mouse = NSEvent.mouseLocation
        let frame = geometry.screen.frame
        let size = store.islandSize
        let island = NSRect(x: frame.midX - size.width / 2, y: frame.maxY - size.height,
                            width: size.width, height: size.height).insetBy(dx: -6, dy: -6)
        let inside = island.contains(mouse)

        // Arrasto de arquivo: o pasteboard de drag muda enquanto o botão está pressionado.
        let down = NSEvent.pressedMouseButtons & 1 != 0
        let dragCount = NSPasteboard(name: .drag).changeCount
        if down && !mouseWasDown {
            dragStartCount = dragCount
            dragInProgress = false
        }
        if down && dragCount != dragStartCount {
            dragInProgress = true
        }
        if !down && mouseWasDown {
            dragInProgress = false
            if store.dragging {
                // Dá tempo para o onDrop do SwiftUI receber o arquivo.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, !self.dragInProgress else { return }
                        self.store.dragging = false
                    }
                }
            }
        }
        mouseWasDown = down

        if dragInProgress {
            let nearTop = frame.maxY - mouse.y < 90 && abs(mouse.x - frame.midX) < 300
            let wantsDrop = nearTop || (store.dragging && inside)
            if wantsDrop != store.dragging { store.dragging = wantsDrop }
        }

        let interactive = inside || store.dragging
        if panel.ignoresMouseEvents == interactive {
            panel.ignoresMouseEvents = !interactive
        }

        // Hover: entra depois de 0,15 s dentro, sai depois de 0,3 s fora.
        if inside && !dragInProgress {
            outsideSince = nil
            if insideSince == nil { insideSince = now }
            if !store.hovering, let since = insideSince, now.timeIntervalSince(since) > 0.15 {
                store.hovering = true
            }
        } else {
            insideSince = nil
            if outsideSince == nil { outsideSince = now }
            if store.hovering, let since = outsideSince, now.timeIntervalSince(since) > 0.3 {
                store.hovering = false
            }
        }
    }
}
