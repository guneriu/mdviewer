# Examples

## `showcase/`: feature showcase and manual test document

`showcase/showcase.md` exercises everything MDViewer renders, and shows what it
blocks on purpose. Each section says what you should see, so the file works as:

- a **demo**: open it to see what the viewer supports
- a **manual acceptance checklist** after changes to the renderer, styles, image
  handling or link handling. Open it in a freshly built app and check each section.
- a **live-refresh playground**: the "Live features to try" section walks through live
  refresh, Follow Changes, image refresh, find, zoom and dark mode.

```bash
bash scripts/package.sh release        # build .build/release/MDViewer.app
open -a "$PWD/.build/release/MDViewer.app" examples/showcase/showcase.md
```

Opening the app is a manual step. Agents must not launch it (see `AGENTS.md`).

| File | Purpose |
|---|---|
| `showcase/showcase.md` | Text formatting, heading anchors, lists and task lists, tables, highlighting for all 8 bundled languages, PNG/JPEG/GIF/WebP images, links, Unicode, blocked content, unsupported syntax. |
| `showcase/second-page.md` | Target for links between Markdown files (opens in its own window, with a fragment). |
| `showcase/images/` | Small generated images, one per supported format. |

### Regenerating the images

The images are generated, not hand-made:

```bash
python3 scripts/make-showcase-images.py
```

The script writes the PNG with the Python standard library, converts to JPEG and GIF
with macOS `sips`, and to WebP with `cwebp` (`brew install webp`). Without `cwebp` the
existing `stripes.webp` is kept. Nothing is downloaded. Running it while the
showcase is open is also a way to test image refresh.

### Updating the showcase

When you add or change a rendering feature, add a short section to
`showcase/showcase.md` that states the expected result. When syntax is deliberately
unsupported, list it under **Not supported**. Fragment links use the heading slug
(`#tables`, `#repeated-heading-2`), not the internal `heading-` id prefix.

The showcase is not used by automated tests. Regression fixtures for automated tests live in
`Fixtures/` and are hash-checked by `scripts/verify_m0.py`. Don't move showcase files there.
