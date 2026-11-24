-- FlatCrossbar: the controller beta's crossbar as one plain action bar.
--
-- The crossbar (Blizzard_GamepadActionBars) holds its actions in "gamepad
-- storage slots": 3 standard pages x 4 bars (top/left/right/bottom) x 8
-- buttons, with the top bar's right-hand 4 reserved for UI actions, leaving
-- 28 usable buttons per page (page 1 is the main set; the LB, RB and double-press
-- bars use pages 2 and 3). Blizzard shows only one bar at a time and picks
-- it with the trigger modifiers. This addon shows all 28 of a page at once as
-- ordinary buttons over the same storage slots, so whatever you set up on the
-- crossbar shows up here, and the other way round.
--
-- Keybinds are kept in two sets, keyboard and controller, and applied as
-- override bindings (they never touch your saved WoW bindings). The mode picks
-- which set is live: keyboard, controller, both, or auto (follows the game's
-- own keyboard/gamepad interface switch). The buttons are also in the normal
-- Key Bindings screen under AddOns, and those bindings are always live.
--
-- The wheel is a radial of 8 slices over the current page's buttons (4 wheel
-- pages cover all 28). It is controller-only: its binds live in the controller
-- set and its header buttons show only while the controller set is live. Hold
-- its key to open it, aim with the right stick or the mouse, release the key to
-- use the slice. It doesn't open in combat. The selected slice is copied onto
-- the wheel button's own secure action attributes while aiming, so releasing
-- the key clicks it; that is the only secure part.

local ADDON = ...

local MAIN_BUTTONS = 28 -- the four crossbar bars, paged
local NUM_BUTTONS = 60 -- plus four bars of 8: LB, RB and the double-press LT and RT
local BUTTON_SIZE = 36
local SPACING = 0
local HEADER_HEIGHT = 18
local WHEEL_SLICES = 8
local WHEEL_PAGES = 6 -- set from the chosen action bars (buildWheelSlots)
local WHEEL_RADIUS = 92
local WHEEL_SLICE_SIZE = 50
local STICK_DEADZONE = 0.5

local MODES = { "auto", "keyboard", "controller", "both" }
local MODE_LABEL = { auto = "AUTO", keyboard = "KB", controller = "PAD", both = "KB+PAD" }

local DEFAULTS = {
  mode = "auto",
  kb = {},
  pad = {},
  helper = true,
  hideButtons = false,
  autoMacros = true,
  yield = true,
  yieldFrames = {},
  fade = true,
  snap = true,
  hideInKeyboard = true,
  iconSet = "shapes",
  fadeAlpha = 0.3,
  wheelBars = { 6, 7, 8 },
  autoScale = true,
  groupPoints = {},
  scale = 1,
  page = 1,
  wheelPage = 1,
  wheelScale = 1,
  locked = true,
  hideBlizzard = true,
  point = { "BOTTOM", "UIParent", "BOTTOM", 0, 135 },
}

BINDING_HEADER_FLATCROSSBAR = "FlatCrossbar"
-- A binding whose name is "CLICK <frame>:<button>" clicks that button (the game reads
-- the name; the body stays empty), so these are the names the Key Bindings screen shows.
for i = 1, NUM_BUTTONS do
  _G["BINDING_NAME_CLICK FlatCrossbarButton" .. i .. ":LeftButton"] = "Crossbar button " .. i
end
_G["BINDING_NAME_CLICK FlatCrossbarWheelButton:LeftButton"] = "Crossbar wheel (hold)"
BINDING_NAME_FLATCROSSBARWHEELPAGENEXT = "Next wheel page"
BINDING_NAME_FLATCROSSBARWHEELPAGEPREV = "Previous wheel page"
BINDING_NAME_FLATCROSSBARTOGGLEMODE = "Toggle keyboard / controller keybinds"

local db
local buttons = {}
local container, header, modeButton, bindButton, bindCapture
local groupFrames, groupHandles, sideTexts, reservedSlots = {}, {}, {}, {}
local toolbarHandle
local layoutToolbar, relayout, updateSpecialIcons
local buildError
local manualHidden = false -- /fcb hide
local wheelDpad = false -- the wheel is open: D-pad left/right turn its pages
local yielding = false -- a bag, bank or vendor window is up: the pad binds step aside
local wheel, wheelPageButton, wheelHeaderButton
local slices = {}
local bindOwner = CreateFrame("Frame")
local pendingLayout, pendingBindings, pendingActions, pendingTypes = false, false, false, false
local hoverTarget, forcedTarget
local rangeState = {}

local function print_(msg)
  print("|cff66ccffFlatCrossbar:|r " .. msg)
end

-- Storage slots ---------------------------------------------------------------

-- The crossbar's page-unit slot IDs for each of our 28 buttons: 1-4 (top bar),
-- then 9-32 (left, right, bottom bars). 5-8 are reserved by Blizzard.
local PAGE_UNIT_SLOT_IDS = {}
for id = 1, 4 do PAGE_UNIT_SLOT_IDS[#PAGE_UNIT_SLOT_IDS + 1] = id end
for id = 9, 32 do PAGE_UNIT_SLOT_IDS[#PAGE_UNIT_SLOT_IDS + 1] = id end
-- The page each button lives on. The main bars are page 1. The other four bars use
-- the left, right and bottom bars of page 3 and the left bar of page 2.
local BUTTON_PAGE = {}
for i = 1, #PAGE_UNIT_SLOT_IDS do BUTTON_PAGE[i] = 1 end
local function addExtraBar(page, firstId)
  for id = firstId, firstId + 7 do
    PAGE_UNIT_SLOT_IDS[#PAGE_UNIT_SLOT_IDS + 1] = id
    BUTTON_PAGE[#PAGE_UNIT_SLOT_IDS] = page
  end
end
addExtraBar(3, 9) -- LB
addExtraBar(3, 17) -- RB
addExtraBar(3, 25) -- LT x2
addExtraBar(2, 9) -- RT x2

-- The crossbar's four bars are 8 buttons each (slots 1-4 on the D-pad, 5-8 on
-- the face buttons) and are picked by the triggers held: none = top, LT = left,
-- RT = right, LT+RT = bottom (PageUnit.lua). The groups layout draws each bar as
-- a small 2x4 block under its trigger label.
local GROUP_SIZE = 8
local GROUP_LABEL = { "Base", "LT", "RT", "LT+RT", "LB", "RB", "LT x2", "RT x2" }
-- The triggers reach the game as Shift (LT) and Ctrl (RT) when binding keys.
-- The other four bars are not modifiers by themselves, so Steam Input sends: Alt for
-- LB, Alt+Ctrl for RB, Alt+Shift for a double press of LT and Alt+Ctrl+Shift for RT.
local GROUP_PREFIX = { "", "SHIFT-", "CTRL-", "CTRL-SHIFT-", "ALT-", "ALT-CTRL-", "ALT-SHIFT-", "ALT-CTRL-SHIFT-" }
local FRAME_COLOR = { 0.85, 0.85, 0.9 }
local GROUP_COLOR = {}
for g = 1, #GROUP_LABEL do GROUP_COLOR[g] = FRAME_COLOR end
local function colorCode(c)
  return string.format("|cff%02x%02x%02x", math.floor(c[1] * 255 + 0.5), math.floor(c[2] * 255 + 0.5), math.floor(c[3] * 255 + 0.5))
end
local SLOT_PAD = { "PADDLEFT", "PADDUP", "PADDRIGHT", "PADDDOWN", "PAD3", "PAD4", "PAD2", "PAD1" }
local BUTTON_GROUP, BUTTON_SLOT = {}, {}
for i, id in ipairs(PAGE_UNIT_SLOT_IDS) do
  if i <= MAIN_BUTTONS then
    BUTTON_GROUP[i] = math.floor((id - 1) / GROUP_SIZE) + 1
    BUTTON_SLOT[i] = (id - 1) % GROUP_SIZE + 1
  else
    BUTTON_GROUP[i] = 5 + math.floor((i - MAIN_BUTTONS - 1) / GROUP_SIZE)
    BUTTON_SLOT[i] = (i - MAIN_BUTTONS - 1) % GROUP_SIZE + 1
  end
end

-- Same arithmetic as GamepadActionBarBindingUtil in Blizzard_GamepadActionBars
-- (ActionBindingUtil.lua), used when that addon's helper isn't available.
local function storageSlot(page, pageUnitSlotID)
  local util = _G.GamepadActionBarBindingUtil
  if util and util.GetGamepadStorageSlotIndexFromPageAndPageUnitSlotID then
    return util.GetGamepadStorageSlotIndexFromPageAndPageUnitSlotID(page, pageUnitSlotID)
  end
  if not (C_GamepadUI and C_GamepadUI.GetFirstGamepadActionStorageSlotIndex) then
    return nil
  end
  local first = C_GamepadUI.GetFirstGamepadActionStorageSlotIndex()
  local perPage, reserved = 32, 4
  local slot = first + perPage * (page - 1) + (pageUnitSlotID - 1) - reserved * (page - 1)
  if pageUnitSlotID >= 5 then slot = slot - reserved end
  return slot
end

-- Modes -----------------------------------------------------------------------

local function gamepadUIActive()
  -- The game's own input style: the one that really switches when gamepad mode is
  -- turned on or off.
  if C_InputInterfaceStyle and C_InputInterfaceStyle.GetCurrentStyle
    and Enum and Enum.InputDeviceInterfaceType then
    local ok, style = pcall(C_InputInterfaceStyle.GetCurrentStyle)
    if ok and style ~= nil then return style == Enum.InputDeviceInterfaceType.Gamepad end
  end
  if InputUtil and InputUtil.IsGamepadUIEnabled then
    return InputUtil.IsGamepadUIEnabled() and true or false
  end
  if C_GamePad and C_GamePad.IsEnabled then
    return C_GamePad.IsEnabled() and true or false
  end
  return false
end

local function effectiveMode()
  if db.mode == "auto" then
    return gamepadUIActive() and "controller" or "keyboard"
  end
  return db.mode
end

-- Key text --------------------------------------------------------------------

local SHORT_KEY = {
  PADLTRIGGER = "LT", PADRTRIGGER = "RT", PADLSHOULDER = "LB", PADRSHOULDER = "RB",
  PADDUP = "Du", PADDDOWN = "Dd", PADDLEFT = "Dl", PADDRIGHT = "Dr",
  PADLSTICK = "LS", PADRSTICK = "RS", PADFORWARD = "Fw", PADBACK = "Bk",
  PAD1 = "A", PAD2 = "B", PAD3 = "X", PAD4 = "Y",
  MOUSEWHEELUP = "MwU", MOUSEWHEELDOWN = "MwD",
}

local function shortKey(key)
  if not key then return nil end
  local mods, base = key:match("^(.*%-)([^%-]+)$")
  if not base then mods, base = "", key end
  if base:find("^PAD") then
    -- On a controller button, Shift and Ctrl are the left and right triggers.
    local out
    if mods:find("ALT%-") then
      -- the shoulder bars
      if mods:find("CTRL%-") and mods:find("SHIFT%-") then
        out = "RT2+"
      elseif mods:find("CTRL%-") then
        out = "RB+"
      elseif mods:find("SHIFT%-") then
        out = "LT2+"
      else
        out = "LB+"
      end
    else
      out = (mods:find("SHIFT%-") and "LT+" or "") .. (mods:find("CTRL%-") and "RT+" or "")
    end
    return out .. (SHORT_KEY[base] or (base:gsub("^PAD", "P")))
  end
  mods = mods:gsub("ALT%-", "a"):gsub("CTRL%-", "c"):gsub("SHIFT%-", "s")
  base = SHORT_KEY[base] or base:gsub("^PAD", "P"):gsub("^NUMPAD", "N"):gsub("^BUTTON", "M")
  return mods .. base
end

-- The corner text is the keyboard key; a controller button is drawn as a glyph.
local function hotkeyText(index)
  local mode = effectiveMode()
  if mode == "controller" then return "" end
  return shortKey(db.kb[index]) or ""
end

-- The controller button a bound key ends in, without the trigger modifiers.
local function padBase(key)
  return key and key:match("([^%-]+)$") or nil
end

local GLYPH_TEXT = {
  PADDLEFT = "<", PADDUP = "^", PADDRIGHT = ">", PADDDOWN = "v",
  PAD1 = "A", PAD2 = "B", PAD3 = "X", PAD4 = "Y",
}
local GLYPH_SIZE = 22
local GLYPH_ALPHA = 0.85
local ICON_DIM = 0.72 -- the action icons are a little duller than the glyphs on top

-- The game's own icon for a controller button (arrows for the D-pad, the face
-- buttons for the controller in use), when this build has them.
-- The game's own button icons, as its menus draw them (names from
-- Blizzard_SharedXML InputIcons): "shapes" are the PlayStation set (cross, circle,
-- square, triangle for A, B, X, Y), "letters" the Xbox set. "auto" asks the game
-- which set the controller in use gets.
local ICON_ATLAS = {
  shapes = {
    PAD1 = "gamepad-ps-buttoncrox-normal", PAD2 = "gamepad-ps-buttoncircle-normal",
    PAD3 = "gamepad-ps-buttonsquare-normal", PAD4 = "gamepad-ps-buttontriangle-normal",
    PADDUP = "gamepad-ps-dpadup-normal", PADDDOWN = "gamepad-ps-dpaddown-normal",
    PADDLEFT = "gamepad-ps-dpadleft-normal", PADDRIGHT = "gamepad-ps-dpadright-normal",
    PADLSHOULDER = "gamepad-ps-triggerl1-normal", PADRSHOULDER = "gamepad-ps-triggerr1-normal",
    PADLTRIGGER = "gamepad-ps-triggerl2-normal", PADRTRIGGER = "gamepad-ps-triggerr2-normal",
    PADLSTICK = "gamepad-ps-stickl3-normal", PADRSTICK = "gamepad-ps-stickr3-normal",
  },
  letters = {
    PAD1 = "gamepad-xbox1-buttona-normal", PAD2 = "gamepad-xbox1-buttonb-normal",
    PAD3 = "gamepad-xbox1-buttonx-normal", PAD4 = "gamepad-xbox1-buttony-normal",
    PADDUP = "gamepad-xbox1-dpadup-normal", PADDDOWN = "gamepad-xbox1-dpaddown-normal",
    PADDLEFT = "gamepad-xbox1-dpadleft-normal", PADDRIGHT = "gamepad-xbox1-dpadright-normal",
    PADLSHOULDER = "gamepad-xbox1-trigger-lb-normal", PADRSHOULDER = "gamepad-xbox1-trigger-rb-normal",
    PADLTRIGGER = "gamepad-xbox1-trigger-lt-normal", PADRTRIGGER = "gamepad-xbox1-trigger-rt-normal",
    PADLSTICK = "gamepad-xbox1-stick-l3-normal", PADRSTICK = "gamepad-xbox1-stick-r3-normal",
  },
}

local function glyphAtlas(key)
  local chosen = ICON_ATLAS[db.iconSet]
  if chosen and chosen[key] then return chosen[key] end
  local util = _G.InputIconTextureSetUtility
  if not (util and util.GetNormalActiveInputIconButtonTexture) then return nil end
  local ok, atlas = pcall(util.GetNormalActiveInputIconButtonTexture, key)
  if ok and type(atlas) == "string" and atlas ~= "" then return atlas end
end

local function addGlyph(frame)
  frame.Glyph = frame:CreateTexture(nil, "OVERLAY", nil, 2)
  frame.Glyph:SetSize(GLYPH_SIZE, GLYPH_SIZE)
  frame.Glyph:SetPoint("CENTER")
  frame.Glyph:SetAlpha(GLYPH_ALPHA)
  frame.GlyphText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  frame.GlyphText:SetPoint("CENTER")
  frame.GlyphText:SetAlpha(GLYPH_ALPHA)
end

-- Centred in the frame at half opacity; the letters or arrows when there is no icon.
local function setGlyph(frame, key)
  if not key then
    frame.Glyph:Hide()
    frame.GlyphText:Hide()
    return
  end
  local atlas = glyphAtlas(key)
  if atlas then
    frame.Glyph:SetAtlas(atlas)
    frame.Glyph:Show()
    frame.GlyphText:Hide()
  else
    frame.Glyph:Hide()
    frame.GlyphText:SetText(GLYPH_TEXT[key] or shortKey(key) or key)
    frame.GlyphText:Show()
  end
end

-- Override bindings -----------------------------------------------------------

-- Bindable things besides the 28 buttons. Keys in db.kb / db.pad. The fourth
-- field marks the controller-only ones (the wheel).
local TARGETS = {
  wheel = { "FlatCrossbarWheelButton", "LeftButton", "wheel (hold)", true },
  wheelNext = { "FlatCrossbarWheelPageButton", "LeftButton", "next wheel page", true },
  wheelPrev = { "FlatCrossbarWheelPageButton", "RightButton", "previous wheel page", true },
  -- The four buttons the game keeps on the base bar's face buttons: slots 5-8 are the
  -- hidden bindings GAMEPADACTIONBUTTON5-8 (fifth field), run as the game runs them.
  dynamic = { nil, nil, "dynamic action (interact / attack)", true, "GAMEPADACTIONBUTTON5" },
  inspect = { nil, nil, "inspect (target menu)", true, "GAMEPADACTIONBUTTON6" },
  back = { nil, nil, "back / close (cancel, clear target)", true, "GAMEPADACTIONBUTTON7" },
  jump = { nil, nil, "jump", true, "GAMEPADACTIONBUTTON8" },
}
local RESERVED_TARGETS = { "dynamic", "inspect", "back", "jump" }
-- The buttons the game's menus and windows use to move around and confirm. An override on
-- one of these for a game button would take it from the window that is open.
local MENU_KEYS = {
  PAD1 = true, PAD2 = true, PAD3 = true, PAD4 = true,
  PADDUP = true, PADDDOWN = true, PADDLEFT = true, PADDRIGHT = true,
}
local RESERVED_LABEL = { "Act", "Insp", "Back", "Jump" }
local RESERVED_DEFAULT = { dynamic = "PAD3", inspect = "PAD4", back = "PAD2", jump = "PAD1" }
local TARGET_ALIASES = {
  wheel = "wheel",
  wheelnext = "wheelNext", wheelprev = "wheelPrev",
  dynamic = "dynamic", inspect = "inspect", back = "back", jump = "jump",
}

local function targetLabel(target)
  return type(target) == "number" and ("button " .. target) or TARGETS[target][3]
end

-- The bar labels (LT, RT ...) and the game-button names are controller things: shown
-- only while the controller binds are the live set, hidden in keyboard mode.
local function updateLabels()
  local mode = effectiveMode()
  local pad = (mode == "controller" or mode == "both")
  for _, list in ipairs(sideTexts) do
    for _, text in ipairs(list) do text:SetShown(pad and db.helper and true or false) end
  end
  for _, slot in ipairs(reservedSlots) do
    if slot.Label then slot.Label:SetShown(pad) end
  end
end

-- In keyboard mode the bars and the toolbar are hidden (the game's own action bars
-- are in use); /fcb hidekb off keeps them. /fcb hide hides them in any mode.
local function updatePanels()
  if not container or InCombatLockdown() then
    if container then pendingBindings = true end
    return
  end
  local mode = effectiveMode()
  local pad = (mode == "controller" or mode == "both")
  local show = not manualHidden and (pad or not db.hideInKeyboard)
  container:SetShown(show)
  for _, gf in ipairs(groupFrames) do gf:SetShown(show) end
end

-- Act, Insp, Back and Jump show the icons the game's own bar draws for them. They are
-- copied from the game's buttons (the dynamic one changes with what you point at, the
-- inspect one becomes the raid marker), with the same pictures as a fallback.
local SPECIAL_FALLBACK = {
  { texture = "Interface\\Cursor\\Interact" },
  { atlas = "crosshair_inspect_32" },
  { atlas = "128-redbutton-exit" },
  { atlas = "gamepad-ability-icon-jump" },
}

local function nativeSpecialIcon(k)
  local ok, icon = pcall(function()
    local frame = _G.GamepadMainActionBarFrame
    local unit = frame and type(frame.PageUnit) == "table" and frame.PageUnit or nil
    local bars = unit and type(unit.actionBars) == "table" and unit.actionBars or nil
    local right = bars and type(bars.topBar) == "table" and bars.topBar.Right or nil
    local button = right and right["ActionButton" .. k]
    return button and button.SpecialActionIcon
  end)
  return ok and icon or nil
end

-- What the game's button shows now, as something we can compare and copy.
local function readSpecial(k)
  local source = nativeSpecialIcon(k)
  if source and source:IsShown() then
    local atlas = source:GetAtlas()
    if atlas then return { key = atlas, atlas = atlas } end
    local texture = source:GetTexture()
    if texture then
      local coords = { source:GetTexCoord() }
      return { key = tostring(texture) .. ":" .. table.concat(coords, ","), texture = texture, coords = coords }
    end
  end
  local fallback = SPECIAL_FALLBACK[k]
  return { key = fallback.atlas or fallback.texture, atlas = fallback.atlas, texture = fallback.texture }
end

local specialKey = {} -- the picture each slot has now, so an unchanged one is not set again

local function updateSpecialIcon(k)
  local slot = reservedSlots[k]
  if not (slot and slot.Art and db) then return end
  local mode = effectiveMode()
  local pad = (mode == "controller" or mode == "both")
  local ok, picture = pcall(readSpecial, k)
  if ok and specialKey[k] ~= picture.key then
    specialKey[k] = picture.key
    if picture.atlas then
      slot.Art:SetAtlas(picture.atlas)
    else
      slot.Art:SetTexture(picture.texture)
      if picture.coords then slot.Art:SetTexCoord(unpack(picture.coords)) else slot.Art:SetTexCoord(0, 1, 0, 1) end
    end
  elseif not ok then
    specialKey[k] = nil
  end
  slot.Art:SetShown(ok)
  slot.Label:SetShown(pad and not ok) -- the name stands in when no icon could be had
end

updateSpecialIcons = function()
  for k = 1, #reservedSlots do updateSpecialIcon(k) end
end

-- No polling: the game redraws these two when something changes (a new soft target,
-- target, combat, equipment...), so a hook on its own update functions follows it.
-- The inspect one changes with the target and raid markers, which we hear about as events.
local specialHooked = false

local function hookSpecialIcons()
  if specialHooked then return end
  local frame = _G.GamepadMainActionBarFrame
  if type(frame) ~= "table" then return end
  local ok = pcall(function()
    if type(frame.UpdateInteractIcons) ~= "function" then error("not ready") end
    hooksecurefunc(frame, "UpdateInteractIcons", function() updateSpecialIcon(1) end)
    if type(frame.UpdateBackIcons) == "function" then
      hooksecurefunc(frame, "UpdateBackIcons", function() updateSpecialIcon(3) end)
    end
  end)
  if ok then specialHooked = true end
end

local function applyBindings()
  updateLabels()
  updateSpecialIcons()
  if InCombatLockdown() then
    pendingBindings = true
    return
  end
  pendingBindings = false
  updatePanels()
  ClearOverrideBindings(bindOwner)
  local mode = effectiveMode()
  -- The controller binds are the D-pad, face buttons and triggers: while a bag or
  -- vendor window (BagPad Forever restyles the game's own bag windows) uses them to
  -- move around, ours would take them, so they step aside until it closes.
  local padLive = (mode == "controller" or mode == "both") and not yielding
  for i = 1, NUM_BUTTONS do
    local name = "FlatCrossbarButton" .. i
    if mode == "keyboard" or mode == "both" then
      if db.kb[i] then SetOverrideBindingClick(bindOwner, true, db.kb[i], name, "LeftButton") end
    end
    if padLive then
      if db.pad[i] then SetOverrideBindingClick(bindOwner, true, db.pad[i], name, "LeftButton") end
    end
  end
  for name, t in pairs(TARGETS) do
    if (mode == "keyboard" or mode == "both") and not t[4] then
      if db.kb[name] then SetOverrideBindingClick(bindOwner, true, db.kb[name], t[1], t[2]) end
    end
    if padLive and db.pad[name] then
      if t[5] then
        SetOverrideBinding(bindOwner, true, db.pad[name], t[5])
      else
        SetOverrideBindingClick(bindOwner, true, db.pad[name], t[1], t[2])
      end
    end
  end
  local padShown = (mode == "controller" or mode == "both")
  for i = 1, NUM_BUTTONS do
    if buttons[i] then
      buttons[i].HotKey:SetText(hotkeyText(i))
      local shown = padBase(db.pad[i]) or (i <= MAIN_BUTTONS and SLOT_PAD[BUTTON_SLOT[i]]) or nil
      setGlyph(buttons[i], padShown and shown or nil)
    end
  end
  for k, slot in ipairs(reservedSlots) do
    local target = RESERVED_TARGETS[k]
    setGlyph(slot, padShown and (padBase(db.pad[target]) or RESERVED_DEFAULT[target]) or nil)
  end
  if modeButton then modeButton:SetText(MODE_LABEL[db.mode]) end

  layoutToolbar()
  if relayout then relayout() end -- the gap in each bar follows the keybind set
  if wheelDpad and wheel and wheel:IsShown() then
    SetOverrideBindingClick(bindOwner, true, "PADDLEFT", "FlatCrossbarButton1", "LeftButton")
    SetOverrideBindingClick(bindOwner, true, "PADDRIGHT", "FlatCrossbarButton3", "LeftButton")
  end
end

local function setMode(mode)
  db.mode = mode
  applyBindings()
  print_("keybinds: " .. MODE_LABEL[mode] .. (mode == "auto" and (" (now " .. MODE_LABEL[effectiveMode()] .. ")") or ""))
end

-- Bound to a key in the Key Bindings screen, and to the header button.
function FlatCrossbar_ToggleMode()
  if not db then return end
  setMode(effectiveMode() == "controller" and "keyboard" or "controller")
end

-- Button display --------------------------------------------------------------

-- Cooldowns. In combat the game can hand back cooldown numbers as secret values, which
-- code like this cannot pass to SetCooldown, and the call does not even complain: the
-- swipe just never appears. What does work, and what other bar addons (EllesmereUI)
-- do, is to read the one flag that is never secret (isActive) and hand the cooldown
-- frame a duration object, which carries the timing without exposing it. The plain call
-- is kept for when the game does not offer duration objects.
local cooldownError
local cooldownPath = "none"

local function clearCooldown(cooldown)
  if not pcall(cooldown.Clear, cooldown) then pcall(cooldown.SetCooldown, cooldown, 0, 0) end
end

local function durationCooldown(btn, action)
  local api = C_ActionBar
  if not (api.GetActionCooldownDuration and btn.cooldown.SetCooldownFromDurationObject) then return false end
  local cooldown = api.GetActionCooldown(action)
  local charges = api.GetActionCharges and api.GetActionCharges(action)
  local loc = api.GetActionLossOfControlCooldownInfo and api.GetActionLossOfControlCooldownInfo(action)
  local locActive = loc and loc.isActive and api.GetActionLossOfControlCooldownDuration ~= nil
  local replace = locActive and loc.shouldReplaceNormalCooldown
  if issecretvalue and issecretvalue(replace) then replace = false end

  if locActive then
    btn.locCooldown:SetCooldownFromDurationObject(api.GetActionLossOfControlCooldownDuration(action))
  else
    clearCooldown(btn.locCooldown)
  end
  if charges and charges.isActive and not replace and api.GetActionChargeDuration then
    btn.chargeCooldown:SetCooldownFromDurationObject(api.GetActionChargeDuration(action))
  else
    clearCooldown(btn.chargeCooldown)
  end
  if cooldown and cooldown.isActive and not replace then
    btn.cooldown:SetCooldownFromDurationObject(api.GetActionCooldownDuration(action))
  else
    clearCooldown(btn.cooldown)
  end
  return true
end

local function plainCooldown(btn, action)
  if ActionButton_ApplyCooldown and C_ActionBar.GetActionCharges and C_ActionBar.GetActionLossOfControlCooldownInfo then
    ActionButton_ApplyCooldown(btn.cooldown, C_ActionBar.GetActionCooldown(action),
      btn.chargeCooldown, C_ActionBar.GetActionCharges(action),
      btn.locCooldown, C_ActionBar.GetActionLossOfControlCooldownInfo(action))
  else
    local info = C_ActionBar.GetActionCooldown(action)
    if info and info.isActive then
      btn.cooldown:SetCooldown(info.startTime, info.duration, info.modRate)
    else
      clearCooldown(btn.cooldown)
    end
  end
end

local function updateCooldown(btn, action)
  local ok, done = pcall(durationCooldown, btn, action)
  if ok and done then
    cooldownPath = "duration objects"
    return
  end
  if not ok and not cooldownError then
    cooldownError = tostring(done)
    print_("cooldowns: the duration-object call failed (" .. cooldownError .. "); using the plain one.")
  end
  local plainOk, err = pcall(plainCooldown, btn, action)
  if plainOk then
    cooldownPath = "plain call"
  else
    if not cooldownError then cooldownError = tostring(err) end
    clearCooldown(btn.cooldown)
  end
end

local function updateButton(btn, actionOverride)
  local action
  if actionOverride == nil then
    action = btn:GetAttribute("action")
  else
    action = actionOverride or nil
  end
  if not action then
    btn.icon:Hide()
    btn.Count:SetText("")
    btn.checked:Hide()
    clearCooldown(btn.cooldown)
    return
  end

  if C_ActionBar.HasAction(action) then
    btn.icon:SetTexture(C_ActionBar.GetActionTexture(action))
    btn.icon:Show()
    btn.Count:SetText(C_ActionBar.GetActionDisplayCount(action, 99) or "")
    btn.checked:SetShown((C_ActionBar.IsCurrentAction(action) or C_ActionBar.IsAutoRepeatAction(action)) and true or false)
    updateCooldown(btn, action)

    local usable, lacking = C_ActionBar.IsUsableAction(action)
    if rangeState[action] == false then
      btn.icon:SetVertexColor(0.8, 0.1, 0.1)
    elseif usable then
      btn.icon:SetVertexColor(ICON_DIM, ICON_DIM, ICON_DIM)
    elseif lacking then
      btn.icon:SetVertexColor(0.3, 0.3, 1)
    else
      btn.icon:SetVertexColor(0.4, 0.4, 0.4)
    end
  else
    btn.icon:Hide()
    btn.Count:SetText("")
    btn.checked:Hide()
    clearCooldown(btn.cooldown)
  end
end

local updateWheel

local function updateAll()
  for i = 1, NUM_BUTTONS do
    if buttons[i] then updateButton(buttons[i]) end
  end
  if updateWheel then updateWheel() end
end

local cooldownRefreshPending = false

local function refreshCooldowns()
  for i = 1, NUM_BUTTONS do
    local btn = buttons[i]
    local action = btn and btn:GetAttribute("action")
    if action and C_ActionBar.HasAction(action) then updateCooldown(btn, action) end
  end
end

local function scheduleCooldownRefresh()
  if cooldownRefreshPending or not (C_Timer and C_Timer.After) then return end
  cooldownRefreshPending = true
  C_Timer.After(0.1, function()
    cooldownRefreshPending = false
    refreshCooldowns()
  end)
end

local function enableRangeChecks()
  if not C_ActionBar.EnableActionRangeCheck then return end
  for i = 1, NUM_BUTTONS do
    local action = buttons[i] and buttons[i]:GetAttribute("action")
    if action then C_ActionBar.EnableActionRangeCheck(action, true) end
  end
end

-- Actions ---------------------------------------------------------------------

-- Points each button at its crossbar storage slot. Out of combat only: a secure
-- button's action can't change in combat.
local function applyActions()
  if InCombatLockdown() then
    pendingActions = true
    return
  end
  pendingActions = false
  for i = 1, NUM_BUTTONS do
    buttons[i]:SetAttribute("action", storageSlot(BUTTON_PAGE[i], PAGE_UNIT_SLOT_IDS[i]))
  end
  enableRangeChecks()
  updateAll()
end

-- Frames ----------------------------------------------------------------------

local function addBorder(frame, r, g, b, a)
  local edges = {}
  for _, e in ipairs({ "TOP", "BOTTOM", "LEFT", "RIGHT" }) do
    local t = frame:CreateTexture(nil, "BORDER")
    t:SetColorTexture(r, g, b, a)
    edges[e] = t
  end
  edges.TOP:SetPoint("TOPLEFT"); edges.TOP:SetPoint("TOPRIGHT"); edges.TOP:SetHeight(1)
  edges.BOTTOM:SetPoint("BOTTOMLEFT"); edges.BOTTOM:SetPoint("BOTTOMRIGHT"); edges.BOTTOM:SetHeight(1)
  edges.LEFT:SetPoint("TOPLEFT"); edges.LEFT:SetPoint("BOTTOMLEFT"); edges.LEFT:SetWidth(1)
  edges.RIGHT:SetPoint("TOPRIGHT"); edges.RIGHT:SetPoint("BOTTOMRIGHT"); edges.RIGHT:SetWidth(1)
end

local function makeCooldown(parent, swipe, edge)
  local cd = CreateFrame("Cooldown", nil, parent, "CooldownFrameTemplate")
  cd:SetAllPoints()
  cd:SetDrawSwipe(swipe)
  cd:SetDrawEdge(edge)
  return cd
end

local function createButton(i)
  local btn = CreateFrame("Button", "FlatCrossbarButton" .. i, groupFrames[BUTTON_GROUP[i]], "SecureActionButtonTemplate")
  btn:SetSize(BUTTON_SIZE, BUTTON_SIZE)
  btn:SetAttribute("type", "action")
  btn:RegisterForClicks("AnyUp", "AnyDown")
  btn:RegisterForDrag("LeftButton")
  btn.index = i

  local bg = btn:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints()
  bg:SetColorTexture(0.04, 0.04, 0.06, 0.85)
  addBorder(btn, 0, 0, 0, 0.9)

  btn.icon = btn:CreateTexture(nil, "ARTWORK")
  btn.icon:SetPoint("TOPLEFT", 1, -1)
  btn.icon:SetPoint("BOTTOMRIGHT", -1, 1)
  btn.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

  btn.cooldown = makeCooldown(btn, true, false)
  btn.chargeCooldown = makeCooldown(btn, false, true)
  btn.locCooldown = makeCooldown(btn, true, false)
  btn.locCooldown:SetSwipeColor(0.17, 0, 0)

  btn.checked = btn:CreateTexture(nil, "OVERLAY")
  btn.checked:SetAllPoints()
  btn.checked:SetTexture("Interface\\Buttons\\CheckButtonHilight")
  btn.checked:SetBlendMode("ADD")
  btn.checked:Hide()

  local hl = btn:CreateTexture(nil, "HIGHLIGHT")
  hl:SetAllPoints()
  hl:SetColorTexture(1, 1, 1, 0.2)

  btn.Count = btn:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
  btn.Count:SetPoint("BOTTOMRIGHT", -2, 2)

  btn.HotKey = btn:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
  btn.HotKey:SetPoint("TOPLEFT", 2, -2)
  btn.HotKey:SetJustifyH("LEFT")
  addGlyph(btn)

  btn:SetScript("OnDragStart", function(self)
    if InCombatLockdown() then return end
    if db.locked and not IsShiftKeyDown() then return end
    local action = self:GetAttribute("action")
    if action then PickupAction(action) end
  end)
  btn:SetScript("OnReceiveDrag", function(self)
    if InCombatLockdown() then return end
    local action = self:GetAttribute("action")
    if action then PlaceAction(action) end
  end)
  -- While the wheel is open (L3 held), the D-pad turns its pages: the button under
  -- the bare D-pad left or right does nothing for that press. The wheel only opens
  -- out of combat, so the button's action can be switched off and back here.
  btn:HookScript("PreClick", function(self, _, down)
    if InCombatLockdown() or not wheelDpad then return end
    local direction = (self.index == 1 and -1) or (self.index == 3 and 1) or nil
    if not direction then return end
    local suppress
    if down then
      suppress = wheel and wheel:IsShown() and true or false
      if suppress then FlatCrossbar_WheelPage(direction) end
      self.wheelPress = suppress
    else
      suppress = self.wheelPress
      self.wheelPress = nil
    end
    if suppress then
      self:SetAttribute("type", nil)
      self.restoreType = true
    end
  end)
  btn:HookScript("PostClick", function(self)
    if not self.restoreType then return end
    if InCombatLockdown() then
      pendingTypes = true
      return
    end
    self.restoreType = nil
    self:SetAttribute("type", "action")
  end)
  btn:HookScript("OnEnter", function(self)
    hoverTarget = self.index
    local action = self:GetAttribute("action")
    if action and not bindCapture:IsShown() and C_ActionBar.HasAction(action) then
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:SetAction(action)
    elseif bindCapture:IsShown() then
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:SetText("Button " .. self.index)
      GameTooltip:AddLine("Press a key or controller button to bind.", 1, 1, 1)
      GameTooltip:AddLine("Backspace clears both sets.", 0.7, 0.7, 0.7)
      GameTooltip:Show()
    end
  end)
  btn:HookScript("OnLeave", function()
    hoverTarget = nil
    GameTooltip:Hide()
  end)
  return btn
end

local GROUP_COLS = 8 -- all eight buttons of a bar in one row
local GROUP_GAP = 10
local MID_GAP = 56 -- the label between the D-pad buttons and the face buttons
local GROUP_FRAME_W = GROUP_COLS * (BUTTON_SIZE + SPACING) - SPACING + MID_GAP
local GROUP_FRAME_H = BUTTON_SIZE
local HANDLE_HEIGHT = 12

-- A scale that lets a row of four bars sit on this screen.
local function fitScale()
  local total = 4 * GROUP_FRAME_W + 3 * GROUP_GAP
  local avail = (UIParent:GetWidth() or total) - 40
  return math.max(0.5, math.min(1, math.floor(avail / total * 20) / 20))
end

-- The four crossbar bars in a row along the bottom and the other four above.
local function groupDefaultPoint(g)
  local step = GROUP_FRAME_W + GROUP_GAP
  local column = (g - 1) % 4 + 1
  return { "BOTTOM", "UIParent", "BOTTOM", (column - 2.5) * step, g <= 4 and 40 or 84 }
end

local function setPoint(frame, p)
  frame:ClearAllPoints()
  frame:SetPoint(p[1], _G[p[2]] or UIParent, p[3], p[4], p[5])
end

local function savePoint(frame)
  local point, _, relPoint, x, y = frame:GetPoint()
  return { point, "UIParent", relPoint, x, y }
end

-- Dragging ---------------------------------------------------------------------

-- A bar is moved by hand rather than with StartMoving, so it can snap to the other
-- bars and the toolbar while it follows the cursor: edge to edge (flush) or lined
-- up with an edge. Hold Ctrl to drag without snapping; /fcb snap off turns it off.
local SNAP_DISTANCE = 14
local SNAP_REACH = 40 -- how far apart two bars can be and still count as neighbours
local drag
local dragDriver = CreateFrame("Frame", "FlatCrossbarDragDriver")
dragDriver:Hide()

local function overlaps(a1, a2, b1, b2)
  return a1 < b2 + SNAP_REACH and a2 > b1 - SNAP_REACH
end

local function snapPosition(frame, left, bottom)
  local width, height = frame:GetWidth(), frame:GetHeight()
  local bestX, bestY, nearX, nearY = nil, nil, SNAP_DISTANCE, SNAP_DISTANCE
  local others = { container }
  for _, gf in ipairs(groupFrames) do others[#others + 1] = gf end
  for _, other in ipairs(others) do
    local oLeft, oBottom = other:GetLeft(), other:GetBottom()
    if other ~= frame and other:IsShown() and oLeft and oBottom then
      local oRight, oTop = oLeft + other:GetWidth(), oBottom + other:GetHeight()
      if overlaps(bottom, bottom + height, oBottom, oTop) then
        -- beside it (flush right, flush left), or the same left or right edge
        for _, target in ipairs({ oRight, oLeft - width, oLeft, oRight - width }) do
          local d = math.abs(left - target)
          if d < nearX then nearX, bestX = d, target end
        end
      end
      if overlaps(left, left + width, oLeft, oRight) then
        -- on top of it, below it, or the same bottom or top edge
        for _, target in ipairs({ oTop, oBottom - height, oBottom, oTop - height }) do
          local d = math.abs(bottom - target)
          if d < nearY then nearY, bestY = d, target end
        end
      end
    end
  end
  return bestX or left, bestY or bottom
end

dragDriver:SetScript("OnUpdate", function()
  if not drag then return end
  local x, y = GetCursorPosition()
  local scale = drag.frame:GetEffectiveScale()
  local left, bottom = x / scale - drag.dx, y / scale - drag.dy
  if db.snap and not IsControlKeyDown() then left, bottom = snapPosition(drag.frame, left, bottom) end
  drag.frame:ClearAllPoints()
  drag.frame:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", left, bottom)
end)

local function beginDrag(frame)
  if InCombatLockdown() or not frame:GetLeft() then return end
  local x, y = GetCursorPosition()
  local scale = frame:GetEffectiveScale()
  drag = { frame = frame, dx = x / scale - frame:GetLeft(), dy = y / scale - frame:GetBottom() }
  dragDriver:Show()
end

-- True if a drag was under way (so the caller saves the new position).
local function endDrag()
  local was = drag ~= nil
  drag = nil
  dragDriver:Hide()
  return was
end

local function restorePosition()
  setPoint(container, db.point)
  for g, gf in ipairs(groupFrames) do
    setPoint(gf, db.groupPoints[g] or groupDefaultPoint(g))
  end
end

-- The gap with the label shows while the controller binds are live, or while unlocked
-- (the label is the drag point). In keyboard mode, locked, the eight buttons sit together.
local function gapOpen()
  local mode = effectiveMode()
  return mode == "controller" or mode == "both" or not db.locked
end

-- Where a bar's slot sits in its row: the D-pad four, the label's gap, the face four.
local function slotX(slot)
  local step = BUTTON_SIZE + SPACING
  return (slot - 1) * step + (slot > 4 and gapOpen() and MID_GAP or 0)
end

local function layout()
  if InCombatLockdown() then
    pendingLayout = true
    return
  end
  pendingLayout = false
  for g, gf in ipairs(groupFrames) do
    gf:SetSize(gapOpen() and GROUP_FRAME_W or GROUP_FRAME_W - MID_GAP, GROUP_FRAME_H)
    gf:SetScale(db.scale)
  end
  for i, btn in ipairs(buttons) do
    btn:ClearAllPoints()
    btn:SetPoint("TOPLEFT", groupFrames[BUTTON_GROUP[i]], "TOPLEFT", slotX(BUTTON_SLOT[i]), 0)
  end
  -- Slots 5-8 of the base bar are the face buttons, kept by the game for jump,
  -- interact and so on, so they are shown empty.
  for k, slot in ipairs(reservedSlots) do
    slot:ClearAllPoints()
    slot:SetPoint("TOPLEFT", groupFrames[1], "TOPLEFT", slotX(4 + k), 0)
  end
  for _, mid in ipairs(groupHandles) do mid:SetShown(gapOpen()) end
  container:SetScale(db.scale)
  layoutToolbar()
  updateLabels()
end
relayout = layout

-- The blue strip above a movable frame, shown while unlocked.
local function makeHandle(frame, text, onMoved, color)
  local h = CreateFrame("Frame", nil, frame)
  h:SetHeight(HANDLE_HEIGHT)
  h:SetPoint("BOTTOMLEFT", frame, "TOPLEFT")
  h:SetPoint("BOTTOMRIGHT", frame, "TOPRIGHT")
  h:EnableMouse(true)
  h:RegisterForDrag("LeftButton")
  local bg = h:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints()
  color = color or { 0.5, 0.5, 0.58 }
  bg:SetColorTexture(color[1] * 0.8, color[2] * 0.8, color[3] * 0.8, 0.9)
  local label = h:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  label:SetPoint("CENTER")
  label:SetText(text)
  h:SetScript("OnDragStart", function() beginDrag(frame) end)
  h:SetScript("OnDragStop", function()
    if endDrag() then onMoved() end
  end)
  return h
end

-- Unlocked: the label in the middle of each bar can be dragged (it lights up) and
-- so can the toolbar's strip. Locked: neither can.
local function applyLock()
  local show = not db.locked
  toolbarHandle:SetShown(show)
  for _, mid in ipairs(groupHandles) do
    mid.bg:SetShown(show)
    mid:EnableMouse(show)
  end
end

local function setBarShown(show)
  if InCombatLockdown() then return print_("can't do that in combat.") end
  manualHidden = not show
  updatePanels()
end

local function makeHeaderButton(text, width)
  local b = CreateFrame("Button", nil, header, "UIPanelButtonTemplate")
  b:SetSize(width, HEADER_HEIGHT)
  b:SetText(text)
  return b
end

-- Packs the toolbar buttons that are showing, left to right. The wheel's two
-- follow the keybind mode; mode, page and bind can be hidden (/fcb hidebuttons).
-- Only called out of combat (the page and wheel buttons are protected).
layoutToolbar = function()
  local mode = effectiveMode()
  local showWheel = (mode == "controller" or mode == "both")
  local utility = not db.hideButtons
  local order = {
    { modeButton, utility },
    { wheelHeaderButton, showWheel }, { wheelPageButton, showWheel },
    { bindButton, utility },
  }
  local prev, width = nil, 0
  for _, entry in ipairs(order) do
    local b, show = entry[1], entry[2]
    -- A binding that clicks a button only finds it while it is shown, so the
    -- buttons are kept shown and made invisible and unclickable instead.
    b:Show()
    b:SetAlpha(show and 1 or 0)
    b:EnableMouse(show and true or false)
    b:ClearAllPoints()
    if show then
      if prev then b:SetPoint("LEFT", prev, "RIGHT", 4, 0) else b:SetPoint("LEFT", container, "LEFT") end
      width = width + b:GetWidth() + (prev and 4 or 0)
      prev = b
    else
      b:SetPoint("LEFT", container, "LEFT")
    end
  end
  container:SetSize(math.max(width, 70), HEADER_HEIGHT)
  if not showWheel and wheel then wheel:Hide() end
end


-- Keybind capture -------------------------------------------------------------

local IGNORED_KEYS = {
  LSHIFT = true, RSHIFT = true, LCTRL = true, RCTRL = true, LALT = true, RALT = true,
  LMETA = true, RMETA = true,
}

local function clearKeyFromSet(set, key)
  for target, k in pairs(set) do
    if k == key then set[target] = nil end
  end
end

local function stopBindMode()
  bindCapture:Hide()
  forcedTarget = nil
  bindButton:SetText("Bind")
  GameTooltip:Hide()
  applyBindings()
end

local function startBindMode()
  if InCombatLockdown() then
    print_("can't change keybinds in combat.")
    return
  end
  bindCapture:Show()
  bindButton:SetText("Done")
  print_("hover a button and press a key or controller button. Esc or Done finishes.")
end

local function onCaptureKey(_, key)
  if key == "ESCAPE" then
    stopBindMode()
    return
  end
  if IGNORED_KEYS[key] then return end
  local target = forcedTarget or hoverTarget
  if not target then return end

  if key == "BACKSPACE" then
    db.kb[target] = nil
    db.pad[target] = nil
    print_("cleared " .. targetLabel(target))
  else
    local full = (IsAltKeyDown() and "ALT-" or "") .. (IsControlKeyDown() and "CTRL-" or "")
      .. (IsShiftKeyDown() and "SHIFT-" or "") .. key
    -- Controller buttons go in the controller set, everything else in the keyboard set.
    local isPad = key:find("^PAD") and true or false
    if isPad and type(target) == "string" and TARGETS[target] and TARGETS[target][5] and MENU_KEYS[padBase(full)] then
      print_("that button is what the game's menus and windows use, so it can't take one of the game's four buttons. Pick a bumper, trigger or stick press.")
      return
    end
    if not isPad and type(target) == "string" and TARGETS[target][4] then
      print_("the wheel is controller-only; press a controller button.")
      return
    end
    local set = isPad and db.pad or db.kb
    clearKeyFromSet(set, full)
    set[target] = full
    print_(targetLabel(target) .. " -> " .. full .. (set == db.pad and " (controller)" or " (keyboard)"))
  end
  applyBindings()
  if forcedTarget then
    forcedTarget = nil
    stopBindMode()
  end
end


-- Wheel -----------------------------------------------------------------------

local wheelSel -- slice being aimed at, or nil

-- The right stick aims the wheel, and it is also the camera stick, so while the wheel
-- is open the pad's camera speeds are set to 0 (the movement stick keeps walking).
-- The speeds the player had are kept in the saved variables meanwhile, so a crash or a
-- logout never leaves the camera still.
local CAMERA_CVARS = { "GamePadCameraYawSpeed", "GamePadCameraPitchSpeed" }
local cameraHeld = false

local function suspendCamera(on)
  if on then
    if cameraHeld then return end
    local saved, any = {}, false
    for _, name in ipairs(CAMERA_CVARS) do
      local ok, value = pcall(GetCVar, name)
      if ok and value ~= nil then saved[name] = tostring(value); any = true end
    end
    if not any then return end
    db.wheelSavedCamera = saved
    for name in pairs(saved) do pcall(SetCVar, name, "0") end
    cameraHeld = true
  elseif cameraHeld or db.wheelSavedCamera then
    for name, value in pairs(db.wheelSavedCamera or {}) do pcall(SetCVar, name, value) end
    db.wheelSavedCamera = nil
    cameraHeld = false
  end
end

-- The wheel's actions are not the crossbar's: they sit on the normal keyboard and
-- mouse action bars (7-10 by default), so the two never share a slot. Action slot
-- ranges per bar, from the pages in Blizzard_ActionBar's MultiActionBars: bar 2 is
-- page 6, 3 is 5, 4 is 3, 5 is 4, then 6, 7 and 8 are pages 13-15; 9 and 10 carry on.
local BAR_PAGE = { [1] = 1, [2] = 6, [3] = 5, [4] = 3, [5] = 4, [6] = 13, [7] = 14, [8] = 15, [9] = 16, [10] = 17 }
local BAR_SIZE = 12
local wheelSlots = {}
local wheelNotice

local function buildWheelSlots()
  wipe(wheelSlots)
  local limit = C_GamepadUI and C_GamepadUI.GetFirstGamepadActionStorageSlotIndex
    and C_GamepadUI.GetFirstGamepadActionStorageSlotIndex()
  local skipped = 0
  for _, bar in ipairs(db.wheelBars) do
    local first = ((BAR_PAGE[bar] or (bar + 7)) - 1) * BAR_SIZE + 1
    for n = 0, BAR_SIZE - 1 do
      local slot = first + n
      -- never touch the crossbar's own storage
      if limit and slot >= limit then
        skipped = skipped + 1
      else
        wheelSlots[#wheelSlots + 1] = slot
      end
    end
  end
  WHEEL_PAGES = math.max(1, math.ceil(#wheelSlots / WHEEL_SLICES))
  db.wheelPage = math.max(1, math.min(WHEEL_PAGES, db.wheelPage))
  wheelNotice = skipped > 0
    and ("the wheel skips " .. skipped .. " slots that are the crossbar's own storage (it starts at slot " .. tostring(limit)
      .. "); pick other bars with /fcb wheelbars.") or nil
end

local function wheelSlot(slice)
  return wheelSlots[(db.wheelPage - 1) * WHEEL_SLICES + slice]
end

updateWheel = function()
  if not (wheel and wheel:IsShown()) then return end
  wheel.pageText:SetText(db.wheelPage .. "/" .. WHEEL_PAGES)
  for i, sl in ipairs(slices) do
    local action = wheelSlot(i)
    updateButton(sl, action or false)
    sl:SetAlpha(action and 1 or 0.35)
    sl.selected:SetShown(wheelSel == i)
  end
end

-- Aiming copies the slice's action onto the wheel button, so that releasing
-- the key (a click on it) uses that action. Attributes on a secure button
-- can't change in combat, which is why the wheel doesn't open then.
local function setWheelSelection(slice)
  if InCombatLockdown() then return end
  if slice and not wheelSlot(slice) then slice = nil end
  wheelSel = slice
  local action = slice and wheelSlot(slice)
  if action then
    wheelHeaderButton:SetAttribute("type", "action")
    wheelHeaderButton:SetAttribute("action", action)
  else
    wheelHeaderButton:SetAttribute("type", nil)
  end
  updateWheel()
end

-- The right stick, as the game reports it. Which entry is the right stick isn't
-- documented, so this takes the second one (the usual order is left, right).
local cameraStick
local function readStick()
  if not (C_GamePad and C_GamePad.GetActiveDeviceID and C_GamePad.GetDeviceMappedState) then return end
  local id = C_GamePad.GetActiveDeviceID()
  local state = id and C_GamePad.GetDeviceMappedState(id)
  if state and not cameraStick then
    for index = 1, tonumber(state.stickCount) or 0 do
      local ok, name = pcall(C_GamePad.StickIndexToConfigName, index - 1)
      if ok and name == "Camera" then cameraStick = index end
    end
  end
  local stick = state and state.sticks and state.sticks[cameraStick or 2]
  if stick then return stick.x, stick.y, stick.len end
end

local stickWasActive = false
local function aimWithStick()
  local x, y, len = readStick()
  if not x then return end
  local sliceSize = (2 * math.pi) / WHEEL_SLICES
  if (len or math.sqrt(x * x + y * y)) >= STICK_DEADZONE then
    -- Same maths as Blizzard's flyout radial: swapping x and y puts 0 at the top.
    local angle = (math.atan2(x, y) + sliceSize / 2) % (2 * math.pi)
    local slice = math.floor(angle / sliceSize) + 1
    stickWasActive = true
    if slice ~= wheelSel then setWheelSelection(slice) end
  elseif stickWasActive then
    -- Stick back in the middle cancels the selection.
    stickWasActive = false
    if wheelSel then setWheelSelection(nil) end
  end
end

local function setWheelPage(page)
  if InCombatLockdown() then return end
  db.wheelPage = ((page - 1) % WHEEL_PAGES) + 1
  wheelPageButton:SetText("W" .. db.wheelPage)
  setWheelSelection(nil)
  updateWheel()
end

local function createSlice(i)
  local sl = CreateFrame("Frame", nil, wheel)
  sl:SetSize(WHEEL_SLICE_SIZE, WHEEL_SLICE_SIZE)
  local angle = (i - 1) * (2 * math.pi / WHEEL_SLICES)
  sl:SetPoint("CENTER", wheel, "CENTER", WHEEL_RADIUS * math.sin(angle), WHEEL_RADIUS * math.cos(angle))
  sl:EnableMouse(true)
  sl:SetScript("OnEnter", function() setWheelSelection(i) end)
  sl:SetScript("OnLeave", function()
    if wheelSel == i then setWheelSelection(nil) end
  end)

  local bg = sl:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints()
  bg:SetColorTexture(0, 0, 0, 0.7)
  addBorder(sl, 0.45, 0.45, 0.45, 1)

  sl.icon = sl:CreateTexture(nil, "ARTWORK")
  sl.icon:SetPoint("TOPLEFT", 2, -2)
  sl.icon:SetPoint("BOTTOMRIGHT", -2, 2)
  sl.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

  sl.cooldown = makeCooldown(sl, true, false)
  sl.chargeCooldown = makeCooldown(sl, false, true)
  sl.locCooldown = makeCooldown(sl, true, false)
  sl.locCooldown:SetSwipeColor(0.17, 0, 0)

  sl.checked = sl:CreateTexture(nil, "OVERLAY")
  sl.checked:SetAllPoints()
  sl.checked:SetTexture("Interface\\Buttons\\CheckButtonHilight")
  sl.checked:SetBlendMode("ADD")
  sl.checked:Hide()

  sl.selected = sl:CreateTexture(nil, "OVERLAY", nil, 2)
  sl.selected:SetPoint("TOPLEFT", -4, 4)
  sl.selected:SetPoint("BOTTOMRIGHT", 4, -4)
  sl.selected:SetColorTexture(1, 0.82, 0, 0.45)
  sl.selected:Hide()

  sl.Count = sl:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
  sl.Count:SetPoint("BOTTOMRIGHT", -2, 2)
  return sl
end

local function createWheel()
  wheel = CreateFrame("Frame", "FlatCrossbarWheel", UIParent)
  wheel:SetSize(WHEEL_RADIUS * 2 + WHEEL_SLICE_SIZE, WHEEL_RADIUS * 2 + WHEEL_SLICE_SIZE)
  wheel:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
  wheel:SetFrameStrata("DIALOG")
  wheel:SetScale(db.wheelScale)
  wheel:Hide()

  local disc = wheel:CreateTexture(nil, "BACKGROUND")
  disc:SetPoint("CENTER")
  disc:SetSize(WHEEL_RADIUS * 2 + WHEEL_SLICE_SIZE, WHEEL_RADIUS * 2 + WHEEL_SLICE_SIZE)
  disc:SetColorTexture(0, 0, 0, 0.35)
  local mask = wheel:CreateMaskTexture()
  mask:SetAllPoints(disc)
  mask:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
  disc:AddMaskTexture(mask)

  wheel.pageText = wheel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  wheel.pageText:SetPoint("CENTER")

  for i = 1, WHEEL_SLICES do
    slices[i] = createSlice(i)
    -- Drop an action on a slice to put it on that action bar slot; drag one off
    -- (hold Shift when locked) to pick it up.
    slices[i]:RegisterForDrag("LeftButton")
    slices[i]:SetScript("OnDragStart", function()
      local slot = wheelSlot(i)
      if slot and not InCombatLockdown() and (not db.locked or IsShiftKeyDown()) then
        PickupAction(slot)
        updateWheel()
      end
    end)
    slices[i]:SetScript("OnReceiveDrag", function()
      local slot = wheelSlot(i)
      if slot and not InCombatLockdown() then
        PlaceAction(slot)
        updateWheel()
      end
    end)
  end

  -- While the wheel is open the D-pad's left and right go to the buttons under
  -- them (the base bar's first and third), which turn a wheel page instead of acting.
  wheel:SetScript("OnShow", function()
    updateAll()
    suspendCamera(true)
    if not InCombatLockdown() then
      wheelDpad = true
      SetOverrideBindingClick(bindOwner, true, "PADDLEFT", "FlatCrossbarButton1", "LeftButton")
      SetOverrideBindingClick(bindOwner, true, "PADDRIGHT", "FlatCrossbarButton3", "LeftButton")
    end
  end)
  wheel:SetScript("OnHide", function()
    stickWasActive = false
    wheelSel = nil
    suspendCamera(false)
    if wheelDpad then
      wheelDpad = false
      applyBindings() -- puts the D-pad back (after combat, if it is in combat now)
    end
  end)
  wheel:SetScript("OnUpdate", aimWithStick)

  -- The wheel's key: press opens the wheel, release clicks the action that
  -- aiming copied onto this button (the click runs after PreClick, before
  -- PostClick). useOnKeyDown=false keeps the secure click for the release.
  wheelHeaderButton:RegisterForClicks("AnyDown", "AnyUp")
  wheelHeaderButton:SetAttribute("useOnKeyDown", false)
  wheelHeaderButton:HookScript("PreClick", function(_, _, down)
    if down then
      if not InCombatLockdown() then
        wheelSel = nil
        wheel:Show()
      end
    else
      wheel:Hide() -- OnHide clears wheelSel but leaves the copied attributes for the click
    end
  end)
  wheelHeaderButton:HookScript("PostClick", function(_, _, down)
    if not down and not InCombatLockdown() then
      wheelHeaderButton:SetAttribute("type", nil)
    end
  end)

  wheelPageButton:SetScript("OnClick", function(_, mouse)
    setWheelPage(db.wheelPage + (mouse == "RightButton" and -1 or 1))
  end)
end

local function createFrames()
  container = CreateFrame("Frame", "FlatCrossbarFrame", UIParent)
  container:SetMovable(true)
  container:SetClampedToScreen(true)
  container:SetFrameStrata("MEDIUM")

  container:SetSize(70, HEADER_HEIGHT)
  header = container
  toolbarHandle = makeHandle(container, "FlatCrossbar", function() db.point = savePoint(container) end)

  modeButton = makeHeaderButton("", 62)
  modeButton:SetPoint("LEFT")
  modeButton:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  modeButton:SetScript("OnClick", function(_, mouse)
    if mouse == "RightButton" then
      local nextIndex = 1
      for i, m in ipairs(MODES) do
        if m == db.mode then nextIndex = i % #MODES + 1 end
      end
      setMode(MODES[nextIndex])
    else
      FlatCrossbar_ToggleMode()
    end
  end)
  modeButton:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText("Keybind set: " .. MODE_LABEL[db.mode])
    GameTooltip:AddLine("Left-click: switch keyboard / controller", 1, 1, 1)
    GameTooltip:AddLine("Right-click: cycle auto, KB, PAD, KB+PAD", 1, 1, 1)
    GameTooltip:Show()
  end)
  modeButton:SetScript("OnLeave", function() GameTooltip:Hide() end)

  wheelHeaderButton = CreateFrame("Button", "FlatCrossbarWheelButton", container, "SecureActionButtonTemplate,UIPanelButtonTemplate")
  wheelHeaderButton:SetSize(52, HEADER_HEIGHT)
  wheelHeaderButton:SetText("Wheel")
  wheelHeaderButton:SetPoint("LEFT", modeButton, "RIGHT", 4, 0)

  wheelPageButton = CreateFrame("Button", "FlatCrossbarWheelPageButton", container, "UIPanelButtonTemplate")
  wheelPageButton:SetSize(36, HEADER_HEIGHT)
  wheelPageButton:SetPoint("LEFT", wheelHeaderButton, "RIGHT", 4, 0)
  wheelPageButton:SetText("W" .. db.wheelPage)
  wheelPageButton:RegisterForClicks("LeftButtonUp", "RightButtonUp")

  -- In bind mode, hovering one of these makes it the thing the next key binds.
  local function bindTarget(frame, target, tooltip)
    frame:HookScript("OnEnter", function(self)
      hoverTarget = target
      if tooltip then
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText(tooltip[1])
        GameTooltip:AddLine(tooltip[2], 1, 1, 1)
        GameTooltip:Show()
      end
    end)
    frame:HookScript("OnLeave", function()
      hoverTarget = nil
      GameTooltip:Hide()
    end)
  end
  bindTarget(wheelHeaderButton, "wheel", { "Wheel", "Controller only. Bind a controller button to hold: aim, then release to use." })
  bindTarget(wheelPageButton, "wheelNext", { "Wheel page", "Left-click: next. Right-click: previous. Not in combat." })

  bindButton = makeHeaderButton("Bind", 44)
  bindButton:SetPoint("LEFT", wheelPageButton, "RIGHT", 4, 0)
  bindButton:SetScript("OnClick", function()
    if bindCapture:IsShown() then stopBindMode() else startBindMode() end
  end)

  bindCapture = CreateFrame("Frame", nil, UIParent)
  bindCapture:SetSize(1, 1)
  bindCapture:SetPoint("CENTER")
  bindCapture:EnableKeyboard(true)
  if bindCapture.EnableGamePadButton then bindCapture:EnableGamePadButton(true) end
  bindCapture:SetPropagateKeyboardInput(false)
  bindCapture:SetScript("OnKeyDown", onCaptureKey)
  bindCapture:SetScript("OnGamePadButtonDown", onCaptureKey)
  bindCapture:Hide()

  for g, name in ipairs(GROUP_LABEL) do
    local gf = CreateFrame("Frame", "FlatCrossbarGroup" .. g, UIParent)
    gf:SetMovable(true)
    gf:SetClampedToScreen(true)
    gf:SetFrameStrata("MEDIUM")
    gf:SetSize(GROUP_FRAME_W, GROUP_FRAME_H)
    groupFrames[g] = gf

    -- The label between the D-pad buttons and the face buttons says what to hold,
    -- and is what you drag to move the bar (while unlocked).
    local mid = CreateFrame("Frame", "FlatCrossbarGroup" .. g .. "Label", gf)
    mid:SetSize(MID_GAP, BUTTON_SIZE)
    mid:SetPoint("TOPLEFT", gf, "TOPLEFT", slotX(4) + BUTTON_SIZE + SPACING, 0)
    mid:RegisterForDrag("LeftButton")
    mid.bg = mid:CreateTexture(nil, "BACKGROUND")
    mid.bg:SetAllPoints()
    mid.bg:SetColorTexture(1, 1, 1, 0.12)
    local title = mid:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("CENTER")
    title:SetText(colorCode(GROUP_COLOR[g]) .. name .. "|r")
    mid:SetScript("OnDragStart", function()
      if db.locked then return end
      beginDrag(gf)
    end)
    mid:SetScript("OnDragStop", function()
      if endDrag() then db.groupPoints[g] = savePoint(gf) end
    end)
    mid:SetScript("OnEnter", function(self)
      if db.locked then return end
      GameTooltip:SetOwner(self, "ANCHOR_TOP")
      GameTooltip:SetText(name)
      GameTooltip:AddLine("Drag to move this bar; it snaps to the others (hold Ctrl for no snap). /fcb lock to stop.", 1, 1, 1)
      GameTooltip:Show()
    end)
    mid:SetScript("OnLeave", function() GameTooltip:Hide() end)
    groupHandles[g] = mid
    mid.title = title
    sideTexts[g] = { title }
  end
  for k = 1, 4 do
    local slot = CreateFrame("Frame", "FlatCrossbarReserved" .. k, groupFrames[1])
    slot:SetSize(BUTTON_SIZE, BUTTON_SIZE)
    local bg = slot:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0, 0, 0, 0.25)
    addBorder(slot, 0, 0, 0, 0.9)
    slot.Label = slot:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    slot.Label:SetPoint("BOTTOM", 0, 2)
    slot.Label:SetText(RESERVED_LABEL[k])
    addGlyph(slot)
    -- The game's icon fills the slot; the button's icon moves to a corner.
    slot.Art = slot:CreateTexture(nil, "ARTWORK")
    slot.Art:SetPoint("TOPLEFT", 3, -3)
    slot.Art:SetPoint("BOTTOMRIGHT", -3, 3)
    slot.Glyph:ClearAllPoints()
    slot.Glyph:SetPoint("BOTTOMRIGHT", -1, 1)
    slot.Glyph:SetSize(14, 14)
    slot.GlyphText:ClearAllPoints()
    slot.GlyphText:SetPoint("BOTTOMRIGHT", -2, 1)
    slot:EnableMouse(true)
    slot:SetScript("OnEnter", function(self)
      hoverTarget = RESERVED_TARGETS[k]
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:SetText(TARGETS[RESERVED_TARGETS[k]][3])
      GameTooltip:AddLine("The game's own button. Bind with /fcb bind (hover, press a controller button).", 1, 1, 1)
      GameTooltip:Show()
    end)
    slot:SetScript("OnLeave", function()
      hoverTarget = nil
      GameTooltip:Hide()
    end)
    reservedSlots[k] = slot
  end
  for i = 1, NUM_BUTTONS do
    buttons[i] = createButton(i)
  end
  createWheel()
end

-- Bound in the Key Bindings screen: plain Lua, so it works whatever is shown.
function FlatCrossbar_WheelPage(delta)
  if not db or not container or InCombatLockdown() then return end
  local mode = effectiveMode()
  if mode ~= "controller" and mode ~= "both" then return end
  setWheelPage(db.wheelPage + delta)
end

-- Blizzard crossbar -----------------------------------------------------------

local hookedTracker

-- Holding LB makes the game show its page tracker (GamepadMainActionBarFrame.PageUnit.
-- PageTracker); keep that hidden along with the crossbar.
local function applyBlizzardVisibility()
  local frame = _G.GamepadMainActionBarFrame
  if not frame then return end
  frame:SetAlpha(db.hideBlizzard and 0 or 1)
  local unit = type(frame.PageUnit) == "table" and frame.PageUnit or nil
  local tracker = unit and type(unit.PageTracker) == "table" and unit.PageTracker or nil
  if not tracker then return end
  if hookedTracker ~= tracker then
    hookedTracker = tracker
    tracker:HookScript("OnShow", function(self)
      if db and db.hideBlizzard then self:Hide() end
    end)
  end
  if db.hideBlizzard then tracker:Hide() end
end

-- Events ----------------------------------------------------------------------

local function copyDefaults(target, defaults)
  for k, v in pairs(defaults) do
    if target[k] == nil then
      if type(v) == "table" then
        target[k] = {}
        copyDefaults(target[k], v)
      else
        target[k] = v
      end
    end
  end
end

-- Controller defaults. The four crossbar bars and the game's own four buttons are
-- pressed by the game's own crossbar, which reads LT and RT itself and keeps working
-- (hidden) underneath these bars, so they get no bind here unless you set one. The
-- other four bars are bound under Alt and the wheel on L3. Only for a fresh set.
local function seedReservedDefaults()
  for target in pairs(RESERVED_DEFAULT) do db.pad[target] = nil end
end

local function seedPadDefaults(from)
  if not from then
    seedReservedDefaults()
    db.pad.wheel = "PADLSTICK" -- L3, pressed in
  end
  for i = from or 1, NUM_BUTTONS do
    if i <= MAIN_BUTTONS then
      db.pad[i] = nil
    else
      db.pad[i] = GROUP_PREFIX[BUTTON_GROUP[i]] .. SLOT_PAD[BUTTON_SLOT[i]]
    end
  end
end

-- Tab-target macros ------------------------------------------------------------

-- Made on login when missing, so they can be dragged from the macro window
-- (/macro) onto the bars.
local MACROS = {
  { name = "FCB Tab Enemy", body = "/targetenemy" },
  { name = "FCB Tab Friend", body = "/targetfriendplayer" },
}
local MACRO_ICON = 134400 -- the question mark; change it in the macro window

local function ensureMacros()
  if InCombatLockdown() or not (CreateMacro and GetMacroIndexByName) then return end
  local made = {}
  for _, m in ipairs(MACROS) do
    if GetMacroIndexByName(m.name) == 0 then
      local ok, index = pcall(CreateMacro, m.name, MACRO_ICON, m.body, false)
      if ok and index then made[#made + 1] = m.name end
    end
  end
  if #made > 0 then
    print_("made macro " .. table.concat(made, ", ") .. ". Open /macro and drag them onto a button.")
  end
end

-- Windows that use the controller's own buttons ----------------------------------

local YIELD_FRAMES = {
  "ContainerFrameCombinedBags", "BankFrame", "MerchantFrame", "MailFrame", "TradeFrame",
  "GameMenuFrame", "SettingsPanel", "CharacterFrame", "SpellBookFrame", "PlayerSpellsFrame",
  "WorldMapFrame", "GossipFrame", "QuestFrame", "FriendsFrame", "CommunitiesFrame",
  "AchievementFrame", "EncounterJournal", "CollectionsJournal", "PVEFrame", "ProfessionsFrame",
  "AuctionHouseFrame",
}
for i = 1, 13 do YIELD_FRAMES[#YIELD_FRAMES + 1] = "ContainerFrame" .. i end

local function frameShown(name)
  local frame = _G[name]
  return frame and frame.IsShown and frame:IsShown() and true or false
end

-- Windows from other addons whose frame names are not known (ForeverMail replaces the
-- mailbox with its own): any large top-level frame whose name starts with one of these
-- counts as a window. /fcb yield add Name* adds a prefix of your own.
local YIELD_PREFIXES = { "ForeverMail" }
local prefixFrames, prefixScannedAt = {}, -100

local function scanPrefixFrames()
  local prefixes = {}
  for _, prefix in ipairs(YIELD_PREFIXES) do prefixes[#prefixes + 1] = prefix end
  for _, name in ipairs(db.yieldFrames) do
    if name:sub(-1) == "*" then prefixes[#prefixes + 1] = name:sub(1, -2) end
  end
  wipe(prefixFrames)
  for name, value in pairs(_G) do
    if type(name) == "string" and type(value) == "table" then
      for _, prefix in ipairs(prefixes) do
        if name:sub(1, #prefix) == prefix then
          prefixFrames[#prefixFrames + 1] = value
          break
        end
      end
    end
  end
end

local function prefixWindowShown()
  local now = GetTime()
  if now - prefixScannedAt > 3 then
    prefixScannedAt = now
    scanPrefixFrames()
  end
  for _, frame in ipairs(prefixFrames) do
    local ok, shown = pcall(function()
      return frame:GetParent() == UIParent and frame:IsVisible() and frame:GetWidth() >= 150
    end)
    if ok and shown then return true end
  end
  return false
end

-- The game's gamepad interface focus: while a menu or window has it, the D-pad, A, B and
-- the bumpers belong to that window. Read with care: these are the game's own tables.
local function uiFocused()
  local ok, focused = pcall(function()
    local manager = _G.GamepadMode and rawget(_G.GamepadMode, "FrameControlsManager")
    if not manager then return false end
    return rawget(manager, "isUIFocused") == true
  end)
  return ok and focused or false
end

local function anyYieldFrameShown()
  if not db.yield then return false end
  if uiFocused() then return true end
  for _, name in ipairs(YIELD_FRAMES) do
    if frameShown(name) then return true end
  end
  for _, name in ipairs(db.yieldFrames) do
    if frameShown(name) then return true end
  end
  return prefixWindowShown()
end

-- Key log ----------------------------------------------------------------------

-- /fcb keys: prints every key, controller button and modifier change the game
-- delivers, to see how the triggers and bumpers arrive (as buttons, or as Shift,
-- Ctrl and Alt from Steam Input).
local keyLogger

local function toggleKeyLogger()
  if InCombatLockdown() then return print_("can't start the key log in combat.") end
  if not keyLogger then
    keyLogger = CreateFrame("Frame", "FlatCrossbarKeyLogger", UIParent)
    keyLogger:SetFrameStrata("BACKGROUND") -- behind everything else that listens for keys
    keyLogger:SetSize(1, 1)
    keyLogger:SetPoint("CENTER")
    keyLogger:EnableKeyboard(true)
    if keyLogger.EnableGamePadButton then keyLogger:EnableGamePadButton(true) end
    keyLogger:SetPropagateKeyboardInput(true)
    -- For a press, also what the key is bound to right now (overrides included): that
    -- shows which binding holds a button, ours or another addon's or the game's.
    local function logger(what)
      return function(_, key)
        local action
        if what:find("down") then
          local ok, bound = pcall(GetBindingAction, key, true)
          action = ok and bound ~= nil and bound ~= "" and (" -> " .. tostring(bound)) or " -> (nothing)"
        end
        print_(what .. ": " .. tostring(key) .. (action or ""))
      end
    end
    keyLogger:SetScript("OnKeyDown", logger("key down"))
    keyLogger:SetScript("OnKeyUp", logger("key up"))
    keyLogger:SetScript("OnGamePadButtonDown", logger("pad down"))
    keyLogger:SetScript("OnGamePadButtonUp", logger("pad up"))
    keyLogger:SetScript("OnEvent", function(_, _, key, state)
      print_("modifier: " .. tostring(key) .. " " .. tostring(state))
    end)
    keyLogger:SetScript("OnShow", function(self) self:RegisterEvent("MODIFIER_STATE_CHANGED") end)
    keyLogger:SetScript("OnHide", function(self) self:UnregisterEvent("MODIFIER_STATE_CHANGED") end)
    keyLogger:Hide()
  end
  if keyLogger:IsShown() then
    keyLogger:Hide()
    print_("key log off")
  else
    keyLogger:Show()
    local token = (rawget(keyLogger, "token") or 0) + 1
    keyLogger.token = token
    -- It listens for buttons itself, so it may keep some from other windows: it stops on
    -- its own after 30 seconds.
    if C_Timer and C_Timer.After then
      C_Timer.After(30, function()
        if rawget(keyLogger, "token") == token and keyLogger:IsShown() then
          keyLogger:Hide()
          print_("key log off (30 seconds are up)")
        end
      end)
    end
    print_("key log on for 30 seconds: press the buttons, then /fcb keys again to stop. Turn it off before testing a window: it can take buttons from it.")
  end
end

-- Saved settings ---------------------------------------------------------------

-- How the bars look and behave is the same for every character (FlatCrossbarAccountDB);
-- keybinds, the wheel's page and the like stay per character (FlatCrossbarDB). The rest
-- of the addon reads and writes db as one table; this sends each key to its own home.
local SHARED = {
  point = true, groupPoints = true, scale = true, autoScale = true, layoutVersion = true,
  locked = true, helper = true, hideButtons = true, snap = true, fade = true, fadeAlpha = true,
  hideInKeyboard = true, iconSet = true, hideBlizzard = true, wheelScale = true, wheelBars = true, wheelBarsVersion = true,
}

local function makeDB(character, account)
  -- The first character to load after this change hands its own layout to the account.
  if not account.layoutShared then
    for key in pairs(SHARED) do
      if character[key] ~= nil then
        account[key] = character[key]
        character[key] = nil
      end
    end
    account.layoutShared = true
  end
  return setmetatable({}, {
    __index = function(_, key)
      if SHARED[key] then return account[key] end
      return character[key]
    end,
    __newindex = function(_, key, value)
      if SHARED[key] then account[key] = value else character[key] = value end
    end,
  })
end

local function onInterfaceTransition()
  if db and db.mode == "auto" then applyBindings() end
  if db then applyBlizzardVisibility() end
end

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
-- Fading the other bars --------------------------------------------------------

-- The game's own crossbar knows which of its four bars the triggers have picked (top
-- is Base, then left LT, right RT, bottom LT+RT), so the focus follows that: it is the
-- bar whose buttons really fire. Nil when the game has none or an override bar (stance,
-- possess) is up.
local function gameActiveBar()
  local frame = _G.GamepadMainActionBarFrame
  local unit = frame and type(frame.PageUnit) == "table" and frame.PageUnit or nil
  local bars = unit and type(unit.actionBars) == "table" and unit.actionBars or nil
  if not (bars and unit.GetActiveBar) then return nil end
  local ok, active = pcall(unit.GetActiveBar, unit)
  if not ok or active == nil then return nil end
  if active == bars.topBar then return 1 end
  if active == bars.leftBar then return 2 end
  if active == bars.rightBar then return 3 end
  if active == bars.bottomBar then return 4 end
  return nil
end

-- Which bar is in use: 1 to 4 from the game, then the Alt bars Steam Input sends:
-- 5 LB (Alt), 6 RB (Alt+Ctrl), 7 LT x2 (Alt+Shift), 8 RT x2 (Alt+Ctrl+Shift).
local function activeGroup()
  if IsAltKeyDown() then
    local shift, ctrl = IsShiftKeyDown(), IsControlKeyDown()
    if ctrl and shift then return 8 end -- RT x2
    if ctrl then return 6 end -- RB
    if shift then return 7 end -- LT x2
    return 5 -- LB
  end
  return gameActiveBar() or 1
end

local fadeActive, fadeElapsed = nil, 0 -- nil: nothing fades
local fader = CreateFrame("Frame", "FlatCrossbarFader")
fader:SetScript("OnUpdate", function(_, elapsed)
  if not db or #groupFrames == 0 then return end
  fadeElapsed = fadeElapsed + elapsed
  if fadeElapsed >= 0.05 then
    fadeElapsed = 0
    local mode = effectiveMode()
    -- In controller mode the bar in use has the focus (Base when nothing is held) and
    -- the others fade. While unlocked every bar stays clear so they can be arranged.
    local live = db.fade and db.locked and (mode == "controller" or mode == "both")
      and not (bindCapture and bindCapture:IsShown())
    fadeActive = live and activeGroup() or nil
  end
  local k = math.min(1, elapsed * 14)
  for g, gf in ipairs(groupFrames) do
    local target = (not fadeActive or fadeActive == g) and 1 or db.fadeAlpha
    local alpha = gf:GetAlpha()
    gf:SetAlpha(math.abs(target - alpha) < 0.01 and target or alpha + (target - alpha) * k)
  end
end)

local lastGamepad
local yieldElapsed = 0
events:SetScript("OnUpdate", function(_, elapsed)
  yieldElapsed = yieldElapsed + elapsed
  if yieldElapsed < 0.25 or not db or not container then return end
  yieldElapsed = 0
  -- The crossbar frame can be built or shown after login; keep it hidden.
  if db.hideBlizzard then applyBlizzardVisibility() end
  if not specialHooked then hookSpecialIcons() end -- the game's bar may load after us
  -- Auto follows the game going in and out of gamepad mode.
  local gamepad = gamepadUIActive()
  if gamepad ~= lastGamepad then
    lastGamepad = gamepad
    if db.mode == "auto" then applyBindings() end
  end
  local now = anyYieldFrameShown()
  if now ~= yielding then
    yielding = now
    applyBindings()
  end
end)

events:SetScript("OnEvent", function(_, event, arg1, arg2, arg3)
  if db and (event == "ACTIONBAR_UPDATE_COOLDOWN" or event == "SPELL_UPDATE_COOLDOWN" or event == "SPELL_UPDATE_CHARGES") then
    scheduleCooldownRefresh()
  end
  if db and (event == "PLAYER_TARGET_CHANGED" or event == "RAID_TARGET_UPDATE") then updateSpecialIcons() end
  if event == "ADDON_LOADED" then
    if arg1 == "Blizzard_GamepadActionBars" then hookSpecialIcons() end
    if arg1 ~= ADDON then return end
    FlatCrossbarDB = FlatCrossbarDB or {}
    FlatCrossbarAccountDB = FlatCrossbarAccountDB or {}
    db = makeDB(FlatCrossbarDB, FlatCrossbarAccountDB)
    copyDefaults(db, DEFAULTS)
    if (db.layoutVersion or 0) < 4 then
      -- The bars were rearranged: the old positions would overlap.
      db.point = { "BOTTOM", "UIParent", "BOTTOM", 0, 135 }
      db.groupPoints = {}
      db.layoutVersion = 4
    end
    if not db.padSeeded and next(db.pad) == nil then seedPadDefaults() end
    db.padSeeded = true
    if not db.wheelSeeded then
      -- Saves from before the wheel had a default: L3, unless it is already bound.
      if db.pad.wheel == nil then db.pad.wheel = "PADLSTICK" end
      db.wheelSeeded = true
    end
    if (db.wheelBarsVersion or 0) < 2 then
      -- The wheel now defaults to action bars 6, 7 and 8 (the ones the game has).
      db.wheelBars = { 6, 7, 8 }
      db.wheelBarsVersion = 2
    end
    if not db.nativeScheme then
      -- The crossbar bars are pressed by the game's own crossbar now: drop the old
      -- default binds (Shift/Ctrl on the D-pad and face buttons) that covered it.
      local old = { "", "SHIFT-", "CTRL-", "CTRL-SHIFT-" }
      for i = 1, MAIN_BUTTONS do
        if db.pad[i] == old[BUTTON_GROUP[i]] .. SLOT_PAD[BUTTON_SLOT[i]] then db.pad[i] = nil end
      end
      for target, key in pairs(RESERVED_DEFAULT) do
        if db.pad[target] == key then db.pad[target] = nil end
      end
      db.nativeScheme = true
    end
    if (db.extraSeedVersion or 0) < 3 then
      -- Saves from before the shoulder bars: give the buttons without a bind their defaults.
      for i = MAIN_BUTTONS + 1, NUM_BUTTONS do
        if db.pad[i] == nil then db.pad[i] = GROUP_PREFIX[BUTTON_GROUP[i]] .. SLOT_PAD[BUTTON_SLOT[i]] end
      end
      db.extraSeedVersion = 3
    end
    local built, err = pcall(function()
      buildWheelSlots()
      createFrames()
      restorePosition()
      applyLock()
      updatePanels()
      if db.autoScale then db.scale = fitScale() end
      layout()
    end)
    if not built then
      buildError = tostring(err)
      print_("couldn't build the bar: " .. buildError)
      return
    end
    for _, e in ipairs({
      "PLAYER_ENTERING_WORLD", "PLAYER_REGEN_ENABLED", "PLAYER_REGEN_DISABLED", "ACTIONBAR_SLOT_CHANGED",
      "ACTIONBAR_UPDATE_COOLDOWN", "ACTIONBAR_UPDATE_USABLE", "ACTIONBAR_UPDATE_STATE",
      "SPELL_UPDATE_COOLDOWN", "SPELL_UPDATE_CHARGES", "ACTION_RANGE_CHECK_UPDATE",
      "PLAYER_TARGET_CHANGED", "RAID_TARGET_UPDATE", "GAME_PAD_ACTIVE_CHANGED",
      "BAG_UPDATE_DELAYED", "PLAYER_SPECIALIZATION_CHANGED",
    }) do
      pcall(events.RegisterEvent, events, e)
    end
    -- The game's keyboard <-> gamepad interface switch, when this build has it.
    if InputUtil and InputUtil.RegisterGamepadInit and InputUtil.RegisterMKBInit then
      local subscriber = { "FlatCrossbar" }
      pcall(InputUtil.RegisterGamepadInit, subscriber, onInterfaceTransition)
      pcall(InputUtil.RegisterMKBInit, subscriber, onInterfaceTransition)
    end
  elseif event == "PLAYER_ENTERING_WORLD" then
    applyActions()
    hookSpecialIcons()
    updateSpecialIcons()
    if db.wheelSavedCamera and not (wheel and wheel:IsShown()) then suspendCamera(false) end -- left at 0 by a session that ended badly
    applyBindings()
    applyBlizzardVisibility()
    if db.autoMacros then ensureMacros() end
    if wheelNotice then print_(wheelNotice) end
  elseif event == "PLAYER_REGEN_DISABLED" then
    wheel:Hide()
  elseif event == "PLAYER_REGEN_ENABLED" then
    wheelHeaderButton:SetAttribute("type", nil)
    if pendingLayout then layout() end
    if pendingActions then applyActions() end
    if pendingTypes then
      pendingTypes = false
      for _, btn in ipairs(buttons) do
        if btn.restoreType then
          btn.restoreType = nil
          btn:SetAttribute("type", "action")
        end
      end
    end
    if pendingBindings then applyBindings() end
  elseif event == "ACTION_RANGE_CHECK_UPDATE" then
    -- slot, isInRange, checksRange
    rangeState[arg1] = (arg3 and arg2 == false) and false or nil
    updateAll()
  elseif event == "GAME_PAD_ACTIVE_CHANGED" then
    onInterfaceTransition()
  else
    updateAll()
  end
end)

-- Slash command ---------------------------------------------------------------

local HELP = {
  "/fcb mode auto|keyboard|controller|both - which keybind set is live",
  "/fcb toggle - switch keyboard / controller",
  "/fcb bind - hover a button, press a key or controller button",
  "/fcb clear [n|all] - clear the keybinds of button n (or all)",
  "/fcb wheel - preview the wheel   /fcb wheelpage N   /fcb wheelscale N",
  "/fcb bindto wheel|wheelnext|wheelprev|dynamic|inspect|back|jump - bind that, then press a key",
  "/fcb helper [on|off] - the label (LT, RT ...) between each bar's D-pad and face buttons",
  "/fcb hidebuttons | showbuttons - the KB/PAD toggle, Pg and Bind buttons",
  "/fcb padreset - put the controller binds back to the default trigger layout",
  "/fcb yield [on|off] | add FrameName (or Prefix*) | remove FrameName | list - pad binds step aside while a bag, bank, vendor or mail window is open",
  "/fcb wheelbars 6 7 8 - the keyboard action bars the wheel uses (not the crossbar's)",
  "/fcb hidekb [on|off] - hide the bars and toolbar in keyboard mode (the game's own bars are used there)",
  "/fcb icons [shapes|letters|auto] - the button icons: PlayStation shapes (default), Xbox letters, or whatever the game uses",
  "/fcb resetbuttons - take your binds off Act, Insp, Back and Jump so they are the game's own again",
  "/fcb snap [on|off] - snap bars to each other while you drag them (hold Ctrl to skip once)",
  "/fcb keys - print every key and controller button the game receives (to see how LT and RT arrive)",
  "/fcb fade [on|off|0-1] - the bar in use has the focus (Base when no trigger is held) and the others dim; only while locked",
  "/fcb macros [create|on|off] - the FCB Tab Enemy / FCB Tab Friend macros (made on login if missing)",
  "/fcb scale N|auto - bar scale (auto fits the screen)",
  "/fcb unlock | lock - drag a bar by the label between its D-pad and face buttons (hold Shift to drag actions off a locked bar)",
  "/fcb blizzard on|off - hide or show Blizzard's own crossbar",
  "/fcb show | hide - the bars   /fcb resetpos - bars back to the default spots   /fcb status",
}

SLASH_FLATCROSSBAR1 = "/fcb"
SLASH_FLATCROSSBAR2 = "/flatcrossbar"
SlashCmdList.FLATCROSSBAR = function(input)
  if not db then return end
  local cmd, arg = input:match("^%s*(%S*)%s*(.-)%s*$")
  cmd = cmd:lower()
  arg = arg:lower()

  if cmd == "status" then
    print_("build error: " .. tostring(buildError))
    for _, key in ipairs({ "PAD1", "PAD2", "PAD3", "PAD4", "PADDLEFT", "PADDRIGHT", "PADLSTICK" }) do
      local ok, bound = pcall(GetBindingAction, key, true)
      print_(key .. " is bound to: " .. tostring(ok and bound ~= "" and bound or "(nothing)"))
    end
    print_("cooldowns use: " .. cooldownPath .. (cooldownError and (", last error: " .. cooldownError) or ""))
    print_("the game says bar " .. tostring(gameActiveBar()) .. " is in use (1 Base, 2 LT, 3 RT, 4 LT+RT; nil = it can't tell)")
    print_("wheel: action bars " .. table.concat(db.wheelBars, ", ") .. ", " .. #wheelSlots .. " slots"
      .. (wheelSlots[1] and (" (" .. wheelSlots[1] .. "-" .. wheelSlots[#wheelSlots] .. ")") or "")
      .. ", crossbar storage starts at " .. tostring(C_GamepadUI and C_GamepadUI.GetFirstGamepadActionStorageSlotIndex
        and C_GamepadUI.GetFirstGamepadActionStorageSlotIndex()))
    print_("bar frame: " .. tostring(container ~= nil) .. ", buttons: " .. #buttons .. ", groups: " .. #groupFrames .. ", locked: " .. tostring(db.locked))
    print_("input: gamepad UI " .. tostring(gamepadUIActive()) .. ", binds " .. effectiveMode() .. ", stepping aside: " .. tostring(yielding))
    if container then
      local parent = container:GetParent()
      print_(string.format("shown %s, visible %s, parent %s (shown %s), size %.0fx%.0f, scale %.2f, alpha %.2f, strata %s",
        tostring(container:IsShown()), tostring(container:IsVisible()), tostring(parent and parent:GetName()),
        tostring(parent and parent:IsShown()), container:GetWidth() or 0, container:GetHeight() or 0,
        container:GetEffectiveScale() or 0, container:GetEffectiveAlpha() or 0, tostring(container:GetFrameStrata())))
      local point, _, relPoint, x, y = container:GetPoint()
      print_("point " .. tostring(point) .. " " .. tostring(relPoint) .. " " .. tostring(x) .. " " .. tostring(y))
    end
    return
  end
  if not container then
    return print_("the bar didn't build" .. (buildError and (": " .. buildError) or "") .. ". /fcb status has details.")
  end

  if cmd == "mode" then
    for _, m in ipairs(MODES) do
      if m == arg then return setMode(m) end
    end
    print_("modes: auto, keyboard, controller, both")
  elseif cmd == "toggle" then
    FlatCrossbar_ToggleMode()
  elseif cmd == "bind" then
    if bindCapture:IsShown() then stopBindMode() else startBindMode() end
  elseif cmd == "bindto" then
    local target = TARGET_ALIASES[arg]
    if not target then return print_("targets: wheel, wheelnext, wheelprev, dynamic, inspect, back, jump") end
    if InCombatLockdown() then return print_("can't change keybinds in combat.") end
    forcedTarget = target
    bindCapture:Show()
    bindButton:SetText("Done")
    print_("press a key or controller button for the " .. targetLabel(target) .. " (Esc cancels).")
  elseif cmd == "wheel" then
    if InCombatLockdown() then return print_("the wheel doesn't open in combat.") end
    local mode = effectiveMode()
    if mode ~= "controller" and mode ~= "both" then
      return print_("the wheel is controller-only; switch to controller mode first.")
    end
    wheel:SetShown(not wheel:IsShown())
  elseif cmd == "wheelpage" then
    local n = tonumber(arg)
    if InCombatLockdown() then return print_("can't change in combat.") end
    if n and n >= 1 and n <= WHEEL_PAGES then
      setWheelPage(math.floor(n))
    else
      print_("/fcb wheelpage 1-" .. WHEEL_PAGES)
    end
  elseif cmd == "wheelscale" then
    local n = tonumber(arg)
    if n and n >= 0.5 and n <= 2 then db.wheelScale = n; wheel:SetScale(n) else print_("/fcb wheelscale 0.5-2") end
  elseif cmd == "clear" then
    local n = tonumber(arg)
    local target = TARGET_ALIASES[arg]
    if target then
      db.kb[target], db.pad[target] = nil, nil
    elseif n and n >= 1 and n <= NUM_BUTTONS then
      db.kb[n], db.pad[n] = nil, nil
    elseif arg == "all" then
      wipe(db.kb); wipe(db.pad)
    else
      return print_("/fcb clear <1-" .. NUM_BUTTONS .. "|all>")
    end
    applyBindings()
  elseif cmd == "yield" then
    local sub_, name = input:match("^%s*%S*%s*(%S*)%s*(.-)%s*$")
    sub_ = sub_:lower()
    if sub_ == "on" or sub_ == "off" then
      db.yield = (sub_ == "on")
    elseif sub_ == "add" and name ~= "" then
      for _, existing in ipairs(db.yieldFrames) do
        if existing == name then name = "" end
      end
      if name ~= "" then db.yieldFrames[#db.yieldFrames + 1] = name end
    elseif sub_ == "remove" and name ~= "" then
      for i = #db.yieldFrames, 1, -1 do
        if db.yieldFrames[i] == name then table.remove(db.yieldFrames, i) end
      end
    end
    print_("pad binds step aside for windows: " .. (db.yield and "on" or "off")
      .. (#db.yieldFrames > 0 and (", extra frames: " .. table.concat(db.yieldFrames, ", ")) or "")
      .. (yielding and " (stepping aside now)" or ""))
    if not (sub_ == "list" or sub_ == "") then applyBindings() end
  elseif cmd == "fade" then
    local n = tonumber(arg)
    if arg == "on" then db.fade = true
    elseif arg == "off" then db.fade = false
    elseif n and n >= 0 and n <= 1 then db.fade = true; db.fadeAlpha = n
    elseif arg ~= "" then return print_("/fcb fade on|off|0-1") end
    print_("fade " .. (db.fade and ("on, other bars at " .. db.fadeAlpha) or "off"))
  elseif cmd == "wheelbars" then
    local bars = {}
    for digits in arg:gmatch("%d+") do
      local bar = tonumber(digits)
      if bar >= 1 and bar <= 10 then bars[#bars + 1] = bar end
    end
    if #bars > 0 then
      db.wheelBars = bars
      buildWheelSlots()
      if wheelPageButton then wheelPageButton:SetText("W" .. db.wheelPage) end
      updateWheel()
    end
    print_("wheel actions from action bars " .. table.concat(db.wheelBars, ", ") .. " (" .. #wheelSlots .. " slots, "
      .. WHEEL_PAGES .. " pages). /fcb wheelbars 6 7 8 to change.")
    if wheelNotice then print_(wheelNotice) end
  elseif cmd == "hidekb" then
    if arg == "on" then db.hideInKeyboard = true elseif arg == "off" then db.hideInKeyboard = false else db.hideInKeyboard = not db.hideInKeyboard end
    updatePanels()
    print_("bars hidden in keyboard mode: " .. (db.hideInKeyboard and "on" or "off"))
  elseif cmd == "icons" then
    if arg == "shapes" or arg == "letters" or arg == "auto" then
      db.iconSet = arg
      applyBindings() -- redraws the icons
    end
    print_("button icons: " .. db.iconSet .. " (/fcb icons shapes|letters|auto)")
  elseif cmd == "resetbuttons" then
    if InCombatLockdown() then return print_("can't change keybinds in combat.") end
    for _, target in ipairs(RESERVED_TARGETS) do db.pad[target] = nil end
    applyBindings()
    print_("Act, Insp, Back and Jump are the game's own again (X, Y, B and A on a standard layout).")
  elseif cmd == "snap" then
    if arg == "on" then db.snap = true elseif arg == "off" then db.snap = false else db.snap = not db.snap end
    print_("snapping " .. (db.snap and "on" or "off"))
  elseif cmd == "keys" then
    toggleKeyLogger()
  elseif cmd == "macros" then
    if arg == "on" then db.autoMacros = true elseif arg == "off" then db.autoMacros = false end
    if InCombatLockdown() then return print_("can't make macros in combat.") end
    ensureMacros()
    print_("macros are made on login: " .. (db.autoMacros and "on" or "off") .. ". Names: FCB Tab Enemy, FCB Tab Friend.")
  elseif cmd == "padreset" then
    if InCombatLockdown() then return print_("can't change keybinds in combat.") end
    seedPadDefaults()
    applyBindings()
    print_("controller binds reset to the default trigger layout.")
  elseif cmd == "scale" then
    local n = tonumber(arg)
    if arg == "auto" then
      db.autoScale = true
      db.scale = fitScale()
      layout()
    elseif n and n >= 0.5 and n <= 2 then
      db.scale = n
      db.autoScale = false
      layout()
    else
      print_("/fcb scale 0.5-2, or auto")
    end
  elseif cmd == "lock" or cmd == "unlock" then
    db.locked = (cmd == "lock")
    applyLock()
    layout() -- the gap closes when locked in keyboard mode, and opens when unlocked
    print_(db.locked and "locked" or "unlocked: drag the label in the middle of a bar to move it")
  elseif cmd == "hidebuttons" or cmd == "showbuttons" then
    if InCombatLockdown() then return print_("can't do that in combat.") end
    db.hideButtons = (cmd == "hidebuttons")
    layoutToolbar()
  elseif cmd == "helper" then
    if arg == "on" then db.helper = true elseif arg == "off" then db.helper = false else db.helper = not db.helper end
    updateLabels()
    print_("helper text " .. (db.helper and "on" or "off"))
  elseif cmd == "resetpos" then
    if InCombatLockdown() then return print_("can't do that in combat.") end
    db.point = { "BOTTOM", "UIParent", "BOTTOM", 0, 135 }
    db.groupPoints = {}
    restorePosition()
  elseif cmd == "blizzard" then
    db.hideBlizzard = (arg ~= "on")
    applyBlizzardVisibility()
    print_("Blizzard crossbar " .. (db.hideBlizzard and "hidden" or "shown"))
  elseif cmd == "show" then
    setBarShown(true)
  elseif cmd == "hide" then
    setBarShown(false)
  else
    for _, line in ipairs(HELP) do print_(line) end
  end
end
