# Claude Pets

A menu-bar crab that shows what your Claude Code sessions are doing.

## Running the app — read this first

**Always build and run with:**

```bash
./build.sh --run
```

**Never run `./.build/debug/ClaudePets` directly.** That bare binary has no
`Resources/` folder beside it, so `PetLibrary.isAvailable` is false and every
crab silently falls back to the old pixel-crab sprite. The app looks broken /
out of date even though the code changes are in — a confusing false alarm.

`./build.sh` assembles `build/Claude Pets.app` with `Assets/pets` copied into
`Contents/Resources/pets`, which is what `PetLibrary` reads.

Before launching, stop anything already running, or you get two copies of every crab:

```bash
pkill -x ClaudePets
```

With debug logging:

```bash
CLAUDE_PETS_DEBUG=1 "build/Claude Pets.app/Contents/MacOS/ClaudePets"
```

## Pets

The crab art is animated SVGs in `Assets/pets/src/`, baked into PNG frame
sheets by `tools/render-pets.py` (needs Google Chrome). `Assets/pets/manifest.json`
maps each `CrabStatus` to a sheet. Re-bake only when the SVGs change.

## Layout

- `PLAN.md` — the build plan, phases 0-5.
- `Sources/ClaudePets/SessionStore.swift` — decides each session's `CrabStatus`.
- `Sources/ClaudePets/DesktopLocalStorage.swift` — reads the Desktop app's own "unread" dot and
  "chat on screen" record out of its web storage (LevelDB). That is the truth for "seen" on
  Desktop Code chats, but it reaches disk late (seconds to ~2 min), so it corrects guesses
  rather than replacing them.
- `Sources/ClaudePets/PlaypenScene.swift` — the per-frame brain (wander, unstack, tags).
- `Sources/ClaudePets/CrabNode.swift` — one crab: sprite, animation, name tag.
