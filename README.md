# LLM Analytics

**Local-first usage analytics for AI coding tools, as a native macOS app with a menu bar tray.**
Free and open source (MIT). No account, no telemetry. Your history never leaves your Mac.

LLM Analytics reads the session logs that Claude Code, Codex, Cursor, GitHub Copilot, Gemini CLI, OpenCode, Qwen Code, Continue, Kiro, Cline (and Roo / Kilo Code), Aider and Factory Droid already write to disk. It turns them into dashboards and updates them live as you work.

## Features

| Page | What you get |
|---|---|
| **Menu bar** | Today's cost, tokens, prompts and sessions; last-hour burn; 7-day sparkline; budget progress; sessions active right now; plan limits. Click a live session to open its transcript. |
| **Dashboard** | KPIs, GitHub-style activity heatmap, coding streaks, daily usage by editor, editor breakdown, token economy (input / output / cache), peak hours by weekday, top models and tools. |
| **Sessions** | Searchable, sortable table of every conversation. Opens any chat in a slide-over sidebar with markdown, syntax-highlighted code, tool calls and optional thinking blocks. |
| **Costs** | Budgets, plan value (plan price vs API-equivalent usage, projected to month end), estimated spend by month, day, model, editor and project with budget lines, **what-if** re-pricing on another model, Opus sessions that probably didn't need Opus, your most expensive sessions and the price table in use. |
| **Projects** | Per-project sessions, messages, tokens, models, editors and tools, with a drill-down detail view. |
| **Deep Analysis** | Tool × editor frequency heatmap, model distribution, token breakdown by model or editor, per-model detail table, session-size histogram. |
| **Compare** | Side-by-side editor columns: averages per session, output:input ratio, cache hit rate, cost per session, tool use. The best value in each comparison is starred. |
| **Subscriptions** | Plans, quotas and rate-limit windows with reset countdowns, plus manually tracked plans (Devin, Windsurf, ChatGPT…) that count toward monthly spend. |

**Budgets and alerts:** set daily, weekly and monthly budgets in Settings → Budgets & Alerts. macOS notifications fire at 80% (configurable) and 100% of a budget or plan quota, and when a single live session passes a cost you choose (again each time it doubles). Each alert is sent once.

**Real-time:** FSEvents watches every source folder, so new messages show up within about a second. A 60-second fallback refresh keeps "today" accurate across midnight.

## Supported sources

| Tool | Where it reads | Tokens | Notes |
|---|---|---|---|
| Claude Code | `~/.claude/projects/**/*.jsonl` (also `CLAUDE_CONFIG_DIR`) | ✅ | Includes subagent transcripts; de-duplicates streamed messages |
| Codex CLI | `~/.codex/sessions/**/*.jsonl` (also `CODEX_HOME`) | ✅ | Rate-limit windows come from Codex's own logs (offline) |
| Cursor | `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb` | ✅ when Cursor records them | Read-only SQLite |
| Copilot CLI | `~/.copilot/session-state/*/events.jsonl` | — | The CLI logs requests, not tokens |
| Copilot in VS Code | `…/Code/User/workspaceStorage/*/chatSessions/*` | partial | Stable, Insiders and VSCodium |
| Gemini CLI | `~/.gemini/tmp/*/chats/session-*.json` | ✅ | |
| OpenCode | `~/.local/share/opencode/opencode.db` | ✅ | Uses OpenCode's own recorded cost |
| Qwen Code | `~/.qwen/tmp/*/chats/session-*.json` | ✅ | Gemini CLI format |
| Continue | `~/.continue/sessions/*.json`, `~/.continue/dev_data` | ✅ | Tokens are logged apart from chats: matched to the chat open at the time, otherwise shown as a daily "Model usage" row. Local models (Ollama, LM Studio) count as $0 |
| Kiro | `~/.kiro/sessions/` (IDE and CLI) | when recorded | Empty CLI session shells and tool-only startup sessions are skipped |
| Cline / Roo Code / Kilo Code | `…/globalStorage/<extension>/tasks/*/ui_messages.json`, `~/.cline/data/tasks` | ✅ | Uses the cost each request records. VS Code, Cursor, Windsurf, VSCodium |
| Aider | `.aider.chat.history.md` in project folders under `~/Projects`, `~/Developer`, `~/code`, `~/src`… | ✅ | Parses the `Tokens: … Cost: …` lines. Times come from the run header only |
| Factory Droid | `~/.factory/sessions/**/*.jsonl` + `.settings.json` | ✅ | |

Claude Code, Codex, Copilot, OpenCode, Continue and the Kiro layout were checked against real data. Qwen Code, Cline/Roo/Kilo, Aider and Factory follow each tool's published storage format and are covered by fixture tests. If yours parses wrongly, run `LLMAnalytics --dump` and open an issue.

**Not supported:** Windsurf (Cascade history is stored encrypted) and Amp (threads live on Amp's servers). Track them as manual plans on the Subscriptions page.

### Live subscription lookups (opt-in)

Codex limits work offline. For the others, turn on **Live lookup** on the Subscriptions page. The app then calls that vendor's own API with the login the tool already stored on your Mac:

- **Claude Code**: reads the `Claude Code-credentials` Keychain item and calls `api.anthropic.com/api/oauth/usage` (5-hour and weekly windows).
- **GitHub Copilot**: uses `gh auth token` and calls `api.github.com/copilot_internal/user` (premium request quota).
- **Cursor**: uses Cursor's stored session token and calls `cursor.com/api/usage`.

These are undocumented endpoints and may change. Nothing is sent anywhere else.

## Install

### Download
Grab the latest `LLMAnalytics-x.y.z.dmg` from Releases and drag the app to **Applications**.
Builds are ad-hoc signed, not notarized. On first launch, right-click the app and choose **Open**, or run:

```bash
xattr -dr com.apple.quarantine "/Applications/LLM Analytics.app"
```

### Build from source (macOS 14+, Xcode 16+ command line tools)

```bash
git clone https://github.com/seyhunak/llmanalytics.git && cd llmanalytics
./scripts/install.sh          # builds, copies to /Applications, launches
```

Other scripts:

```bash
./scripts/build-app.sh        # universal (arm64 + x86_64) dist/LLM Analytics.app
./scripts/make-dmg.sh         # dist/LLMAnalytics-<version>.dmg
swift run LLMAnalytics --dump # print what each parser found (great for bug reports)
```

Pushing a `v*` tag builds and attaches the DMG to a GitHub Release via `.github/workflows/release.yml`.

## Settings

- **Launch at login**, **Show Dock icon** (hide it to live only in the menu bar), and **Menu bar shows** cost, tokens or icon only.
- **Pricing overrides**: costs are estimated at public API list prices, which is what your usage would cost on the API. Subscription plans are flat-rate. To correct or add a price, edit `~/Library/Application Support/LLMAnalytics/pricing.json` (USD per 1M tokens):

```json
{ "gpt-5": { "input": 1.25, "output": 10, "cacheRead": 0.125, "cacheWrite": 0 } }
```

Keys are model-name prefixes.

## Architecture

Pure SwiftUI + Swift Charts with no third-party dependencies. It is a single SwiftPM executable target.

```
Sources/LLMAnalytics/
  App/            entry point, menu bar scene, --dump / --snapshot debug modes
  Sources/        one parser per tool (UsageSource protocol): discover → parse → transcript
  Store/          DataStore (incremental re-parse by mtime, FSEvents), Analytics aggregation
  Subscriptions/  quota providers + manual plans
  Models/         SessionSummary, UsageEvent, TokenUsage, Pricing
  Views/          pages, transcript viewer, charts, components
```

To add a tool, implement `UsageSource` and register it in `Sources.all`.

## Privacy

All parsing happens locally and read-only. The only network calls are the opt-in live subscription lookups described above, sent directly to the vendor whose token is used.

## License

MIT. See [LICENSE](LICENSE).
