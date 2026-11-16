local DeathList = LibStub("AceAddon-3.0"):NewAddon("DeathList", "AceConsole-3.0", "AceEvent-3.0")
local AceConfig = LibStub("AceConfig-3.0")
local AceConfigDialog = LibStub("AceConfigDialog-3.0")
local AceConfigRegistry = LibStub("AceConfigRegistry-3.0")

local SKULL_ICON = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_8"
local ICON_SIZE = 24
local KILL_WINDOW = 20      -- seconds: a player who hit you this shortly before you died counts as your killer
local REALERT_AFTER = 300   -- seconds: warn about the same player again only after they were gone this long
local ALERT_SOUND = 8959    -- raid warning sound

local issecretvalue = issecretvalue or function() return false end

-- Classic clients let addons read the combat log. Retail and WoW Forever don't
-- (only Blizzard's own code can read it there), so on those the killer comes
-- from the death recap, and listed players are only spotted by nameplate,
-- target or mouseover.
local useCombatLog = type(CombatLogGetCurrentEventInfo) == "function"
local TYPE_PLAYER = COMBATLOG_OBJECT_TYPE_PLAYER or 0x00000400
local REACTION_HOSTILE = COMBATLOG_OBJECT_REACTION_HOSTILE or 0x00000040
local DAMAGE_EVENTS = {
    SWING_DAMAGE = true,
    RANGE_DAMAGE = true,
    SPELL_DAMAGE = true,
    SPELL_PERIODIC_DAMAGE = true,
}

local playerGUID
local lastHitName, lastHitTime  -- last enemy player who damaged you (combat log clients)
local lastRecapStamp            -- newest death recap entry already read (recap clients)
local lastKiller                -- the player who killed you last, for /dl add
local lastSeen = {}             -- key -> GetTime() when that listed player was last seen
local plateKeys = {}            -- nameplate unit -> key of the listed player on it
local keyCache = {}             -- combat log name -> key (false = invalid name)
local debugMode = false
local options

local defaults = {
    profile = {
        -- key (lower case "name-realm", Forever "first last") -> { name = "Name-Realm", addedDate = time(), note = "" }
        killList = {},
        alertSound = true,
        alertChat = true,
        alertScreen = true,
        nameplateIcon = true,
        askAfterDeath = true,
    },
}

--------------------------------------------------------------------------------
-- Names
--------------------------------------------------------------------------------

-- WoW Forever: every character has a surname ("First Last") and the full name is unique
-- in the whole region. UnitName returns the surname where other clients return the
-- realm, and the realm the game reports there is a server layer ("CAMWOWEU5Realm2PvP")
-- that can change, so names are kept without a realm.
local uniqueNames = (WOW_PROJECT_CAMELOT ~= nil and WOW_PROJECT_ID == WOW_PROJECT_CAMELOT)
    or (type(RegionalUniqueNamesEnabled) == "function" and RegionalUniqueNamesEnabled() == true)
local separators = Constants and Constants.CharacterNameSeparatorConsts
local SURNAME_SEP = separators and separators.CHARACTERNAME_SURNAME_SEPARATOR or " "
local NAME_EXAMPLE = uniqueNames and "First Last" or "Name-Realm"

local function NormalizeRealm(realm)
    return (realm:gsub("[%s%-]", ""))
end

local function PlayerRealm()
    return GetNormalizedRealmName() or NormalizeRealm(GetRealmName() or "")
end

-- "Name" or "Name-Realm" -> lookup key (lower case) and display name ("Name-Realm").
-- Names never contain "-" but realms can ("Azjol-Nerub"), so the first "-" splits
-- them. Forever: "First Last", "First Last-Realm" or "First-Last" -> "First Last".
local function MakeKey(name, realm)
    name = strtrim(name or "")
    if uniqueNames then
        local first, rest = name:match("^(.-)%-(.+)$")
        if first then
            first = strtrim(first)
            if first:find(SURNAME_SEP, 1, true) then
                name = first -- a realm after the full name
            else
                name = first .. SURNAME_SEP .. strtrim(rest:match("^[^%-]*"))
            end
        end
        name = strtrim(name)
        if name == "" then return nil end
        return strlower(name), name
    end
    if not realm or realm == "" then
        local base, rest = name:match("^(.-)%-(.+)$")
        if base then
            name, realm = strtrim(base), rest
        end
    end
    if name == "" then return nil end
    realm = (realm and realm ~= "") and NormalizeRealm(realm) or PlayerRealm()
    local display = name .. "-" .. realm
    return strlower(display), display
end

local function UnitKey(unit)
    if not UnitIsPlayer(unit) then return nil end
    local name, realm = UnitName(unit)
    if not name or issecretvalue(name) or issecretvalue(realm) or name == UNKNOWNOBJECT then
        return nil
    end
    if uniqueNames then
        -- the second value is the surname
        if realm and realm ~= "" and not name:find(SURNAME_SEP, 1, true) then
            name = name .. SURNAME_SEP .. realm
        end
        return MakeKey(name)
    end
    return MakeKey(name, realm)
end

local function TargetName()
    if not UnitIsPlayer("target") then return nil end
    local isMe = UnitIsUnit("target", "player")
    if issecretvalue(isMe) or isMe then return nil end
    local _, display = UnitKey("target")
    return display
end

local function SortedKeys(list)
    local keys = {}
    for key in pairs(list) do
        keys[#keys + 1] = key
    end
    table.sort(keys)
    return keys
end

function DeathList:Debug(text)
    if debugMode then
        self:Print("|cff888888" .. text .. "|r")
    end
end

--------------------------------------------------------------------------------
-- The list
--------------------------------------------------------------------------------

function DeathList:AddToList(input, note)
    local key, display = MakeKey(input)
    if not key then
        self:Print("Invalid player name.")
        return
    end
    note = note and strtrim(note) or ""
    local list = self.db.profile.killList
    local entry = list[key]
    if entry then
        if note ~= "" then
            entry.note = note
            self:Print("Note for " .. entry.name .. " saved.")
            self:RebuildListOptions()
        else
            self:Print(entry.name .. " is already on your list.")
        end
        return
    end
    list[key] = { name = display, addedDate = time(), note = note }
    self:Print("|cffff0000" .. display .. "|r added to your death list.")
    self:RebuildListOptions()
    -- Mark them on screen right away, but don't warn about someone you just added.
    self:ScanNameplates(key)
    if UnitExists("target") and UnitKey("target") == key then
        self:Spotted(key, true)
    end
end

function DeathList:RemoveFromList(input)
    local key = MakeKey(input)
    local list = self.db.profile.killList
    if not key or not list[key] then
        self:Print((input or "?") .. " is not on your list.")
        return
    end
    local name = list[key].name
    list[key] = nil
    lastSeen[key] = nil
    self:Print("|cff00ff00" .. name .. "|r removed from your death list.")
    self:RebuildListOptions()
    self:ScanNameplates()
end

function DeathList:PrintList()
    local list = self.db.profile.killList
    local keys = SortedKeys(list)
    if #keys == 0 then
        self:Print("Your death list is empty.")
        return
    end
    self:Print("Death list:")
    for _, key in ipairs(keys) do
        local entry = list[key]
        local note = (entry.note and entry.note ~= "") and (" - " .. entry.note) or ""
        self:Print(format("  %s (added %s)%s", entry.name, date("%Y-%m-%d", entry.addedDate), note))
    end
end

-- Old versions stored killList["Name-Realm"] = { addedDate = ... }.
function DeathList:MigrateList()
    local list = self.db.profile.killList
    local old = {}
    for k, v in pairs(list) do
        if type(v) ~= "table" or not v.name then
            old[k] = v
        end
    end
    for k, v in pairs(old) do
        list[k] = nil
        local key, display = MakeKey(k)
        if key and not list[key] then
            local addedDate = type(v) == "table" and v.addedDate or time()
            list[key] = { name = display, addedDate = addedDate, note = "" }
        end
    end

    -- Forever: earlier test versions kept a realm ("First Last-Realm") or took the
    -- surname for one ("First-Last").
    if uniqueNames then
        local moved = {}
        for k, v in pairs(list) do
            local key, display = MakeKey(v.name)
            if key and key ~= k then
                moved[k] = { key = key, display = display }
            end
        end
        for k, m in pairs(moved) do
            local v = list[k]
            list[k] = nil
            local other = list[m.key]
            if other then
                -- the same player twice: keep the older date and both notes
                other.addedDate = math.min(other.addedDate or time(), v.addedDate or time())
                local note = v.note or ""
                if note ~= "" and note ~= other.note then
                    other.note = (other.note and other.note ~= "") and (other.note .. "; " .. note) or note
                end
            else
                v.name = m.display
                list[m.key] = v
            end
        end
    end
end

function DeathList:ExportList()
    local list = self.db.profile.killList
    local lines = {}
    for _, key in ipairs(SortedKeys(list)) do
        local entry = list[key]
        lines[#lines + 1] = format("%s;%s;%s", entry.name, date("%Y-%m-%d", entry.addedDate), entry.note or "")
    end
    return table.concat(lines, "\n")
end

-- One player per line: "Name-Realm;2026-01-31;note". Date and note are optional.
-- Players already on the list are left as they are.
function DeathList:ImportList(text)
    local list = self.db.profile.killList
    local added = 0
    for line in (text or ""):gmatch("[^\r\n]+") do
        local name, day, note = line:match("^([^;]*);?([^;]*);?(.*)$")
        local key, display = MakeKey(name)
        if key and not list[key] then
            local y, m, d = (day or ""):match("^%s*(%d+)%-(%d+)%-(%d+)")
            local addedDate = y and time({ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12 }) or time()
            list[key] = { name = display, addedDate = addedDate, note = strtrim(note or "") }
            added = added + 1
        end
    end
    self:Print(format("%d player(s) imported.", added))
    if added > 0 then
        self:RebuildListOptions()
        self:ScanNameplates()
    end
end

--------------------------------------------------------------------------------
-- Spotting listed players
--------------------------------------------------------------------------------

local function ScreenWarning(text)
    local color = ChatTypeInfo and ChatTypeInfo["RAID_WARNING"]
    if RaidWarningUtil and RaidWarningUtil.AddMessage then
        RaidWarningUtil.AddMessage(text, color)
    elseif RaidNotice_AddMessage and RaidWarningFrame then
        RaidNotice_AddMessage(RaidWarningFrame, text, color)
    end
end

function DeathList:Alert(entry)
    local p = self.db.profile
    if p.alertSound then
        PlaySound(ALERT_SOUND, "Master")
    end
    if p.alertScreen then
        ScreenWarning(format("|T%s:0|t %s is nearby!", SKULL_ICON, entry.name))
    end
    if p.alertChat then
        local note = (entry.note and entry.note ~= "") and (" (" .. entry.note .. ")") or ""
        self:Print("|cffff0000" .. entry.name .. "|r is nearby!" .. note)
    end
end

-- Warns once when a listed player shows up. While they stay around (or come back
-- within REALERT_AFTER) there is no new warning.
function DeathList:Spotted(key, quiet)
    local entry = self.db.profile.killList[key]
    if not entry then return end
    local now = GetTime()
    local last = lastSeen[key]
    lastSeen[key] = now
    if quiet or (last and now - last < REALERT_AFTER) then return end
    self:Alert(entry)
end

function DeathList:CheckUnit(unit)
    local key, display = UnitKey(unit)
    local entry = key and self.db.profile.killList[key]
    if entry then
        entry.name = display -- the game's spelling, in case it was typed in lower case
        self:Spotted(key)
    end
end

local function PlateUnit(plate)
    return plate.namePlateUnitToken or plate.unitToken or (plate.UnitFrame and plate.UnitFrame.unit)
end

local function ShowIcon(plate)
    if not plate.DeathListIcon then
        local icon = plate:CreateTexture(nil, "OVERLAY")
        icon:SetTexture(SKULL_ICON)
        icon:SetSize(ICON_SIZE, ICON_SIZE)
        icon:SetPoint("BOTTOM", plate, "TOP", 0, 0)
        plate.DeathListIcon = icon
    end
    plate.DeathListIcon:Show()
end

-- Nameplates are reused for other units, so the skull is set or cleared every time.
function DeathList:UpdatePlate(unit, quietKey)
    local key, display = UnitKey(unit)
    local entry = key and self.db.profile.killList[key]
    if not entry then key = nil end
    local alreadyShown = key ~= nil and plateKeys[unit] == key
    plateKeys[unit] = key

    local plate = C_NamePlate.GetNamePlateForUnit(unit)
    if plate then
        if entry and self.db.profile.nameplateIcon then
            ShowIcon(plate)
        elseif plate.DeathListIcon then
            plate.DeathListIcon:Hide()
        end
    end

    if entry and not alreadyShown then
        entry.name = display
        self:Spotted(key, key == quietKey)
    end
end

function DeathList:ScanNameplates(quietKey)
    for _, plate in ipairs(C_NamePlate.GetNamePlates() or {}) do
        local unit = PlateUnit(plate)
        if unit then
            self:UpdatePlate(unit, quietKey)
        elseif plate.DeathListIcon then
            plate.DeathListIcon:Hide()
        end
    end
end

function DeathList:NAME_PLATE_UNIT_ADDED(_, unit)
    self:UpdatePlate(unit)
end

function DeathList:NAME_PLATE_UNIT_REMOVED(_, unit)
    local key = plateKeys[unit]
    if key then
        lastSeen[key] = GetTime() -- they were around until now
    end
    plateKeys[unit] = nil
    local plate = C_NamePlate.GetNamePlateForUnit(unit)
    if plate and plate.DeathListIcon then
        plate.DeathListIcon:Hide()
    end
end

-- A nameplate can appear before the game knows the player's name ("Unknown").
function DeathList:UNIT_NAME_UPDATE(_, unit)
    if type(unit) == "string" and unit:find("^nameplate") then
        self:UpdatePlate(unit)
    end
end

function DeathList:PLAYER_TARGET_CHANGED()
    self:CheckUnit("target")
end

function DeathList:UPDATE_MOUSEOVER_UNIT()
    self:CheckUnit("mouseover")
end

--------------------------------------------------------------------------------
-- Combat log (classic clients): last attacker, and listed players fighting nearby
--------------------------------------------------------------------------------

local function IsPlayerFlags(flags)
    return flags and bit.band(flags, TYPE_PLAYER) ~= 0
end

function DeathList:SpotCombatLogName(name)
    local key = keyCache[name]
    if key == nil then
        key = MakeKey(name) or false
        keyCache[name] = key
    end
    if key and self.db.profile.killList[key] then
        self:Spotted(key)
    end
end

function DeathList:COMBAT_LOG_EVENT_UNFILTERED()
    local _, subevent, _, sourceGUID, sourceName, sourceFlags, _, destGUID, destName, destFlags = CombatLogGetCurrentEventInfo()

    if destGUID == playerGUID and sourceGUID ~= playerGUID and DAMAGE_EVENTS[subevent] and sourceName
        and IsPlayerFlags(sourceFlags) and bit.band(sourceFlags, REACTION_HOSTILE) ~= 0 then
        lastHitName, lastHitTime = sourceName, GetTime()
    end

    if next(self.db.profile.killList) then
        if sourceName and IsPlayerFlags(sourceFlags) then
            self:SpotCombatLogName(sourceName)
        end
        if destName and IsPlayerFlags(destFlags) then
            self:SpotCombatLogName(destName)
        end
    end
end

--------------------------------------------------------------------------------
-- Who killed you
--------------------------------------------------------------------------------

-- Retail and Forever: the death recap lists the last hits before you died,
-- the killing blow first.
function DeathList:ReadKillerFromRecap()
    if not (C_DeathRecap and C_DeathRecap.GetRecapEvents) then
        self:Debug("This client has no death recap.")
        return nil
    end
    local ok, events = pcall(C_DeathRecap.GetRecapEvents)
    if not ok or type(events) ~= "table" or not events[1] then
        self:Debug("The death recap is empty.")
        return nil
    end

    local newest = events[1].timestamp
    if issecretvalue(newest) or type(newest) ~= "number" then
        newest = nil
    end
    if newest and newest == lastRecapStamp then
        self:Debug("The death recap is still the one from your last death.")
        return nil
    end
    lastRecapStamp = newest

    for i, e in ipairs(events) do
        local guid, name, stamp, hidden = e.sourceGUID, e.sourceName, e.timestamp, e.hideCaster
        if issecretvalue(guid) or issecretvalue(name) or issecretvalue(stamp) or issecretvalue(hidden) then
            self:Debug(format("Recap hit %d: hidden by the game.", i))
        else
            self:Debug(format("Recap hit %d: %s (%s)", i, tostring(name), tostring(guid)))
            if newest and type(stamp) == "number" and newest - stamp > KILL_WINDOW then
                break
            end
            if not hidden and type(name) == "string" and type(guid) == "string"
                and guid ~= playerGUID and guid:find("^Player%-") then
                return name
            end
        end
    end
    self:Debug("No player in the death recap.")
    return nil
end

function DeathList:PLAYER_DEAD()
    if useCombatLog then
        local killer = lastHitName and GetTime() - lastHitTime <= KILL_WINDOW and lastHitName or nil
        lastHitName = nil
        self:Debug(killer and ("Last hit by " .. killer .. ".")
            or ("No enemy player hit you in the last " .. KILL_WINDOW .. " seconds."))
        self:OnKilled(killer)
    else
        -- give the game a moment to fill in the recap
        C_Timer.After(0.5, function()
            self:OnKilled(self:ReadKillerFromRecap())
        end)
    end
end

function DeathList:OnKilled(name)
    lastKiller = nil
    local key, display = MakeKey(name)
    if not key then return end
    lastKiller = display

    -- In battlegrounds and arenas you die to players all the time; /dl add still works there.
    local _, instanceType = IsInInstance()
    if instanceType == "pvp" or instanceType == "arena" then return end

    local entry = self.db.profile.killList[key]
    if entry then
        self:Print("|cffff0000" .. entry.name .. "|r killed you again.")
    elseif self.db.profile.askAfterDeath then
        StaticPopup_Show("DEATHLIST_ADD_KILLER", display, nil, display)
    else
        self:Print("You were killed by |cffff0000" .. display .. "|r. Type |cff00ff00/dl add|r to put them on your list.")
    end
end

local function PopupEditBox(dialog)
    return (dialog.GetEditBox and dialog:GetEditBox()) or dialog.editBox or dialog.EditBox
end

StaticPopupDialogs["DEATHLIST_ADD_KILLER"] = {
    text = "You were killed by |cffff0000%s|r.\nAdd them to your death list? You can write down why.",
    button1 = "Add",
    button2 = "No",
    hasEditBox = true,
    maxLetters = 200,
    OnAccept = function(dialog, data)
        local editBox = PopupEditBox(dialog)
        DeathList:AddToList(data, editBox and editBox:GetText())
    end,
    EditBoxOnEnterPressed = function(editBox, data)
        DeathList:AddToList(data, editBox:GetText())
        StaticPopup_Hide("DEATHLIST_ADD_KILLER")
    end,
    EditBoxOnEscapePressed = function()
        StaticPopup_Hide("DEATHLIST_ADD_KILLER")
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

--------------------------------------------------------------------------------
-- Slash commands
--------------------------------------------------------------------------------

local USAGE = "/dl add [name][, note] - adds the name, else your target, else your last killer. "
    .. "/dl remove name, /dl list, /dl debug, /dl (options)"

function DeathList:SlashCommand(input)
    local cmd, rest = strtrim(input or ""):match("^(%S*)%s*(.-)$")
    cmd = strlower(cmd or "")

    if cmd == "add" then
        -- Forever names contain a space, so a note is split off with a comma.
        local who, note = rest:match("^([^,]*),%s*(.-)$")
        who = strtrim(who or rest)
        if who == "" then
            who = TargetName() or lastKiller
        end
        if who then
            self:AddToList(who, note)
        else
            self:Print("Target a player or type a name: /dl add " .. NAME_EXAMPLE)
        end
    elseif cmd == "remove" then
        if rest ~= "" then
            self:RemoveFromList(rest)
        else
            self:Print("Usage: /dl remove " .. NAME_EXAMPLE)
        end
    elseif cmd == "list" then
        self:PrintList()
    elseif cmd == "debug" then
        debugMode = not debugMode
        self:Print(debugMode and "Debug output on. /dl debug turns it off." or "Debug output off.")
    elseif cmd == "help" then
        self:Print(USAGE)
    else
        AceConfigDialog:Open("DeathList")
    end
end

--------------------------------------------------------------------------------
-- Options
--------------------------------------------------------------------------------

local function Toggle(key, name, desc, order)
    return {
        type = "toggle",
        name = name,
        desc = desc,
        order = order,
        get = function() return DeathList.db.profile[key] end,
        set = function(_, value)
            DeathList.db.profile[key] = value
            if key == "nameplateIcon" then
                DeathList:ScanNameplates()
            end
        end,
    }
end

function DeathList:BuildOptions()
    options = {
        name = "DeathList",
        type = "group",
        args = {
            description = {
                type = "description",
                name = "Keeps a list of players who killed you and warns you when one of them is near.\n",
                order = 1,
            },
            warnHeader = { type = "header", name = "Warnings", order = 10 },
            alertScreen = Toggle("alertScreen", "Screen warning", "Show a warning in the middle of the screen.", 11),
            alertSound = Toggle("alertSound", "Sound", "Play a sound.", 12),
            alertChat = Toggle("alertChat", "Chat message", "Write a line in the chat, with your note.", 13),
            nameplateIcon = Toggle("nameplateIcon", "Skull on nameplate", "Show a skull over their nameplate.", 14),
            askAfterDeath = Toggle("askAfterDeath", "Ask after death",
                "When a player kills you, ask if you want to add them.", 15),
            addHeader = { type = "header", name = "Add Player", order = 20 },
            addInput = {
                type = "input",
                name = "Player name",
                desc = uniqueNames and "First and last name."
                    or "Name or Name-Realm. Without a realm, your own realm is used.",
                order = 21,
                width = "double",
                get = function() return "" end,
                set = function(_, value)
                    if value and strtrim(value) ~= "" then
                        DeathList:AddToList(value)
                    end
                end,
            },
            addTarget = {
                type = "execute",
                name = "Add Target",
                order = 22,
                func = function()
                    local name = TargetName()
                    if name then
                        DeathList:AddToList(name)
                    else
                        DeathList:Print("Your target is not a player.")
                    end
                end,
            },
            listHeader = { type = "header", name = "Your List", order = 30 },
            -- one row per player is added by RebuildListOptions (orders 100+)
            exportGroup = {
                type = "group",
                inline = true,
                name = "Export / Import",
                order = 100000,
                args = {
                    text = {
                        type = "input",
                        name = "",
                        desc = "Copy this text to keep or share your list. Paste a list here and click Accept to add those players.",
                        multiline = 8,
                        width = "full",
                        order = 1,
                        get = function() return DeathList:ExportList() end,
                        set = function(_, value) DeathList:ImportList(value) end,
                    },
                },
            },
        },
    }
    self:RebuildListOptions()
end

function DeathList:RebuildListOptions()
    if not options then return end
    local args = options.args
    for key in pairs(args) do
        if key:find("^row") then
            args[key] = nil
        end
    end

    local list = self.db.profile.killList
    local keys = SortedKeys(list)
    for i, key in ipairs(keys) do
        local entry = list[key]
        local order = 100 + i * 3
        -- full width, so every player starts a new line
        args["rowName" .. i] = {
            type = "description",
            name = format("|cffff6060%s|r   |cff888888added %s|r", entry.name, date("%Y-%m-%d", entry.addedDate)),
            fontSize = "medium",
            width = "full",
            order = order,
        }
        args["rowNote" .. i] = {
            type = "input",
            name = "Note",
            width = "double",
            order = order + 1,
            get = function() return entry.note or "" end,
            set = function(_, value) entry.note = strtrim(value or "") end,
        }
        args["rowRemove" .. i] = {
            type = "execute",
            name = "Remove",
            width = "half",
            order = order + 2,
            func = function() DeathList:RemoveFromList(entry.name) end,
        }
    end
    if #keys == 0 then
        args.rowEmpty = {
            type = "description",
            name = "|cff888888Your death list is empty.|r",
            order = 100,
        }
    end

    AceConfigRegistry:NotifyChange("DeathList")
end

--------------------------------------------------------------------------------
-- Ace3 lifecycle
--------------------------------------------------------------------------------

function DeathList:OnInitialize()
    self.db = LibStub("AceDB-3.0"):New("DeathListDB", defaults, true)
    self:MigrateList()
    self:BuildOptions()
    AceConfig:RegisterOptionsTable("DeathList", options)
    AceConfigDialog:AddToBlizOptions("DeathList", "DeathList")
    self:RegisterChatCommand("dl", "SlashCommand")
    self:RegisterChatCommand("deathlist", "SlashCommand")
end

function DeathList:OnEnable()
    playerGUID = UnitGUID("player")
    self:RegisterEvent("PLAYER_DEAD")
    self:RegisterEvent("PLAYER_TARGET_CHANGED")
    self:RegisterEvent("UPDATE_MOUSEOVER_UNIT")
    self:RegisterEvent("NAME_PLATE_UNIT_ADDED")
    self:RegisterEvent("NAME_PLATE_UNIT_REMOVED")
    self:RegisterEvent("UNIT_NAME_UPDATE")
    if useCombatLog then
        self:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
    end
    self:ScanNameplates()
end
