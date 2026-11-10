# Screenshot checklist

The Phase 4 suite runs headlessly, so it cannot produce screenshots. Capture
these on a desktop build before the Phase 6 release and keep the files in this
folder. Use the default theme, a 1440×900 (or 1280×800) window at 100% scale,
and a trusted workspace with Python available so the run-backed path is visible.

| File | Shot | Steps |
| --- | --- | --- |
| `01-onboarding.png` | First-run onboarding | Remove the course progress/onboarding key (or use a fresh profile), open the course, capture the dialog with its three bullets and **Later**/**Start**. |
| `02-typing.png` | Full shell, typing phase | Open lesson 1, start it, type a few correct characters so ghost text and the coach panel are both visible. Include the host chrome strip and progress. |
| `03-freeform.png` | Full shell, freeform phase | Finish the typing phase, add a partial second line, and capture the prompt, example and **Check** state. |
| `04-check-passed.png` | Passed lesson | Submit a correct lesson 1, wait for the run result, and capture the success status, hint and **Next lesson**. |
| `05-help.png` | Help dialog | Open **Help** and capture the keyboard/panic instructions. |
| `06-partial-panel.png` | Partial-UI fallback | Make another mod’s shell active (or use a host build without `ui.shell`), open the course and capture the panel with the reason line, lesson list, progress and actions. |
| `07-course-complete.png` | Five lessons done | Complete all five (or mark progress via a test profile) and capture the course list with every lesson checked and 100% progress. |

Guidelines:

- Capture the whole window, not a cropped widget, so shell framing and host
  chrome are auditable.
- Do not include personal paths, tokens or unrelated editor tabs.
- Keep text legible at the documented window size; do not scale the image
  after capture.
- For `06-partial-panel.png`, do not fake the reason; use a real permission or
  takeover failure and leave the exact message visible.
- If a capture reveals a layout bug, fix the mod and re-capture rather than
  retouching the image.

After capturing, add the images to the Phase 4 README and the sample README
where they help, and update the Gate E table from “Screenshots pending” to the
captured filenames.
