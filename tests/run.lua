--[[
Offline tests for Misspelled. They load the real addon code and the enUS dictionary against a
few stubbed WoW APIs, so they check the logic, not how things look in the game client.

Run from the repository root with Lua 5.1 and Lua BitOp (WoW provides its "bit" library):
	lua5.1 tests/run.lua
Debian/Ubuntu: apt install lua5.1 lua-bitop
--]]

local ok, bitlib = pcall(require, "bit")
if not ok then
	print("Lua BitOp is required (WoW provides it as the global 'bit'): apt install lua-bitop, or luarocks install luabitop")
	os.exit(1)
end
bit = bitlib

-------------------------------------------------------------------------
-- WoW API stubs
-------------------------------------------------------------------------

local SECRET = setmetatable({}, {__tostring = function() return "<secret>" end})
function issecretvalue(value) return value == SECRET end

local noop = function() end

--Any method a test doesn't care about is a no-op.
local function FakeObject(methods)
	local object = {}
	return setmetatable(object, {__index = function(_, key)
		return methods[key] or noop
	end})
end

--Font strings measure every visible character as 7 pixels wide.
local CHAR_WIDTH = 7
local function VisibleText(s)
	s = s:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|cn[^:]+:", ""):gsub("|r", "")
	s = s:gsub("|H.-|h", ""):gsub("|h", "")
	return s
end

local function FakeFontString()
	local text = ""
	return FakeObject({
		SetText = function(_, s) text = s or "" end,
		GetText = function() return text end,
		GetUnboundedStringWidth = function() return #VisibleText(text) * CHAR_WIDTH end,
		GetStringWidth = function() return #VisibleText(text) * CHAR_WIDTH end,
		GetStringHeight = function() return 12 end,
		GetFont = function() return "Fonts\\ARIALN.TTF", 14, "" end,
	})
end

local function FakeFrame(parent)
	local shown = true
	local scripts = {}
	local frame
	frame = FakeObject({
		GetParent = function() return parent end,
		CreateFontString = function() return FakeFontString() end,
		CreateTexture = function() return FakeFrame(frame) end,
		Show = function() shown = true end,
		Hide = function() shown = false end,
		SetShown = function(_, value) shown = value and true or false end,
		IsShown = function() return shown end,
		SetScript = function(_, name, fn) scripts[name] = fn end,
		GetScript = function(_, name) return scripts[name] end,
		GetChecked = function() return false end,
	})
	return frame
end

function CreateFrame(frameType, name, parent, template)
	local frame = FakeFrame(parent)
	if template == "UICheckButtonTemplate" then
		rawset(frame, "Text", FakeFontString())
	end
	if name then _G[name] = frame end
	return frame
end

--A chat edit box that records every write, so the tests can prove typing never changes it.
local function FakeEditBox(name)
	local box = {text = "", cursor = 0, hooks = {}, writes = {}, focus = true}
	local function record(what, ...) box.writes[#box.writes + 1] = {what, ...} end
	local methods = {
		GetName = function() return name end,
		GetText = function() return box.text end,
		GetCursorPosition = function() return box.cursor end,
		GetTextInsets = function() return 15, 13, 0, 0 end,
		GetWidth = function() return 400 end,
		GetLeft = function() return 100 end,
		GetEffectiveScale = function() return 1 end,
		GetFont = function() return "Fonts\\ARIALN.TTF", 14, "" end,
		IsMultiLine = function() return false end,
		HasFocus = function() return box.focus end,
		HookScript = function(_, script, fn)
			box.hooks[script] = box.hooks[script] or {}
			table.insert(box.hooks[script], fn)
		end,
		SetScript = function(_, script) record("SetScript", script) end,
		SetText = function(self, s) record("SetText", s); box.text = s; box.cursor = #s; self:Fire("OnTextChanged") end,
		Insert = function(_, s) record("Insert", s) end,
		SetCursorPosition = function(_, pos) record("SetCursorPosition", pos); box.cursor = pos end,
		HighlightText = function(_, startPos, endPos) record("HighlightText", startPos, endPos) end,
		SetFocus = function() record("SetFocus") end,
		SetAttribute = function(_, key) record("SetAttribute", key) end,
		--What the client does: runs the post-hooks after Blizzard's own handler.
		Fire = function(self, script, ...)
			for _, fn in ipairs(box.hooks[script] or {}) do fn(self, ...) end
		end,
		--The user typing: the client changes the text itself, then OnTextChanged fires.
		Type = function(self, s)
			box.text = box.text .. s
			box.cursor = #box.text
			self:Fire("OnTextChanged", true)
		end,
	}
	return setmetatable(box, {__index = function(_, key) return methods[key] or noop end})
end

local chatFrameEditBox = FakeEditBox("ChatFrame1EditBox")
ChatFrame1EditBox = chatFrameEditBox
NUM_CHAT_WINDOWS = 1
CHAT_FRAMES = {"ChatFrame1"}

local messages = {}
DEFAULT_CHAT_FRAME = {AddMessage = function(_, message) messages[#messages + 1] = message end}
UIParent = FakeFrame()

local originalSendChatMessage = function() end
C_ChatInfo = {SendChatMessage = originalSendChatMessage, InChatMessagingLockdown = function() return false end}
SendChatMessage = originalSendChatMessage

local inCombat = false
function InCombatLockdown() return inCombat end
function IsInGroup() return false end
function IsInInstance() return false, "none" end
LE_PARTY_CATEGORY_INSTANCE = 2

local secureHooks = {}
function hooksecurefunc(tableOrName, key, fn)
	if fn == nil then
		secureHooks[tableOrName] = key
	else
		secureHooks[key] = fn
	end
end
ChatFrameUtil = {ActivateChat = noop}

local timers = {}
C_Timer = {After = function(_, fn) timers[#timers + 1] = fn end}

local menu
MenuUtil = {CreateContextMenu = function(owner, generator)
	menu = {owner = owner, items = {}}
	local root = {
		CreateTitle = function(_, text) table.insert(menu.items, {kind = "title", text = text}) end,
		CreateDivider = function() table.insert(menu.items, {kind = "divider"}) end,
		CreateButton = function(_, text, fn) table.insert(menu.items, {kind = "button", text = text, fn = fn}) end,
	}
	generator(owner, root)
end}

local mouseX = 0
function GetCursorPosition() return mouseX, 0 end

local settingsCategory
Settings = {
	RegisterCanvasLayoutCategory = function(frame, name) settingsCategory = {frame = frame, name = name}; return settingsCategory end,
	RegisterAddOnCategory = noop,
}

C_FriendList = {
	GetNumFriends = function() return 1 end,
	GetFriendInfoByIndex = function() return {name = "Zanthor-Bloodfury"} end,
}
function IsInGuild() return false end
function GetLocale() return "enUS" end
PlaySound = noop
C_AddOns = {GetAddOnMetadata = function() return "test" end}

-- Just enough of LibStub and Ace3 for the addon to load.
local localeStrings = {}
local libs = {
	["AceAddon-3.0"] = {NewAddon = function(_, name)
		return {
			name = name,
			events = {},
			RegisterEvent = function(self, event, method) self.events[event] = method or event end,
			UnregisterEvent = function(self, event) self.events[event] = nil end,
		}
	end},
	["AceLocale-3.0"] = {
		NewLocale = function() return setmetatable({}, {__newindex = function(_, k, v) localeStrings[k] = (v == true) and k or v end}) end,
		GetLocale = function() return setmetatable({}, {__index = function(_, k)
			assert(localeStrings[k], "missing locale string: " .. tostring(k))
			return localeStrings[k]
		end}) end,
	},
	["AceGUI-3.0"] = {},
}
function LibStub(name) return assert(libs[name], "unknown library " .. name) end

-------------------------------------------------------------------------
-- Load the addon, in TOC order
-------------------------------------------------------------------------

local function LoadAddonFile(path)
	local handle = assert(io.open(path, "rb"))
	local source = handle:read("*a"):gsub("^\239\187\191", "")
	handle:close()
	assert(loadstring(source, "@" .. path))()
end

LoadAddonFile("Localization/enUS.lua")
LoadAddonFile("UTF8/utf8data.lua")
LoadAddonFile("UTF8/utf8.lua")
LoadAddonFile("Dict/Dic_enUS.lua")
LoadAddonFile("WordDict.lua")
LoadAddonFile("Misspelled.lua")

Misspelled:OnInitialize()
Misspelled:OnEnable()

-------------------------------------------------------------------------
-- Tests
-------------------------------------------------------------------------

local failures, count = 0, 0
local function test(name, fn)
	count = count + 1
	local passed, err = pcall(fn)
	if passed then
		print("PASS  " .. name)
	else
		failures = failures + 1
		print("FAIL  " .. name .. "\n      " .. tostring(err))
	end
end

local function eq(actual, expected, what)
	if actual ~= expected then
		error(string.format("%s: expected %s, got %s", what or "value", tostring(expected), tostring(actual)), 2)
	end
end

local function words(list)
	local out = {}
	for _, w in ipairs(list) do out[#out + 1] = w.Word .. "@" .. w.StartPos .. "-" .. w.EndPos end
	return table.concat(out, " ")
end

local function Reset(box)
	box.text, box.cursor, box.writes, box.focus = "", 0, {}, true
	box:Fire("OnEscapePressed")
	box.writes = {}
end

test("finds a misspelled word once it's finished", function()
	eq(words(Misspelled:FindMisspelledWords("Hello wrold ")), "wrold@7-11")
end)

test("doesn't check the word still being typed", function()
	eq(words(Misspelled:FindMisspelledWords("Hello wrold")), "")
end)

test("ignores slash commands, upper case words, words with numbers and raid icons", function()
	eq(words(Misspelled:FindMisspelledWords("/cast Flsh Heall ")), "")
	eq(words(Misspelled:FindMisspelledWords("OMG lol1 {sqare} {rt1} ")), "")
end)

test("doesn't check links, colors or textures", function()
	eq(words(Misspelled:FindMisspelledWords("Test |cff71d5ff|Hspell:2061:0|h[Flsh Heall]|h|r badd.")), "badd@49-52")
	eq(words(Misspelled:FindMisspelledWords("test: |cnIQ2:|Hitem:225566::::::::80:258:::::::::|h[Warpd Wing]|h|r badd.")), "badd@69-72")
	eq(words(Misspelled:FindMisspelledWords("|Hplayer:Bob|h[Bbo]|h |TInterface\\Icons\\Foo:0|t hi.")), "")
	eq(words(Misspelled:FindMisspelledWords("Off-hand: |cffa335ee|Hitem:222566::::|h[Vagabnd's Torch |A:Professions-ChatIcon-Quality-Tier5:17:17::1|a]|h|r fine.")), "")
end)

test("hooks chat edit boxes with post-hooks only and leaves SendChatMessage alone", function()
	assert(chatFrameEditBox.hooks.OnTextChanged, "OnTextChanged not hooked")
	assert(chatFrameEditBox.hooks.OnMouseUp, "OnMouseUp not hooked")
	eq(#chatFrameEditBox.writes, 0, "writes to the edit box while hooking")
	eq(C_ChatInfo.SendChatMessage, originalSendChatMessage, "C_ChatInfo.SendChatMessage")
	eq(SendChatMessage, originalSendChatMessage, "SendChatMessage")
	assert(secureHooks.ActivateChat, "ChatFrameUtil.ActivateChat not hooked")
end)

test("typing never writes to the chat edit box", function()
	Reset(chatFrameEditBox)
	for c in ("Hello wrold, how are yuo doing? ok"):gmatch(".") do
		chatFrameEditBox:Type(c)
	end
	eq(#chatFrameEditBox.writes, 0, "writes while typing")
end)

test("underline sits under the misspelled word", function()
	Reset(chatFrameEditBox)
	chatFrameEditBox:Type("Hello wrold ok")
	-- 7px per char, 15px left inset: "wrold" covers characters 7-11
	mouseX = 100 + 15 + 6 * CHAR_WIDTH + 3
	menu = nil
	chatFrameEditBox:Fire("OnMouseUp", "RightButton")
	assert(menu, "right-click on the word didn't open the menu")
	eq(menu.items[1].text, "Suggestions for: wrold", "menu title")

	menu = nil
	mouseX = 100 + 15 + 1 * CHAR_WIDTH -- over "Hello"
	chatFrameEditBox:Fire("OnMouseUp", "RightButton")
	eq(menu, nil, "menu for a correctly spelled word")
end)

test("scroll follows the caret like a single line edit box", function()
	eq(Misspelled.ComputeScroll(0, 100, 200, 372), 0, "text fits")
	eq(Misspelled.ComputeScroll(0, 700, 700, 372), 328, "caret at the end of long text")
	eq(Misspelled.ComputeScroll(328, 500, 700, 372), 328, "caret moves left but stays in view")
	eq(Misspelled.ComputeScroll(328, 100, 700, 372), 100, "caret moves left out of view")
	eq(Misspelled.ComputeScroll(328, 400, 500, 372), 128, "text deleted from the end")
end)

test("picking a suggestion out of combat replaces the word", function()
	Reset(chatFrameEditBox)
	chatFrameEditBox:Type("Hello wrold ok")
	mouseX = 100 + 15 + 7 * CHAR_WIDTH
	chatFrameEditBox:Fire("OnMouseUp", "RightButton")
	local choice
	for _, item in ipairs(menu.items) do
		if item.kind == "button" and item.text == "world" then choice = item end
	end
	assert(choice, "'world' not suggested for 'wrold'")
	choice.fn()
	eq(chatFrameEditBox.text, "Hello world ok", "text")
	eq(chatFrameEditBox.cursor, 12, "cursor after the word and its space")
end)

test("in combat a suggestion selects the word instead of changing the text", function()
	Reset(chatFrameEditBox)
	chatFrameEditBox:Type("Hello wrold ok")
	inCombat = true
	timers = {}
	Misspelled:ReplaceWord(chatFrameEditBox, {Word = "wrold", StartPos = 7, EndPos = 11}, "world")
	inCombat = false
	eq(chatFrameEditBox.text, "Hello wrold ok", "text")
	eq(#chatFrameEditBox.writes, 1, "number of writes")
	eq(chatFrameEditBox.writes[1][1], "HighlightText", "write")
	eq(chatFrameEditBox.writes[1][2], 6, "selection start")
	eq(chatFrameEditBox.writes[1][3], 11, "selection end")
	eq(#timers, 1, "hint timer")
end)

test("chat lockdown also blocks replacing text", function()
	Reset(chatFrameEditBox)
	chatFrameEditBox:Type("Hello wrold ok")
	C_ChatInfo.InChatMessagingLockdown = function() return true end
	Misspelled:ReplaceWord(chatFrameEditBox, {Word = "wrold", StartPos = 7, EndPos = 11}, "world")
	C_ChatInfo.InChatMessagingLockdown = function() return false end
	eq(chatFrameEditBox.text, "Hello wrold ok", "text")
end)

test("keeps the capital letter of the misspelled word", function()
	Reset(chatFrameEditBox)
	chatFrameEditBox:Type("Wrold hi")
	Misspelled:ReplaceWord(chatFrameEditBox, {Word = "Wrold", StartPos = 1, EndPos = 5}, "world")
	eq(chatFrameEditBox.text, "World hi", "text")
end)

test("secret text is left alone", function()
	Reset(chatFrameEditBox)
	chatFrameEditBox.text = SECRET
	chatFrameEditBox:Fire("OnTextChanged", true)
	chatFrameEditBox:Fire("OnMouseUp", "RightButton")
	eq(#chatFrameEditBox.writes, 0, "writes")
end)

test("friend names, with realm or surname, are valid words", function()
	eq(words(Misspelled:FindMisspelledWords("hi Zanthor and Bloodfury ok")), "")
	eq(Misspelled:IsFriend("Zanthor"), true, "IsFriend")
end)

test("Ignore All and Add to Dictionary take effect right away", function()
	eq(words(Misspelled:FindMisspelledWords("zzqx ok")), "zzqx@1-4")
	Misspelled:IgnoreWord("zzqx")
	eq(words(Misspelled:FindMisspelledWords("zzqx ok")), "")

	Misspelled_DB.UserDict = {}
	Misspelled:AddToUserDict("Qwzzle")
	eq(words(Misspelled:FindMisspelledWords("Qwzzle ok")), "")
	assert(Misspelled_DB.UserDict.Qwzzle, "not saved in the user dictionary")
end)

test("options panel is registered with the Settings panel", function()
	assert(settingsCategory, "not registered")
	eq(settingsCategory.name, "Misspelled", "category name")
end)

print(string.format("\n%d of %d passed", count - failures, count))
os.exit(failures == 0 and 0 or 1)
