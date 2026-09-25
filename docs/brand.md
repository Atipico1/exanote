# Exanote brand

Exanote's core is precision: it places every word at the moment it was said. The mark and the type say the same thing.

## Mark

A page folded at its top-right corner. Two slits cut in from the right turn the page into an E, and one narrow cut frees the fold, whose lower edge is the top of the first slit. The name becomes the note: one solid shape, one color, sharp corners, no outlines. The mark is lime on the dark tile; lime stays on the mark alone so the icon sits calmly in the Dock.

- Files: `exanote-mark.svg` (tile + mark), `exanote-icon-1024.png`, `exanote-lockup-light.png` for light backgrounds, `exanote-lockup-dark.png` for dark backgrounds.
- Source: `scripts/brand_assets.py` holds the coordinates and redraws the app icon, the SVG and both lockups. `native/App/Brand.swift` (`LogoMark`) draws the same coordinates in the app. Change both together.

```bash
.venv/bin/python scripts/brand_assets.py            # add --preview to write /tmp/exanote-brand-preview.png
```

## Wordmark

`Exanote` with a capital E, SF Pro Display Semibold, tracking −2 %. Only the **x** takes the accent: x marks the exact spot. In the app it is `Wordmark` in `Brand.swift`.

## Color

| Role | Value |
|---|---|
| Lime, fills only (primary buttons, the mark) | `#D1FE17` with ink `#0F1113` on it (16:1) |
| Accent text on light surfaces, the wordmark x in light mode | `#4A6A00` (6.3:1 on white) |
| Tile, one flat color | `#16181B` |
| Page (`canvas`) | `#FFFFFF` light, `#191919` dark |
| Sidebar (`sidebar`), the only gray surface | `#F7F7F5` light, `#202020` dark |

Lime is never used as text on a light surface; it would be about 1.2:1.

## Type

System fonts only: SF Pro for words, SF Mono for pure timecodes, Apple SD Gothic Neo for Hangul (automatic). Roles live in `Brand.swift`.

| Role | Setting | Used for |
|---|---|---|
| `exDisplay` | 30 pt Semibold, tracking −0.7 | Page titles |
| `exTitle` | 17 pt Semibold, tracking −0.2 | Section headers |
| `exHeadline` | 14 pt Medium | Row and card titles |
| `exBody` | 14 pt Regular | Notes and transcript |
| `exData` | 12.5 pt Medium, tabular digits | Dates and durations that include Hangul (오후 11:05, 29초) |
| `exDataSmall` | 11 pt, tabular digits | The time under a time |
| `exTimecode` | 12.5 pt Medium, SF Mono | Pure timecodes, shares and counts (0:29, 51%, 2/5) |
| `exTimecodeSmall` | 11 pt, SF Mono | Timeline axis labels |
| `exEyebrow` | 11.5 pt Medium | Column headers, today's date |
| `exTimer` | 13 pt Semibold, SF Mono | The running recording timer |

Numbers line up digit for digit in both settings, so a time never shifts as it counts. Hangul is kept out of SF Mono because a monospaced design spaces it out like a typewriter.
