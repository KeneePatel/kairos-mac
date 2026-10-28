# Bundled fonts

The Harvard resume template and the cover letter are set in **Liberation Serif**, metric-compatible
with Times New Roman, the font of Harvard's own resume sample. Times New Roman can't be bundled;
Liberation Serif can. Typst runs with `--ignore-system-fonts`, so every Mac prints the same PDF.

| File | Weight | SHA-256 |
|---|---|---|
| `LiberationSerif-Regular.ttf` | Regular | `058ea80864aef09a23f45cbec2bb5400bc3dfbdea01c3f10538a21fcb497fb74` |
| `LiberationSerif-Bold.ttf` | Bold | `d754ba427cfe0bca54ae052384baa8f842da5bd6550ad4da024ac441e7a7d5ce` |
| `LiberationSerif-Italic.ttf` | Italic | `0e3dea9f8d613e006ccfa62201f33e265d19167bd0907725c3e145368b04fc2e` |

- **Source:** https://github.com/liberationfonts/liberation-fonts, release 2.1.5,
  `liberation-fonts-ttf-2.1.5.tar.gz`. Bold italic is left out; no template uses it.
- **License:** SIL Open Font License 1.1, in `OFL-Liberation.txt`.
