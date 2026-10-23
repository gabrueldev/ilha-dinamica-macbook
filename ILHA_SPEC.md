# Ilha — um "dynamic island" no notch do Mac para o Claude

> Especificação para construir o app. Feita para ser entregue ao Claude Code (VS Code) e implementada de ponta a ponta.
> Inspiração: o app "korus" (Windows) de um reel do Instagram e o Vibe Notch / Claude Island (Mac, open source).

---

## 1. O que é

Um app de barra de menu do macOS (sem ícone no Dock) que desenha uma "ilha" preta colada no **notch** do MacBook. Ela:

1. **Mostra ao vivo o que o Claude Code está fazendo** em cada sessão aberta no terminal (ex.: `Read billing.ts`, `Bash npm test`).
2. **Pede permissão na própria ilha**: quando o Claude Code quer rodar algo que precisa de aprovação (ex.: `git push origin main`), a ilha expande com **Permitir / Negar / Ver no terminal**.
3. **Avisa quando o Claude terminou**, mostrando um trecho da última mensagem, por alguns segundos.
4. **Aceita arquivos arrastados** (PDF, imagem, texto, .docx): soltou na ilha → aparece um campo "Pergunte algo sobre o arquivo…" → a resposta do Claude (API) aparece em streaming dentro da ilha.
5. Tem um **mascote próprio** (original, não copiar o do korus) que muda de expressão conforme o estado.

Nome do app: **Ilha**. Bundle id: `app.ilha.notch`.

---

## 2. Stack e requisitos

- **Swift + SwiftUI + AppKit**, como **Swift Package** (sem projeto do Xcode).
- Compila com `swift build`; só precisa das **Command Line Tools** (`xcode-select --install`). Não precisa do Xcode completo.
- macOS **13+** (`.macOS(.v13)`), `swift-tools-version:5.9` (modo de linguagem Swift 5, para evitar erros de concorrência estrita do Swift 6).
- Sem dependências externas.
- Funciona em Mac **com ou sem notch**. Sem notch, a ilha fica no topo central, logo abaixo/na altura da barra de menus.

---

## 3. Estrutura de arquivos

```
Ilha/
├── Package.swift
├── Info.plist
├── build.sh                 # gera build/Ilha.app
├── README.md
└── Sources/Ilha/
    ├── main.swift           # NSApplication + AppDelegate (status item, painel, servidor)
    ├── NotchPanel.swift     # NSPanel sem borda + geometria do notch + passagem de cliques
    ├── NotchShape.swift     # Shape com cantos de cima "abertos" e de baixo arredondados
    ├── IslandView.swift     # SwiftUI: estados recolhido / expandido / permissão / concluído / arquivo
    ├── Mascot.swift         # mascote desenhado em SwiftUI (Canvas/Shapes) com expressões
    ├── SessionStore.swift   # ObservableObject com sessões, permissões pendentes, estado da UI
    ├── HookServer.swift     # servidor HTTP mínimo (Network.framework) em 127.0.0.1:47821
    ├── HookInstaller.swift  # instala/remove os hooks em ~/.claude/settings.json
    ├── ClaudeAPI.swift      # chamada streaming à Messages API com o arquivo arrastado
    ├── FileLoader.swift     # transforma arquivo em bloco de conteúdo (PDF/imagem/texto/docx)
    └── Keychain.swift       # guarda a chave da API no Keychain
```

### 3.1 Arquivos já prontos

**Package.swift**
```swift
// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Ilha",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Ilha",
            path: "Sources/Ilha"
        )
    ]
)
```

**Info.plist** (`LSUIElement = true` → sem ícone no Dock)
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>app.ilha.notch</string>
    <key>CFBundleName</key>
    <string>Ilha</string>
    <key>CFBundleDisplayName</key>
    <string>Ilha</string>
    <key>CFBundleExecutable</key>
    <string>Ilha</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
```

**build.sh**
```bash
#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
APP=build/Ilha.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Ilha "$APP/Contents/MacOS/Ilha"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --deep -s - "$APP"   # assinatura ad-hoc, suficiente para rodar localmente
echo "Pronto: $APP  (abra com: open $APP)"
```

---

## 4. Integração com o Claude Code (hooks HTTP)

O Claude Code tem **hooks do tipo `http`**: ele faz um `POST` com o JSON do evento para uma URL e lê a resposta. Assim não precisamos de scripts, só de um servidor local no app.

Documentação: https://code.claude.com/docs/en/hooks

### 4.1 Comportamento importante (confirmado na doc)
- Resposta **2xx com corpo vazio** = "sem decisão", o fluxo normal segue.
- Resposta **2xx com JSON** = interpretada como a saída de um hook de comando.
- **Conexão recusada, status não-2xx ou timeout = erro não bloqueante**: o Claude Code segue normalmente.
  → Se o app estiver fechado, **nada quebra**. Não usar `onFailure: "block"`.
- `timeout` é em **segundos**.

### 4.2 Eventos que vamos ouvir
| Evento | Para quê | Resposta do app |
|---|---|---|
| `SessionStart` | criar a sessão na lista (usar `cwd` → nome do projeto) | vazia |
| `UserPromptSubmit` | marcar a sessão como "trabalhando" | vazia |
| `PreToolUse` | mostrar a ação atual (ex.: `Bash npm test`) | vazia (não decide nada aqui) |
| `PostToolUse` | atualizar status e resolver permissão pendente "órfã" | vazia |
| `PermissionRequest` | **segurar a requisição** até o usuário clicar | JSON de decisão (abaixo) |
| `Notification` | `idle_prompt` / `permission_prompt` → chamar atenção | vazia |
| `Stop` | "Claude terminou" + trecho de `last_assistant_message` | vazia |
| `SessionEnd` | remover a sessão | vazia |

Campos comuns de entrada (todos os eventos): `session_id`, `cwd`, `hook_event_name`, `transcript_path`, `permission_mode`. Eventos de ferramenta trazem `tool_name`, `tool_input` e (no PreToolUse) `tool_use_id`. **Ler tudo de forma defensiva** (campos podem faltar ou mudar de versão). Usar `JSONSerialization` em `[String: Any]`, não `Codable` rígido.

### 4.3 Resposta do PermissionRequest
Permitir:
```json
{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}
```
Negar:
```json
{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"Negado pela Ilha"}}}
```
"Ver no terminal" → responder **200 com corpo vazio** (cai no prompt normal do terminal).

Regras:
- Guardar a conexão aberta da requisição pendente (por id interno) e responder quando o usuário clicar.
- **Timeout interno de 280 s**: se ninguém clicar, responder vazio (volta para o terminal). O hook é configurado com `timeout: 300`.
- Se chegar `PostToolUse`, `Stop` ou `SessionEnd` da **mesma sessão** enquanto houver permissão pendente, responder vazio e fechar o cartão (o usuário respondeu pelo terminal).
- Se houver várias pendentes, mostrar uma por vez (fila), com contador "1/3".

### 4.4 Config gerada em `~/.claude/settings.json`
O app instala sozinho (item de menu "Instalar hooks do Claude Code") e faz **merge** sem apagar nada do usuário:

```json
{
  "hooks": {
    "SessionStart":      [{ "hooks": [{ "type": "http", "url": "http://127.0.0.1:47821/hook", "timeout": 5 }] }],
    "UserPromptSubmit":  [{ "hooks": [{ "type": "http", "url": "http://127.0.0.1:47821/hook", "timeout": 5 }] }],
    "PreToolUse":        [{ "matcher": "*", "hooks": [{ "type": "http", "url": "http://127.0.0.1:47821/hook", "timeout": 5 }] }],
    "PostToolUse":       [{ "matcher": "*", "hooks": [{ "type": "http", "url": "http://127.0.0.1:47821/hook", "timeout": 5 }] }],
    "PermissionRequest": [{ "matcher": "*", "hooks": [{ "type": "http", "url": "http://127.0.0.1:47821/hook", "timeout": 300 }] }],
    "Notification":      [{ "hooks": [{ "type": "http", "url": "http://127.0.0.1:47821/hook", "timeout": 5 }] }],
    "Stop":              [{ "hooks": [{ "type": "http", "url": "http://127.0.0.1:47821/hook", "timeout": 5 }] }],
    "SessionEnd":        [{ "hooks": [{ "type": "http", "url": "http://127.0.0.1:47821/hook", "timeout": 5 }] }]
  }
}
```

`HookInstaller`:
- Antes da primeira alteração, fazer backup em `~/.claude/settings.json.ilha-backup` (só se ainda não existir).
- Idempotente: remover qualquer grupo cujo hook tenha `url` começando com `http://127.0.0.1:47821/` e então adicionar os nossos.
- "Remover hooks" faz só a remoção (e apaga a chave `hooks` se ficar vazia).
- Escrever com `.prettyPrinted` e `.withoutEscapingSlashes`.
- Na primeira execução, se os hooks não estiverem instalados, mostrar um `NSAlert` perguntando se quer instalar.

---

## 5. Servidor HTTP local (`HookServer.swift`)

- `NWListener` (Network.framework) **só em loopback**: `parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: 47821)`.
- Para cada conexão: ir acumulando `Data` até achar `\r\n\r\n`, ler o `Content-Length` e esperar o corpo completo.
- Rotas: `POST /hook` (eventos) e `GET /health` (responde `ok`, útil para teste com curl).
- Resposta:
  ```
  HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: N\r\nConnection: close\r\n\r\n<corpo>
  ```
- Despachar os eventos para o `SessionStore` na **main thread**.
- Se a porta estiver ocupada, mostrar o erro no menu (não travar).

Teste manual:
```bash
curl -s http://127.0.0.1:47821/health
curl -s -X POST http://127.0.0.1:47821/hook -d '{"hook_event_name":"PreToolUse","session_id":"t1","cwd":"/Users/eu/projeto","tool_name":"Bash","tool_input":{"command":"npm test"}}'
curl -s -X POST http://127.0.0.1:47821/hook -d '{"hook_event_name":"PermissionRequest","session_id":"t1","cwd":"/Users/eu/projeto","tool_name":"Bash","tool_input":{"command":"git push origin main"}}'
# ^ esse último deve ficar esperando até você clicar na ilha
```

---

## 6. Estado (`SessionStore.swift`)

```swift
enum SessionStatus { case idle, working(String), waitingPermission, done(String) }

struct Session: Identifiable {
    let id: String          // session_id
    var project: String     // último componente do cwd
    var status: SessionStatus
    var lastUpdate: Date
}

struct PendingPermission: Identifiable {
    let id: UUID
    let sessionID: String
    let project: String
    let toolName: String
    let summary: String     // ex.: "git push origin main"
    let respond: (Data) -> Void   // envia a resposta HTTP e fecha a conexão
}
```

Texto curto da ação, a partir de `tool_name` + `tool_input`:
- `Bash` → `command` (primeira linha, cortada em ~60 caracteres)
- `Read` / `Edit` / `Write` / `MultiEdit` / `NotebookEdit` → nome do arquivo de `file_path`
- `Grep` / `Glob` → `pattern`
- `WebFetch` → host de `url`; `WebSearch` → `query`
- `Task` / `Agent` → `description`
- outros → o próprio `tool_name` (MCP: `mcp__server__tool` → `server · tool`)

Limpeza: remover sessões sem atualização há mais de 30 min (timer a cada 60 s).

Estado da UI (`@Published var mode`):
`collapsed`, `hover` (expandido mostrando sessões), `permission`, `finished` (auto-fecha em 4 s), `dropTarget` (arrastando arquivo), `ask` (arquivo solto + pergunta + resposta).
Prioridade: `permission` > `ask` > `dropTarget` > `finished` > `hover` > `collapsed`.

---

## 7. Janela no notch (`NotchPanel.swift`)

### 7.1 Geometria do notch
```swift
let screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main!
let hasNotch = screen.safeAreaInsets.top > 0
let notchHeight = hasNotch ? screen.safeAreaInsets.top : NSStatusBar.system.thickness
var notchWidth: CGFloat = 200
if hasNotch, let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea {
    notchWidth = screen.frame.width - l.width - r.width
}
```
Recalcular em `NSApplication.didChangeScreenParametersNotification`.

### 7.2 Painel
- `NSPanel` com `styleMask: [.borderless, .nonactivatingPanel]`, `isOpaque = false`, `backgroundColor = .clear`, `hasShadow = false`.
- `level = .statusBar` (ou `NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)`) para ficar **por cima da barra de menus**.
- `collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]`.
- Subclasse com `override var canBecomeKey: Bool { true }` (precisa para digitar a pergunta) e `canBecomeMain` `false`.
- Tamanho **fixo grande** (ex.: 700×500), colado no topo e centralizado: `x = screen.frame.midX - 350`, `y = screen.frame.maxY - 500`.
- O conteúdo SwiftUI (`NSHostingView`) desenha a ilha **alinhada ao topo-centro**; o resto é transparente.

### 7.3 Deixar os cliques passarem (essencial)
A área transparente do painel não pode bloquear a barra de menus nem os apps. Solução: um **Timer a ~30 Hz** que:
1. Lê `NSEvent.mouseLocation`.
2. Calcula o retângulo atual da ilha em coordenadas de tela: `(midX - w/2, screen.maxY - h, w, h)` + margem de 6 pt, onde `w`/`h` vêm do estado atual.
3. `panel.ignoresMouseEvents = !retângulo.contains(mouse)`.
4. Hover: mouse dentro por mais de 0,15 s → `mode = .hover`; saiu por mais de 0,3 s → volta a `collapsed` (a menos que haja `permission`/`ask`).

### 7.4 Detectar arrasto de arquivo (sem permissões especiais)
No mesmo timer:
- Quando `NSEvent.pressedMouseButtons & 1 != 0` começa, guardar `NSPasteboard(name: .drag).changeCount`.
- Se o `changeCount` mudar enquanto o botão está pressionado → há **um arrasto em andamento**.
- Se, nesse estado, o mouse estiver a menos de ~90 pt do topo e a menos de ~300 pt do centro → `mode = .dropTarget` e `ignoresMouseEvents = false` (para o `onDrop` do SwiftUI receber).
- Soltou o botão → sai do `dropTarget` se não houve drop.

---

## 8. Visual (`IslandView.swift`, `NotchShape.swift`, `Mascot.swift`)

### 8.1 Forma
`NotchShape(topRadius: 6, bottomRadius: r)`, com os cantos de cima curvando **para fora** (igual ao notch real) e os de baixo arredondados:
```
move(0,0)
quadCurve(to: (tr, tr), control: (tr, 0))
line(to: (tr, h - br))
quadCurve(to: (tr + br, h), control: (tr, h))
line(to: (w - tr - br, h))
quadCurve(to: (w - tr, h - br), control: (w - tr, h))
line(to: (w - tr, tr))
quadCurve(to: (w, 0), control: (w - tr, 0))
close
```
Preenchimento **preto puro** (para se fundir ao notch). `bottomRadius` vai de ~10 (recolhido) a ~24 (expandido). Animar com `.spring(response: 0.35, dampingFraction: 0.8)`.

### 8.2 Tamanhos por estado
| Estado | Largura | Altura |
|---|---|---|
| collapsed sem sessão | notchWidth | notchHeight (fica invisível no notch) |
| collapsed com sessão ativa | notchWidth + 2×36 ("orelhas") | notchHeight |
| hover | 460 | ~ notchHeight + 44 por sessão (mín. 140, máx. 320) |
| permission | 480 | notchHeight + 150 |
| finished | 440 | notchHeight + 90 |
| dropTarget | 420 | notchHeight + 110 |
| ask | 520 | notchHeight + 140 até 420 (cresce com a resposta) |

No modo recolhido com sessão: **mascote na orelha esquerda**, e na direita um indicador (bolinha pulsando laranja = trabalhando; amarela = esperando permissão; verde = terminou; número se houver mais de uma sessão). O conteúdo expandido começa **abaixo** de `notchHeight` (a faixa do notch fica vazia; a câmera está ali).

### 8.3 Conteúdo
- **hover**: cabeçalho (mascote + "Ilha" + nº de sessões) e lista: `projeto · ação atual` com ícone de estado. Rodapé discreto: "Arraste um arquivo aqui para perguntar ao Claude". Clique numa sessão: ativar o Terminal/VS Code (`NSWorkspace` — tentar Terminal, iTerm, VS Code, nessa ordem, pelo bundle id que estiver rodando).
- **permission**: "**projeto** quer rodar" + ferramenta + comando em fonte mono (até 3 linhas) + botões **Negar** (cinza), **Terminal** (texto) e **Permitir** (destaque). Atalhos com a ilha em foco: ⏎ = permitir, ⎋ = negar.
- **finished**: "✓ projeto terminou" + até 2 linhas de `last_assistant_message`. Som `NSSound(named: "Glass")` (desligável no menu).
- **dropTarget**: área tracejada "Solte aqui · PDF · Imagens · Textos · Docs", com o mascote animado.
- **ask**: chip com ícone + nome do arquivo (×  para remover), `TextField` "Pergunte algo sobre o arquivo…" (focado; ao entrar nesse modo chamar `panel.makeKey()`), resposta em `ScrollView` com texto selecionável e botão "Copiar". ⎋ fecha.

Tipografia: SF (`.system`), branco 90% para texto principal e 55% para o secundário. Fonte mono `.system(.caption, design: .monospaced)` para comandos.

### 8.4 Mascote (original!)
Uma "gotinha" arredondada **coral** (`#D97757`), ~18 pt no modo recolhido e ~28 pt no cabeçalho, com dois olhos brancos ovais. Expressões:
- **idle**: olhos normais, piscando a cada 3–5 s (aleatório).
- **working**: olhos olhando para os lados (animação de vaivém) e um leve "quique" vertical.
- **waitingPermission**: olhos grandes + um "!" amarelo pequeno acima.
- **done**: olhos em arco feliz (`^ ^`).
- **dropTarget**: boca aberta em "o", como quem vai "comer" o arquivo.
Desenhar com `Canvas` ou `Shape`s simples + `TimelineView(.animation)`. **Não** copiar o mascote branco do korus.

---

## 9. Arrastar arquivo → perguntar ao Claude

### 9.1 `FileLoader.swift` — arquivo → bloco de conteúdo da API
| Tipo | Como enviar |
|---|---|
| `.pdf` | `{"type":"document","source":{"type":"base64","media_type":"application/pdf","data":…}}` |
| `.png .jpg .jpeg .gif .webp` | `{"type":"image","source":{"type":"base64","media_type":"image/…","data":…}}` |
| `.heic .tiff .bmp` | converter para PNG (`NSImage` → `NSBitmapImageRep.representation(using: .png)`) e enviar como imagem |
| `.doc .docx .rtf .odt .html` | extrair texto com `/usr/bin/textutil -convert txt -stdout <arquivo>` (via `Process`) e enviar como texto |
| texto (`.txt .md .csv .json .swift .py .js .ts …` ou qualquer arquivo decodificável em UTF-8) | `{"type":"text","text":"<arquivo nome=\"x\">\n…\n</arquivo>"}` |
| outros | erro amigável "Tipo de arquivo não suportado" |

Limites: recusar acima de 30 MB; texto acima de ~400 mil caracteres → cortar e avisar.

### 9.2 `ClaudeAPI.swift` — streaming
- `POST https://api.anthropic.com/v1/messages`
- Headers: `x-api-key`, `anthropic-version: 2023-06-01`, `content-type: application/json`
- Corpo:
  ```json
  {
    "model": "<modelo>",
    "max_tokens": 2048,
    "stream": true,
    "system": "Você é um assistente direto. Responda em português do Brasil, de forma curta, salvo se pedirem detalhes.",
    "messages": [{ "role": "user", "content": [ <bloco do arquivo>, {"type":"text","text":"<pergunta>"} ] }]
  }
  ```
- Modelo padrão em `UserDefaults` (chave `model`), editável pelo menu. Padrão: `claude-sonnet-5-5`. Conferir os nomes atuais em https://docs.claude.com/en/docs/about-claude/models.
- Ler com `URLSession.shared.bytes(for:)` → `for try await line in bytes.lines`; para cada `data: {...}` com `"type":"content_block_delta"` e `delta.type == "text_delta"`, acrescentar `delta.text` à resposta (main thread).
- Status ≠ 200: ler o corpo e mostrar `error.message` na ilha.
- Botão "Parar" cancela a `Task`.
- Permitir pergunta **sem arquivo** também (clicar na ilha no modo hover → "Perguntar ao Claude…").

### 9.3 Chave da API (`Keychain.swift`)
- `SecItemAdd` / `SecItemCopyMatching` / `SecItemDelete` com `kSecClassGenericPassword`, `kSecAttrService = "app.ilha.notch"`, `kSecAttrAccount = "anthropic-api-key"`.
- Fallback: variável de ambiente `ANTHROPIC_API_KEY`.
- Se não houver chave, o modo `ask` mostra um `SecureField` "Cole sua chave da API (console.anthropic.com)" + Salvar.
- A chave da API é cobrada à parte da assinatura do Claude. Deixar isso claro no README.

---

## 10. Menu da barra (`main.swift`)

`NSStatusItem` com ícone SF Symbol (`sparkle` ou `circle.hexagongrid`) e menu:
- Status: "Servidor: ativo na porta 47821" / erro
- Instalar hooks do Claude Code / Remover hooks
- Chave da API…  (NSAlert com NSSecureTextField)
- Modelo…  (NSAlert com NSTextField)
- ☑ Som ao terminar
- ☑ Abrir ao iniciar sessão (`SMAppService.mainApp.register()` / `unregister()`, macOS 13+)
- Sair

`AppDelegate.applicationDidFinishLaunching`: `NSApp.setActivationPolicy(.accessory)`, iniciar `HookServer`, criar o painel, montar o menu, oferecer a instalação dos hooks se faltarem.

---

## 11. README (para o usuário final)

1. `xcode-select --install` (se `swift --version` não funcionar)
2. `cd Ilha && chmod +x build.sh && ./build.sh`
3. `open build/Ilha.app` (opcional: mover para `/Applications`)
4. Na primeira vez, aceitar "Instalar hooks do Claude Code"
5. Abrir um terminal novo e rodar `claude`. A ilha deve reagir.
6. Para perguntar sobre arquivos: menu → Chave da API… → colar a chave.
7. Desinstalar: menu → Remover hooks; apagar o app. O backup fica em `~/.claude/settings.json.ilha-backup`.

---

## 12. Checklist de aceite

- [ ] `./build.sh` compila sem warnings graves e gera `build/Ilha.app`.
- [ ] Com o app fechado, o Claude Code funciona normalmente (hooks falham sem bloquear).
- [ ] A ilha recolhida some no notch; com uma sessão ativa aparecem as orelhas com o mascote e o indicador.
- [ ] A área transparente **não bloqueia** cliques na barra de menus nem nas janelas abaixo.
- [ ] Hover expande e mostra as sessões; sair do hover recolhe.
- [ ] Os `curl`s da seção 5 funcionam; o de `PermissionRequest` fica esperando e responde o JSON certo para Permitir e para Negar, e vazio para Terminal.
- [ ] Rodando `claude` de verdade e pedindo algo que exija permissão (ex.: "faça git push"), aprovar pela ilha funciona.
- [ ] Responder pelo terminal fecha o cartão da ilha (via PostToolUse/Stop).
- [ ] "Claude terminou" aparece com um trecho da mensagem e some em 4 s.
- [ ] Arrastar PDF, PNG, .docx e .md abre o drop zone; soltar → pergunta → a resposta chega em streaming.
- [ ] Funciona em tela cheia e em vários Spaces; num Mac/monitor sem notch aparece no topo central.
- [ ] Instalar hooks duas vezes não duplica as entradas; Remover só remove as nossas.

---

## 13. Armadilhas conhecidas

- **Não** usar `NSWindow.Level.screenSaver`: fica por cima de tudo, até de alertas do sistema.
- `nonactivatingPanel` + `canBecomeKey = true` permite digitar **sem roubar o foco do app atual**. Ao sair do modo `ask`, chamar `panel.resignKey()`.
- `NSHostingView` dentro de um painel sem borda: definir `hostingView.layer?.backgroundColor = .clear` e `wantsLayer = true`.
- As atualizações da UI vindas do servidor precisam ir para `DispatchQueue.main`.
- Os campos de entrada dos hooks podem mudar entre versões do Claude Code. Fazer o parse defensivo e ignorar o que não reconhecer.
- O Claude Code lê o `settings.json` ao iniciar a sessão. Depois de instalar os hooks, só as **sessões novas** vão reagir.
- Mais de um monitor: usar a tela com notch; sem notch, a `NSScreen.main`.

---

## 14. Ideias para depois (fora do MVP)
- Atalhos/integrações (GitHub, Vercel, Stripe, n8n) como no vídeo.
- Mostrar o uso de tokens e o custo da sessão (ler o `transcript_path`).
- "Permitir sempre para este comando" (usar `permission_suggestions` / `updatedPermissions`, se disponíveis no evento).
- Temas e mascotes alternativos.
