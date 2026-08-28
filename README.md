```
 ⠀⠀⠀⠀⠀⠀⣠⣾⣿⣿⣿⠀⠀⠀⠀⠀⠀⠀⠀
 ⠀⠀⠀⠀⠀⢰⣿⡿⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
 ⠀⠀⠀⣠⣶⣿⣿⣷⣶⡶⣶⣶⣆⠀⠀⠀⣴⣶⣶⠆
 ⠀⠀⠀⠉⢹⣿⣿⠉⠉⠀⠘⢿⣿⣧⣀⣾⣿⡿⠃⠀             Tiny, open, embeddable, native coding agent.
 ⠀⠀⠀⠀⣼⣿⡏⠀⠀⠀⠀⠀⠻⣿⣿⣿⠟⠀⠀⠀
 ⠀⠀⠀⢀⣿⣿⠃⠀⠀⠀⠀⢠⣦⠘⢿⣿⣷⡀⠀⠀             A fork of fx, adapted for DeepSeek.
 ⠀⠀⠀⣸⣿⡟⠀⠀⠀⠀⣰⣿⣿⠗⠀⠻⣿⣿⣄⠀
 ⠀⠀⠀⣿⣿⠇⠀⠀⠀⠾⠿⠿⠋⠀⠀⠀⠘⠿⠿⠦             ⚠ Status: Experimental. Use at your own risk.
  ⠀⣸⣿⡿⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
 ⣿⣿⣿⠟⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
```

# DeepSeek fork of fx

This is a fork of [fx](https://github.com/vercel-labs/fx). Its purpose is a first-class DeepSeek provider: fx talks to DeepSeek directly at `https://api.deepseek.com` with your API key. ChatGPT login is unchanged, as is the rest of fx. NB. fx stores API keys in plaintext on linux when necessary.

This fork is not offered as a pull request. Upstream fx routes model access through Vercel AI Gateway by design; adding a per-vendor API provider (DeepSeek talking straight to `api.deepseek.com`) subverts that. When DeepSeek and other models are available through independent, non-Vercel routes in upstream fx, this repository can be retired.

It is not kept in sync with upstream. Do not expect ongoing feature work or regular rebases. Updates, if any, are limited to major bugs or security issues.

Do not install from `https://fx.sh/setup.sh`. That script installs official fx from the CDN, not this fork.

## Install on Linux

Building fx requires [Zig 0.16.0+](https://ziglang.org/download/). Then:

```bash
git clone https://github.com/ldbiz/fx.git
cd fx
zig build -Doptimize=ReleaseSafe
mkdir -p ~/.local/bin
install -m 755 zig-out/bin/fx ~/.local/bin/fx
```

`~/.local/bin` is the same default location as upstream's installer. If it is not already on your `PATH`:

```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
```

Use `~/.zshrc` instead of `~/.bashrc` if your shell is zsh. Confirm with `which fx` and `fx --help`.

Rebuild from this checkout to update. Auto-upgrade and `fx upgrade` are disabled in this fork so they cannot replace your binary with upstream.

## Sign in

### DeepSeek

Get an API key from [DeepSeek](https://platform.deepseek.com), then:

```bash
export DEEPSEEK_API_KEY="your-api-key"
fx login deepseek
fx
```

Requests go directly to `https://api.deepseek.com` using your key. fx supports `deepseek-v4-flash` and `deepseek-v4-pro`, including streamed thinking and agent tool calls.

You can also store a key interactively via `/setup` → **Connections** → **DeepSeek API key** (saved to the same profile keychain or `~/.fx/deepseek-api-key` path used for other stored keys). After interactive save, the stored key is preferred over the environment variable until you remove it with `/logout deepseek` or clear the remembered credential source. Unset `DEEPSEEK_API_KEY` and restart fx to clear an environment key.

### ChatGPT

Same as upstream. With an eligible ChatGPT subscription:

```bash
fx login codex
fx
```

### Run fx

```bash
cd your_project
fx
```

The current directory becomes the primary workspace. Enter a prompt, or run `/help` to browse interactive commands.

Inside fx, open `/setup` and choose **Model provider** to move between DeepSeek, Codex, Gateway, and Grok. `/model` lists the active provider's models.

## Official fx

For the official product, CDN install, documentation, and issue tracker, start at [fx.sh](https://fx.sh) and [vercel-labs/fx](https://github.com/vercel-labs/fx).

The remainder of this file is the upstream README, except the CDN install command, which would replace this fork.

---

```
 ⠀⠀⠀⠀⠀⠀⣠⣾⣿⣿⣿⠀⠀⠀⠀⠀⠀⠀⠀
 ⠀⠀⠀⠀⠀⢰⣿⡿⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
 ⠀⠀⠀⣠⣶⣿⣿⣷⣶⡶⣶⣶⣆⠀⠀⠀⣴⣶⣶⠆
 ⠀⠀⠀⠉⢹⣿⣿⠉⠉⠀⠘⢿⣿⣧⣀⣾⣿⡿⠃⠀             Tiny, open, embeddable, native coding agent.
 ⠀⠀⠀⠀⣼⣿⡏⠀⠀⠀⠀⠀⠻⣿⣿⣿⠟⠀⠀⠀
 ⠀⠀⠀⢀⣿⣿⠃⠀⠀⠀⠀⢠⣦⠘⢿⣿⣷⡀⠀⠀             Rebuild from this checkout.
 ⠀⠀⠀⣸⣿⡟⠀⠀⠀⠀⣰⣿⣿⠗⠀⠻⣿⣿⣄⠀
 ⠀⠀⠀⣿⣿⠇⠀⠀⠀⠾⠿⠿⠋⠀⠀⠀⠘⠿⠿⠦             ⚠ Status: Experimental. Use at your own risk.
  ⠀⣸⣿⡿⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
 ⣿⣿⣿⠟⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
```

fx is a coding agent harness and CLI written in Zig, optimized for research and embeddability as part of larger systems.

It focuses on minimalism and performance across the board, from system prompt design to its tools, feature set, and 7.8 MiB binary.

For end users, its CLI output style and form factor aim to be closer to a Unix shell than a heavy "IDE in the terminal" TUI.

It's open source (Apache-2.0), model-agnostic, and suitable for both local and cloud inference.

## Install

This checkout is the DeepSeek fork. Install from source as above. Do not run `curl -fsSL https://fx.sh/setup.sh | bash` — that installs official fx from the CDN.

## Run fx

Sign in with Vercel AI Gateway:

```bash
fx login
```

Or use an eligible ChatGPT subscription through OpenAI Codex OAuth:

```bash
fx login codex
fx
```

Or use an eligible Grok subscription through xAI OAuth:

```bash
fx login grok
fx
```

Or use your own DeepSeek API key directly:

```bash
export DEEPSEEK_API_KEY="your-api-key"
fx login deepseek
fx
```

DeepSeek requests go directly to `https://api.deepseek.com` using your key. fx supports the current `deepseek-v4-flash` and `deepseek-v4-pro` models, including streamed thinking and agent tool calls. You can set `DEEPSEEK_API_KEY` in the environment, or store a key interactively via `/setup` → **Connections** → **DeepSeek API key** (saved to the same profile keychain or `~/.fx/deepseek-api-key` path used for other stored keys). After interactive save, the stored key is preferred over the environment variable until you remove it with `/logout deepseek` or clear the remembered credential source.

`fx login codex` and `fx login grok` select that provider and a model from its authenticated catalog. `fx login deepseek` selects DeepSeek and its default model when a DeepSeek API key is available from the environment or profile store. Inside fx, open `/setup` and choose **Model provider** to move between Gateway, Codex, Grok, and DeepSeek. `/model` lists the active provider's models. Subscription model IDs are the raw IDs returned by each authenticated catalog. Use `/logout codex` or `/logout grok` to remove that subscription session without affecting other providers; `/logout deepseek` removes a stored DeepSeek key and recalculates credentials (unset `DEEPSEEK_API_KEY` and restart fx to clear an environment key). Choosing a provider again from **Model provider** starts sign-in or API-key entry when needed.

The OpenAI Codex route uses ChatGPT subscription access directly and never sends its OAuth token to Vercel AI Gateway. The session is stored privately at `~/.fx/chatgpt-auth.json` and refreshed when needed. On supported Codex models, `/fast` requests OpenAI's priority service tier and consumes ChatGPT credits at the higher Fast mode rate.

The Grok route uses subscription access directly at xAI and never sends its OAuth token to Vercel AI Gateway or OpenAI. Its session is stored privately at `~/.fx/grok-auth.json`, refreshed when needed, and used only with the authenticated xAI catalog and Responses API.

To use an AI Gateway API key instead:

```bash
fx setup
```

Run fx from a project:

```bash
cd your_project
fx
```

The current directory becomes the primary workspace. Enter a prompt, or run `/help` to browse interactive commands.

The status line hides the workspace path and Git branch by default. Enable the `Status line workspace` option in `/settings`, run `/statusline workspace`, or set it in `~/.fx/settings.json`:

```json
{
  "statusLine": {
    "workspace": true
  }
}
```

List saved sessions with `fx sessions`. Resume the latest session for the current workspace, or select an exact session ID, through the same command group:

```bash
fx session resume last
fx session resume --id <id>
```

Each interactive session names its terminal tab. The title prefers the session name, falls back to the workspace name, and keeps the active model as secondary context. Renaming or resuming a session updates the tab, and exiting clears the fx-owned title. Noninteractive commands do not emit terminal-title controls.

Run `/feedback` to open the feedback form at `fx.sh/feedback`. It does not create a diagnostic or change the clipboard.

Run `/trace` to create a private Markdown diagnostic with logs, session context, runtime state, permissions, and recent activity. On macOS, fx copies the `.md` file to the clipboard; on other platforms, it saves the file and prints its path. Review and redact the trace before sharing it.

Use `fx ask` for a single request:

```bash
fx ask "explain the changes in this repository"
```

Foreground terminal commands run with an explicit finite deadline. fx uses durable terminal sessions for services, watchers, GUI applications, and other long-lived work, and keeps captured foreground output available through an opaque bounded-read handle for the active session or `--no-save` process.

fx starts in `auto` permission mode. Routine understood development actions run directly. Each unresolved action receives one narrow safety review based on the current user request and the exact pending action. A clear result authorizes only that action. A caution or unavailable review holds the action and returns advice to the agent without opening a permission prompt or ending the turn. See [Permissions](https://fx.sh/docs/configure-fx/permissions) for other modes and persistent rules.

JSON and quiet requests stay noninteractive by default. Add `--prompt-permissions` to allow configured approval prompts when stdin is a TTY. Automatic safety review never opens that prompt. Prompt text is written to stderr, so JSON stdout stays parseable and quiet stdout stays empty. Piped or redirected stdin remains noninteractive and fails instead of waiting for approval.

Inside a saved session, `/permissions remember <allow|deny> <tool-name> <arguments-json>` stores an exact confirmed rule without running the action. `/permissions` lists stable rule IDs, and `/permissions revoke <rule-id>` removes a stored rule even when its original workspace or file state has changed.

## Embed fx

fx builds as a native binary or WebAssembly. Applications embedding fx can provide network transport, session storage, configuration, permission handling, and terminal I/O.

| Surface | Use |
| --- | --- |
| `fx acp` | Connect the native agent to editors and other Agent Client Protocol clients. |
| `createFxAgent()` | Embed the agent core in a JavaScript host with `fx-core.wasm`. |
| `createFxTerminal()` | Embed the interactive terminal with `fx-term.wasm`. |

The WebAssembly SDK is experimental. See the [WebAssembly SDK](sdk/README.md) and [ACP documentation](https://fx.sh/docs/using-fx/acp).

## Extend fx

Add reusable instructions with [skills](https://fx.sh/docs/capabilities/skills), connect external tools through [MCP](https://fx.sh/docs/capabilities/mcp), or delegate independent work to [subagents](https://fx.sh/docs/capabilities/subagents). Inside fx, `/mcp add <name> <command> [args...]` saves a local server and `/mcp add --transport http <name> <url>` saves a remote Streamable HTTP server. Project instruction files may link within their scope, and read-only workspace or compatibility skill directories and their primary `SKILL.md` files may link within their owning workspace or home; managed skills, secondary resources, and escaping links remain no-follow. Skills installed via symlinks that resolve outside home or workspace (e.g. Nix store paths) are loaded when their resolved target is inside a directory listed in the `FX_SKILL_SYMLINK_AUTHORITIES` environment variable (colon-separated absolute paths). `fx status` and `fx doctor` report an invalid trusted MCP profile without starting its servers.

## Documentation

Read the [fx documentation](https://fx.sh/docs).

## Build from source

Building fx requires [Zig 0.16.0+](https://ziglang.org/download/):

```bash
git clone https://github.com/vercel-labs/fx.git
cd fx
zig build -Doptimize=ReleaseSafe
./zig-out/bin/fx
```

Run the test suite with `zig build test`. See [CONTRIBUTING.md](CONTRIBUTING.md) for development and contribution guidelines.

## License

[Apache-2.0](LICENSE)

Third-party licenses and attributions are listed in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Credits

Interface sounds by [cuelume](https://github.com/Danilaa1/cuelume).
