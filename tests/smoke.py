"""Smoke test for FlatCrossbar: loads the addon against stubbed WoW APIs and
drives its events, slash commands and wheel flow.

    pip install lupa
    python flatcrossbar/tests/smoke.py [path/to/FlatCrossbar]

This runs on a newer Lua than WoW's 5.1 (math.atan2 is shimmed), and the stubs
return whatever they're told to, so it checks the addon's own logic, not game
behaviour. Anything that prints ERROR is a failure.
"""
import os
import sys
from lupa import LuaRuntime

addon_dir = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
    os.path.dirname(os.path.abspath(__file__)), '..', 'FlatCrossbar')
lua = LuaRuntime(unpack_returned_tuples=True)
print('lua:', lua.eval('_VERSION'), 'jit' if lua.eval('jit ~= nil') else '')

src = open(addon_dir + '/FlatCrossbar.lua', encoding='utf-8').read()

harness = r'''
local src, addonName = ...
local log = {}
local function note(s) log[#log + 1] = s end

-- A frame/region stub: any method returns a harmless value; a few keep state.
local Stub = {}
local function newStub(kind, name)
  local o = { __kind = kind, __attrs = {}, __scripts = {}, __hooks = {}, __shown = true, __name = name }
  return setmetatable(o, Stub)
end
Stub.__index = function(t, k)
  local m = rawget(Stub, k)
  if m then return m end
  -- every unknown method is a no-op that returns the object (chainable)
  return function(self, ...) return self end
end
function Stub.SetAttribute(self, k, v) self.__attrs[k] = v end
function Stub.GetAttribute(self, k) return self.__attrs[k] end
function Stub.SetScript(self, k, f) self.__scripts[k] = f end
function Stub.GetScript(self, k) return self.__scripts[k] end
function Stub.HookScript(self, k, f) self.__hooks[k] = self.__hooks[k] or {}; table.insert(self.__hooks[k], f) end
function Stub.Show(self) self.__shown = true; if self.__scripts.OnShow then self.__scripts.OnShow(self) end end
function Stub.Hide(self) self.__shown = false; if self.__scripts.OnHide then self.__scripts.OnHide(self) end end
function Stub.SetShown(self, v) if v then self:Show() else self:Hide() end end
function Stub.IsShown(self) return self.__shown end
function Stub.GetName(self) return self.__name end
function Stub.CreateTexture(self) return newStub('Texture') end
function Stub.CreateFontString(self) return newStub('FontString') end
function Stub.CreateMaskTexture(self) return newStub('Mask') end
function Stub.GetPoint() return 'BOTTOM', nil, 'BOTTOM', 0, 120 end
function Stub.RegisterEvent(self, e) local ev = rawget(self, '__events') or {}; rawset(self, '__events', ev); ev[e] = true end
function Stub.GetCenter() return 0, 0 end
function Stub.SetAlpha(self, v) self.__alpha = v end
function Stub.GetAlpha(self) return rawget(self, '__alpha') or 1 end
function Stub.GetWidth() return 100 end
function Stub.GetHeight() return 50 end
function Stub.GetEffectiveScale() return 1 end
function Stub.GetEffectiveAlpha() return 1 end
function Stub.GetFrameStrata() return 'MEDIUM' end
function Stub.GetParent() return UIParent end

local G = _G
math.atan2 = math.atan2 or function(y, x) return math.atan(y, x) end
local ALL = {}
CreateFrame = function(kind, name, parent, template)
  local f = newStub(kind, name)
  ALL[#ALL + 1] = f
  f.__template = template
  f.__parent = parent and parent.__name or nil
  if kind == 'Frame' then f.__shown = true end
  if name then G[name] = f end
  return f
end
UIParent = newStub('Frame', 'UIParent')
GameTooltip = newStub('Frame', 'GameTooltip')
GamepadMainActionBarFrame = newStub('Frame', 'GamepadMainActionBarFrame')

-- Constants the addon touches
SlashCmdList = {}
InCombatLockdown = function() return false end
IsShiftKeyDown = function() return false end
IsControlKeyDown = function() return false end
IsAltKeyDown = function() return false end
GetCursorInfo = function() return nil end
PickupAction = function() end
PlaceAction = function() end
ClearOverrideBindings = function() note('ClearOverrideBindings') end
BINDS = 0
InputIconTextureSetUtility = { GetNormalActiveInputIconButtonTexture = function(k) return 'atlas-' .. k end }
SetOverrideBinding = function(owner, pri, key, cmd) BINDS = BINDS + 1; note(('bindcmd %s -> %s'):format(key, cmd)) end
SetOverrideBindingClick = function(owner, pri, key, name, btn) BINDS = BINDS + 1; note(('bind %s -> %s:%s'):format(key, name, btn)) end
ActionButton_ApplyCooldown = nil
local macros = {}
GetMacroIndexByName = function(n) return macros[n] and 1 or 0 end
CreateMacro = function(n, icon, body, perChar) macros[n] = body; note('CreateMacro ' .. n .. ' = ' .. body); return 1 end
wipe = function(t) for k in pairs(t) do t[k] = nil end return t end
C_ActionBar = setmetatable({
  HasAction = function(a) return a == 1000 end,
  GetActionTexture = function(a) return 123 end,
  GetActionDisplayCount = function() return '' end,
  IsCurrentAction = function() return false end,
  IsAutoRepeatAction = function() return false end,
  IsUsableAction = function() return true, false end,
  GetActionCooldown = function() return { isActive = false } end,
  EnableActionRangeCheck = function() end,
}, { __index = function() return function() end end })
C_GamepadUI = { GetFirstGamepadActionStorageSlotIndex = function() return 1000 end }
C_GamePad = {
  GetActiveDeviceID = function() return 1 end,
  GetDeviceMappedState = function() return { sticks = { { x = 0, y = 0, len = 0 }, { x = 0, y = 1, len = 1 } } } end,
  IsEnabled = function() return true end,
}
InputUtil = { IsGamepadUIEnabled = function() return false end,
  RegisterGamepadInit = function() end, RegisterMKBInit = function() end }
NUMS = nil
print = function(...) local t = {} for i = 1, select('#', ...) do t[#t+1] = tostring((select(i, ...))) end note('print: ' .. table.concat(t, ' ')) end
SecureHandlerWrapScript = function() error('SecureHandlerWrapScript should no longer be used') end

local chunk, err = loadstring and loadstring(src, 'FlatCrossbar.lua') or load(src, 'FlatCrossbar.lua')
if not chunk then return 'SYNTAX ERROR: ' .. tostring(err) end
local ok, e = pcall(chunk, addonName)
if not ok then return 'LOAD ERROR: ' .. tostring(e) end


local events
for _, f in ipairs(ALL) do
  local ev = rawget(f, '__events'); if ev and ev.ADDON_LOADED then events = f end
end
if not events then return 'NO EVENT FRAME' end
local function fire(ev, ...)
  local ok, e = pcall(events.__scripts.OnEvent, events, ev, ...)
  if not ok then note('ERROR in ' .. ev .. ': ' .. tostring(e)) end
end
local function try(label, f, ...)
  local ok, e = pcall(f, ...)
  note((ok and 'ok    ' or 'ERROR ') .. label .. (ok and '' or (': ' .. tostring(e))))
end

fire('ADDON_LOADED', addonName)
fire('PLAYER_ENTERING_WORLD')

if not G.FlatCrossbarButton1 then return 'ERROR bar did not build:' .. string.char(10) .. table.concat(log, string.char(10)) end
local wheel, wbtn, wpage = G.FlatCrossbarWheel, G.FlatCrossbarWheelButton, G.FlatCrossbarWheelPageButton
note('wheel frame: ' .. tostring(wheel ~= nil) .. ', wheel button: ' .. tostring(wbtn ~= nil))
note('button1 action = ' .. tostring(G.FlatCrossbarButton1:GetAttribute('action')) ..
     ', button5 = ' .. tostring(G.FlatCrossbarButton5:GetAttribute('action')) ..
     ', button28 = ' .. tostring(G.FlatCrossbarButton28:GetAttribute('action')))

-- controller mode: header buttons show, wheel binds apply
local slash = SlashCmdList.FLATCROSSBAR
try('/fcb mode controller', slash, 'mode controller')
note('wheel header (shown and alpha) in controller mode: ' .. tostring((wbtn:IsShown() and wbtn:GetAlpha())))
try('/fcb mode keyboard', slash, 'mode keyboard')
note('wheel header (shown and alpha) in keyboard mode: ' .. tostring((wbtn:IsShown() and wbtn:GetAlpha())))
try('/fcb wheel (keyboard mode)', slash, 'wheel')
try('/fcb mode controller', slash, 'mode controller')

-- bind the wheel to a pad button through the capture frame
try('/fcb bindto wheel', slash, 'bindto wheel')
local cap
for _, f in ipairs(ALL) do if f.__scripts.OnGamePadButtonDown then cap = f end end
try('capture PADLSHOULDER', cap.__scripts.OnGamePadButtonDown, cap, 'PADLSHOULDER')
try('capture keyboard key for wheel (should refuse)', function()
  slash('bindto wheel'); cap.__scripts.OnKeyDown(cap, 'F')
end)

-- wheel flow: press opens, aim, release fires
try('wheel press', function()
  for _, h in ipairs(wbtn.__hooks.PreClick or {}) do h(wbtn, 'LeftButton', true) end
end)
note('wheel open after press: ' .. tostring(wheel:IsShown()))
try('wheel aim (stick up)', wheel.__scripts.OnUpdate, wheel)
note('wheel button type/action after aim: ' .. tostring(wbtn:GetAttribute('type')) .. ' / ' .. tostring(wbtn:GetAttribute('action')))
try('wheel release', function()
  for _, h in ipairs(wbtn.__hooks.PreClick or {}) do h(wbtn, 'LeftButton', false) end
end)
note('wheel open after release: ' .. tostring(wheel:IsShown()) .. ', attrs kept for click: ' .. tostring(wbtn:GetAttribute('type')))
try('wheel post-click', function()
  for _, h in ipairs(wbtn.__hooks.PostClick or {}) do h(wbtn, 'LeftButton', false) end
end)
note('attrs after post-click: ' .. tostring(wbtn:GetAttribute('type')))

try('wheel page click', wpage.__scripts.OnClick, wpage, 'LeftButton')
try('/fcb wheelpage 3', slash, 'wheelpage 3')
note('extras: b29=' .. tostring(G.FlatCrossbarButton29:GetAttribute('action')) .. ' b45=' .. tostring(G.FlatCrossbarButton45:GetAttribute('action')) .. ' b53=' .. tostring(G.FlatCrossbarButton53:GetAttribute('action')) .. ' b60 parent=' .. tostring(G.FlatCrossbarButton60.__parent) .. ', pad45=' .. tostring(FlatCrossbarDB.pad[45]) .. ' pad53=' .. tostring(FlatCrossbarDB.pad[53]) .. ' pad60=' .. tostring(FlatCrossbarDB.pad[60]))
note('groups: ' .. tostring(G.FlatCrossbarGroup1 ~= nil) .. tostring(G.FlatCrossbarGroup4 ~= nil) .. ', button 9 parent = ' .. tostring(G.FlatCrossbarButton9 and G.FlatCrossbarButton9.__parent))
try('/fcb hidebuttons', slash, 'hidebuttons')
try('/fcb showbuttons', slash, 'showbuttons')
try('/fcb helper off', slash, 'helper off')
try('/fcb helper', slash, 'helper')
try('/fcb lock', slash, 'lock')
try('/fcb unlock', slash, 'unlock')
try('/fcb hide', slash, 'hide')
note('group 1 shown after hide: ' .. tostring(G.FlatCrossbarGroup1:IsShown()))
try('/fcb show', slash, 'show')
try('/fcb resetpos', slash, 'resetpos')
try('/fcb macros', slash, 'macros')
try('/fcb macros off', slash, 'macros off')
-- a bag window opens: the pad binds step aside, then come back
try('/fcb mode controller', slash, 'mode controller')
local live = BINDS
G.ContainerFrame1 = newStub('Frame', 'ContainerFrame1')
events.__scripts.OnUpdate(events, 1)
local before = BINDS
note('binds applied while a bag is open: ' .. tostring(BINDS - live))
G.ContainerFrame1:Hide()
events.__scripts.OnUpdate(events, 1)
note('binds applied after the bag closes: ' .. tostring(BINDS - before))
try('/fcb yield add MyBagFrame', slash, 'yield add MyBagFrame')
try('/fcb yield', slash, 'yield')
try('/fcb yield remove MyBagFrame', slash, 'yield remove MyBagFrame')
try('/fcb bindto jump', slash, 'bindto jump')
try('capture PADRSHOULDER for jump', cap.__scripts.OnGamePadButtonDown, cap, 'PADRSHOULDER')
note('jump bind now: ' .. tostring(FlatCrossbarDB.pad.jump) .. ', default others: ' .. tostring(FlatCrossbarDB.pad.dynamic) .. ' ' .. tostring(FlatCrossbarDB.pad.inspect) .. ' ' .. tostring(FlatCrossbarDB.pad.back))
try('global wheel page next', FlatCrossbar_WheelPage, 1)
try('global wheel page prev', FlatCrossbar_WheelPage, -1)
-- the bars fade while LT is held
IsShiftKeyDown = function() return true end
for _ = 1, 40 do G.FlatCrossbarFader.__scripts.OnUpdate(G.FlatCrossbarFader, 0.05) end
note('alpha with LT held: base=' .. string.format('%.2f', G.FlatCrossbarGroup1:GetAlpha()) .. ' LT=' .. string.format('%.2f', G.FlatCrossbarGroup2:GetAlpha()) .. ' RT=' .. string.format('%.2f', G.FlatCrossbarGroup3:GetAlpha()))
IsShiftKeyDown = function() return false end
for _ = 1, 40 do G.FlatCrossbarFader.__scripts.OnUpdate(G.FlatCrossbarFader, 0.05) end
note('alpha with nothing held: base=' .. string.format('%.2f', G.FlatCrossbarGroup1:GetAlpha()) .. ' LT=' .. string.format('%.2f', G.FlatCrossbarGroup2:GetAlpha()))
try('/fcb fade 0.5', slash, 'fade 0.5')
try('/fcb scale auto', slash, 'scale auto')
-- glyphs: the game's icons, then the letter and arrow fallback
local function glyphOf(btn) return btn.Glyph:IsShown(), rawget(btn, '__atlas') end
try('/fcb mode controller (icons)', slash, 'mode controller')
note('glyph shown with icons: ' .. tostring(G.FlatCrossbarButton1.Glyph:IsShown()) .. ', text shown: ' .. tostring(G.FlatCrossbarButton1.GlyphText:IsShown()))
local keep = InputIconTextureSetUtility
InputIconTextureSetUtility = nil
try('/fcb mode keyboard', slash, 'mode keyboard')
try('/fcb mode controller (no icons)', slash, 'mode controller')
note('glyph shown without icons: ' .. tostring(G.FlatCrossbarButton1.Glyph:IsShown()) .. ', text shown: ' .. tostring(G.FlatCrossbarButton1.GlyphText:IsShown()))
InputIconTextureSetUtility = keep
try('/fcb keys on', slash, 'keys')
try('/fcb keys off', slash, 'keys')
try('/fcb padreset', slash, 'padreset')
note('seeded pad binds: b1=' .. tostring(FlatCrossbarDB.pad[1]) .. ' b5=' .. tostring(FlatCrossbarDB.pad[5]) .. ' b13=' .. tostring(FlatCrossbarDB.pad[13]) .. ' b21=' .. tostring(FlatCrossbarDB.pad[21]))
try('/fcb status', slash, 'status')
try('/fcb help', slash, '')
fire('ACTIONBAR_SLOT_CHANGED', 1)
fire('PLAYER_REGEN_DISABLED')
fire('PLAYER_REGEN_ENABLED')
return table.concat(log, string.char(10))
'''

fn = lua.eval('function(h) return load(h) end')(harness)
if isinstance(fn, tuple):
    print('harness load error:', fn[1])
    sys.exit(1)
res = fn(src, 'FlatCrossbar')
print(res if res else '(loaded clean, no log)')
sys.exit(1 if res and ('ERROR' in res) else 0)
