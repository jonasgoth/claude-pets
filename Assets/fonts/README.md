# Menu icons

`Hugeicons-ClaudePets.ttf` is a subset of the free Hugeicons "stroke rounded" icon font
(https://hugeicons.com), cut down to the nine glyphs the menu uses so the
bundle stays ~4 KB instead of 3 MB.

Glyphs: cursor-in-window, eye, eye-off, volume-high, volume-off, flash, flash-off,
sparkles, power. They are listed with their codepoints in `Sources/ClaudePets/IconFont.swift`.

To add another icon, look its codepoint up in https://use.hugeicons.com/font/icons.css
and re-cut the subset from the full `hgi-stroke-rounded.ttf`:

    python3 -m fontTools.subset hgi-stroke-rounded.ttf \
      --unicodes=f1ac5,f1c4a,f312d,f2981,f2986,f1ce8,f1ce7,f266b,f238b \
      --drop-tables+=GSUB,GPOS --name-IDs='*' \
      --output-file=Assets/fonts/Hugeicons-ClaudePets.ttf
