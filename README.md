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

Each of the crossbar's bars is a single row of 8 buttons in its own panel with the same blue edge: Base, LT, RT and LT+RT, plus LB, RB, LT x2 and RT x2 in a second row above. The scale is set on first run so a row fits the screen (`/fcb scale auto` redoes it). Under each bar a label says what to hold ("LT", "hold LT"), so the buttons only show which controller button they are: arrows for the D-pad and the A/B/X/Y icons, centred in each button at half opacity. The first four buttons of a bar are the D-pad and the last four are the face buttons. A keyboard bind still shows as small text in the corner. The base bar's face buttons are the game's own (see below). A small toolbar above holds the keyboard/controller toggle, wheel and bind buttons.

While you hold LT, RT, LB or RB (as Shift, Ctrl or Alt) in controller mode, the other bars fade so the active one stands out. `/fcb fade off` turns that off; `/fcb fade 0.5` sets how dim they get.

On a first run the controller binds are set to match: D-pad and X/Y/B/A bare for Base, with Shift for LT, Ctrl for RT and both for LT+RT. This follows the key-modifier convention ClassicConsoleGamepadUI uses for the triggers and has not been checked against the real client.

- `/fcb unlock` shows a coloured drag handle above each bar and the toolbar; drag them separately. `/fcb lock` hides the handles.
- `/fcb helper [on|off]` shows or hides the labels under each bar.
- `/fcb hidebuttons` and `/fcb showbuttons` hide or show the keyboard/controller toggle and Bind buttons.
- `/fcb resetpos` puts the bars and toolbar back in their default spots.
- `/fcb padreset` puts the controller binds back to the defaults.

## The other four bars: LB, RB and double-press LT and RT

Four more bars, **LB**, **RB**, **LT x2** and **RT x2**, make up a second row above the first four. A shoulder button or a double press is not a modifier by itself, so Steam Input has to send one for each:

| Bar | Hold | Steam Input outputs |
| --- | --- | --- |
| LB | left bumper | `Alt` |
| RB | right bumper | `Alt` + `Ctrl` |
| LT x2 | double-press left trigger | `Alt` + `Shift` |
| RT x2 | double-press right trigger | `Alt` + `Ctrl` + `Shift` |

Keep the single press of the triggers as Shift (LT) and Ctrl (RT).

**Both triggers need their analog output turned off** in Steam Input, or the double-press and other activator options are not offered for them. Set each trigger to a digital (button) output first.

Don't hold LT or RT together with a bumper: the combinations overlap (Alt+Shift is both "LT x2" and "LB with LT"), so the same bar would fire. Any button can be rebound with `/fcb bind` if you pick other outputs.

There is no paging any more: the crossbar has 84 usable slots (3 pages of 28), so the main bars use page 1 and these four bars use the rest: LB, RB and LT x2 on page 3 and RT x2 on page 2. Actions you put on the old page 2 will show up on the RT x2 bar's left row.

Not checked in the real client: that Alt, Alt+Shift and Alt+Ctrl+Shift are free in the game's controller mode.

## Tab-target macros

On login the addon makes two account macros if they are missing: **FCB Tab Enemy** (`/targetenemy`) and **FCB Tab Friend** (`/targetfriendplayer`). Open `/macro` and drag them onto any button. Their icon is a question mark; change it in the macro window. `/fcb macros` makes them now, `/fcb macros off` stops them being made on login, and `/fcb macros on` turns it back on. I have not checked that these two slash commands exist on Forever.

## With BagPad Forever

BagPad Forever restyles the game's own bag and bank windows and uses the D-pad, face buttons, LB and RB inside them. This addon's controller binds sit on those same buttons, so while a bag, bank, vendor, mail or trade window is open the controller binds step aside (keyboard binds are not touched) and come back when it closes. Out of combat only; in combat the change waits for combat to end.

- `/fcb yield off` turns this off; `/fcb yield on` turns it back on.
- If BagPad (or another addon) uses a window with its own name, add it: `/fcb yield add FrameName`, `/fcb yield remove FrameName`, `/fcb yield` to list. `/fcb status` shows whether the binds are stepping aside.

The two addons share no frame names, slash commands or globals (`/bp` and `/bagpad` vs `/fcb` and `/flatcrossbar`), and BagPad's list of conflicting bag addons does not include this one. I could not read BagPad's source (it has no public repository), so this is based on its CurseForge page and has not been tried with it installed.

One conflict that is not fixable in the addon: the shoulder bars need Steam Input to send Alt for LB and Alt+Ctrl for RB, so the game never sees LB/RB while that is on, and BagPad's LB (compare gear) and RB (DataPad) will not work. Either turn that Steam Input layer off while using BagPad, or put it on an action layer you switch to.

## The game's own four buttons

The base bar's face buttons are the game's own: **Act** (dynamic action: interact or attack), **Insp** (inspect: the target menu), **Back** (cancel cast, clear target) and **Jump**. They are the game's hidden bindings `GAMEPADACTIONBUTTON5-8`, and they show as dim labelled slots in the Base block. They are bound like the other buttons, to controller buttons only:

- `/fcb bindto jump` (or `dynamic`, `inspect`, `back`), then press a controller button; or `/fcb bind`, hover the slot and press one.
- The defaults are X (Act), Y (Insp), B (Back) and A (Jump). `/fcb clear jump` removes one, `/fcb padreset` restores them.

Holding LB makes the game show its own page tracker. With `/fcb blizzard off` (the default) the addon hides the page tracker and the game's crossbar, and keeps them hidden if the game shows them again later. `/fcb blizzard on` leaves them alone.

Not checked in the real client: that an override binding to `GAMEPADACTIONBUTTON5-8` runs the game's button, and that the page tracker is hidden by this.
