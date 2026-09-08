# Memory (SwiftBar)

Shows how much memory is in use out of what is installed, e.g. `30.4 GB / 36 GB`.

**Used** is computed the way Activity Monitor does it:
`app memory (anonymous − purgeable) + wired + compressed`, from `vm_stat`
and `hw.memsize`. Memory pressure comes from
`kern.memorystatus_vm_pressure_level`; swap from `vm.swapusage`.

## Menu bar looks

Pick one from **Menu Bar Style** in the dropdown. The choice is saved to
`~/.config/mac-utilities/memory-menubar.json`.

| Style | Shows | Notes |
| --- | --- | --- |
| Text | `▣ 30.4 GB / 36 GB` | default |
| Percent | `▣ 84%` | |
| Bar | pill gauge + `30.4 GB` | rendered image |
| Ring | ring gauge + `30.4 / 36` | rendered image |
| Graph | last-hour sparkline + `84%` | rendered image, 5 s samples kept in `~/.cache/mac-utilities/memory-history.txt` |
| Icon only | `▣` | the quietest option |

Everything is drawn in white/black to match the menu bar. When memory
pressure is **Warning** the gauge and symbol turn orange, on **Critical** red.

## Dropdown

- Headline: used of total, pressure, and a stacked bar of
  App / Wired / Compressed / Cached / Free.
- Breakdown of those five plus swap.
- Top six apps by resident memory (helper processes folded into their app).
- Style picker, Open Activity Monitor, Refresh.

## Dev

```sh
./memory.5s.py --set style bar     # what the style menu items run
./memory.5s.py --dump /tmp/imgs    # also writes bar/ring/graph/breakdown PNGs
```

Graphics are produced by a small pure-Python renderer (supersampled, retina
via a 144-dpi `pHYs` chunk) so there are no dependencies beyond the system
Python.
