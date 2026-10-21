# Bundled fonts

The Classic template is set in **Source Serif 4** (design/kairos/README.md, Type). Typst runs with
`--ignore-system-fonts`, so output is the same on every Mac, and these are the only text fonts it
sees besides those built into typst.

The Harvard template, which builds use, and the cover letter are set in **Liberation Serif**,
metric-compatible with Times New Roman, the font of Harvard's own resume sample. Times New Roman
itself can't be bundled; Liberation Serif can.

| File | Weight | SHA-256 |
|---|---|---|
| `LiberationSerif-Regular.ttf` | Regular | `058ea80864aef09a23f45cbec2bb5400bc3dfbdea01c3f10538a21fcb497fb74` |
| `LiberationSerif-Bold.ttf` | Bold | `d754ba427cfe0bca54ae052384baa8f842da5bd6550ad4da024ac441e7a7d5ce` |
| `LiberationSerif-Italic.ttf` | Italic | `0e3dea9f8d613e006ccfa62201f33e265d19167bd0907725c3e145368b04fc2e` |

- **Source:** https://github.com/liberationfonts/liberation-fonts, release 2.1.5,
  `liberation-fonts-ttf-2.1.5.tar.gz` (fetched 2026-10-21). Bold italic is left out; no template uses it.
- **License:** SIL Open Font License 1.1, copied in `OFL-Liberation.txt` (Red Hat, with digitized
  data from Google's Tinos).

| File | Weight | SHA-256 |
|---|---|---|
| `SourceSerif4-Regular.otf` | Regular | `edf160d0d584deee8a3bb2c3371b2a7624ca63580fbe02c57c1f4c91e84d8787` |
| `SourceSerif4-It.otf` | Italic | `f8062257f4693e438a8e317c9fe2b4393f0d4eed84d897edcbfd733c30a1c1a1` |
| `SourceSerif4-Semibold.otf` | Semibold | `25e034392847d9965c92f98971b3646436b7ab919ece9118b0c0e5ec94c02efc` |
| `SourceSerif4-Bold.otf` | Bold | `f5fb9a7b1611353fdfebcf8b1e46c7d9108470f25999b841816d8b643b1856ff` |

- **Source:** https://github.com/adobe-fonts/source-serif, `release` branch, `OTF/` (fetched 2026-10-20).
- **License:** SIL Open Font License 1.1, copied in `OFL.txt`. Bundling and embedding in PDFs are allowed; the fonts may not be sold on their own.
