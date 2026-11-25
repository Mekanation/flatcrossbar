# FlatCrossbar

Paste into the CurseForge project description (it accepts Markdown).

---

**FlatCrossbar** turns the WoW Forever controller beta's crossbar into plain, flat action bars, in the style of ClassicConsoleGamepadUI, and adds more of them.

## Features

- **Eight bars of eight buttons**, laid out horizontally and never stacked: Base, LT, RT and LT+RT, plus LB, RB, LT x2 and RT x2.
- **The bar in use is in focus.** Base is bright when no trigger is held, and the others fade.
- **Keyboard and controller keybinds** you can switch between, or let `auto` follow the game. In keyboard mode the bars hide and the default bars are used.
- **Radial wheel** on L3: aim with the right stick, release to use, D-pad left/right to page. The camera stays still while it is open.
- **Act / Insp / Back / Jump** show the game's own icons.
- **Combat cooldowns**, charges and loss of control.
- **Drag, snap and lock** each bar. The layout is shared by all your characters.
- **Plays nicely** with bags, banks, vendors, mail (BagPad, ForeverMail) and the game menu.
- **Tab-target macros** for enemies and friendly players, made for you.
- Controller button icons for PlayStation shapes, Xbox letters, or whatever the game uses.

## Getting started

Type `/fcb` for the command list. `/fcb unlock` lets you drag the bars; `/fcb mode controller|keyboard|auto` picks the keybind set.

## Steam Input setup (Steam Deck and controllers)

The four main bars (Base, LT, RT, LT+RT) work with the game's own controller input and need no setup. The other four bars need Steam Input, because a shoulder button or a double press is not a modifier on its own.

**Easiest: use the community layout.** In Steam, open the game's controller settings, go to Browse Community Layouts and pick **WOW: Forever FlatCrossBar Addon**. It sets up everything below for you.

**Or set it up yourself.** Make Steam Input send these keys:

| Bar | Hold | Steam Input outputs |
| --- | --- | --- |
| LB | left bumper | `Alt` |
| RB | right bumper | `Alt` + `Ctrl` |
| LT x2 | double-press left trigger | `Alt` + `Shift` |
| RT x2 | double-press right trigger | `Alt` + `Ctrl` + `Shift` |

A single press of LT and RT stays as the normal triggers.

Things to know:
- **Turn analog output off for both triggers** (set them to digital button output). Otherwise Steam Input doesn't offer the double-press option for them.
- Don't hold a trigger together with a bumper. The combinations overlap (Alt+Shift is both "LT x2" and "LB with LT"), so the same bar would fire.
- With LB and RB sending Alt, the game no longer sees the bumpers, so windows that use them for tabs or pages won't respond to LB/RB. Put the bumper bars on a Steam Input action layer you can switch off, or only enable them while playing. This also affects BagPad's LB (compare gear) and RB (DataPad).
- Prefer other outputs? Rebind any bar's buttons with `/fcb bind`.

## Notes

Made for the WoW Forever controller beta (interface 16001). Report problems with the output of `/fcb status`.
