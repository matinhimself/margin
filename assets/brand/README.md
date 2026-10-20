# Margin identity

An open book forms a lowercase-style **m** monogram. The cut in the left page
suggests a margin or annotation. Pair it with the lowercase serif wordmark.

- `logo.svg`: primary forest wordmark and symbol, with all type outlined.
- `logo-reversed.svg`: paper-colored logo for dark backgrounds.
- `mark.svg` / `mark-reversed.svg`: transparent standalone symbols.
- `app-icon.svg` / `app-icon-1024.png`: square, opaque app-icon masters.
- `identity-preview.png`: logo, launcher treatment, palette, and small-size study.

Forest `#193E32`, paper `#FAF9F5`, sage `#DCEBD1`. Use forest and paper for the
main identity; reserve sage for supporting surfaces. Keep at least one quarter
of the symbol's width clear around the logo. Minimum recommended icon size: 16px;
minimum full-logo width: 140px. Avoid stretching, rotating, or adding effects.

The serif wordmark uses outlined Apple system serif glyphs. Native UI uses the
system serif font and the matching vector `MarginMark` in the sidebar.

Regenerate exports and the iOS/macOS asset catalog from the repository root:

```sh
swift scripts/generate_brand.swift
python3 scripts/generate_project.py
```

iOS masters are opaque and square; the OS supplies the corner mask. macOS icons
include a rounded tile and transparent inset. Xcode uses the `AppIcon` asset
catalog; the Swift package command-line executable does not bundle launcher icons.
