# Cursor shaders (third party)

The cursor trail in `resources/shaders/cursor_trail.gdshader` is a port of the cursor
shaders by [sahaj-b](https://github.com/sahaj-b/cursor-shaders), which are
MIT licensed. The originals are kept here, unchanged, next to their licence.

| Original | Ported effect |
| --- | --- |
| `cursor_warp.glsl` | **Warp** — the Neovide-like smear, every corner of the caret has its own easing. |
| `cursor_sweep.glsl` | **Sweep** — the trail shrinks from the old caret onto the new one. |
| `cursor_tail.glsl` | **Tail** — a comet: the head follows the caret, the tail lags behind. |

The remaining files (`ripple_cursor.glsl`, `ripple_rectangle_cursor.glsl`,
`rectangle_boom_cursor.glsl`, `sonic_boom_cursor.glsl`) trigger on a change of
the cursor's *shape*, which a text editor has no equivalent for: its caret
never switches between a bar and a block on its own. They are kept for
reference.

## What the port changed

The originals are written for Ghostty and Kitty, which hand the shader the
whole terminal framebuffer; the shader paints the trail over it and punches a
hole for the live cursor. Godot's canvas shaders cannot read what is already
on the canvas, so the port:

- draws the trail over the code as its own quad instead of over a terminal
  texture, and keeps a hole for the caret instead of restoring the background;
- works in the quad's own pixels instead of normalised screen coordinates, so
  the trail scales with the camera exactly like the code it belongs to;
- takes the two caret rectangles from the editor instead of from the
  terminal.

The maths of the three trail effects is otherwise unchanged.

## Licence

MIT — see `LICENSE`.
