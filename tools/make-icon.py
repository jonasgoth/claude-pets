#!/usr/bin/env python3
"""Draw the Claude Pets app icon and bake it into Assets/AppIcon.{svg,png,icns}.

One cute crab on an Apple-style squircle: shell, raised claws, big sparkly eyes,
blush, smile. All vector, so it stays sharp from 1024px down to the 16px Finder
list. Edit the numbers below, re-run, done.

Usage: tools/make-icon.py [--theme warm|dark] [--out-prefix PATH] [--png-only]
Needs Google Chrome (SVG -> PNG) and macOS iconutil (PNG -> icns).
"""
import argparse, math, os, subprocess, sys, tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
SIZE = 1024                 # icon canvas
PLATE = 824                 # macOS art area inside the canvas

THEMES = {
    "warm": dict(bg_top="#FFF7EF", bg_bot="#FFD9B5", glow="#FFFFFF",
                 shell="#EF8763", shell_bot="#D9664A", limb="#C25C42", eye="#2E211B", hi="#FFFFFF",
                 blush="#EE6E72", mouth="#2E211B", shadow="#A85E3E", sparkle="#FFBE52"),
    "dark": dict(bg_top="#3E4759", bg_bot="#171B24", glow="#FFFFFF",
                 shell="#EF8763", shell_bot="#D9664A", limb="#BE5941", eye="#17120F", hi="#FFFFFF",
                 blush="#EE6E72", mouth="#17120F", shadow="#000000", sparkle="#FFBE52"),
}


def squircle(cx, cy, half, n=5.0, steps=256):
    """Apple-ish continuous-corner rounded square as an SVG path."""
    pts = []
    for i in range(steps):
        t = 2 * math.pi * i / steps
        ct, st = math.cos(t), math.sin(t)
        x = half * math.copysign(abs(ct) ** (2 / n), ct)
        y = half * math.copysign(abs(st) ** (2 / n), st)
        pts.append(f"{cx + x:.2f},{cy + y:.2f}")
    return "M" + " L".join(pts) + " Z"


def star(cx, cy, r, k=0.22):
    """Four-point sparkle."""
    a, b = r, r * k
    return (f"M{cx},{cy - a} Q{cx + b},{cy - b} {cx + a},{cy} Q{cx + b},{cy + b} {cx},{cy + a} "
            f"Q{cx - b},{cy + b} {cx - a},{cy} Q{cx - b},{cy - b} {cx},{cy - a} Z")


# Shell: domed top, flat-ish bottom. Spans x 276..748, y 392..712.
SHELL = ("M276,606 C276,462 362,392 512,392 C662,392 748,462 748,606 "
         "C748,678 688,712 512,712 C336,712 276,678 276,606 Z")

# One pincer: a round claw with a wedge bitten out of the top-left. Drawn around
# (0,0), then scaled/rotated into place.
CLAW = ("M-6,-58 C22,-58 45,-40 45,-13 C45,13 25,29 -2,29 C-25,29 -43,14 -45,-10 "
        "C-46,-22 -44,-29 -39,-35 L-4,-19 Z")


def mirror(x):
    return 2 * 512 - x


def build_svg(theme):
    c = THEMES[theme]
    limb = lambda d, w: f'<path d="{d}" stroke="{c["limb"]}" stroke-width="{w}" stroke-linecap="round" fill="none"/>'

    legs = []
    for (x1, y1, x2, y2, w) in ((326, 662, 284, 694, 38), (398, 698, 378, 742, 38), (468, 710, 460, 752, 38)):
        legs.append(limb(f"M{x1},{y1} L{x2},{y2}", w))
        legs.append(limb(f"M{mirror(x1)},{y1} L{mirror(x2)},{y2}", w))

    arms = [limb("M338,510 L280,452", 46), limb(f"M{mirror(338)},510 L{mirror(280)},452", 46)]

    claws = [f'<g transform="translate(246,398) rotate(-14) scale(1.18)"><path d="{CLAW}" fill="{c["shell"]}"/></g>',
             f'<g transform="translate({mirror(246)},398) scale(-1.18,1.18) rotate(-14)"><path d="{CLAW}" fill="{c["shell"]}"/></g>']

    eyes = []
    for ex in (442, mirror(442)):
        eyes.append(f'<circle cx="{ex}" cy="548" r="39" fill="{c["eye"]}"/>')
        eyes.append(f'<circle cx="{ex - 13}" cy="534" r="14" fill="{c["hi"]}"/>')
        eyes.append(f'<circle cx="{ex + 14}" cy="565" r="7" fill="{c["hi"]}" opacity="0.75"/>')

    blush = "".join(f'<ellipse cx="{bx}" cy="616" rx="38" ry="22" fill="{c["blush"]}" opacity="0.5"/>'
                    for bx in (352, mirror(352)))

    nl = "\n    "
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="{SIZE}" height="{SIZE}" viewBox="0 0 {SIZE} {SIZE}">
  <defs>
    <linearGradient id="plate" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="{c['bg_top']}"/><stop offset="1" stop-color="{c['bg_bot']}"/>
    </linearGradient>
    <radialGradient id="glow" cx="0.5" cy="0.32" r="0.62">
      <stop offset="0" stop-color="{c['glow']}" stop-opacity="0.6"/>
      <stop offset="1" stop-color="{c['glow']}" stop-opacity="0"/>
    </radialGradient>
    <linearGradient id="shell" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="{c['shell']}"/><stop offset="1" stop-color="{c['shell_bot']}"/>
    </linearGradient>
    <filter id="soft" x="-40%" y="-40%" width="180%" height="180%">
      <feGaussianBlur stdDeviation="16"/>
    </filter>
    <clipPath id="shellclip"><path d="{SHELL}"/></clipPath>
  </defs>
  <path d="{squircle(SIZE / 2, SIZE / 2, PLATE / 2)}" fill="url(#plate)"/>
  <path d="{squircle(SIZE / 2, SIZE / 2, PLATE / 2)}" fill="url(#glow)"/>
  <path d="{star(700, 268, 25)}" fill="{c['sparkle']}" opacity="0.9"/>
  <path d="{star(300, 318, 16)}" fill="{c['sparkle']}" opacity="0.75"/>
  <ellipse cx="512" cy="792" rx="200" ry="26" fill="{c['shadow']}" opacity="0.25" filter="url(#soft)"/>
    {nl.join(legs)}
    {nl.join(arms)}
    {nl.join(claws)}
  <path d="{SHELL}" fill="url(#shell)"/>
  <g clip-path="url(#shellclip)">
    <ellipse cx="512" cy="444" rx="168" ry="66" fill="#FFFFFF" opacity="0.18"/>
    <ellipse cx="512" cy="756" rx="240" ry="72" fill="{c['limb']}" opacity="0.4"/>
  </g>
    {nl.join(eyes)}
  {blush}
  <path d="M474,608 Q512,652 550,608" stroke="{c['mouth']}" stroke-width="17" stroke-linecap="round" fill="none"/>
</svg>'''


def render_png(svg, out_png, width=SIZE, height=None):
    """SVG -> PNG with headless Chrome, transparent where the SVG is."""
    height = height or width
    with tempfile.TemporaryDirectory() as tmp:
        page = os.path.join(tmp, "icon.html")
        with open(page, "w") as f:
            f.write(f'<html><body style="margin:0;width:{width}px;height:{height}px">{svg}</body></html>')
        subprocess.run([CHROME, "--headless=new", "--disable-gpu", "--hide-scrollbars",
                        "--default-background-color=00000000", f"--window-size={width},{height}",
                        "--virtual-time-budget=400", f"--screenshot={out_png}", f"file://{page}"],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def make_icns(png, out_icns):
    iconset = out_icns.replace(".icns", "") + ".iconset"
    subprocess.run(["rm", "-rf", iconset], check=True)
    os.makedirs(iconset)
    for pt in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            px = pt * scale
            name = f"icon_{pt}x{pt}{'@2x' if scale == 2 else ''}.png"
            subprocess.run(["sips", "-z", str(px), str(px), png, "--out", os.path.join(iconset, name)],
                           check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    subprocess.run(["iconutil", "-c", "icns", iconset, "-o", out_icns], check=True)
    subprocess.run(["rm", "-rf", iconset], check=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--theme", default="warm", choices=sorted(THEMES))
    ap.add_argument("--out-prefix", default=os.path.join(ROOT, "Assets", "AppIcon"))
    ap.add_argument("--png-only", action="store_true")
    args = ap.parse_args()

    if not os.path.exists(CHROME):
        sys.exit("Google Chrome not found; it renders the SVG.")
    svg = build_svg(args.theme)
    with open(args.out_prefix + ".svg", "w") as f:
        f.write(svg)
    render_png(svg, args.out_prefix + ".png")
    if not args.png_only:
        make_icns(args.out_prefix + ".png", args.out_prefix + ".icns")
    print("Wrote " + args.out_prefix + (".svg/.png" if args.png_only else ".svg/.png/.icns"))


if __name__ == "__main__":
    main()
