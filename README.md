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

The crossbar's four bars are four separate blocks: Base, LT, RT and LT+RT, each with the D-pad on the top row and the face buttons below. The base block's face buttons are reserved by the game and shown empty. Text beside each block says what to hold (`LT +` and so on). A small toolbar holds the keyboard/controller toggle, page, wheel and bind buttons.

On a first run the controller binds are set to match: D-pad and X/Y/B/A bare for Base, with Shift for LT, Ctrl for RT and both for LT+RT. This follows the key-modifier convention ClassicConsoleGamepadUI uses for the triggers and has not been checked against the real client.

- `/fcb unlock` shows a blue drag handle above each block and the toolbar; drag them separately. `/fcb lock` hides the handles.
- `/fcb helper [on|off]` shows or hides the text beside each block.
- `/fcb hidebuttons` and `/fcb showbuttons` hide or show the keyboard/controller toggle, Pg and Bind buttons.
- `/fcb resetpos` puts the blocks and toolbar back in their default spots.
- `/fcb padreset` puts the controller binds back to the defaults.

## Shoulder bars

Three more blocks, **LB**, **RB** and **LB+RB**, sit above the LT, RT and LT+RT blocks with 8 buttons each. They are bound under Alt (LB), Alt+Ctrl (RB) and Alt+Shift (LB+RB), so they work in combat. A shoulder button is not a modifier by itself, so Steam Input has to send those:

1. Left bumper: output `Alt` while held.
2. Right bumper: output `Alt` and `Ctrl` while held.
3. Both bumpers: output `Alt` and `Shift` (a chord on one of them).
4. Keep the triggers as Shift (LT) and Ctrl (RT).

Don't hold LT or RT together with a bumper: Alt+Shift is both "LB+RB" and "LT with LB", so they would trigger the same bar. Any button can be rebound with `/fcb bind` if you pick other outputs.

Their actions are stored in page 3's left, right and bottom crossbar bars, so paging cycles pages 1-2 only. The page-3 buttons still show in the game's crossbar editor. Saves from before this change get the default binds for any new buttons once.

Not checked in the real client: that Alt, Alt+Ctrl and Alt+Shift are free in the game's controller mode, and how Steam Input handles the LB+RB chord.

## Tab-target macros

On login the addon makes two account macros if they are missing: **FCB Tab Enemy** (`/targetenemy`) and **FCB Tab Friend** (`/targetfriendplayer`). Open `/macro` and drag them onto any button. Their icon is a question mark; change it in the macro window. `/fcb macros` makes them now, `/fcb macros off` stops them being made on login, and `/fcb macros on` turns it back on. I have not checked that these two slash commands exist on Forever.
