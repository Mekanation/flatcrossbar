# FlatCrossbar

A separate WoW Forever addon (not part of C2XP) that takes the controller beta's
crossbar and lays all of it out as one plain action bar.

Install: copy the `FlatCrossbar` folder into `_forever_/Interface/AddOns/`.

## What it does

- Shows the crossbar's 28 usable buttons per page (3 pages) at once, over the
  same storage slots, so anything you set on the crossbar shows here too.
- Two keybind sets, keyboard and controller. Mode `auto` follows the game's own
  keyboard/gamepad interface switch; or force `keyboard`, `controller` or `both`.
- The header has a mode button (left-click: keyboard/controller, right-click:
  cycle all modes), a page button (works in combat), and Bind.
- Bind: hover a button, press a key or controller button. Controller buttons
  (`PAD*`) go in the controller set, everything else in the keyboard set.
  Backspace clears the button.
- Bindings are override bindings, so your saved WoW bindings are untouched.
  The buttons are also in Key Bindings > AddOns, and those are always live.
- Wheel (controller mode only): 8 slices over the current page's buttons, in the
  style of Blizzard's flyout radial, with 4 wheel pages (header button `W1`..`W4`)
  covering all 28. Its header buttons show, and its binds apply, only while the
  controller keybind set is live. Bind a controller button to `Wheel` (Bind,
  hover `Wheel`, press), hold it to open, aim with the right stick or the mouse,
  release to use the slice. Stick back to centre cancels. It doesn't open in
  combat. Wheel next/prev page are bindable too (`/fcb bindto ...`).
- Hides Blizzard's crossbar (`/fcb blizzard on` to show it again).

`/fcb` lists the commands.

## Not tested in game

Written against the `forever` branch of Gethe/wow-ui-source (1.60.1.70532).
Not run in the client yet. Things to check first:

- Buttons show the actions you have on the crossbar.
- Controller capture: `EnableGamePadButton` / `OnGamePadButtonDown` on the Bind
  frame, and that PAD names (e.g. `PAD1`) work with override bindings.
- Trigger combos need modifier emulation (e.g. `GamePadEmulateShift`); the
  capture records them as `SHIFT-PAD1` etc.
- Wheel: the selected slice's action is copied onto the `Wheel` button's secure
  attributes while aiming, and releasing the key clicks it. That relies on the
  `useOnKeyDown` attribute to fire on release, and I assumed the right stick is
  `sticks[2]` in `C_GamePad.GetDeviceMappedState`.
- The vehicle/possess page and stance bars are not shown.

## Tests

`pip install lupa`, then `python flatcrossbar/tests/smoke.py`. It loads the addon against
stubbed WoW APIs and walks the events, slash commands and wheel flow. It checks the
addon's own logic, not game behaviour.

## Layout

By default the bar shows the crossbar's four bars as four 2x4 blocks: Base, LT, RT and LT+RT, each with the D-pad on the top row and the face buttons below. The base block's face buttons are reserved by the game and shown empty. On a first run the controller binds are set to match: D-pad and X/Y/B/A bare for Base, with Shift for LT, Ctrl for RT and both for LT+RT. This follows the key-modifier convention that ClassicConsoleGamepadUI uses for the triggers and has not been checked against the real client.

- `/fcb layout groups|row` switches between the blocks and the single 28-button row.
- `/fcb groupcols 1-4` sets how many blocks sit side by side.
- `/fcb padreset` puts the controller binds back to the defaults.
