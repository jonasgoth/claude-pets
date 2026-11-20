#!/usr/bin/env python3
"""Crop the baked pet sheets down to the part of each cell the pet actually uses.

render-pets.py bakes every frame into a full 240 x 240 cell, but the pet only ever touches a small
box inside it (about a fifth of the cell, on average). The GPU holds every sheet uncompressed, so
those empty pixels cost real memory: ~28 MB per sheet before, ~5 MB after.

For each state not packed yet, this finds the one box that holds every frame of that state (plus a
1 px clear border, so linear filtering at the edge blends into nothing, exactly as it did in the
full cell), re-packs the frames into a tight grid, and records the box in the manifest:

    "box":  [x, y, w, h]   the kept part of the cell, in cell pixels, top-left origin
    "cols": n              frames per row in the packed sheet

PetLibrary reads both and places the cropped frame exactly where it sat in the full cell, so the
pets look the same, pixel for pixel. A state that already has a "box" is left alone, so this is safe
to run again; render-pets.py runs it after every bake.

Usage: tools/pack-pets.py
"""
import json, math, os
from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "Assets", "pets")


def main():
    manifest_path = os.path.join(OUT, "manifest.json")
    manifest = json.load(open(manifest_path))
    cell, cols = manifest["cell"], manifest["cols"]
    before = after = 0
    for state, info in sorted(manifest["states"].items()):
        if "box" in info:
            continue
        path = os.path.join(OUT, info["file"])
        sheet = Image.open(path).convert("RGBA")
        frames = [sheet.crop(((i % cols) * cell, (i // cols) * cell,
                              (i % cols) * cell + cell, (i // cols) * cell + cell))
                  for i in range(info["frames"])]
        box = None
        for f in frames:
            b = f.getchannel("A").getbbox()
            if b:
                box = b if box is None else (min(box[0], b[0]), min(box[1], b[1]),
                                             max(box[2], b[2]), max(box[3], b[3]))
        if box is None:
            continue
        x0, y0 = max(box[0] - 1, 0), max(box[1] - 1, 0)
        x1, y1 = min(box[2] + 1, cell), min(box[3] + 1, cell)
        w, h = x1 - x0, y1 - y0
        n = len(frames)
        # Roughly square sheet: fewer, shorter rows keep it well inside any texture size limit.
        pcols = max(1, min(n, round(math.sqrt(n * h / w))))
        prows = math.ceil(n / pcols)
        packed = Image.new("RGBA", (pcols * w, prows * h), (0, 0, 0, 0))
        for i, f in enumerate(frames):
            packed.paste(f.crop((x0, y0, x1, y1)), ((i % pcols) * w, (i // pcols) * h))
        old = os.path.getsize(path)
        packed.save(path, optimize=True)
        info["box"] = [x0, y0, w, h]
        info["cols"] = pcols
        before += sheet.width * sheet.height
        after += packed.width * packed.height
        print(f"  {state:28} {sheet.width}x{sheet.height} -> {packed.width}x{packed.height}"
              f"  ({old // 1024} KB -> {os.path.getsize(path) // 1024} KB)")
    json.dump(manifest, open(manifest_path, "w"), indent=2)
    if before:
        print(f"packed: {after / before:.0%} of the pixels kept "
              f"({before * 4 / 2**20:.0f} MB -> {after * 4 / 2**20:.0f} MB on the GPU, all sheets)")
    else:
        print("nothing to pack")


if __name__ == "__main__":
    main()
