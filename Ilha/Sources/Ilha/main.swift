import AppKit
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let store = SessionStore.shared
    private let server = HookServer()
    private var controller: NotchController?
    private var statusItem: NSStatusItem?
    private var serverStatus = "Servidor: iniciando…"

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        server.onEvent = { [weak self] event, reply in
            MainActor.assumeIsolated { self?.store.handle(event, reply: reply) }
        }
        server.onStatus = { [weak self] error in
            MainActor.assumeIsolated {
                if let error {
                    self?.serverStatus = "Servidor: erro — \(error)"
                } else {
                    self?.serverStatus = "Servidor: ativo na porta \(HookServer.port)"
                }
            }
        }
        server.start()

        controller = NotchController(store: store)
        setupStatusItem()
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.offerHookInstall() }
        }
    }

    // MARK: - Menu

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "sparkle", accessibilityDescription: "Ilha")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let installed = HookInstaller.isInstalled()

        menu.addItem(makeItem(serverStatus, nil, enabled: false))
        menu.addItem(.separator())
        menu.addItem(makeItem(installed ? "Hooks do Claude Code instalados" : "Instalar hooks do Claude Code",
                              #selector(installHooks), state: installed))
        menu.addItem(makeItem("Remover hooks", installed ? #selector(removeHooks) : nil, enabled: installed))
        menu.addItem(.separator())
        menu.addItem(makeItem("Chave da API…", #selector(editAPIKey)))
        menu.addItem(makeItem("Modelo…", #selector(editModel)))
        menu.addItem(.separator())
        menu.addItem(makeItem("Som ao terminar", #selector(toggleSound),
                              state: UserDefaults.standard.bool(forKey: "soundOnFinish")))
        menu.addItem(makeItem("Abrir ao iniciar sessão", #selector(toggleLoginItem),
                              state: SMAppService.mainApp.status == .enabled))
        menu.addItem(.separator())
        menu.addItem(makeItem("Sair", #selector(quit), key: "q"))
    }

    private func makeItem(_ title: String, _ action: Selector?, key: String = "", state: Bool? = nil, enabled: Bool = true) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.isEnabled = enabled && action != nil
        if let state { item.state = state ? .on : .off }
        return item
    }

    // MARK: - Hooks

    private func offerHookInstall() {
        let defaults = UserDefaults.standard
        guard !HookInstaller.isInstalled(), !defaults.bool(forKey: "didOfferHooks") else { return }
        defaults.set(true, forKey: "didOfferHooks")

        let alert = NSAlert()
        alert.messageText = "Instalar hooks do Claude Code?"
        alert.informativeText = "A Ilha adiciona hooks HTTP em ~/.claude/settings.json (com backup) para acompanhar suas sessões e pedir permissões no notch. Se a Ilha estiver fechada, o Claude Code segue normal."
        alert.addButton(withTitle: "Instalar")
        alert.addButton(withTitle: "Agora não")
        if runModal(alert) == .alertFirstButtonReturn {
            installHooks()
        }
    }

    @objc private func installHooks() {
        do {
            try HookInstaller.install()
            inform("Hooks instalados", "Abra uma sessão nova do claude no terminal. Sessões que já estavam abertas não reagem.")
        } catch {
            inform("Não deu para instalar os hooks", error.localizedDescription, style: .warning)
        }
    }

    @objc private func removeHooks() {
        do {
            try HookInstaller.uninstall()
            inform("Hooks removidos", "Só as entradas da Ilha foram apagadas. O backup original fica em ~/.claude/settings.json.ilha-backup.")
        } catch {
            inform("Não deu para remover os hooks", error.localizedDescription, style: .warning)
        }
    }

    // MARK: - Preferências

    @objc private func editAPIKey() {
        let hasKey = Keychain.read() != nil
        let alert = NSAlert()
        alert.messageText = "Chave da API da Anthropic"
        alert.informativeText = "Usada para perguntar sobre arquivos. É cobrada à parte da assinatura do Claude (console.anthropic.com) e fica guardada no Keychain."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = hasKey ? "Já existe uma chave salva — cole outra para trocar" : "sk-ant-…"
        alert.accessoryView = field
        alert.addButton(withTitle: "Salvar")
        alert.addButton(withTitle: "Cancelar")
        if hasKey { alert.addButton(withTitle: "Apagar chave") }
        alert.window.initialFirstResponder = field

        switch runModal(alert) {
        case .alertFirstButtonReturn:
            let key = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty { Keychain.save(key) }
        case .alertThirdButtonReturn:
            Keychain.delete()
        default:
            break
        }
    }

    @objc private func editModel() {
        let alert = NSAlert()
        alert.messageText = "Modelo do Claude"
        alert.informativeText = "Usado para as perguntas sobre arquivos. Padrão: \(ClaudeAPI.defaultModel)."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.stringValue = ClaudeAPI.model
        alert.accessoryView = field
        alert.addButton(withTitle: "Salvar")
        alert.addButton(withTitle: "Cancelar")
        alert.window.initialFirstResponder = field
        if runModal(alert) == .alertFirstButtonReturn {
            let model = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            UserDefaults.standard.set(model.isEmpty ? nil : model, forKey: "model")
        }
    }

    @objc private func toggleSound() {
        let defaults = UserDefaults.standard
        defaults.set(!defaults.bool(forKey: "soundOnFinish"), forKey: "soundOnFinish")
    }

    @objc private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            inform("Não deu para mudar a abertura automática", error.localizedDescription, style: .warning)
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Alertas

    private func runModal(_ alert: NSAlert) -> NSApplication.ModalResponse {
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal()
    }

    private func inform(_ title: String, _ text: String, style: NSAlert.Style = .informational) {
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = title
        alert.informativeText = text
        _ = runModal(alert)
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
