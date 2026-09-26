#!/usr/bin/env python3
"""Draw the backdrop for the drag-to-Applications installer window.

Writes Assets/dmg/background.png (660x420), background@2x.png and the
background.tiff that Finder actually reads (both sizes in one file, so the
window stays sharp on Retina). tools/make-dmg.sh copies the .tiff into the DMG.

Usage: tools/make-dmg-background.py
"""
import importlib.util, os, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "Assets", "dmg")
W, H = 660, 420                       # installer window size, in points
APP_X, APPS_X, ICON_Y = 170, 490, 200  # icon centres; must match make-dmg.sh

_spec = importlib.util.spec_from_file_location("makeicon", os.path.join(ROOT, "tools", "make-icon.py"))
makeicon = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(makeicon)

FONT = "-apple-system, 'SF Pro Text', 'Helvetica Neue', Helvetica, sans-serif"

SVG = f'''<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}">
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#FFF8F1"/><stop offset="1" stop-color="#FFE2CB"/>
    </linearGradient>
    <linearGradient id="arrow" gradientUnits="userSpaceOnUse" x1="{APP_X + 80}" y1="0" x2="{APPS_X - 90}" y2="0">
      <stop offset="0" stop-color="#E8886B" stop-opacity="0.25"/>
      <stop offset="1" stop-color="#E8886B" stop-opacity="0.95"/>
    </linearGradient>
  </defs>
  <rect width="{W}" height="{H}" fill="url(#bg)"/>
  <path d="{makeicon.star(596, 74, 13)}" fill="#FFBE52" opacity="0.8"/>
  <path d="{makeicon.star(64, 112, 9)}" fill="#FFBE52" opacity="0.6"/>
  <text x="{W/2}" y="66" text-anchor="middle" font-family="{FONT}" font-size="30"
        font-weight="700" fill="#5B3A2B">Claude Pets</text>
  <text x="{W/2}" y="98" text-anchor="middle" font-family="{FONT}" font-size="15"
        fill="#9A7261">Drag the crab into Applications</text>
  <g>
    <path d="M{APP_X + 86},{ICON_Y} L{APPS_X - 104},{ICON_Y}" stroke="url(#arrow)"
          stroke-width="12" stroke-linecap="round" fill="none"/>
    <path d="M{APPS_X - 118},{ICON_Y - 22} L{APPS_X - 92},{ICON_Y} L{APPS_X - 118},{ICON_Y + 22}"
          stroke="#E8886B" stroke-width="12" stroke-linecap="round" stroke-linejoin="round" fill="none"/>
  </g>
  <text x="{W/2}" y="368" text-anchor="middle" font-family="{FONT}" font-size="12" fill="#A98A79">
    First launch: right-click Claude Pets in Applications and choose Open.
  </text>
</svg>'''


def main():
    os.makedirs(OUT, exist_ok=True)
    one, two = os.path.join(OUT, "background.png"), os.path.join(OUT, "background@2x.png")
    makeicon.render_png(SVG, one, W, H)
    makeicon.render_png(SVG.replace(f'width="{W}" height="{H}" viewBox', f'width="{W*2}" height="{H*2}" viewBox'),
                        two, W * 2, H * 2)
    tiff = os.path.join(OUT, "background.tiff")
    subprocess.run(["tiffutil", "-cathidpicheck", one, two, "-out", tiff],
                   check=True, stdout=subprocess.DEVNULL)
    print(f"Wrote {one}, {two}, {tiff}")


if __name__ == "__main__":
    main()
