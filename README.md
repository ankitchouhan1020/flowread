# FlowRead for KOReader

A focused speed-reading plugin for KOReader. Displays books word-by-word using
RSVP with an ORP anchor letter, intelligent pacing, and e-ink optimized rendering.
Includes a scroll reading mode, library browser, chapter navigation, and scrub preview.

Inspired by [rsvpnano](https://github.com/ionutdecebal/rsvpnano).

## Installation

Copy `flowread.koplugin/` into KOReader's `plugins/` folder and restart:

```
.../plugins/flowread.koplugin/main.lua
```

Open via **Tools → More tools → FlowRead**.

### Zen UI

Enable the plugin under **Tools → More tools → Plugin management → FlowRead**.

To add a navbar tile: create a custom tab and assign the **Open FlowRead** action.

## First Run

1. Open FlowRead from the tools menu.
2. Tap the settings icon (top-left) in the library screen.
3. Set **Books folder** to the folder containing your books (default: `/sdcard/Books`).
4. Tap a book to start reading.

## Supported Formats

`.epub` · `.txt` · `.md` · `.fb2` · `.html` · `.htm` · `.xhtml`

## Controls

### Reading Screen

| Gesture | Action |
| --- | --- |
| Tap | Play / pause |
| Double tap | Lock autoplay |
| Tap left edge | Rewind to sentence start |
| Swipe up / down | Increase / decrease WPM |
| Swipe left / right (paused) | Open scrub preview |
| Swipe left / right (playing) | Jump backward / forward |
| Long press | Settings or chapter menu |
| Back | Save and return |

### Scrub Preview

| Gesture | Action |
| --- | --- |
| Hold and drag | Browse backward / forward |
| Release | Stop browsing |
| Tap | Return to reader |

## Settings

| Setting | Default | Options |
| --- | --- | --- |
| WPM | `250` | 60 – 800 |
| Reading mode | `rsvp` | `rsvp` · `scroll` |
| Font size | `medium` | `small` · `medium` · `large` |
| Typeface | `default` | `default` · `atkinson` · `opendyslexic` |
| Theme | `light` | `light` · `dark` |
| Anchor position | `50%` | 20 – 80% |
| Anchor style | `invert` | `invert` · `bold` · `underline` · `none` |
| Anchor guides | `on` | on · off |
| Phantom words | `off` | on · off |
| Letter spacing | `0` | –4 to +12 px |
| Pacing | `on` | long words · complexity · punctuation |
| Books folder | `/sdcard/Books` | any path |

## License

MIT. See `LICENSE`.
