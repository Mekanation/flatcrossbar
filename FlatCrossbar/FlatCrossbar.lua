-- FlatCrossbar: the controller beta's crossbar as one plain action bar.
--
-- The crossbar (Blizzard_GamepadActionBars) holds its actions in "gamepad
-- storage slots": 3 standard pages x 4 bars (top/left/right/bottom) x 8
-- buttons, with the top bar's right-hand 4 reserved for UI actions, leaving
-- 28 usable buttons per page. Blizzard shows only one bar at a time and picks
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

local NUM_BUTTONS = 28
local NUM_PAGES = 3
local BUTTON_SIZE = 38
local SPACING = 4
local HEADER_HEIGHT = 18
local WHEEL_SLICES = 8
local WHEEL_PAGES = math.ceil(NUM_BUTTONS / WHEEL_SLICES)
local WHEEL_RADIUS = 92
local WHEEL_SLICE_SIZE = 50
local STICK_DEADZONE = 0.5

local MODES = { "auto", "keyboard", "controller", "both" }
local MODE_LABEL = { auto = "AUTO", keyboard = "KB", controller = "PAD", both = "KB+PAD" }

local DEFAULTS = {
  mode = "auto",
  kb = {},
  pad = {},
  layout = "groups",
  groupCols = 4,
  cols = 14,
  scale = 1,
  page = 1,
  wheelPage = 1,
  wheelScale = 1,
  locked = false,
  hideBlizzard = true,
  point = { "BOTTOM", "UIParent", "BOTTOM", 0, 120 },
}

BINDING_HEADER_FLATCROSSBAR = "FlatCrossbar"
for i = 1, NUM_BUTTONS do
  _G["BINDING_NAME_FLATCROSSBAR" .. i] = "Crossbar button " .. i
end
BINDING_NAME_FLATCROSSBARPAGENEXT = "Next crossbar page"
BINDING_NAME_FLATCROSSBARPAGEPREV = "Previous crossbar page"
BINDING_NAME_FLATCROSSBARWHEEL = "Crossbar wheel (hold)"
BINDING_NAME_FLATCROSSBARWHEELPAGENEXT = "Next wheel page"
BINDING_NAME_FLATCROSSBARWHEELPAGEPREV = "Previous wheel page"
BINDING_NAME_FLATCROSSBARTOGGLEMODE = "Toggle keyboard / controller keybinds"

local db
local buttons = {}
local container, header, modeButton, pageButton, bindButton, bindCapture
local groupLabels, reservedSlots = {}, {}
local buildError
local securePaging = true

-- Secure handler frames get SetFrameRef from their template; fall back to the
-- global helper, and to out-of-combat paging if this client has neither.
local function setFrameRef(handler, label, frame)
  if handler.SetFrameRef then
    handler:SetFrameRef(label, frame)
  elseif _G.SecureHandlerSetFrameRef then
    _G.SecureHandlerSetFrameRef(handler, label, frame)
  else
    securePaging = false
  end
end
local wheel, wheelPageButton, wheelHeaderButton
local slices = {}
local bindOwner = CreateFrame("Frame")
local pendingLayout, pendingBindings, pendingPage = false, false, nil
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

-- The crossbar's four bars are 8 buttons each (slots 1-4 on the D-pad, 5-8 on
-- the face buttons) and are picked by the triggers held: none = top, LT = left,
-- RT = right, LT+RT = bottom (PageUnit.lua). The groups layout draws each bar as
-- a small 2x4 block under its trigger label.
local GROUP_SIZE = 8
local GROUP_LABEL = { "Base", "LT", "RT", "LT+RT" }
-- The triggers reach the game as Shift (LT) and Ctrl (RT) when binding keys.
local GROUP_PREFIX = { "", "SHIFT-", "CTRL-", "CTRL-SHIFT-" }
local SLOT_PAD = { "PADDLEFT", "PADDUP", "PADDRIGHT", "PADDDOWN", "PAD3", "PAD4", "PAD2", "PAD1" }
local BUTTON_GROUP, BUTTON_SLOT = {}, {}
for i, id in ipairs(PAGE_UNIT_SLOT_IDS) do
  BUTTON_GROUP[i] = math.floor((id - 1) / GROUP_SIZE) + 1
  BUTTON_SLOT[i] = (id - 1) % GROUP_SIZE + 1
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
    local out = (mods:find("SHIFT%-") and "LT+" or "") .. (mods:find("CTRL%-") and "RT+" or "")
      .. (mods:find("ALT%-") and "a" or "")
    return out .. (SHORT_KEY[base] or (base:gsub("^PAD", "P")))
  end
  mods = mods:gsub("ALT%-", "a"):gsub("CTRL%-", "c"):gsub("SHIFT%-", "s")
  base = SHORT_KEY[base] or base:gsub("^PAD", "P"):gsub("^NUMPAD", "N"):gsub("^BUTTON", "M")
  return mods .. base
end

local function hotkeyText(index)
  local mode = effectiveMode()
  local kb, pad = db.kb[index], db.pad[index]
  if mode == "keyboard" then return shortKey(kb) or "" end
  if mode == "controller" then return shortKey(pad) or "" end
  if kb and pad then return shortKey(kb) .. "\n" .. shortKey(pad) end
  return shortKey(kb or pad) or ""
end

-- Override bindings -----------------------------------------------------------

-- Bindable things besides the 28 buttons. Keys in db.kb / db.pad. The fourth
-- field marks the controller-only ones (the wheel).
local TARGETS = {
  pageNext = { "FlatCrossbarPageButton", "LeftButton", "next page" },
  pagePrev = { "FlatCrossbarPageButton", "RightButton", "previous page" },
  wheel = { "FlatCrossbarWheelButton", "LeftButton", "wheel (hold)", true },
  wheelNext = { "FlatCrossbarWheelPageButton", "LeftButton", "next wheel page", true },
  wheelPrev = { "FlatCrossbarWheelPageButton", "RightButton", "previous wheel page", true },
}
local TARGET_ALIASES = {
  pagenext = "pageNext", pageprev = "pagePrev", wheel = "wheel",
  wheelnext = "wheelNext", wheelprev = "wheelPrev",
}

local function targetLabel(target)
  return type(target) == "number" and ("button " .. target) or TARGETS[target][3]
end

local function applyBindings()
  if InCombatLockdown() then
    pendingBindings = true
    return
  end
  pendingBindings = false
  ClearOverrideBindings(bindOwner)
  local mode = effectiveMode()
  for i = 1, NUM_BUTTONS do
    local name = "FlatCrossbarButton" .. i
    if mode == "keyboard" or mode == "both" then
      if db.kb[i] then SetOverrideBindingClick(bindOwner, true, db.kb[i], name, "LeftButton") end
    end
    if mode == "controller" or mode == "both" then
      if db.pad[i] then SetOverrideBindingClick(bindOwner, true, db.pad[i], name, "LeftButton") end
    end
  end
  for name, t in pairs(TARGETS) do
    if (mode == "keyboard" or mode == "both") and not t[4] then
      if db.kb[name] then SetOverrideBindingClick(bindOwner, true, db.kb[name], t[1], t[2]) end
    end
    if mode == "controller" or mode == "both" then
      if db.pad[name] then SetOverrideBindingClick(bindOwner, true, db.pad[name], t[1], t[2]) end
    end
  end
  for i = 1, NUM_BUTTONS do
    if buttons[i] then buttons[i].HotKey:SetText(hotkeyText(i)) end
  end
  if modeButton then modeButton:SetText(MODE_LABEL[db.mode]) end

  local showWheel = (mode == "controller" or mode == "both")
  if wheelHeaderButton then
    wheelHeaderButton:SetShown(showWheel)
    wheelPageButton:SetShown(showWheel)
    bindButton:ClearAllPoints()
    bindButton:SetPoint("LEFT", showWheel and wheelPageButton or pageButton, "RIGHT", 4, 0)
    if not showWheel and wheel then wheel:Hide() end
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

local function updateCooldown(btn, action)
  local ok = pcall(function()
    if ActionButton_ApplyCooldown and C_ActionBar.GetActionCharges and C_ActionBar.GetActionLossOfControlCooldownInfo then
      ActionButton_ApplyCooldown(btn.cooldown, C_ActionBar.GetActionCooldown(action),
        btn.chargeCooldown, C_ActionBar.GetActionCharges(action),
        btn.locCooldown, C_ActionBar.GetActionLossOfControlCooldownInfo(action))
    else
      local info = C_ActionBar.GetActionCooldown(action)
      if info and info.isActive then
        btn.cooldown:SetCooldown(info.startTime, info.duration, info.modRate)
      else
        btn.cooldown:Clear()
      end
    end
  end)
  if not ok then btn.cooldown:Clear() end
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
    btn.cooldown:Clear()
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
      btn.icon:SetVertexColor(1, 1, 1)
    elseif lacking then
      btn.icon:SetVertexColor(0.3, 0.3, 1)
    else
      btn.icon:SetVertexColor(0.4, 0.4, 0.4)
    end
  else
    btn.icon:Hide()
    btn.Count:SetText("")
    btn.checked:Hide()
    btn.cooldown:Clear()
  end
end

local updateWheel

local function updateAll()
  for i = 1, NUM_BUTTONS do
    if buttons[i] then updateButton(buttons[i]) end
  end
  if updateWheel then updateWheel() end
end

local function enableRangeChecks()
  if not C_ActionBar.EnableActionRangeCheck then return end
  for i = 1, NUM_BUTTONS do
    local action = buttons[i] and buttons[i]:GetAttribute("action")
    if action then C_ActionBar.EnableActionRangeCheck(action, true) end
  end
end

-- Pages -----------------------------------------------------------------------

-- Sets each button's action to the storage slot for the page. Combat-safe
-- paging goes through pageButton's secure snippet; this is the out-of-combat
-- path used at login and by /fcb page.
local function applyPage(page)
  if InCombatLockdown() then
    pendingPage = page
    return
  end
  pendingPage = nil
  page = math.max(1, math.min(NUM_PAGES, page))
  db.page = page
  pageButton:SetAttribute("page", page)
  for i = 1, NUM_BUTTONS do
    buttons[i]:SetAttribute("action", storageSlot(page, PAGE_UNIT_SLOT_IDS[i]))
  end
  pageButton:SetText("Pg " .. page)
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
  local btn = CreateFrame("Button", "FlatCrossbarButton" .. i, container, "SecureActionButtonTemplate")
  btn:SetSize(BUTTON_SIZE, BUTTON_SIZE)
  btn:SetAttribute("type", "action")
  btn:RegisterForClicks("AnyUp", "AnyDown")
  btn:RegisterForDrag("LeftButton")
  btn.index = i

  local bg = btn:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints()
  bg:SetColorTexture(0, 0, 0, 0.55)
  addBorder(btn, 0.35, 0.35, 0.35, 1)

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

local GROUP_COLS = 4 -- buttons per row inside a group
local GROUP_ROWS = GROUP_SIZE / GROUP_COLS
local GROUP_GAP = 10
local GROUP_LABEL_HEIGHT = 12

-- The groups layout: the four bars as 2x4 blocks, laid out db.groupCols across.
local function layoutGroups()
  local step = BUTTON_SIZE + SPACING
  local per = math.max(1, math.min(#GROUP_LABEL, math.floor(db.groupCols)))
  local groupW = GROUP_COLS * step - SPACING
  local groupH = GROUP_LABEL_HEIGHT + GROUP_ROWS * step - SPACING
  local top = HEADER_HEIGHT + SPACING

  local function place(frame, g, col, row)
    local gx, gy = (g - 1) % per, math.floor((g - 1) / per)
    frame:ClearAllPoints()
    frame:SetPoint("TOPLEFT", container, "TOPLEFT", gx * (groupW + GROUP_GAP) + col * step,
      -(top + gy * (groupH + GROUP_GAP) + GROUP_LABEL_HEIGHT + row * step))
  end

  for g, label in ipairs(groupLabels) do
    local gx, gy = (g - 1) % per, math.floor((g - 1) / per)
    label:ClearAllPoints()
    label:SetPoint("TOPLEFT", container, "TOPLEFT", gx * (groupW + GROUP_GAP), -(top + gy * (groupH + GROUP_GAP)))
    label:SetWidth(groupW)
    label:Show()
  end
  for i, btn in ipairs(buttons) do
    local s = BUTTON_SLOT[i]
    place(btn, BUTTON_GROUP[i], (s - 1) % GROUP_COLS, math.floor((s - 1) / GROUP_COLS))
  end
  -- Slots 5-8 of the base bar are the face buttons, kept by the game for jump,
  -- interact and so on, so they are shown empty.
  for k, slot in ipairs(reservedSlots) do
    local s = 4 + k
    place(slot, 1, (s - 1) % GROUP_COLS, math.floor((s - 1) / GROUP_COLS))
    slot:Show()
  end
  local groupRows = math.ceil(#GROUP_LABEL / per)
  container:SetSize(per * groupW + (per - 1) * GROUP_GAP, top + groupRows * groupH + (groupRows - 1) * GROUP_GAP)
end

local function layoutRow()
  local cols = math.max(1, math.min(NUM_BUTTONS, db.cols))
  local rows = math.ceil(NUM_BUTTONS / cols)
  for i, btn in ipairs(buttons) do
    local col = (i - 1) % cols
    local row = math.floor((i - 1) / cols)
    btn:ClearAllPoints()
    btn:SetPoint("TOPLEFT", container, "TOPLEFT", col * (BUTTON_SIZE + SPACING), -(HEADER_HEIGHT + SPACING + row * (BUTTON_SIZE + SPACING)))
  end
  for _, label in ipairs(groupLabels) do label:Hide() end
  for _, slot in ipairs(reservedSlots) do slot:Hide() end
  container:SetSize(cols * (BUTTON_SIZE + SPACING) - SPACING,
    HEADER_HEIGHT + SPACING + rows * (BUTTON_SIZE + SPACING) - SPACING)
end

local function layout()
  if InCombatLockdown() then
    pendingLayout = true
    return
  end
  pendingLayout = false
  if db.layout == "row" then layoutRow() else layoutGroups() end
  container:SetScale(db.scale)
end

local function restorePosition()
  local p = db.point
  container:ClearAllPoints()
  container:SetPoint(p[1], _G[p[2]] or UIParent, p[3], p[4], p[5])
end

local function makeHeaderButton(text, width)
  local b = CreateFrame("Button", nil, header, "UIPanelButtonTemplate")
  b:SetSize(width, HEADER_HEIGHT)
  b:SetText(text)
  return b
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

local function wheelButtonIndex(slice)
  return (db.wheelPage - 1) * WHEEL_SLICES + slice
end

updateWheel = function()
  if not (wheel and wheel:IsShown()) then return end
  wheel.pageText:SetText(db.wheelPage .. "/" .. WHEEL_PAGES)
  for i, sl in ipairs(slices) do
    local btn = buttons[wheelButtonIndex(i)]
    local action = btn and btn:GetAttribute("action")
    updateButton(sl, action or false)
    sl:SetAlpha(btn and 1 or 0.35)
    sl.selected:SetShown(wheelSel == i)
  end
end

-- Aiming copies the slice's action onto the wheel button, so that releasing
-- the key (a click on it) uses that action. Attributes on a secure button
-- can't change in combat, which is why the wheel doesn't open then.
local function setWheelSelection(slice)
  if InCombatLockdown() then return end
  if slice and not buttons[wheelButtonIndex(slice)] then slice = nil end
  wheelSel = slice
  local action = slice and buttons[wheelButtonIndex(slice)]:GetAttribute("action")
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
local function readStick()
  if not (C_GamePad and C_GamePad.GetActiveDeviceID and C_GamePad.GetDeviceMappedState) then return end
  local id = C_GamePad.GetActiveDeviceID()
  local state = id and C_GamePad.GetDeviceMappedState(id)
  local stick = state and state.sticks and state.sticks[2]
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
  end

  wheel:SetScript("OnShow", function() updateAll() end)
  wheel:SetScript("OnHide", function()
    stickWasActive = false
    wheelSel = nil
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

  header = CreateFrame("Frame", nil, container)
  header:SetPoint("TOPLEFT")
  header:SetPoint("TOPRIGHT")
  header:SetHeight(HEADER_HEIGHT)
  header:EnableMouse(true)
  header:RegisterForDrag("LeftButton")
  header:SetScript("OnDragStart", function()
    if db.locked or InCombatLockdown() then return end
    container:StartMoving()
  end)
  header:SetScript("OnDragStop", function()
    container:StopMovingOrSizing()
    local point, _, relPoint, x, y = container:GetPoint()
    db.point = { point, "UIParent", relPoint, x, y }
  end)

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

  -- Combat-safe paging: the click handler rewrites every button's action
  -- inside the restricted environment.
  pageButton = CreateFrame("Button", "FlatCrossbarPageButton", container, "SecureHandlerClickTemplate,UIPanelButtonTemplate")
  pageButton:SetSize(48, HEADER_HEIGHT)
  pageButton:SetPoint("LEFT", modeButton, "RIGHT", 4, 0)
  pageButton:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  pageButton:SetAttribute("page", 1)
  pageButton:SetAttribute("_onclick", string.format([[
    local pages = %d
    local page = self:GetAttribute("page") or 1
    if button == "RightButton" then
      page = page - 1
      if page < 1 then page = pages end
    else
      page = page + 1
      if page > pages then page = 1 end
    end
    self:SetAttribute("page", page)
    for i = 1, %d do
      local b = self:GetFrameRef("b" .. i)
      b:SetAttribute("action", self:GetAttribute("slot-" .. page .. "-" .. i))
    end
  ]], NUM_PAGES, NUM_BUTTONS))
  pageButton:HookScript("PostClick", function(self, mouse)
    if not securePaging then
      -- No secure handler on this client: page out of combat only.
      if not InCombatLockdown() then
        applyPage(db.page + (mouse == "RightButton" and -1 or 1))
      end
      return
    end
    local page = self:GetAttribute("page") or 1
    db.page = page
    self:SetText("Pg " .. page)
    enableRangeChecks()
    updateAll()
  end)
  pageButton:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText("Crossbar page")
    GameTooltip:AddLine("Left-click: next page. Right-click: previous.", 1, 1, 1)
    GameTooltip:Show()
  end)
  pageButton:SetScript("OnLeave", function() GameTooltip:Hide() end)

  wheelHeaderButton = CreateFrame("Button", "FlatCrossbarWheelButton", container, "SecureActionButtonTemplate,UIPanelButtonTemplate")
  wheelHeaderButton:SetSize(52, HEADER_HEIGHT)
  wheelHeaderButton:SetText("Wheel")
  wheelHeaderButton:SetPoint("LEFT", pageButton, "RIGHT", 4, 0)

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
  bindTarget(pageButton, "pageNext")
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

  for g, text in ipairs(GROUP_LABEL) do
    local label = container:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetHeight(GROUP_LABEL_HEIGHT)
    label:SetJustifyH("LEFT")
    label:SetText(text)
    groupLabels[g] = label
  end
  for k = 1, 4 do
    local slot = CreateFrame("Frame", nil, container)
    slot:SetSize(BUTTON_SIZE, BUTTON_SIZE)
    local bg = slot:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0, 0, 0, 0.25)
    addBorder(slot, 0.2, 0.2, 0.2, 1)
    reservedSlots[k] = slot
  end
  for i = 1, NUM_BUTTONS do
    buttons[i] = createButton(i)
    setFrameRef(pageButton, "b" .. i, buttons[i])
  end
  createWheel()
  for page = 1, NUM_PAGES do
    for i = 1, NUM_BUTTONS do
      pageButton:SetAttribute("slot-" .. page .. "-" .. i, storageSlot(page, PAGE_UNIT_SLOT_IDS[i]))
    end
  end
end

-- Blizzard crossbar -----------------------------------------------------------

local function applyBlizzardVisibility()
  local frame = _G.GamepadMainActionBarFrame
  if not frame then return end
  frame:SetAlpha(db.hideBlizzard and 0 or 1)
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

-- Controller defaults: each bar's D-pad and face buttons under its trigger
-- (Base = bare, LT = Shift, RT = Ctrl, LT+RT = both). Only for a fresh set.
local function seedPadDefaults()
  for i = 1, NUM_BUTTONS do
    db.pad[i] = GROUP_PREFIX[BUTTON_GROUP[i]] .. SLOT_PAD[BUTTON_SLOT[i]]
  end
end

local function onInterfaceTransition()
  if db and db.mode == "auto" then applyBindings() end
  if db then applyBlizzardVisibility() end
end

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:SetScript("OnEvent", function(_, event, arg1, arg2, arg3)
  if event == "ADDON_LOADED" then
    if arg1 ~= ADDON then return end
    FlatCrossbarDB = FlatCrossbarDB or {}
    db = FlatCrossbarDB
    copyDefaults(db, DEFAULTS)
    if not db.padSeeded and next(db.pad) == nil then seedPadDefaults() end
    db.padSeeded = true
    local built, err = pcall(function()
      createFrames()
      restorePosition()
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
      "PLAYER_TARGET_CHANGED", "GAME_PAD_ACTIVE_CHANGED",
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
    applyPage(db.page)
    applyBindings()
    applyBlizzardVisibility()
  elseif event == "PLAYER_REGEN_DISABLED" then
    wheel:Hide()
  elseif event == "PLAYER_REGEN_ENABLED" then
    wheelHeaderButton:SetAttribute("type", nil)
    if pendingLayout then layout() end
    if pendingPage then applyPage(pendingPage) end
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
  "/fcb page 1-3 - show that crossbar page",
  "/fcb wheel - preview the wheel   /fcb wheelpage 1-4   /fcb wheelscale N",
  "/fcb bindto wheel|wheelnext|wheelprev|pagenext|pageprev - bind that, then press a key",
  "/fcb layout groups|row - four trigger groups (Base, LT, RT, LT+RT), or one row",
  "/fcb groupcols 1-4 - groups per row   /fcb cols N - buttons per row (row layout)",
  "/fcb padreset - put the controller binds back to the default trigger layout",
  "/fcb scale N - bar scale",
  "/fcb lock | unlock - dragging the bar and (without Shift) its buttons",
  "/fcb blizzard on|off - hide or show Blizzard's own crossbar",
  "/fcb show | hide - this bar   /fcb status - why it isn't showing",
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
    print_("bar frame: " .. tostring(container ~= nil) .. ", buttons: " .. #buttons .. ", layout: " .. tostring(db.layout))
    print_("secure paging: " .. tostring(securePaging) .. "; input: gamepad UI " .. tostring(gamepadUIActive()) .. ", binds " .. effectiveMode())
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
    if not target then return print_("targets: wheel, wheelnext, wheelprev, pagenext, pageprev") end
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
  elseif cmd == "page" then
    local n = tonumber(arg)
    if n then applyPage(n) else print_("/fcb page 1-" .. NUM_PAGES) end
  elseif cmd == "layout" then
    if arg == "groups" or arg == "row" then
      db.layout = arg
      layout()
    else
      print_("/fcb layout groups|row")
    end
  elseif cmd == "groupcols" then
    local n = tonumber(arg)
    if n and n >= 1 and n <= #GROUP_LABEL then db.groupCols = math.floor(n); layout() else print_("/fcb groupcols 1-" .. #GROUP_LABEL) end
  elseif cmd == "padreset" then
    if InCombatLockdown() then return print_("can't change keybinds in combat.") end
    seedPadDefaults()
    applyBindings()
    print_("controller binds reset to the default trigger layout.")
  elseif cmd == "cols" then
    local n = tonumber(arg)
    if n then db.cols = math.floor(n); layout() else print_("/fcb cols 1-" .. NUM_BUTTONS) end
  elseif cmd == "scale" then
    local n = tonumber(arg)
    if n and n >= 0.5 and n <= 2 then db.scale = n; layout() else print_("/fcb scale 0.5-2") end
  elseif cmd == "lock" or cmd == "unlock" then
    db.locked = (cmd == "lock")
    print_(db.locked and "locked" or "unlocked")
  elseif cmd == "blizzard" then
    db.hideBlizzard = (arg ~= "on")
    applyBlizzardVisibility()
    print_("Blizzard crossbar " .. (db.hideBlizzard and "hidden" or "shown"))
  elseif cmd == "show" then
    container:Show()
  elseif cmd == "hide" then
    container:Hide()
  else
    for _, line in ipairs(HELP) do print_(line) end
  end
end
