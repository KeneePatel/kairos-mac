# Contact icons

`harvard.typ` and `cover.typ` draw the contact line's icons from SVG kept inline in each template,
so typst needs no files besides the template and its data. They come from **Bootstrap Icons
1.13.2** (https://github.com/twbs/icons, tag `v1.13.2`, `icons/`, fetched 2026-10-21), chosen over
Font Awesome because Font Awesome's icons are CC BY 4.0, which asks for credit in the output, and a
resume can't carry it.

| Key | File | SHA-256 of the original |
|---|---|---|
| `email` | `envelope-fill.svg` | `fd95ca77535ac259ebea82fc857056960e8bce9b99bb8a1c0fe43e483b7f30f5` |
| `phone` | `telephone-fill.svg` | `3e558dc602d4d3fa92ac99f70072ba27943665deeeabf7380440c2f9a741ee42` |
| `linkedin` | `linkedin.svg` | `ddcbb2735eea12f090ea0ee371d1b9a3462531dc11efd0e944adc2d38c71e2df` |
| `github` | `github.svg` | `419c5de58f4bfeb06ed2e15e475965bd39cfb040d1c8627eed00bcba5f59ae96` |
| `website` | `globe2.svg` | `4365f2044bae83b1fc81cae38169777f62131103782ed74236b8e289822cad58` |
| `location` | `geo-alt-fill.svg` | `bca85e28d15d759fe99841074572caa1a30cdc3b053135986627179ab50b88f9` |

Changes from the originals: the `class` attribute is removed, `fill="currentColor"` becomes black,
double quotes become single quotes, and line breaks become spaces. The paths are untouched.

The GitHub and LinkedIn marks are their owners' trademarks, used here only to label a link to your
own profile on each.

## License

The MIT License (MIT)

Copyright (c) 2019-2024 The Bootstrap Authors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
