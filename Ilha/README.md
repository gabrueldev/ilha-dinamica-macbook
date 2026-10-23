# Ilha

Um "dynamic island" no notch do Mac para o Claude Code. Mostra o que cada sessão está fazendo, pede permissão no próprio notch, avisa quando o Claude termina e aceita arquivos arrastados para perguntar ao Claude.

## Instalar

1. Rode `swift --version`. Se não funcionar, rode `xcode-select --install`.
2. `cd Ilha && chmod +x build.sh && ./build.sh`
3. `open build/Ilha.app` (opcional: mova para `/Applications`).
4. Na primeira vez, aceite **Instalar hooks do Claude Code**.
5. Abra um terminal novo e rode `claude`. A ilha deve reagir. Sessões que já estavam abertas antes de instalar os hooks não reagem.

## Abrir no dia a dia

- **Finder**: dois cliques em `Ilha/build/Ilha.app` (ou em `/Applications/Ilha.app`, se tiver movido).
- **Terminal**: `open ~/Documents/IMPORTANTE/ilha_dinamica_claude/Ilha/build/Ilha.app`
- **Automático**: menu ✦ → **Abrir ao iniciar sessão**. Se ativar a partir de `build/`, recompilar pode quebrar o atalho, então prefira mover para `/Applications` antes.

A Ilha não aparece no Dock. Ela fica só no ícone ✦ da barra de menus e no notch. Para fechar: ✦ → **Sair**.

Recolhida, ela fica invisível enquanto não houver nenhuma sessão do Claude Code ativa.

## Menu ✦

| Item | O que faz |
|---|---|
| Status do servidor | Mostra se a porta 47821 está ativa |
| Instalar / Remover hooks | Liga ou desliga a integração com o Claude Code |
| Chave da API… / Modelo… | Para perguntar sobre arquivos |
| Som ao terminar | Toca um som quando uma sessão termina |
| Abrir ao iniciar sessão | Abre a Ilha quando você faz login no Mac |
| Sair | Fecha o app (⌘Q) |

## Usar

- **Passar o mouse no notch**: lista as sessões. Clicar numa sessão traz o Terminal / iTerm / VS Code para frente.
- **Permissão**: quando o Claude Code pede permissão, a ilha expande com **Negar** (⎋), **Permitir** (⏎) e **Ver no terminal**. Se ninguém responder em ~280 s, a pergunta volta para o terminal.
- **Terminou**: a ilha mostra um trecho da última mensagem por 4 s, com som (dá para desligar no menu).
- **Arrastar arquivo** (PDF, imagens, textos, .docx…) para o notch → digite a pergunta → a resposta chega em streaming.
- **Comandos rápidos** (no notch → **Perguntar ao Claude…**), não precisam de chave da API:
  - `abrir calculadora`, `abrir photoshop`, `abrir vscode` → abre o app (aceita o nome em português).
  - `abrir downloads`, `abrir ~/Projetos` → abre a pasta no Finder.
  - `gabrueldev.com`, `https://github.com`, `localhost:3000` → abre no Safari (com ou sem `abrir`).

## Chave da API (só para perguntar sobre arquivos)

Menu ✦ → **Chave da API…** → cole a chave de [console.anthropic.com](https://console.anthropic.com). Ela fica guardada no Keychain.

> A API é **cobrada à parte** da assinatura do Claude (Pro/Max). O acompanhamento das sessões e as permissões não usam a API e não custam nada.

O modelo padrão é `claude-sonnet-5-5` e pode ser trocado no menu **Modelo…**.

## Não está reagindo?

1. **A Ilha está aberta?** Veja se o ✦ aparece na barra de menus, ou rode `curl -s http://127.0.0.1:47821/health` (tem que responder `ok`).
2. **Os hooks estão instalados?** Abra o menu ✦: tem que aparecer "Hooks do Claude Code instalados" com ✓.
3. **A sessão é nova?** Só sessões abertas **depois** de instalar os hooks reagem. Feche o `claude` e abra de novo, porque `/clear` não basta.
4. **"Porta 47821 ocupada"** no menu: provavelmente tem outra Ilha aberta. Rode `pkill -x Ilha` e abra de novo.

## Desinstalar

1. Menu ✦ → **Remover hooks** (só as entradas da Ilha saem do `~/.claude/settings.json`).
2. Apague o app.

O `settings.json` original fica salvo em `~/.claude/settings.json.ilha-backup`.

## Como funciona

O Claude Code chama hooks HTTP em `http://127.0.0.1:47821/hook`. Se a Ilha estiver fechada, a conexão falha e o Claude Code segue normalmente, sem travar nada.

Teste manual:

```bash
curl -s http://127.0.0.1:47821/health
curl -s -X POST http://127.0.0.1:47821/hook -d '{"hook_event_name":"PreToolUse","session_id":"t1","cwd":"/Users/eu/projeto","tool_name":"Bash","tool_input":{"command":"npm test"}}'
curl -s -X POST http://127.0.0.1:47821/hook -d '{"hook_event_name":"PermissionRequest","session_id":"t1","cwd":"/Users/eu/projeto","tool_name":"Bash","tool_input":{"command":"git push origin main"}}'
# ^ esse último fica esperando até você clicar na ilha
```
