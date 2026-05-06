# FlowRead for KOReader

FlowRead is a focused speed-reading plugin for KOReader. It turns books into a
smooth word-by-word flow using RSVP (Rapid Serial Visual Presentation), ORP
anchor highlighting, intelligent pacing, and e-ink friendly rendering.

It is built for Kindle, Kobo, PocketBook, Android, desktop KOReader, and any
device where you want reading to feel faster, calmer, and easier to hold focus.

Inspired by the excellent [rsvpnano](https://github.com/ionutdecebal/rsvpnano)
hardware reader concept.

## Highlights

- RSVP reading mode: one word at a time, aligned around an ORP focal letter.
- Scroll reading mode: context-rich page flow with the current word highlighted.
- Built-in library browser: scan a books folder, open books, and resume progress.
- Intelligent pacing: optional pauses for long words, complex words, clauses,
  and sentence endings.
- Custom anchor styles: invert, bold, underline, or no highlight.
- Phantom context words: optionally show previous and next words around the main
  word.
- Chapter navigation for parsed EPUB chapters.
- Scrub preview: pause, swipe, then browse forward or backward with context.
- Typography controls: font size, typeface, and letter spacing.
- Light and dark themes.
- E-ink optimized rendering: cached fonts, cached word metadata, stable timers,
  deferred settings writes, and shared text-layout caching.

## Supported Formats

- `.epub`
- `.txt`
- `.md`
- `.markdown`
- `.fb2`
- `.html`
- `.htm`
- `.xhtml`

EPUB files are parsed in spine order, and chapter boundaries are used when
available.

## Installation

Copy `flowread.koplugin` into KOReader's plugin directory.

Common plugin paths:

- Kindle: `/mnt/us/koreader/plugins/`
- Kobo: `.adds/koreader/plugins/`
- Android: `/sdcard/koreader/plugins/`
- Linux desktop: `~/.config/koreader/plugins/`

The final path should look like this:

```text
.../plugins/flowread.koplugin/main.lua
```

Restart KOReader, then open:

```text
Top menu -> Tools -> More tools -> FlowRead
```

If you use [Zen UI](https://anthonygress.github.io/zen_ui.koplugin/) and the
normal KOReader tools menu is hidden, first confirm the plugin is enabled in:

```text
Tools -> More tools -> Plugin management -> FlowRead
```

FlowRead also registers a general KOReader action named `Open FlowRead`, so Zen
UI custom buttons/action menus can launch it even when the standard tools menu is
not visible.

## First Run

1. Open `FlowRead` from KOReader's More tools menu.
2. Open settings from the library screen.
3. Set `Books folder` to the folder containing your books. The default is
   `/sdcard/Books`.
4. Tap a book to start reading.

FlowRead autosaves your position while reading and again when you leave the
reader.

## Controls

### Reading Screen

| Gesture | Action |
| --- | --- |
| Tap | Play or pause |
| Double tap | Lock autoplay |
| Tap left edge | Rewind to the start of the current sentence |
| Swipe up | Increase WPM |
| Swipe down | Decrease WPM |
| Swipe left or right while paused | Open scrub preview |
| Swipe left or right while playing | Jump backward or forward |
| Long press | Open settings or chapter menu |
| Back | Save and return |

### Scrub Preview

| Gesture | Action |
| --- | --- |
| Hold and drag | Browse backward or forward |
| Release | Stop browsing |
| Tap | Return to the reader |

## Settings

| Setting | Default | Description |
| --- | --- | --- |
| WPM | `250` | Reading speed from 60 to 800 words per minute |
| Reading mode | `rsvp` | RSVP flow or scroll mode |
| Anchor position | `50%` | Horizontal position of the focal letter |
| Anchor style | `invert` | Invert, bold, underline, or none |
| Anchor guides | `on` | Small guide marks above and below the anchor |
| Phantom words | `off` | Show previous and next words for context |
| Font size | `medium` | Small, medium, or large |
| Typeface | `default` | KOReader default, Atkinson Hyperlegible, or OpenDyslexic |
| Letter spacing | `0` | Extra spacing between characters |
| Theme | `light` | Light or dark reader screen |
| Pacing | `on` | Optional long-word, complexity, and punctuation pacing |
| Books folder | `/sdcard/Books` | Folder scanned by the library browser |

## Project Layout

```text
flowread.koplugin/
├── _meta.lua
├── main.lua
├── library_screen.lua
├── settings.lua
├── settings_panel.lua
├── document_parser.lua
├── rsvp_engine.lua
├── rsvp_screen.lua
├── scroll_screen.lua
├── scrub_preview.lua
├── chapters_screen.lua
└── text_layout.lua
```

## Development

Run a Lua syntax check:

```bash
luac -p flowread.koplugin/*.lua
```

This repository intentionally keeps the plugin self-contained. Drop the
`flowread.koplugin` folder into KOReader and restart to test on device.

## Status

FlowRead is currently an early release. The core reader, library browser,
settings, multiple formats, chapter navigation, scroll mode, and performance
optimizations are in place. Real-device feedback is welcome, especially from
Kindle and Kobo e-ink devices.

## License

MIT. See `LICENSE`.
