# Claude Pets — plan

Little crab pets on your Mac desktop. One crab per Claude session.
They show you, at a glance, who is working, who is done, and who needs you.

Unofficial. Not made by Anthropic. "Claude" and the Clawd crab belong to Anthropic.

---

## 1. What it does (short)

- Every Claude session gets a crab. CLI, Desktop Code tab, and Cowork.
- Crabs live in a strip along the bottom of your screen. On top of other windows.
- They walk, hop, sleep, and wave. Based on what the session is doing.
- A badge on each crab tells you the state. Green check = done. Red ! = needs you.
- "Done, not seen" only clears when you actually look at the chat. Never by clicking the crab.
- You can drag crabs around inside the strip. Clicks elsewhere pass through to your apps.
- A menu bar icon shows how many crabs are alive and lists them.

---

## 2. What I found on your Mac (why this is possible)

I checked your real files on 2026-09-11. This is what Claude writes to disk.

### Live "who is running" list
`~/.claude/sessions/<pid>.json`
One file per running Claude process. Deleted when it exits.
Has: `pid`, `sessionId`, `cwd`, `name`, `entrypoint` (`cli` or `claude-desktop`), `startedAt`.

### Transcripts (CLI and Desktop Code)
`~/.claude/projects/<folder-slug>/<sessionId>.jsonl`
Every message is appended live. Key facts inside:
- `type: assistant` with `stop_reason: tool_use` = still working.
- `type: assistant` with `stop_reason: end_turn` = finished its turn.
- `type: user` with `tool_result` = a tool just ran.
- `type: system, subtype: api_error` = something broke.
- `type: ai-title` / `custom-title` = the chat's name.
- Sub-agents: `<sessionId>/subagents/agent-*.jsonl` (one file per sub-agent).

### Desktop Code tab metadata
`~/Library/Application Support/Claude/claude-code-sessions/<account>/<org>/local_*.json`
Has: `title`, `cliSessionId` (links to the transcript), `cwd`, `lastActivityAt`, `isArchived`, `permissionMode`.
**And `lastFocusedAt`.** This updates when you click into that chat in the Desktop app.
Checked: 324 of your 444 sessions have lastFocusedAt later than lastActivityAt. So it really tracks re-visits.
This is our "you looked at it" signal for Desktop Code.

### Cowork metadata
`~/Library/Application Support/Claude/local-agent-mode-sessions/<account>/<org>/local_*.json`
Has: `title`, `cliSessionId`, `lastActivityAt`, `isArchived`, `sessionType` (`scheduled` for automations). **No lastFocusedAt.**
Next to it, a folder with the same name:
- `audit.jsonl` — clean event stream. Has `system:permission_request`, `system:permission_response`, `system:status`, `result` (session ended). Very good for state.
- `.claude/projects/*/*.jsonl` — the normal transcript, inside the sandbox home.

### Hooks (instant signals)
`~/.claude/settings.json` can run a script on: `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `Notification` (permission_prompt / idle_prompt), `PermissionRequest`, `Stop`, `SubagentStart`, `SubagentStop`, `SessionEnd`.
Works for CLI and Desktop Code. **Does not fire for Cowork** (sandbox has its own home folder). Cowork is covered by audit.jsonl instead.

### Desktop "unread" store
The Desktop app keeps its own unread list (`unread-v1` in Local Storage). It is inside Electron's locked LevelDB. Do not depend on it. Nice-to-have later.

### Your machine
macOS 26.6. Xcode 26.6. Swift 6.3. Node 22. Homebrew. Terminal.app only (no iTerm).
All your sessions so far came from Claude Desktop. Zero from a terminal. So Desktop is the priority.

---

## 3. Crab states

| State | How we know | What the crab does | Badge |
|---|---|---|---|
| Spawning | new `sessions/<pid>.json` or new jsonl | drops in from the top, lands | none |
| Working | hook `UserPromptSubmit`/`PostToolUse`; jsonl `stop_reason: tool_use` | scuttles side to side, "…" bubble | none |
| Using a tool | hook `PreToolUse` | pauses, holds a tiny tool icon | wrench / magnifier |
| Needs you: permission | hook `PermissionRequest` or `Notification(permission_prompt)`; Cowork: `permission_request` without a `permission_response` | jumps up and down, claws up | red **!** |
| Needs you: question | `Stop` and last text ends with "?" or used `AskUserQuestion` | jumps, tilts head | orange **?** |
| Done, not seen | `Stop` hook / `end_turn`, and not yet seen | sits still, faces you, hops now and then | green **✓** |
| Done, seen | seen rule below fired | badge fades, relaxes, wanders | none |
| Dormant | no activity > 10 min | lies down, "zzz", dimmed | zzz |
| Error | `api_error` record, or Cowork `result` with `is_error` | dizzy, stars over head | red **×** |
| Gone | process dead (`kill(pid,0)` fails), `SessionEnd`, archived, Cowork `result` | walks off the edge and fades | none |
| Sub-agent | `SubagentStart` hook or new `subagents/agent-*.jsonl` | baby crab follows its parent, leaves when done | none |

Priority when signals disagree: permission > question > error > done-not-seen > working > done-seen > dormant.

---

## 4. The "seen" rule (the important part)

A done-badge never clears from touching the crab. Only from you actually looking at the chat.

**Desktop Code session**
The Desktop app keeps its own "unread" dot per chat (the sidebar's blue dot) in its web storage,
and that is the truth. It lands on disk late (usually seconds, up to ~2 min), so:
- Once Desktop's record on disk is newer than the finish, it decides: you marked it unread on
  purpose → unseen; you clicked into it after it finished (`lastFocusedAt`) → seen; the dot is on →
  unseen; no dot → seen once the Claude app has been the front app for 1.5 s after the finish.
- Until then, guess: seen if `lastFocusedAt` is later than the finish, or if it was the most
  recently focused chat and Claude is front for 1.5 s. `lastFocusedAt` is never written for an
  empty new chat, so Desktop's "chat on screen" record vetoes the guess when it is fresher than
  the last click. A wrong guess gets corrected when Desktop's record arrives.
Front app comes from `NSWorkspace`. No permission needed.

**Cowork session**
No `lastFocusedAt`. So:
1. Best: Claude app is front and its window title matches the session title. Needs Accessibility permission (one toggle in System Settings, you do it once).
2. Fallback if no permission: when the Claude app comes to front and stays 3 s, clear done-badges on Cowork crabs. Rougher, but honest.

**Terminal CLI session**
`sessions/<pid>.json` gives the pid. The pid gives the tty. Ask Terminal.app (AppleScript) which tab is selected in the front window and match the tty. Terminal must be the front app. Needs Automation permission (macOS asks once).
iTerm2 later, same trick.

**Always**
Screen locked or display asleep = nothing counts as seen.

---

## 5. How it is built

One Swift app. macOS 14+. No dock icon. Menu bar icon + one see-through always-on-top window.

```
Sources (each emits SessionEvent)
  RegistryWatcher      ~/.claude/sessions/*.json         (alive, pid, cwd, entrypoint)
  TranscriptWatcher    ~/.claude/projects/**/*.jsonl      (working / done / error / sub-agents)
                       + Cowork inner .claude/projects
  DesktopMetaWatcher   claude-code-sessions/**/local_*.json   (title, lastFocusedAt, archived)
                       local-agent-mode-sessions/**/local_*.json
  CoworkAuditWatcher   local-agent-mode-sessions/**/audit.jsonl (permission, status, result)
  HookReceiver         tiny hook script writes ~/.claude-pets/events/<sid>.json (instant)
        │
        ▼
  SessionStore         merges everything into one Session per sessionId, runs the state machine
        │
        ▼
  SeenDetector         NSWorkspace front app + lastFocusedAt + AppleScript/AX
        │
        ▼
  PlaypenScene (SpriteKit)   CrabNode: sprite, badge, bubble, drag. Wander, clumping, spacing.
  PlaypenWindow              NSPanel, borderless, floating, click-through except on crabs, all Spaces
  MenuBar                    count, list, toggle playpen, settings, quit
  HookInstaller              merges into ~/.claude/settings.json with a backup
```

Hooks give the state in under 50 ms. File watchers give the same info a bit later and cover Cowork and any session where hooks are missing. Both feed the same store. Hooks win when both exist.

Why Swift, not Electron: both inspiration apps are Swift. Overlay windows, click-through, and Spaces behave properly. Tiny CPU use. Claude Code writes the Swift. You press Build.

---

## 6. Build order (each step is something you can see)

Status: all five phases done. Run `./build.sh --run`; `tools/make-dmg.sh` makes the installer; `tools/render-pets.py` re-bakes the pets. Optional menu items: "Turn on instant updates" (installs hooks) and "Allow window checks" (Accessibility, for Cowork seen-detection). Debug: `CLAUDE_PETS_DEBUG=1 "build/Claude Pets.app/Contents/MacOS/ClaudePets"` logs status changes, seen-rule inputs and slow ticks. Debug the click-through with `CLAUDE_PETS_DEBUG=1 "build/Claude Pets.app/Contents/MacOS/ClaudePets"`.

**Phase 0 — Skeleton (day 1)** ✅ done 2026-09-12
Swift package + build script. Menu bar icon. Empty see-through strip along the bottom of the screen. One static crab you can drag. Prove clicks pass through to apps behind it.

**Phase 1 — Crabs appear (days 2–3)** ✅ done 2026-09-12
Watch `~/.claude/sessions` and the transcripts. One crab per live session. Color from the project folder. Name tag from the title. Working vs idle from the jsonl. Crab leaves when the process dies.

**Phase 2 — Feelings (days 4–5)** ✅ done 2026-09-12
Full state table. Badges. Hook installer for instant permission/done. Cowork via audit.jsonl. Baby crabs for sub-agents.

**Phase 3 — Seen rule (days 6–7)** ✅ done 2026-09-12
The rule in section 4. Test: finish a chat while looking at it, while on another chat, while in Chrome, while screen locked.

**Phase 4 — Personality (week 2)** ✅ done 2026-09-12
Wander AI. Crabs stay loosely together. Jump, celebrate, sleep, wave. Optional sound. Menu bar count.

**Phase 5 — Ship (week 3)** ✅ done 2026-09-12 (art = Clawd pets from clawd-pet, per Jonas; notarization needs an Apple Developer account, see tools/make-dmg.sh)
Own crab art. App icon. Sign and notarize. DMG + Homebrew cask. README. MIT license. "Not affiliated" note.

---

## 7. Art

- Prototype: the 20-frame pixel Clawd crab from claude-status-bar. 51×36 px. Walk cycle only.
- Per-session color: hue-shift the body in code. Keep the eyes black.
- Frames to add: idle bob (code), jump (2–3 frames), sleep (eyes closed + zzz), alert (claws up), dizzy.
- Badges are drawn in code with SF Symbols. No image files needed.
- For public release: draw an original crab, or keep Clawd with the same nominative-use note both repos use. (See decision A.)

---

## 8. What to reuse (both repos are MIT)

**claude-status-bar** (github.com/m1ckc3s/claude-status-bar)
- `hooks/install.js`, `hooks/uninstall.js` — safe merge into settings.json with backup.
- `hooks/update.js` — the per-session state file idea and the tool label table.
- `Sources/CrabFrames.swift` — the pixel crab frames.
- Self-launch on SessionStart, quit when no sessions. Nice touch.

**so-agentbar** (github.com/sotthang/so-agentbar)
- `SessionMonitor.swift` — jsonl parsing, status heuristics, Desktop + Cowork discovery. Already handles `end_turn` quirks with extended thinking.
- `PixelAgentsWindowController.swift` — floating SKView window setup.
- `PixelCharacterNode.swift` — wander, walk, bob, name badge, speech bubble.

---

## 9. Risks (honest)

- From files alone, "waiting for permission" is a guess (silence after a tool call). Hooks fix this for CLI and Desktop Code. Cowork has a real `permission_request` event, so it is fine.
- Cowork seen-detection needs Accessibility permission. You toggle it once.
- Anthropic can change these file formats any time. Keep parsers tolerant. Keep sample logs as tests.
- A long build in Bash looks like "stuck". Use hooks, plus a 10-minute grace for Bash like so-agentbar does.
- Trademark: Claude and Clawd are Anthropic's. Add the "unofficial" note.

---

## 10. Decisions

**Decided by Jonas on 2026-09-12:**
- A. Crab art: session crabs use the animated Clawd pets from https://clawd-pet.vercel.app (MIT, baked to frame sheets). Sub-agent baby crabs keep the pixel crab. (Changed by Jonas 2026-09-12.)
- B. Where crabs live: on top of all windows, in a see-through strip. Click-through except on crabs.

**I made for you** (say so if you disagree):
- Swift + SpriteKit, macOS 14+.
- Crabs live on the Dock's row, in the wallpaper gaps left and right of the Dock (never under it). The Dock's footprint comes from Accessibility when allowed, else an estimate from Dock preferences. If the Dock is hidden or on a side, the whole bottom edge is used. (Changed by Jonas 2026-09-12.)
- One crab per session, all three sources, each with its own color. Sub-agents are baby crabs that follow the parent. A crab leaves after 5 minutes idle (unless it needs you); badges are hidden for now, the pet's pose carries the state.
- Archived chats and dead processes walk off. Cowork crabs leave after the `result` event or when archived.
- Name: Claude Pets. Repo: `Package.swift` (Xcode opens it; `./build.sh --run` builds and launches), `Sources/`, `hooks/`, `Assets/`, `PLAN.md`.
