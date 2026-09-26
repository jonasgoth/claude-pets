# Asset attribution

## Session crabs: Clawd pets
`Assets/pets/src/*.svg` are animated SVGs from
[abderrahimghazali/clawd-pet](https://github.com/abderrahimghazali/clawd-pet) (MIT, © 2026 Abderrahim Ghazali),
also browsable at https://clawd-pet.vercel.app. `tools/render-pets.py` bakes them into the frame
sheets in `Assets/pets/*.png` (headless Chrome + the Web Animations API).

The app icon (`Assets/AppIcon.*`) and the installer backdrop (`Assets/dmg/*`) are not upstream
art: they were drawn for Claude Pets by `tools/make-icon.py` and `tools/make-dmg-background.py`, in
clawd-pet's palette so they match the pets. Same MIT terms as the rest.

State → pet: working = coding · moving = crab-walking · tool = working-tool-calling ·
permission = praying · question = asking* · done = celebrating · done & seen = idle-living ·
dormant = sleeping · error = dizzy · leaving = going-away.

\* `clawd-asking.svg` is a derivative, not an upstream pet: the crab body reuses clawd-pet's
shape and palette so it matches the set, while the bouncing "!", the pulsing attention ring and
the hop/claw-wave were drawn for Claude Pets. Same MIT terms as the rest.

## Sub-agent baby crabs: pixel crab
`Assets/crab-walk-strip.png` — 20-frame pixel-art crab walk cycle, 51×36 px per frame, extracted
from `Sources/CrabFrames.swift` in [m1ckc3s/claude-status-bar](https://github.com/m1ckc3s/claude-status-bar)
(MIT), which generated them from `Clawd-CrabWalking.gif`.

## Trademarks
"Clawd" is Anthropic's mascot and "Claude" is Anthropic's trademark. Anthropic owns those designs
and marks. Claude Pets is an unofficial side project, not affiliated with or endorsed by Anthropic.
The MIT license covers this repository's code only and conveys no rights to Anthropic's
trademarks or artwork.
