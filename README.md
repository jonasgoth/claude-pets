# Claude Pets

Little Clawd pets on your Mac desktop, one per Claude session. They show you who is working, who is done, and who needs you.

![Swift 5.9](https://img.shields.io/badge/Swift-5.9-orange.svg)
![Unofficial](https://img.shields.io/badge/unofficial-not%20affiliated%20with%20Anthropic-lightgrey.svg)

![Claude pets along the bottom of a Mac screen](docs/screenshot.png)

## What it does

Claude Pets is a menu-bar app. Every live Claude session gets an animated pet: Claude Code in the terminal, the Claude Desktop Code tab, and Cowork. The pets sit along the bottom of your screen, in the wallpaper gaps beside the Dock. Never under it.

The pose tells you the state:

- **Coding** while it works (also while running tools)
- **Praying** when it is waiting for permission
- **Confused** when it asked you a question
- **Celebrating** when it is done
- **Idle** once you have seen the result
- **Dizzy** on errors
- **Walking off** when the chat closes

A few more details:

- Each pet gets its own color, so you can tell sessions apart.
- Sub-agents show up as tiny pixel baby crabs beside their parent.
- The "done" state clears only when you actually look at the chat. Clicking the pet never clears it.
- A pet leaves after 5 minutes idle, unless it still needs you.
- Drag pets around. Clicks anywhere else pass through to your apps.
- Hover a pet for a speech bubble: what it is doing, for how long, and which project it is in.
- The menu bar icon shows how many pets are alive and turns red when one needs you.

Nothing leaves your Mac. Claude Pets only reads files Claude already writes.

## Install

### Download

Grab the latest `claude-pets-<version>.dmg` from [Releases](https://github.com/jonasgoth/claude-pets/releases) and open it. The disk image opens as a window: drag the crab onto Applications.

![The Claude Pets installer window: drag the crab into Applications](docs/install.png)

The build is ad-hoc signed, not notarized. The first time, right-click Claude Pets in Applications and choose **Open**.

After that Claude Pets keeps itself current: it checks GitHub for a new release a few times a
day, and when there is one the menu grows an **Update to …** row. One click downloads it,
swaps the app and restarts. Nothing is downloaded until you click.

Claude Pets used to be called Clawdy. An installed Clawdy cannot update itself across the
rename, so download Claude Pets once by hand and drag Clawdy to the Trash. Your settings and
hooks carry over on first launch.

### Build from source

You need Xcode or the Command Line Tools.

```bash
git clone https://github.com/jonasgoth/claude-pets.git
cd claude-pets
./build.sh --run
```

This builds `build/Claude Pets.app` and launches it. To make your own installer:

```bash
tools/make-dmg.sh
```

That writes `build/claude-pets-<version>.dmg` with the drag-to-Applications layout. It asks macOS for permission to control Finder the first time, since Finder is what arranges the window. Say no and it falls back to the layout saved in `Assets/dmg/DS_Store`, which is also how the GitHub build gets it: a CI runner has no Finder to drive.

## Releasing

Releases are built by GitHub, not on a laptop. Set the version in `build.sh`, then push a matching tag:

```bash
git tag v0.6.0
git push origin v0.6.0
```

[`.github/workflows/release.yml`](.github/workflows/release.yml) builds the app on a macOS
runner, wraps it in the DMG, and publishes a GitHub Release with the DMG attached and notes
generated from the commits. The tag sets the version the app reports, so `build.sh`'s
`VERSION` and the tag should agree.

Everyone already running Claude Pets sees the new version in their menu within a few hours. That
check reads `https://api.github.com/repos/jonasgoth/claude-pets/releases/latest` and nothing else.

Two things to know:

- A release is ad-hoc signed, so macOS forgets any Accessibility grant on update, and a fresh
  download still needs right-click > Open. Fixing both needs a paid Apple Developer account;
  `release.yml` ends with the steps to add.
- Updates downloaded by Claude Pets itself are not quarantined, because the app fetches them
  directly rather than through a browser. So an update installs without the right-click dance.

## Menu

Click the crab in the menu bar. It lists your sessions and offers:

- **Turn on instant updates…** installs Claude Code hooks so pets react the moment a chat needs permission or finishes. It edits `~/.claude/settings.json` and backs it up first. Optional.
- **Allow window checks…** grants Accessibility access. Claude Pets uses it for exact Dock bounds and to tell when you have looked at a Cowork chat. Optional.
- **Sounds** plays a soft chime when a job finishes and a pop when one needs you. Off by default.
- **Tidy crabs** lines everyone up.
- **Show playpen** / **Hide playpen** toggles the pets.

## How it works

Claude Pets watches the files Claude writes to disk: the live-session list in `~/.claude/sessions`, the chat transcripts in `~/.claude/projects`, the Desktop app's chat metadata (which records when you last opened a chat), and Cowork's audit log. Folders are watched with FSEvents, so it idles at a few percent CPU. With hooks turned on, state changes arrive instantly instead of a moment later.

See [PLAN.md](PLAN.md) for the full design, including the "seen" rule.

To see what Claude Pets is thinking, run it from a terminal with debug logging:

```bash
CLAUDE_PETS_DEBUG=1 "build/Claude Pets.app/Contents/MacOS/ClaudePets"
```

## Rebuilding the pets

The pets are animated SVGs baked into PNG frame sheets. To re-bake them (needs Google Chrome):

```bash
tools/render-pets.py
```

This writes `Assets/pets/<state>.png` and `Assets/pets/manifest.json`.

## Redrawing the icon

The app icon and the installer backdrop are drawn by scripts, not by hand:

```bash
tools/make-icon.py             # Assets/AppIcon.svg + .png + .icns
tools/make-dmg-background.py   # Assets/dmg/background.tiff
```

`tools/make-icon.py --theme dark` swaps the cream plate for a dark one. Both need Google Chrome, which turns the SVG into a PNG.

## Contributing

Issues and pull requests are welcome. If something looks wrong, a debug log (see above) helps a lot.

## Credits

- The animated pets are **[clawd-pet](https://github.com/abderrahimghazali/clawd-pet)** by Abderrahim Ghazali (MIT). You can browse them at [clawd-pet.vercel.app](https://clawd-pet.vercel.app).
- The pixel baby crab frames come from [claude-status-bar](https://github.com/m1ckc3s/claude-status-bar) by m1ckc3s (MIT).
- Inspired by [so-agentbar](https://github.com/sotthang/so-agentbar).

"Claude" and Clawd belong to Anthropic. Claude Pets is an unofficial side project, not affiliated with or endorsed by Anthropic. See [Assets/ATTRIBUTION.md](Assets/ATTRIBUTION.md) for details.

## License

[MIT](LICENSE). This covers the code in this repository only and conveys no rights to Anthropic's trademarks or artwork.
