UnrealFX = UnrealFX or {}
UnrealFX.settings = UnrealFX.settings or {}
UnrealFX.logFileName = "UnrealFX"
UnrealFX.prefixName = "UnrealFX"
UnrealFX.prefixColor = { 255, 0, 0 }
UnrealFX.helpHeaderColor = { 255, 220, 120 }
UnrealFX.helpCommandColor = { 160, 220, 255 }

-- World-attached announcer FX (TGA overlays). SCT-style: one window per victim so
-- multi-kills can show on every killed target at once, not only the current target.
UnrealFX.FX_WINDOW_PREFIX = "UnrealFXWindow"
UnrealFX.FX_TEMPLATE = "UnrealFXTemplate"
-- Texture pixel size must match files/*.tga (456x256 RLE).
UnrealFX.FX_TEX_W = 456
UnrealFX.FX_TEX_H = 256
UnrealFX.FX_DISP_W = 456
UnrealFX.FX_DISP_H = 256
UnrealFX.FX_SCALE_DEFAULT = 0.75
UnrealFX.FX_SCALE_MIN = 0.25
UnrealFX.FX_SCALE_MAX = 1.5
UnrealFX.FX_MAX_INSTANCES = 12
-- FX timeline: snappy grow/spin/spiral intro -> shake/pulse -> brief hold -> fade.
-- All intro motions share the same duration; spin rotates texture, spiral orbits position.
UnrealFX.FX_GROW_SECONDS = 0.45
UnrealFX.FX_SPIN_GROW_SECONDS = UnrealFX.FX_GROW_SECONDS
UnrealFX.FX_SHAKE_SECONDS = 0.65
UnrealFX.FX_HOLD_SECONDS = 0.25
UnrealFX.FX_FADE_SECONDS = 1.0
UnrealFX.FX_SHAKE_AMP = 20
UnrealFX.FX_SHAKE_FREQ = 32
UnrealFX.FX_SHAKE_VERT = 0.55
UnrealFX.FX_PULSE_FREQ = 14
UnrealFX.FX_PULSE_DELTA = 0.14
-- Relative to getFxDisplaySize() / settings.fxScale. Grow ends at 1.0 before shake.
UnrealFX.FX_PUNCH_SCALE_START = 0.78
UnrealFX.FX_PUNCH_SCALE_PEAK = 1.06
UnrealFX.FX_PUNCH_GROW_FRAC = 0.6
-- Spin-grow: start rotated by this many degrees (sign = direction), ease to 0.
UnrealFX.FX_SPIN_DEGREES = 720
-- Spiral-grow: orbit anchor into center (no texture spin; radius in display pixels at scale 1).
UnrealFX.FX_SPIRAL_RADIUS = 56
UnrealFX.FX_SPIRAL_TURNS = 2.0
-- Motions randomly chosen per FX unless opts.motion / /ufx fx <key> grow|spin|spiral.
UnrealFX.FX_MOTIONS = { "grow", "spin", "spiral" }
-- Chat-bubble style projection height for MoveWindowToWorldObject (stock uses 1.0).
UnrealFX.FX_ATTACH_HEIGHT = 1.0
UnrealFX.fxActive = UnrealFX.fxActive or {} -- [1..n] = { win, attachedId, key, phase, t, image }
UnrealFX.fxFree = UnrealFX.fxFree or {} -- recycled instances (never DestroyWindow - crashes WAR)
UnrealFX.fxPoolReady = UnrealFX.fxPoolReady or false
UnrealFX.fxLastKey = nil
-- name (wstring, ^suffix stripped, lowercased) -> worldObjNum seen via combat events / targets
UnrealFX.worldObjByName = UnrealFX.worldObjByName or {}
-- Sticky hostile: target often clears on death before the kill chat line arrives.
UnrealFX.lastHostile = UnrealFX.lastHostile or { id = 0, name = L"" }
-- Target snapshots. Only OnPlayerTargetUpdated refreshes TargetInfo (UpdateFromClient);
-- everything else reads these reused tables. hp = -1 when unknown.
UnrealFX.targetSnap = UnrealFX.targetSnap or {
    hostile = { id = 0, key = L"", name = L"", hp = -1, t = 0 },
    mouseover = { id = 0, key = L"", name = L"", hp = -1, t = 0 },
}
-- Recent hit-target entity ids (WORLD_OBJ_COMBAT_EVENT): fixed ring, see hitRing below.
UnrealFX.FX_RECENT_WORLD_OBJ_MAX = 96

-- Fixed-size id -> time rings: parallel arrays, no per-entry tables. Setting a known
-- id updates it in place; a new id overwrites the oldest slot.
local function newIdTimeRing(cap)
    return { cap = cap, head = 0, count = 0, ids = {}, times = {}, slotById = {} }
end
local function idRingSet(ring, id, t)
    local slot = ring.slotById[id]
    if slot then
        ring.times[slot] = t
        return slot
    end
    local head = (ring.head % ring.cap) + 1
    ring.head = head
    local old = ring.ids[head]
    if old and ring.slotById[old] == head then
        ring.slotById[old] = nil
    end
    ring.ids[head] = id
    ring.times[head] = t
    ring.slotById[id] = head
    if ring.count < ring.cap then
        ring.count = ring.count + 1
    end
    return head
end
local function idRingGet(ring, id)
    local slot = ring.slotById[id]
    if slot then
        return ring.times[slot]
    end
    return nil
end
-- k = 1 is the newest insert. Returns id, time.
local function idRingAt(ring, k)
    local slot = ((ring.head - k) % ring.cap) + 1
    return ring.ids[slot], ring.times[slot]
end
UnrealFX._idRing = { new = newIdTimeRing, set = idRingSet, get = idRingGet, at = idRingAt }
-- Per-id time a target slot reported 0% HP (from PLAYER_TARGET_UPDATED snapshots).
local zeroHpRing = newIdTimeRing(32)
UnrealFX.zeroHpRing = zeroHpRing
-- Per-id time of WORLD_OBJ_XP_GAINED / WORLD_OBJ_RENOWN_GAINED (never the player id).
local rewardRing = newIdTimeRing(32)
UnrealFX.rewardRing = rewardRing
-- Recent combat-hit ids (any hit, incl. heals). times = last event; extra parallel
-- arrays: dmgT (last damage/miss), armT (last damage = soft-arm), name/key cache and
-- nameT (last GetNameForObject call, so at most one lookup per id per second).
local hitRing = newIdTimeRing(UnrealFX.FX_RECENT_WORLD_OBJ_MAX)
hitRing.dmgT = {}
hitRing.armT = {}
hitRing.name = {}
hitRing.key = {}
hitRing.nameT = {}
UnrealFX.hitRing = hitRing
UnrealFX.FX_NAME_LOOKUP_SECONDS = 1.0
-- Kill-time scan caps (GetNameForObject probes per resolve).
UnrealFX.FX_KILL_PROBE_CAP = 48

-- Remember a combat-hit id; returns its ring slot. No allocation once the ring is full.
local function touchCombatHit(id, now)
    local isNew = hitRing.slotById[id] == nil
    local slot = idRingSet(hitRing, id, now)
    if isNew then
        hitRing.dmgT[slot] = false
        hitRing.armT[slot] = false
        hitRing.name[slot] = false
        hitRing.key[slot] = false
        hitRing.nameT[slot] = false
    end
    if id > (UnrealFX.nameScanMaxSeen or 0) then
        UnrealFX.nameScanMaxSeen = id
    end
    return slot
end

-- Last damage/miss time on id (nil if unknown). Used to drop ids hit after a kill.
function UnrealFX.getLastDamageTime(id)
    local slot = hitRing.slotById[tonumber(id) or 0]
    if slot then
        return hitRing.dmgT[slot] or nil
    end
    return nil
end

-- Damage pairing rings: fixed slots, entry tables created once per slot and reused.
local function newEntryRing(cap)
    return { cap = cap, head = 0, count = 0, items = {} }
end
local function entryRingNext(ring)
    local head = (ring.head % ring.cap) + 1
    ring.head = head
    local entry = ring.items[head]
    if entry == nil then
        entry = {}
        ring.items[head] = entry
    end
    if ring.count < ring.cap then
        ring.count = ring.count + 1
    end
    return entry
end
-- k = 1 is the newest entry.
local function entryRingAt(ring, k)
    if k < 1 or k > ring.count then
        return nil
    end
    return ring.items[((ring.head - k) % ring.cap) + 1]
end
UnrealFX._entryRing = { new = newEntryRing, next = entryRingNext, at = entryRingAt }

-- Target slot lists, built once on first use (TargetInfo may load after this file).
local victimNameSlots = nil
local function getVictimNameSlots()
    if victimNameSlots == nil then
        victimNameSlots = {
            (TargetInfo and TargetInfo.HOSTILE_TARGET) or "selfhostiletarget",
            "mouseovertarget",
            (TargetInfo and TargetInfo.FRIENDLY_TARGET) or "selffriendlytarget",
        }
    end
    return victimNameSlots
end
-- No client API maps player name -> entity id. GetNameForObject can reverse-lookup
-- ids within ~180 yards; we budget-scan known seeds + a local id window.
UnrealFX.FX_NAME_SCAN_BUDGET = 120
UnrealFX.FX_NAME_SCAN_RADIUS = 24
UnrealFX.FX_PENDING_SECONDS = 0.55
UnrealFX.FX_PENDING_SCAN_PER_FRAME = 48
-- Soft-attach (hidden) on combat hits while the world object still exists - kill chat
-- often arrives after the corpse is gone; AttachWindowToWorldObject then cannot bind.
UnrealFX.FX_ARM_SECONDS = 8.0
-- After a kill FX plays on a world id, ignore that id for re-arm / re-FX briefly.
UnrealFX.FX_DONE_SECONDS = 8.0
-- Pair WORLD_OBJ_COMBAT_EVENT (id+amount) with YOUR_HITS combat chat (name+amount).
-- On kill, score several recent pairs and pick the best match for the victim name.
UnrealFX.FX_DAMAGE_PAIR_SECONDS = 3.0
UnrealFX.FX_DAMAGE_PAIR_MAX = 24
UnrealFX.FX_DAMAGE_PAIR_CHAT_CANDIDATES = 8
-- Kill-line ability vs the paired hit's ability (combat log or event abilityId).
UnrealFX.FX_ABILITY_MATCH_BONUS = 3000
UnrealFX.FX_ABILITY_MISMATCH_PENALTY = 1500
-- Combat-log ability vs event abilityId ability on the same pair.
UnrealFX.FX_PAIR_ABILITY_AGREE_BONUS = 500
UnrealFX.FX_PAIR_ABILITY_DISAGREE_PENALTY = 800
-- Fixed rings of reused { id, amount, t, used } / { key, amount, t, used } entries.
UnrealFX.recentDamageEvents = newEntryRing(UnrealFX.FX_DAMAGE_PAIR_MAX)
UnrealFX.recentDamageChats = newEntryRing(UnrealFX.FX_DAMAGE_PAIR_MAX)
UnrealFX.fxClock = UnrealFX.fxClock or 0
UnrealFX.fxDoneWorldIds = UnrealFX.fxDoneWorldIds or {}
UnrealFX.pendingFxQueue = UnrealFX.pendingFxQueue or {}
UnrealFX.nameScanMaxSeen = UnrealFX.nameScanMaxSeen or 0
-- Texture name must match <Texture name=...> in UnrealFX.xml.
-- `sounds` lists log/playback keywords that should show this art (file-name based).
-- BEGIN FX_TEXTURES (sync_fx_assets.py)
UnrealFX.FX_TEXTURES = {
    {
        key = "annihilation",
        texture = "UnrealFX_annihilation",
        label = "annihilation",
        sounds = { "annihilation" },
    },
    {
        key = "bloodbath",
        texture = "UnrealFX_bloodbath",
        label = "bloodbath",
        sounds = { "bloodbath" },
    },
    {
        key = "defeat",
        texture = "UnrealFX_defeat",
        label = "defeat",
        sounds = { "defeat" },
    },
    {
        key = "denied",
        texture = "UnrealFX_denied",
        label = "denied",
        sounds = { "denied" },
    },
    {
        key = "dominating",
        texture = "UnrealFX_dominating",
        label = "dominating",
        sounds = { "dominating" },
    },
    {
        key = "doublekill",
        texture = "UnrealFX_doublekill",
        label = "doublekill",
        sounds = { "doublekill" },
    },
    {
        key = "erradication",
        texture = "UnrealFX_erradication",
        label = "erradication",
        sounds = { "erradication" },
    },
    {
        key = "extermination",
        texture = "UnrealFX_extermination",
        label = "extermination",
        sounds = { "extermination" },
    },
    {
        key = "firstblood",
        texture = "UnrealFX_firstblood",
        label = "firstblood",
        sounds = { "firstblood" },
    },
    {
        key = "godlike",
        texture = "UnrealFX_godlike",
        label = "godlike",
        sounds = { "godlike" },
    },
    {
        key = "headshot",
        texture = "UnrealFX_headshot",
        label = "headshot",
        sounds = { "headshot" },
    },
    {
        key = "holyshit",
        texture = "UnrealFX_holyshit",
        label = "holyshit",
        sounds = { "holyshit" },
    },
    {
        key = "killingspree",
        texture = "UnrealFX_killingspree",
        label = "killingspree",
        sounds = { "killingspree" },
    },
    {
        key = "ludicrous",
        texture = "UnrealFX_ludicrous",
        label = "ludicrous",
        sounds = { "ludicrous" },
    },
    {
        key = "megakill",
        texture = "UnrealFX_megakill",
        label = "megakill",
        sounds = { "megakill" },
    },
    {
        key = "monsterkill",
        texture = "UnrealFX_monsterkill",
        label = "monsterkill",
        sounds = { "monsterkill", "monsterkill1", "monsterkill2" },
    },
    {
        key = "multikill",
        texture = "UnrealFX_multikill",
        label = "multikill",
        sounds = { "multikill" },
    },
    {
        key = "rampage",
        texture = "UnrealFX_rampage",
        label = "rampage",
        sounds = { "rampage" },
    },
    {
        key = "slaughter",
        texture = "UnrealFX_slaughter",
        label = "slaughter",
        sounds = { "slaughter" },
    },
    {
        key = "triplekill",
        texture = "UnrealFX_triplekill",
        label = "triplekill",
        sounds = { "triplekill" },
    },
    {
        key = "ultrakill",
        texture = "UnrealFX_ultrakill",
        label = "ultrakill",
        sounds = { "ultrakill" },
    },
    {
        key = "unstoppable",
        texture = "UnrealFX_unstoppable",
        label = "unstoppable",
        sounds = { "unstoppable" },
    },
    {
        key = "wickedsick",
        texture = "UnrealFX_wickedsick",
        label = "wickedsick",
        sounds = { "wickedsick" },
    },
}
-- END FX_TEXTURES
-- Career-gated pull-ability alerts. At most one entry can ever arm per
-- session (a character has exactly one career), so the ability event
-- handler stays a single table lookup plus one integer compare.
UnrealFX.pullAlertConfigs = {
    embrace = {
        settingKey = "terribleEmbraceAlertsEnabled",
        label = "Terrible Embrace alerts",
        careerKey = "MARAUDER",
        careerName = "Marauder",
        abilityId = 8410,
        soundKeyword = "getoverhere",
    },
    fetch = {
        settingKey = "fetchAlertsEnabled",
        label = "Fetch! alerts",
        careerKey = "WHITE_LION",
        careerName = "White Lion",
        abilityId = 9178,
        soundKeyword = "getoverhere",
    },
}
UnrealFX.PULL_ALERT_MIN_LEVEL = 40

-- Kill streak state (formerly the PlayerName / KillSpree / FirstBloodTime globals).
UnrealFX.playerNameKey = L""   -- normalizeUnitName(GameData.Player.name), set in Initialize
UnrealFX.killSpree = 0
UnrealFX.lastKillClock = 0     -- UnrealFX.fxClock of the previous kill (monotonic)
-- Victims in the current <5s kill streak: { name=, worldId=, fxShown= } (duplicate NPC names allowed).
UnrealFX.killSpreeVictims = UnrealFX.killSpreeVictims or {}
-- World ids that already received kill FX in the current streak (no re-stamp).
UnrealFX.killSpreeFxWorldIds = UnrealFX.killSpreeFxWorldIds or {}
-- Recent combat hits with names - needed when many identical PVE mobs die.
-- Fixed-size ring buffer: entry tables are reused, one live entry per world id.
-- Read newest-first with UnrealFX.getRecentNamedHit(k) for k = 1..getRecentNamedHitCount().
local NAMED_HIT_CAP = 96
local namedHitRing = {}       -- slot (1..NAMED_HIT_CAP) -> entry table
local namedHitHead = 0        -- slot of the newest entry
local namedHitCount = 0
local namedHitSlotById = {}   -- world id -> slot of its live entry

-- Normalized own name (no ^suffix, lowercase). Retries if the name was not yet
-- populated when Initialize ran.
function UnrealFX.getPlayerNameKey()
    local key = UnrealFX.playerNameKey
    if key == nil or key == L"" then
        if GameData and GameData.Player then
            key = UnrealFX.normalizeUnitName(GameData.Player.name)
        else
            key = L""
        end
        UnrealFX.playerNameKey = key
    end
    return key
end

function UnrealFX.Initialize()
    UnrealFX.playerNameKey = L""
    UnrealFX.getPlayerNameKey()
    TextLogCreate(UnrealFX.logFileName, 18000)
    TextLogSetEnabled(UnrealFX.logFileName, true)
    TextLogSetIncrementalSaving(UnrealFX.logFileName, true, StringToWString("logs/"..UnrealFX.logFileName..".log"))

    RegisterEventHandler(TextLogGetUpdateEventId("Combat"), "UnrealFX.OnCombatHappened");
    -- PVE "You have slain ...!" lines land on the Chat log (KILLS_DEATH_YOURS), not Combat/RvR.
    RegisterEventHandler(TextLogGetUpdateEventId("Chat"), "UnrealFX.OnChatKillHappened");
    RegisterEventHandler(SystemData.Events.SCENARIO_SHOW_JOIN_PROMPT, "UnrealFX.AnnounceScenarioPop")

    if SystemData and SystemData.Events then
        if SystemData.Events.CITY_CAPTURE_SHOW_JOIN_PROMPT then
            RegisterEventHandler(SystemData.Events.CITY_CAPTURE_SHOW_JOIN_PROMPT, "UnrealFX.AnnounceScenarioPop")
        end
        if SystemData.Events.CITY_CAPTURE_SHOW_LOW_LEVEL_JOIN_PROMPT then
            RegisterEventHandler(SystemData.Events.CITY_CAPTURE_SHOW_LOW_LEVEL_JOIN_PROMPT, "UnrealFX.AnnounceScenarioPop")
        end
        if SystemData.Events.INFO_ALERT then
            RegisterEventHandler(SystemData.Events.INFO_ALERT, "UnrealFX.OnInfoAlertEvent")
        end
        if SystemData.Events.APPLICATION_ONE_BUTTON_DIALOG then
            RegisterEventHandler(SystemData.Events.APPLICATION_ONE_BUTTON_DIALOG, "UnrealFX.OnApplicationOneButtonDialogEvent")
        end
        if SystemData.Events.APPLICATION_TWO_BUTTON_DIALOG then
            RegisterEventHandler(SystemData.Events.APPLICATION_TWO_BUTTON_DIALOG, "UnrealFX.OnApplicationTwoButtonDialogEvent")
        end
        if SystemData.Events.ALL_MODULES_INITIALIZED then
            RegisterEventHandler(SystemData.Events.ALL_MODULES_INITIALIZED, "UnrealFX.OnModulesInitialized")
        end
        if SystemData.Events.WORLD_OBJ_COMBAT_EVENT then
            RegisterEventHandler(SystemData.Events.WORLD_OBJ_COMBAT_EVENT, "UnrealFX.OnWorldObjCombatEvent")
        end
        if SystemData.Events.WORLD_OBJ_XP_GAINED then
            RegisterEventHandler(SystemData.Events.WORLD_OBJ_XP_GAINED, "UnrealFX.OnWorldObjXpGained")
        end
        if SystemData.Events.WORLD_OBJ_RENOWN_GAINED then
            RegisterEventHandler(SystemData.Events.WORLD_OBJ_RENOWN_GAINED, "UnrealFX.OnWorldObjRenownGained")
        end
        if SystemData.Events.PLAYER_TARGET_UPDATED then
            RegisterEventHandler(SystemData.Events.PLAYER_TARGET_UPDATED, "UnrealFX.OnPlayerTargetUpdated")
        end
    end

    UnrealFX.TryHookDialogManager()
    UnrealFX.TryRegisterReadyCheckPacket()
    if UnrealFX.RegisterSlashCommands() then
        UnrealFX.printLoginLine()
    end
    UnrealFX.updatePullAlertWatch()
    -- Seed snapshots from TargetInfo's cached slots (no client refresh here).
    UnrealFX.snapshotTargets(false)
end

-- One chat line per login. Printed from Initialize when /ufx is ready, otherwise
-- after ALL_MODULES_INITIALIZED once the LibSlash retry has run.
-- The version lives only in UnrealFX.mod (<UiMod version="...">); read it from
-- the client's module list so there is a single place to bump.
function UnrealFX.getVersion()
    if UnrealFX._version then
        return UnrealFX._version
    end
    local version = "?"
    if type(ModulesGetData) == "function" then
        local ok, mods = pcall(ModulesGetData)
        if ok and type(mods) == "table" then
            for _, mod in ipairs(mods) do
                if type(mod) == "table" and mod.name == "UnrealFX" and mod.version ~= nil then
                    version = tostring(mod.version)
                    break
                end
            end
        end
    end
    if version ~= "?" then
        UnrealFX._version = version
    end
    return version
end

function UnrealFX.printLoginLine()
    if UnrealFX._loginLinePrinted then
        return
    end
    UnrealFX._loginLinePrinted = true
    local hint = " Type /ufx for commands."
    if not UnrealFX._slashRegistered then
        hint = " Install LibSlash for /ufx commands."
    end
    UnrealFX.chatPrint("v" .. UnrealFX.getVersion() .. " loaded." .. hint)
end

function UnrealFX.collectUsedSpreeWorldIds()
    local used = {}
    local list = UnrealFX.killSpreeVictims
    if type(list) ~= "table" then
        return used
    end
    for i = 1, #list do
        local entry = list[i]
        local id = 0
        if type(entry) == "table" then
            id = tonumber(entry.worldId) or 0
        end
        if id ~= 0 then
            used[id] = true
        end
    end
    return used
end

function UnrealFX.isPlayerRvRFlagged()
    if type(GameData) ~= "table" or type(GameData.Player) ~= "table" then
        return false
    end
    return GameData.Player.rvrZoneFlagged == true or GameData.Player.rvrPermaFlagged == true
end

-- Player pets/summons are usually PvP-flagged with no career line; wild NPCs are not.
function UnrealFX.isLikelyPlayerPetMeta(meta)
    if type(meta) ~= "table" then
        return false
    end
    if meta.isPvP ~= true then
        return false
    end
    -- Players have a career line when flagged; pets/summons do not.
    return (tonumber(meta.career) or 0) == 0
end

function UnrealFX.shouldSkipPveVictim(victimName)
    local want = UnrealFX.normalizeUnitName(victimName)
    if want == L"" then
        return false
    end

    local last = UnrealFX.lastHostile
    if type(last) == "table"
        and UnrealFX.namesEqual(last.name, want)
        and UnrealFX.isLikelyPlayerPetMeta(last)
    then
        return true
    end

    for k = 1, namedHitCount do
        local hit = UnrealFX.getRecentNamedHit(k)
        if hit and hit.id ~= 0 and hit.key == want and UnrealFX.isLikelyPlayerPetMeta(hit) then
            return true
        end
    end
    return false
end

function UnrealFX.rememberRecentNamedHit(worldObjNum, name, meta, key)
    local id = tonumber(worldObjNum) or 0
    key = key or UnrealFX.normalizeUnitName(name)
    if id == 0 or key == L"" then
        return
    end
    -- Keep a single newest entry per world id so target polling cannot bury combat hits.
    local oldSlot = namedHitSlotById[id]
    if oldSlot then
        local old = namedHitRing[oldSlot]
        if old then
            old.id = 0
        end
        namedHitSlotById[id] = nil
    end

    namedHitHead = (namedHitHead % NAMED_HIT_CAP) + 1
    local entry = namedHitRing[namedHitHead]
    if entry == nil then
        entry = {}
        namedHitRing[namedHitHead] = entry
    elseif entry.id ~= 0 and namedHitSlotById[entry.id] == namedHitHead then
        namedHitSlotById[entry.id] = nil
    end
    if namedHitCount < NAMED_HIT_CAP then
        namedHitCount = namedHitCount + 1
    end

    entry.id = id
    entry.key = key
    entry.t = UnrealFX.fxClock or 0
    entry.consumed = false
    entry.fromCombat = false
    entry.isPvP = nil
    entry.isNPC = nil
    entry.career = 0
    entry.unitType = nil
    if type(meta) == "table" then
        entry.fromCombat = meta.fromCombat == true
        entry.isPvP = meta.isPvP == true
        entry.isNPC = meta.isNPC
        entry.career = tonumber(meta.career) or 0
        entry.unitType = meta.unitType
    end
    namedHitSlotById[id] = namedHitHead
end

function UnrealFX.getRecentNamedHitCount()
    return namedHitCount
end

-- k = 1 is the newest entry. Entries with id == 0 were superseded; skip them.
function UnrealFX.getRecentNamedHit(k)
    if k < 1 or k > namedHitCount then
        return nil
    end
    return namedHitRing[((namedHitHead - k) % NAMED_HIT_CAP) + 1]
end

function UnrealFX.getPlayerWorldObjNum()
    if GameData and GameData.Player then
        return tonumber(GameData.Player.worldObjNum) or 0
    end
    return 0
end

-- Current hostile entity id (any HP) from the last PLAYER_TARGET_UPDATED snapshot.
function UnrealFX.getCurrentHostileWorldId()
    return UnrealFX.targetSnap.hostile.id or 0
end

-- Living current hostile (HP > 0). resolveWorldObjForKill prefers other candidates
-- so AOE same-name kills are not stamped onto a still-living target.
function UnrealFX.getLivingHostileWorldId()
    local snap = UnrealFX.targetSnap.hostile
    -- Unknown HP (-1): do not treat as living-avoid (targeted kill path needs the id).
    if snap.id ~= 0 and snap.hp > 0 then
        return snap.id
    end
    return 0
end

-- Time the id was last seen at 0% HP in a target slot, or nil.
function UnrealFX.getZeroHpTime(id)
    return idRingGet(zeroHpRing, tonumber(id) or 0)
end

-- XP / renown floating-text events: (hitTargetObjectNumber, pointsGained). Stock uses
-- them for the reward text above an object; when that object is not the player it is
-- kill evidence for that id. The player's own id is never stored.
function UnrealFX.onWorldObjReward(kind, hitTargetObjectNumber, pointsGained)
    local id = tonumber(hitTargetObjectNumber) or 0
    if id == 0 or id == UnrealFX.getPlayerWorldObjNum() then
        return false
    end
    idRingSet(rewardRing, id, UnrealFX.fxClock or 0)
    return true
end

function UnrealFX.OnWorldObjXpGained(hitTargetObjectNumber, pointsGained)
    UnrealFX.onWorldObjReward("xp", hitTargetObjectNumber, pointsGained)
end

function UnrealFX.OnWorldObjRenownGained(hitTargetObjectNumber, pointsGained)
    UnrealFX.onWorldObjReward("renown", hitTargetObjectNumber, pointsGained)
end

function UnrealFX.getRewardTime(id)
    id = tonumber(id) or 0
    if id == 0 or id == UnrealFX.getPlayerWorldObjNum() then
        return nil
    end
    return idRingGet(rewardRing, id)
end

-- Kill-time evidence window for 0% HP / XP / renown on a candidate id.
UnrealFX.FX_KILL_EVIDENCE_SECONDS = 3.0
UnrealFX.FX_REWARD_EVIDENCE_BONUS = 1200
UnrealFX.FX_ZERO_HP_EVIDENCE_BONUS = 800

-- Bonus for a candidate id that just gave XP/renown or reported 0% HP.
function UnrealFX.killEvidenceBonus(id, now)
    id = tonumber(id) or 0
    if id == 0 or id == UnrealFX.getPlayerWorldObjNum() then
        return 0
    end
    now = now or (UnrealFX.fxClock or 0)
    local win = UnrealFX.FX_KILL_EVIDENCE_SECONDS or 3.0
    local bonus = 0
    local rt = idRingGet(rewardRing, id)
    if rt and (now - rt) <= win then
        bonus = bonus + (UnrealFX.FX_REWARD_EVIDENCE_BONUS or 1200)
    end
    local zt = idRingGet(zeroHpRing, id)
    if zt and (now - zt) <= win then
        bonus = bonus + (UnrealFX.FX_ZERO_HP_EVIDENCE_BONUS or 800)
    end
    return bonus
end

-- When the kill victim id is unknown / projection fails: current hostile, else self.
function UnrealFX.resolveFxDisplayFallbackWorldId(excludeId)
    excludeId = tonumber(excludeId) or 0
    local hid = UnrealFX.getCurrentHostileWorldId()
    if hid ~= 0 and hid ~= excludeId then
        return hid
    end
    local selfId = UnrealFX.getSelfWorldObjNum()
    if selfId ~= 0 and selfId ~= excludeId then
        return selfId
    end
    return 0
end

function UnrealFX.consumeCombatHitWorldId(worldId)
    worldId = tonumber(worldId) or 0
    if worldId == 0 then
        return
    end
    local slot = namedHitSlotById[worldId]
    local hit = slot and namedHitRing[slot]
    if hit and hit.id == worldId then
        hit.consumed = true
    end
end

-- Soft-arm still uses Attach (hidden). Playing kill FX follows stock chat bubbles:
-- MoveWindowToWorldObject each tick (no Attach), which avoids sticky top-left binds.
function UnrealFX.rebindFxToWorldObject(win, worldId)
    worldId = tonumber(worldId) or 0
    if not win or not DoesWindowExist(win) or worldId == 0 then
        return false
    end
    if type(DetachWindowFromWorldObject) == "function" then
        pcall(DetachWindowFromWorldObject, win, worldId)
    end
    if type(AttachWindowToWorldObject) ~= "function" then
        return false
    end
    AttachWindowToWorldObject(win, worldId)
    if type(ForceUpdateWorldObjectWindow) == "function" then
        pcall(ForceUpdateWorldObjectWindow, worldId, win)
    end
    return true
end

-- ChatManager.UpdateChatBubbles: one-shot project. Cheap; max FX_MAX_INSTANCES / frame.
function UnrealFX.projectFxToWorldObject(win, worldId)
    worldId = tonumber(worldId) or 0
    if not win or not DoesWindowExist(win) or worldId == 0 then
        return false
    end
    if type(MoveWindowToWorldObject) == "function" then
        local height = UnrealFX.FX_ATTACH_HEIGHT or 1.0
        pcall(MoveWindowToWorldObject, win, worldId, height)
        return true
    end
    -- Older clients without Move: fall back to Attach rebind.
    return UnrealFX.rebindFxToWorldObject(win, worldId)
end

-- Failed / off-screen world binds park the window at screen origin (same GroupIcons
-- stuck-icon symptom). See docs/api/world-object-windows.md.
function UnrealFX.isFxWindowStuckAtOrigin(win)
    if not win or not DoesWindowExist(win) or type(WindowGetScreenPosition) ~= "function" then
        return false
    end
    local x, y = WindowGetScreenPosition(win)
    x = tonumber(x)
    y = tonumber(y)
    if x == nil or y == nil then
        return false
    end
    return x >= 0 and x < 2 and y >= 0 and y < 2
end

-- Drop any Attach and project onto toWorldId instead.
function UnrealFX.fallbackFxProjectToWorldId(win, fromWorldId, toWorldId)
    toWorldId = tonumber(toWorldId) or 0
    if toWorldId == 0 or not win or not DoesWindowExist(win) then
        return 0
    end
    fromWorldId = tonumber(fromWorldId) or 0
    if type(DetachWindowFromWorldObject) == "function" then
        if fromWorldId ~= 0 then
            pcall(DetachWindowFromWorldObject, win, fromWorldId)
        end
        if toWorldId ~= fromWorldId then
            pcall(DetachWindowFromWorldObject, win, toWorldId)
        end
    end
    if not UnrealFX.projectFxToWorldObject(win, toWorldId) then
        return 0
    end
    return toWorldId
end

-- Stuck / unknown id: current hostile first, then self.
function UnrealFX.fallbackFxProjectToHostileOrSelf(win, fromWorldId)
    local toId = UnrealFX.resolveFxDisplayFallbackWorldId(fromWorldId)
    if toId == 0 then
        return 0
    end
    return UnrealFX.fallbackFxProjectToWorldId(win, fromWorldId, toId)
end

-- Drop any Attach and project onto the local player instead.
function UnrealFX.fallbackFxProjectToSelf(win, fromWorldId)
    return UnrealFX.fallbackFxProjectToWorldId(win, fromWorldId, UnrealFX.getSelfWorldObjNum())
end

function UnrealFX.markFxDoneWorldId(worldId)
    worldId = tonumber(worldId) or 0
    if worldId == 0 then
        return
    end
    local done = UnrealFX.fxDoneWorldIds
    if type(done) ~= "table" then
        done = {}
        UnrealFX.fxDoneWorldIds = done
    end
    done[worldId] = UnrealFX.fxClock or 0
end

function UnrealFX.isFxDoneWorldId(worldId)
    worldId = tonumber(worldId) or 0
    if worldId == 0 then
        return false
    end
    local done = UnrealFX.fxDoneWorldIds
    if type(done) ~= "table" then
        return false
    end
    local stamped = done[worldId]
    if stamped == nil then
        return false
    end
    local age = (UnrealFX.fxClock or 0) - (tonumber(stamped) or 0)
    if age > (UnrealFX.FX_DONE_SECONDS or 8.0) then
        done[worldId] = nil
        return false
    end
    return true
end

function UnrealFX.isUsableVictimWorldId(id, usedIds, avoidId)
    id = tonumber(id) or 0
    if id == 0 then
        return false
    end
    if usedIds and usedIds[id] then
        return false
    end
    avoidId = tonumber(avoidId) or 0
    if avoidId ~= 0 and id == avoidId then
        return false
    end
    -- Never attach kill FX to self (incoming SCT trackers use the player wid).
    if id == UnrealFX.getPlayerWorldObjNum() then
        return false
    end
    if UnrealFX.isFxDoneWorldId(id) then
        return false
    end
    return true
end

-- Ability names compared as trimmed lowercase narrow strings; nil when unknown.
function UnrealFX.normalizeAbilityKey(ability)
    if ability == nil or ability == L"" or ability == "" then
        return nil
    end
    local s = string.lower(UnrealFX.toNarrow(ability))
    s = string.gsub(s, "^%s+", "")
    s = string.gsub(s, "%s+$", "")
    if s == "" then
        return nil
    end
    return s
end

-- abilityId -> normalized name (false when GetAbilityData has none). Bounded by the
-- abilities that actually hit something.
local abilityKeyById = {}
function UnrealFX.getAbilityKeyById(abilityId)
    abilityId = tonumber(abilityId) or 0
    if abilityId <= 0 or type(GetAbilityData) ~= "function" then
        return nil
    end
    local cached = abilityKeyById[abilityId]
    if cached == nil then
        cached = false
        local ok, data = pcall(GetAbilityData, abilityId)
        if ok and type(data) == "table" then
            cached = UnrealFX.normalizeAbilityKey(data.name) or false
        end
        abilityKeyById[abilityId] = cached
    end
    return cached or nil
end

-- Outgoing damage event: world id + absolute damage amount (+ ability when the event
-- carries an abilityId). Reuses a ring slot.
function UnrealFX.rememberRecentDamageEvent(worldId, amount, abilityKey)
    worldId = tonumber(worldId) or 0
    amount = math.abs(tonumber(amount) or 0)
    if worldId == 0 or amount == 0 or worldId == UnrealFX.getPlayerWorldObjNum() then
        return
    end
    local entry = entryRingNext(UnrealFX.recentDamageEvents)
    entry.id = worldId
    entry.amount = amount
    entry.ability = abilityKey or false
    entry.t = UnrealFX.fxClock or 0
    entry.used = false
end

-- Combat YOUR_HITS / PET_HITS: "Your X hits Target for N damage."
-- Returns targetKey, amount, abilityKey, petName (narrow, pet lines only).
-- No table: this runs on every hit line.
function UnrealFX.parseOutgoingDamageCombatLog(msg, isPetHit)
    local s = UnrealFX.toNarrow(msg)
    if s == "" then
        return nil
    end
    local ability, targetName, damageStr, pet
    if isPetHit then
        pet, ability, targetName, damageStr =
            string.match(s, "^Your (.+)'s (.+) critically hits (.+) for (%d+) damage")
        if targetName == nil then
            pet, ability, targetName, damageStr =
                string.match(s, "^Your (.+)'s (.+) hits (.+) for (%d+) damage")
        end
    else
        ability, targetName, damageStr =
            string.match(s, "^Your (.+) critically hits (.+) for (%d+) damage")
        if targetName == nil then
            ability, targetName, damageStr =
                string.match(s, "^Your (.+) hits (.+) for (%d+) damage")
        end
    end
    if targetName == nil then
        return nil
    end
    local amount = tonumber(damageStr) or 0
    if amount == 0 then
        return nil
    end
    return UnrealFX.normalizeUnitName(targetName), amount, UnrealFX.normalizeAbilityKey(ability), pet
end

-- Pet name learned from "Your <Pet>'s ..." hit lines; key is rebuilt only on change.
UnrealFX.learnedPetName = nil
UnrealFX.learnedPetKey = L""

function UnrealFX.learnPetName(pet)
    if pet == nil or pet == "" or pet == UnrealFX.learnedPetName then
        return
    end
    UnrealFX.learnedPetName = pet
    UnrealFX.learnedPetKey = UnrealFX.normalizeUnitName(pet)
end

-- Normalized names the player's pet may appear under in kill lines.
function UnrealFX.isPlayerPetKey(killerKey)
    if killerKey == nil or killerKey == L"" then
        return false
    end
    local pet = GameData and GameData.Player and GameData.Player.Pet
    local petName = pet and pet.name
    if petName ~= nil and petName ~= L"" and UnrealFX.normalizeUnitName(petName) == killerKey then
        return true
    end
    return UnrealFX.learnedPetKey ~= L"" and UnrealFX.learnedPetKey == killerKey
end

-- Pet kill lines only count when we (or the pet) hit that victim recently, so another
-- player's same-named pet does not trigger our FX.
UnrealFX.FX_PET_KILL_RECENT_HIT_SECONDS = 10

function UnrealFX.hasRecentDamageChatFor(key, maxAge)
    local ring = UnrealFX.recentDamageChats
    local now = UnrealFX.fxClock or 0
    for k = 1, ring.count do
        local entry = entryRingAt(ring, k)
        if (now - (entry.t or 0)) > maxAge then
            return false
        end
        if entry.key == key then
            return true
        end
    end
    return false
end

function UnrealFX.rememberRecentDamageChat(nameOrKey, amount, abilityKey)
    local key = UnrealFX.normalizeUnitName(nameOrKey)
    amount = math.abs(tonumber(amount) or 0)
    if key == L"" or amount == 0 then
        return
    end
    local entry = entryRingNext(UnrealFX.recentDamageChats)
    entry.key = key
    entry.amount = amount
    entry.ability = abilityKey or false
    entry.t = UnrealFX.fxClock or 0
    entry.used = false
end

function UnrealFX.onOutgoingDamageCombatLog(filterType)
    local filters = SystemData and SystemData.ChatLogFilters
    if not filters then
        return
    end
    local isPet = filterType == filters.PET_HITS
    if not isPet and filterType ~= filters.YOUR_HITS then
        return
    end
    local num = TextLogGetNumEntries("Combat") - 1
    if num < 0 then
        return
    end
    local _, _, msg = TextLogGetEntry("Combat", num)
    local key, amount, abilityKey, pet = UnrealFX.parseOutgoingDamageCombatLog(msg, isPet)
    if not key then
        return
    end
    if pet then
        UnrealFX.learnPetName(pet)
    end
    UnrealFX.rememberRecentDamageChat(key, amount, abilityKey)
end

-- Score a chat line (name+amount) against a damage event (id+amount). Higher is better.
-- killAbility: normalized ability from the kill line (nil when unknown). Returns nil if
-- incompatible. Unknown abilities leave the score unchanged.
function UnrealFX.scoreDamagePair(chat, event, wantKey, now, killAbility)
    if type(chat) ~= "table" or type(event) ~= "table" then
        return nil
    end
    if chat.used or event.used then
        return nil
    end
    local amount = tonumber(chat.amount) or 0
    if amount == 0 or amount ~= (tonumber(event.amount) or 0) then
        return nil
    end
    local chatKey = chat.key
    if wantKey and wantKey ~= L"" and chatKey ~= wantKey then
        return nil
    end
    local id = tonumber(event.id) or 0
    if id == 0 then
        return nil
    end

    now = now or (UnrealFX.fxClock or 0)
    local chatAge = now - (tonumber(chat.t) or 0)
    local eventAge = now - (tonumber(event.t) or 0)
    local timeSkew = math.abs((tonumber(chat.t) or 0) - (tonumber(event.t) or 0))
    local maxAge = UnrealFX.FX_DAMAGE_PAIR_SECONDS or 3.0
    if chatAge > maxAge or eventAge > maxAge then
        return nil
    end

    local score = 1000
    -- Prefer fresher chat lines and events that landed near that chat.
    score = score - (chatAge * 40) - (eventAge * 15) - (timeSkew * 80)

    local nameHit = UnrealFX.probeWorldObjName(id, chatKey)
    if nameHit ~= 0 then
        score = score + 2000
    elseif type(GetNameForObject) == "function" then
        local ok, n = pcall(GetNameForObject, id)
        if ok and n and n ~= L"" and not UnrealFX.namesEqual(n, chatKey) then
            -- Amount matched a different named entity - reject.
            return nil
        end
    end

    local chatAbility = chat.ability or nil
    local eventAbility = event.ability or nil
    if chatAbility and eventAbility then
        if chatAbility == eventAbility then
            score = score + (UnrealFX.FX_PAIR_ABILITY_AGREE_BONUS or 500)
        else
            score = score - (UnrealFX.FX_PAIR_ABILITY_DISAGREE_PENALTY or 800)
        end
    end
    score = score + UnrealFX.killEvidenceBonus(id, now)

    local pairAbility = chatAbility or eventAbility
    if killAbility and pairAbility then
        if pairAbility == killAbility then
            score = score + (UnrealFX.FX_ABILITY_MATCH_BONUS or 3000)
        else
            score = score - (UnrealFX.FX_ABILITY_MISMATCH_PENALTY or 1500)
        end
    end

    return score
end

-- Among recent damage chats for victimName, pick the best amount-matched event id.
-- Skip the living current hostile (HP > 0) - that is still targeted, not the corpse.
function UnrealFX.findBestDamagePairWorldId(victimName, usedIds, killAbility)
    local want = UnrealFX.normalizeUnitName(victimName)
    if want == L"" then
        return 0
    end
    local chats = UnrealFX.recentDamageChats
    local events = UnrealFX.recentDamageEvents

    local now = UnrealFX.fxClock or 0
    local maxChats = UnrealFX.FX_DAMAGE_PAIR_CHAT_CANDIDATES or 8
    local livingTargetId = UnrealFX.getLivingHostileWorldId()
    local bestScore, bestEvent, bestChat = nil, nil, nil
    local considered = 0

    for ci = 1, chats.count do
        local chat = entryRingAt(chats, ci)
        if chat and not chat.used and chat.key == want then
            considered = considered + 1
            if considered > maxChats then
                break
            end
            for ei = 1, events.count do
                local event = entryRingAt(events, ei)
                local score = UnrealFX.scoreDamagePair(chat, event, want, now, killAbility)
                if score ~= nil then
                    local id = tonumber(event.id) or 0
                    -- Living current target: keep searching for another pair.
                    if livingTargetId ~= 0 and id == livingTargetId then
                        id = 0
                    end
                    if id ~= 0
                        and UnrealFX.isUsableVictimWorldId(id, usedIds, 0)
                        and (bestScore == nil or score > bestScore)
                    then
                        bestScore = score
                        bestEvent = event
                        bestChat = chat
                    end
                end
            end
        end
    end

    if not bestEvent or not bestChat then
        return 0
    end
    bestEvent.used = true
    bestChat.used = true
    local id = tonumber(bestEvent.id) or 0
    UnrealFX.rememberWorldObjName(id, want)
    UnrealFX.rememberRecentNamedHit(id, want, { fromCombat = true })
    return id
end

-- Newest-first. Does not touch the named-hit ring (avoids reordering / target pollution).
function UnrealFX.collectCombatHitWorldObjsNewestFirst()
    local ordered = {}
    local orderedSeen = {}
    local function push(id)
        id = tonumber(id) or 0
        if id == 0 or orderedSeen[id] then
            return
        end
        if id == UnrealFX.getPlayerWorldObjNum() then
            return
        end
        orderedSeen[id] = true
        ordered[#ordered + 1] = id
    end

    local cap = UnrealFX.FX_KILL_PROBE_CAP or 48
    for k = 1, hitRing.count do
        if #ordered >= cap then
            break
        end
        push((idRingAt(hitRing, k)))
    end

    local trackerIds = {}
    local trackerSeen = {}
    UnrealFX.collectEventTrackerIds(trackerIds, trackerSeen)
    for i = 1, #trackerIds do
        if #ordered >= cap * 2 then
            break
        end
        push(trackerIds[i])
    end

    return ordered
end

-- Kill FX world id. Prefer best damage-event/combat-chat amount+name pair, then
-- soft-arm / SCT / dead hostile. Self fallback is handled by playKillFx / announce.
-- opts (optional): { ability = normalized kill-line ability }.
function UnrealFX.resolveWorldObjForKill(victimName, usedIds, opts)
    local want = UnrealFX.normalizeUnitName(victimName)
    if want == L"" then
        return 0
    end
    usedIds = usedIds or {}
    local killAbility = opts and opts.ability or nil
    local avoidId = UnrealFX.getLivingHostileWorldId()
    local combatIds = UnrealFX.collectCombatHitWorldObjsNewestFirst()

    local function usable(id, allowAvoid)
        if allowAvoid then
            return UnrealFX.isUsableVictimWorldId(id, usedIds, 0)
        end
        return UnrealFX.isUsableVictimWorldId(id, usedIds, avoidId)
    end

    local probesLeft = UnrealFX.FX_KILL_PROBE_CAP or 48
    local function softArmMatches(slot, id)
        local key = hitRing.key[slot]
        if key then
            return key == want
        end
        if probesLeft <= 0 then
            return false
        end
        probesLeft = probesLeft - 1
        return UnrealFX.probeWorldObjName(id, want) ~= 0
    end

    -- 0) Best YOUR_HITS chat + WORLD_OBJ_COMBAT_EVENT amount pair for this victim.
    local pairId = UnrealFX.findBestDamagePairWorldId(want, usedIds, killAbility)
    if pairId ~= 0 then
        return pairId
    end

    -- 1) Soft-armed ids (damaged within FX_ARM_SECONDS): prefer ids that are not the
    -- living hostile (AOE same-name), then allow the living hostile itself when it was
    -- soft-armed (targeted kill + HP lag).
    local now = UnrealFX.fxClock or 0
    local armDur = UnrealFX.FX_ARM_SECONDS or 8.0
    local softAvoidMatch = 0
    for k = 1, hitRing.count do
        local id, _ = idRingAt(hitRing, k)
        local slot = hitRing.slotById[id]
        local armT = slot and hitRing.armT[slot]
        if armT and now - armT <= armDur and not UnrealFX.isFxDoneWorldId(id) then
            if softArmMatches(slot, id) then
                if usable(id, false) then
                    return id
                end
                if softAvoidMatch == 0 and avoidId ~= 0 and id == avoidId and usable(id, true) then
                    softAvoidMatch = id
                end
            end
        end
    end
    if softAvoidMatch ~= 0 then
        return softAvoidMatch
    end

    -- 2) Named combat hits learned while alive (unconsumed), newest first.
    local namedAvoidMatch = 0
    for k = 1, namedHitCount do
        local hit = UnrealFX.getRecentNamedHit(k)
        if hit and hit.id ~= 0 and hit.fromCombat and not hit.consumed and hit.key == want then
            local id = hit.id
            if usable(id, false) then
                return id
            end
            if namedAvoidMatch == 0 and avoidId ~= 0 and id == avoidId and usable(id, true) then
                namedAvoidMatch = id
            end
        end
    end
    if namedAvoidMatch ~= 0 then
        return namedAvoidMatch
    end

    -- 3) Probe recent combat + CustomUI SCT EventTracker ids by name (same source
    -- SCT uses for off-target damage numbers). This is the AOE reliability path.
    local probeAvoidMatch = 0
    if type(GetNameForObject) == "function" then
        for i = 1, #combatIds do
            local id = combatIds[i]
            if probesLeft <= 0 then
                break
            end
            probesLeft = probesLeft - 1
            if UnrealFX.probeWorldObjName(id, want) ~= 0 then
                if usable(id, false) then
                    return id
                end
                if probeAvoidMatch == 0 and avoidId ~= 0 and id == avoidId and usable(id, true) then
                    probeAvoidMatch = id
                end
            end
        end
    end
    if probeAvoidMatch ~= 0 then
        return probeAvoidMatch
    end

    -- 4) Dead / cleared hostile matching the kill name (targeted kill), from the snapshot.
    do
        local snap = UnrealFX.targetSnap.hostile
        local tid = snap.id
        local tname = snap.name
        if tid ~= 0 and snap.key == want then
            local hp = snap.hp >= 0 and snap.hp or nil
            -- HP <= 0: corpse still targeted. HP > 0: kill line often races the HP update;
            -- only accept when combat evidence already pointed at this same id (steps 1-3
            -- would have returned it via allowAvoid - reaching here means no soft-arm/hit,
            -- so require hp <= 0 or lastHostile agreement below).
            if hp ~= nil and hp <= 0 and UnrealFX.isUsableVictimWorldId(tid, usedIds, 0) then
                return tid
            end
        elseif tid == 0 or tname == nil or tname == L"" then
            local last = UnrealFX.lastHostile
            if type(last) == "table" and UnrealFX.namesEqual(last.name, want) then
                local lid = tonumber(last.id) or 0
                if UnrealFX.isUsableVictimWorldId(lid, usedIds, 0) then
                    -- Cleared target: corpse id from lastHostile (HP lag / slot wipe).
                    return lid
                end
            end
        end
    end

    return 0
end

-- Soft-arm: data only. Stamps the hit-ring slot; no window work per hit. The corpse
-- keeps the same worldObjNum, so the kill line only has to supply the name.
function UnrealFX.armCombatWorldObj(worldId, slot)
    worldId = tonumber(worldId) or 0
    if worldId == 0 or worldId == UnrealFX.getPlayerWorldObjNum() then
        return false
    end
    slot = slot or hitRing.slotById[worldId]
    if not slot or hitRing.ids[slot] ~= worldId then
        return false
    end
    hitRing.armT[slot] = UnrealFX.fxClock or 0
    return true
end

-- ability: normalized kill-line ability (RvR line), nil for PvE / unknown.
function UnrealFX.addKillSpreeVictim(victimName, ability)
    if victimName == nil or victimName == L"" then
        return 0
    end
    local list = UnrealFX.killSpreeVictims
    if type(list) ~= "table" then
        list = {}
        UnrealFX.killSpreeVictims = list
    end
    local used = UnrealFX.collectUsedSpreeWorldIds()
    local entry = {
        name = victimName,
        worldId = 0,
        ability = ability,
    }
    entry.worldId = UnrealFX.resolveWorldObjForKill(victimName, used, entry)
    list[#list + 1] = entry
    return entry.worldId
end

function UnrealFX.resetKillSpreeVictims(victimName, ability)
    UnrealFX.killSpreeVictims = {}
    UnrealFX.killSpreeFxWorldIds = {}
    if victimName ~= nil and victimName ~= L"" then
        UnrealFX.addKillSpreeVictim(victimName, ability)
    end
end

-- A streak continues while each kill lands within this many seconds of the last.
local KILL_SPREE_WINDOW_SECONDS = 5
-- The same victim reported by both the RvR kill line and "You have slain X!"
-- within this window is one kill.
local KILL_DEDUPE_SECONDS = 2
local NORMAL_KILL_KEYS = {
    L"annihilation", L"erradication", L"extermination", L"godlike",
    L"headshot", L"dominating", L"denied", L"wickedsick",
}
local MULTI_KILL_KEYS = {
    L"bloodbath", L"holyshit", L"killingspree", L"ludicrous", L"megakill",
    L"monsterkill1", L"monsterkill2", L"multikill", L"rampage", L"slaughter", L"unstoppable",
}

-- Small reused ring of recent kills: { key = normalized name, t = fxClock, source = "rvr"|"pve" }.
local RECENT_KILL_CAP = 8
local recentKills = {}
local recentKillHead = 0

-- True when the other kill path already reported this victim moments ago.
-- Same-path repeats are real kills (e.g. several identically named mobs).
local function isDuplicateKill(key, source, now)
    for i = 1, RECENT_KILL_CAP do
        local k = recentKills[i]
        if k and k.source ~= source and k.key == key and (now - k.t) <= KILL_DEDUPE_SECONDS then
            return true
        end
    end
    return false
end

local function rememberKill(key, source, now)
    recentKillHead = (recentKillHead % RECENT_KILL_CAP) + 1
    local k = recentKills[recentKillHead]
    if k == nil then
        k = {}
        recentKills[recentKillHead] = k
    end
    k.key = key
    k.t = now
    k.source = source
end

-- source: "rvr" (Combat RvR kill line) or "pve" (Chat "You have slain").
-- ability: killing ability from the RvR line (any form), nil when unknown.
function UnrealFX.processPlayerKill(victimName, source, ability)
    if victimName == nil or victimName == L"" then
        return
    end

    local now = UnrealFX.fxClock or 0
    local key = UnrealFX.normalizeUnitName(victimName)
    if isDuplicateKill(key, source, now) then
        return
    end
    rememberKill(key, source, now)
    local abilityKey = UnrealFX.normalizeAbilityKey(ability)

    if UnrealFX.killSpree < 1 then
        UnrealFX.killSpree = 1
        UnrealFX.lastKillClock = now
        UnrealFX.resetKillSpreeVictims(victimName, abilityKey)
        UnrealFX.announcePlayerKill(L"firstblood", victimName)
        return
    end

    local sinceLast = now - (UnrealFX.lastKillClock or 0)
    UnrealFX.lastKillClock = now

    if sinceLast >= 0 and sinceLast < KILL_SPREE_WINDOW_SECONDS then
        UnrealFX.killSpree = UnrealFX.killSpree + 1
        UnrealFX.addKillSpreeVictim(victimName, abilityKey)
        if UnrealFX.killSpree == 2 then
            -- Sound once; FX on every distinct corpse in the streak.
            UnrealFX.announcePlayerKill(L"doublekill", victimName)
            return
        end
        local killType = MULTI_KILL_KEYS[math.random(#MULTI_KILL_KEYS)]
        UnrealFX.announcePlayerKill(killType, victimName)
        return
    end

    UnrealFX.killSpree = 1
    UnrealFX.resetKillSpreeVictims(victimName, abilityKey)
    local killType = NORMAL_KILL_KEYS[math.random(#NORMAL_KILL_KEYS)]
    UnrealFX.announcePlayerKill(killType, victimName)
end

function UnrealFX.OnCombatHappened(updateType, filterType)
    if updateType ~= SystemData.TextLogUpdate.ADDED then
        return
    end

    local filters = SystemData and SystemData.ChatLogFilters
    if filters
        and (filterType == filters.YOUR_HITS or filterType == filters.PET_HITS)
    then
        UnrealFX.onOutgoingDamageCombatLog(filterType)
        return
    end

    if not filters
        or not (filterType == filters.RVR_KILLS_ORDER or filterType == filters.RVR_KILLS_DESTRUCTION)
    then
        return
    end

    local num = TextLogGetNumEntries("Combat") - 1
    if num < 0 then
        return
    end
    local _time, _filter, msg = TextLogGetEntry("Combat", num)
    if msg == nil or msg == L"" then
        return
    end
    -- "Victim has been slain by Killer's Ability in Zone." - keep the ability for pairing.
    -- Killer may be a multi-word pet name.
    local victim, killer, ability = msg:match(L"([%a]+) has been [%a]+ by (.-)'s (.-) in [^%.]+%.")
    if victim == nil or killer == nil or victim == killer then
        return
    end

    local playerKey = UnrealFX.getPlayerNameKey()
    local victimKey = UnrealFX.normalizeUnitName(victim)
    local killerKey = UnrealFX.normalizeUnitName(killer)

    if playerKey ~= L"" and victimKey == playerKey then
        if UnrealFX.getDefeatAlertsEnabled() then
            UnrealFX.announcePlayerDeath(killer)
        end
        return
    end

    if playerKey ~= L"" and killerKey == playerKey then
        UnrealFX.processPlayerKill(victim, "rvr", ability)
        return
    end

    if UnrealFX.isPlayerPetKey(killerKey)
        and UnrealFX.hasRecentDamageChatFor(victimKey, UnrealFX.FX_PET_KILL_RECENT_HIT_SECONDS)
    then
        UnrealFX.processPlayerKill(victim, "rvr", ability)
    end
end

function UnrealFX.OnChatKillHappened(updateType, filterType)
    if not UnrealFX.getPveKillAlertsEnabled() then
        return
    end
    -- Pets and lake trash while flagged land on this Chat path; keep PVE FX for true PvE only.
    if UnrealFX.isPlayerRvRFlagged() then
        return
    end
    if filterType ~= SystemData.ChatLogFilters.KILLS_DEATH_YOURS then
        return
    end
    if updateType ~= SystemData.TextLogUpdate.ADDED then
        return
    end

    local num = TextLogGetNumEntries("Chat") - 1
    if num < 0 then
        return
    end

    local _time, _filter, msg = TextLogGetEntry("Chat", num)
    if msg == nil or msg == L"" then
        return
    end
    -- PVE kill confirm: "You have slain Training Construct!"
    local victim = msg:match(L"You have slain (.+)!")
    if victim == nil or victim == L"" then
        return
    end
    if UnrealFX.shouldSkipPveVictim(victim) then
        return
    end

    UnrealFX.processPlayerKill(victim, "pve")
end

function UnrealFX.logDeathBlow(killType)
    -- Incremental saving (enabled in Initialize) appends the entry to
    -- logs/UnrealFX.log; no full TextLogSaveLog per keyword.
    TextLogAddEntry(UnrealFX.logFileName, 0, towstring(killType))
end

function UnrealFX.markKillSpreeFxShown(entry, worldId)
    if type(entry) == "table" then
        entry.fxShown = true
        local id = tonumber(entry.worldId) or 0
        if id == 0 then
            id = tonumber(worldId) or 0
            if id ~= 0 then
                entry.worldId = id
            end
        end
    end
    worldId = tonumber(worldId) or 0
    if worldId ~= 0 then
        local seen = UnrealFX.killSpreeFxWorldIds
        if type(seen) ~= "table" then
            seen = {}
            UnrealFX.killSpreeFxWorldIds = seen
        end
        seen[worldId] = true
    end
end

function UnrealFX.announcePlayerKill(killType, victimName)
    -- One announcer sound per event. FX only on corpses not yet stamped this streak.
    UnrealFX.logDeathBlow(killType)

    local fxKey = UnrealFX.mapSoundKeywordToFxKey(killType)
    if not fxKey then
        return
    end

    local seenIds = UnrealFX.killSpreeFxWorldIds
    if type(seenIds) ~= "table" then
        seenIds = {}
        UnrealFX.killSpreeFxWorldIds = seenIds
    end

    local victims = UnrealFX.killSpreeVictims
    if type(victims) == "table" and #victims > 0 then
        -- Re-resolve missing world ids from SCT/combat trackers before stamping
        -- (AOE victims often were never the hostile target).
        local used = {}
        for id, _ in pairs(seenIds) do
            used[id] = true
        end
        -- Drop duplicate world ids across streak rows, then fill gaps.
        for i = 1, #victims do
            local entry = victims[i]
            if type(entry) == "table" then
                local worldId = tonumber(entry.worldId) or 0
                if worldId ~= 0 then
                    if entry.fxShown then
                        used[worldId] = true
                    elseif used[worldId] then
                        entry.worldId = 0
                    else
                        used[worldId] = true
                    end
                end
            end
        end
        for i = 1, #victims do
            local entry = victims[i]
            if type(entry) == "table" and not entry.fxShown and (tonumber(entry.worldId) or 0) == 0 then
                local worldId = UnrealFX.resolveWorldObjForKill(entry.name or victimName, used, entry)
                entry.worldId = worldId
                if worldId ~= 0 then
                    used[worldId] = true
                end
            end
        end

        -- One new kill -> one new corpse FX (no re-stamp of older streak victims).
        local entry = victims[#victims]
        if type(entry) == "table" and not entry.fxShown then
            local name = entry.name or victimName
            local worldId = tonumber(entry.worldId) or 0
            if worldId ~= 0 and (seenIds[worldId] or UnrealFX.isFxDoneWorldId(worldId)) then
                UnrealFX.markKillSpreeFxShown(entry, worldId)
            else
                if worldId == 0 then
                    worldId = UnrealFX.resolveWorldObjForKill(name, seenIds, entry)
                    entry.worldId = worldId
                end
                local shown = false
                if worldId ~= 0 then
                    shown = UnrealFX.showFxOnWorldObject(fxKey, worldId, {
                        quiet = true,
                        label = UnrealFX.toNarrow(UnrealFX.normalizeUnitName(name)),
                    })
                else
                    -- Unknown victim after damage-pair / resolve -> self.
                    shown = UnrealFX.showFxOnSelf(fxKey, { quiet = true })
                    worldId = UnrealFX.getSelfWorldObjNum()
                    entry.worldId = worldId
                end
                if not shown then
                    shown = UnrealFX.playKillFx(fxKey, name, { usedIds = seenIds })
                    worldId = tonumber(entry.worldId) or worldId
                end
                if shown then
                    UnrealFX.markKillSpreeFxShown(entry, worldId)
                    return
                end
            end
        elseif type(entry) == "table" and entry.fxShown then
            return
        end
    end

    UnrealFX.playKillFx(fxKey, victimName)
end

function UnrealFX.announcePlayerDeath(killerName)
    -- Always defeat.wav; FX prefers killer world object, else pending scan / self.
    UnrealFX.logPlaybackKeyword("defeat")
    -- playKillFx resolves the killer, else queues a name scan that ends on hostile/self.
    UnrealFX.playKillFx("defeat", killerName, { defeat = true })
end

function UnrealFX.getSelfWorldObjNum()
    if GameData and GameData.Player then
        return tonumber(GameData.Player.worldObjNum) or 0
    end
    return 0
end

function UnrealFX.showFxOnSelf(requestedKey, opts)
    opts = opts or {}
    local selfId = UnrealFX.getSelfWorldObjNum()
    if selfId == 0 then
        return false
    end
    if not opts.label then
        opts.label = "player"
    end
    return UnrealFX.showFxOnWorldObject(requestedKey, selfId, opts)
end

-- Victim id unknown: current hostile target, else self.
function UnrealFX.showFxOnHostileOrSelf(requestedKey, opts)
    opts = opts or {}
    local hid = UnrealFX.getCurrentHostileWorldId()
    if hid ~= 0 then
        if not opts.label then
            local last = UnrealFX.lastHostile
            if last and (tonumber(last.id) or 0) == hid then
                opts.label = UnrealFX.toNarrow(last.name or L"hostile")
            else
                opts.label = "hostile"
            end
        end
        return UnrealFX.showFxOnWorldObject(requestedKey, hid, opts)
    end
    return UnrealFX.showFxOnSelf(requestedKey, opts)
end

function UnrealFX.resolvePlaybackKeyword(keyword)
    return string.lower(UnrealFX.trim(keyword))
end

function UnrealFX.logPlaybackKeyword(keyword)
    local resolved = UnrealFX.resolvePlaybackKeyword(keyword)
    UnrealFX.logDeathBlow(resolved)
    return resolved
end

function UnrealFX.clearLogFile()
    UnrealFX.hideFx()
    TextLogDestroy("UnrealFX")
    TextLogCreate(UnrealFX.logFileName, 18000)
    TextLogSetEnabled(UnrealFX.logFileName, true)
    TextLogSetIncrementalSaving(UnrealFX.logFileName, true, StringToWString("logs/"..UnrealFX.logFileName..".log"))
end

function UnrealFX.anchorFxImageCenter(win, image, xOffset, yOffset)
    if not win or not image or not DoesWindowExist(image) or not DoesWindowExist(win) then
        return
    end
    WindowClearAnchors(image)
    -- SCT pattern: child center <-> parent center so scale pulses from the middle.
    WindowAddAnchor(image, "center", win, "center", xOffset or 0, yOffset or 0)
end

function UnrealFX.setFxImageRotation(image, degrees)
    if not image or not DoesWindowExist(image) then
        return
    end
    if type(DynamicImageSetRotation) ~= "function" then
        return
    end
    pcall(DynamicImageSetRotation, image, tonumber(degrees) or 0)
end

function UnrealFX.resetFxMotionVisuals(win)
    local image = win and (win .. "Image") or nil

    if image and DoesWindowExist(image) then
        if type(WindowStopScaleAnimation) == "function" then
            pcall(WindowStopScaleAnimation, image)
        end
        if type(WindowStopPositionAnimation) == "function" then
            pcall(WindowStopPositionAnimation, image)
        end
        WindowSetScale(image, 1.0)
        if type(WindowSetRelativeScale) == "function" then
            pcall(WindowSetRelativeScale, image, 1.0)
        end
        UnrealFX.setFxImageRotation(image, 0)
        local dispW, dispH = UnrealFX.getFxDisplaySize()
        WindowSetDimensions(image, dispW, dispH)
        UnrealFX.anchorFxImageCenter(win, image, 0, 0)
    end

    if win and DoesWindowExist(win) then
        WindowSetScale(win, 1.0)
        if type(WindowSetRelativeScale) == "function" then
            pcall(WindowSetRelativeScale, win, 1.0)
        end
        local dispW, dispH = UnrealFX.getFxDisplaySize()
        WindowSetDimensions(win, dispW, dispH)
    end
end

function UnrealFX.pickFxMotion(opts)
    opts = opts or {}
    local want = opts.motion
    if type(want) == "string" then
        want = string.lower(UnrealFX.trim(want))
        if want == "spin" or want == "spinning" then
            return "spin"
        end
        if want == "spiral" or want == "spiraling" or want == "spiralling" then
            return "spiral"
        end
        if want == "grow" or want == "punch" or want == "default" then
            return "grow"
        end
    end
    local motions = UnrealFX.FX_MOTIONS
    if type(motions) == "table" and #motions > 0 then
        return motions[math.random(#motions)]
    end
    return "grow"
end

function UnrealFX.computeFxGrowScale(u)
    if u < 0 then
        u = 0
    elseif u > 1 then
        u = 1
    end
    local startS = UnrealFX.FX_PUNCH_SCALE_START or 0.78
    local peakS = UnrealFX.FX_PUNCH_SCALE_PEAK or 1.06
    local growFrac = UnrealFX.FX_PUNCH_GROW_FRAC or 0.6
    if growFrac < 0.15 then
        growFrac = 0.15
    elseif growFrac > 0.9 then
        growFrac = 0.9
    end
    if u < growFrac then
        local v = u / growFrac
        local e = 1 - (1 - v) * (1 - v) * (1 - v)
        return startS + (peakS - startS) * e
    end
    local v = (u - growFrac) / (1 - growFrac)
    local e = v * v * (3 - 2 * v)
    return peakS + (1.0 - peakS) * e
end

-- Pass the pool instance as `inst` to skip the client calls when its alpha is
-- already at the requested value (e.g. the hold phase).
function UnrealFX.setFxAlpha(win, image, alpha, inst)
    alpha = tonumber(alpha) or 0
    if alpha < 0 then
        alpha = 0
    elseif alpha > 1 then
        alpha = 1
    end
    if inst then
        if inst.alpha == alpha then
            return
        end
        inst.alpha = alpha
    end
    if win and DoesWindowExist(win) then
        WindowSetAlpha(win, alpha)
    end
    if image and DoesWindowExist(image) then
        WindowSetAlpha(image, alpha)
    end
end

function UnrealFX.findFxInstanceByWorldId(worldId)
    worldId = tonumber(worldId) or 0
    if worldId == 0 then
        return nil, nil
    end
    local active = UnrealFX.fxActive or {}
    for i = 1, #active do
        local inst = active[i]
        if inst and (tonumber(inst.attachedId) or 0) == worldId then
            return inst, i
        end
    end
    return nil, nil
end

function UnrealFX.ensureFxPool()
    if UnrealFX.fxPoolReady then
        return true
    end
    if type(CreateWindowFromTemplate) ~= "function" then
        return false
    end

    local maxN = UnrealFX.FX_MAX_INSTANCES or 8
    local prefix = UnrealFX.FX_WINDOW_PREFIX or "UnrealFXWindow"
    UnrealFX.fxFree = UnrealFX.fxFree or {}
    UnrealFX.fxActive = UnrealFX.fxActive or {}

    for i = 1, maxN do
        local win = prefix .. tostring(i)
        if not DoesWindowExist(win) then
            CreateWindowFromTemplate(win, UnrealFX.FX_TEMPLATE, "Root")
        end
        if DoesWindowExist(win) then
            WindowSetShowing(win, false)
            UnrealFX.fxFree[#UnrealFX.fxFree + 1] = {
                win = win,
                image = win .. "Image",
                attachedId = nil,
                key = nil,
                phase = nil,
                t = 0,
            }
        end
    end

    UnrealFX.fxPoolReady = #UnrealFX.fxFree > 0
    return UnrealFX.fxPoolReady
end

function UnrealFX.releaseFxInstance(inst)
    if type(inst) ~= "table" then
        return
    end
    local win = inst.win
    local image = inst.image or (win and (win .. "Image"))
    local attachedId = tonumber(inst.attachedId) or 0

    -- Detach FIRST. While attached, the client forces WindowSetShowing(true) whenever
    -- the world object is on screen - so a release that only hides will "stick" visible.
    -- Never DestroyWindow - WAR crashes on destroy of (recently) world-bound overlays.
    if win and DoesWindowExist(win) then
        if type(WindowStopAlphaAnimation) == "function" then
            pcall(WindowStopAlphaAnimation, win)
            if image and DoesWindowExist(image) then
                pcall(WindowStopAlphaAnimation, image)
            end
        end
        if attachedId ~= 0 and type(DetachWindowFromWorldObject) == "function" then
            pcall(DetachWindowFromWorldObject, win, attachedId)
        end
        if type(WindowClearAnchors) == "function" then
            pcall(WindowClearAnchors, win)
        end
        UnrealFX.resetFxMotionVisuals(win)
        -- Alpha 0 (not 1): after death the client leaves the window Showing; alpha 1 = hang.
        -- Free-pool windows are hidden here once; nothing re-hides them per frame.
        inst.alpha = nil
        UnrealFX.setFxAlpha(win, image, 0, inst)
        WindowSetShowing(win, false)
    end

    inst.attachedId = nil
    inst.phase = nil
    inst.t = 0
    inst.key = nil
    inst.motion = nil
    inst.spinStartDeg = nil
    inst.spiralDir = nil
    inst.useMoveProject = nil
    inst.fellBackToSelf = nil
    inst.noSelfFallback = nil
    inst.projectTicks = nil
    inst.stuckChecked = nil
    UnrealFX.fxFree = UnrealFX.fxFree or {}
    UnrealFX.fxFree[#UnrealFX.fxFree + 1] = inst
end

function UnrealFX.acquireFxInstance(worldId)
    worldId = tonumber(worldId) or 0
    if not UnrealFX.ensureFxPool() then
        return nil
    end

    UnrealFX.fxActive = UnrealFX.fxActive or {}
    local active = UnrealFX.fxActive

    -- Reuse the instance already pinned to this entity (re-kill / refresh art).
    local existing = UnrealFX.findFxInstanceByWorldId(worldId)
    if existing then
        return existing
    end

    local free = UnrealFX.fxFree
    local inst = nil
    if type(free) == "table" and #free > 0 then
        inst = table.remove(free)
    elseif #active > 0 then
        -- Pool exhausted: recycle the oldest playing instance.
        local oldestIdx = 1
        local oldestT = active[1] and (active[1].t or 0) or 0
        for i = 2, #active do
            local t = active[i] and (active[i].t or 0) or 0
            if t > oldestT then
                oldestT = t
                oldestIdx = i
            end
        end
        inst = active[oldestIdx]
        table.remove(active, oldestIdx)
        UnrealFX.releaseFxInstance(inst)
        inst = table.remove(UnrealFX.fxFree)
    end

    if not inst or not inst.win or not DoesWindowExist(inst.win) then
        return nil
    end

    inst.attachedId = nil
    inst.key = nil
    inst.phase = "punch"
    inst.t = 0
    active[#active + 1] = inst
    return inst
end

function UnrealFX.detachFxFromWorld(inst)
    if type(inst) ~= "table" then
        return
    end
    local win = inst.win
    local attachedId = tonumber(inst.attachedId) or 0
    if win and DoesWindowExist(win) and attachedId ~= 0 and type(DetachWindowFromWorldObject) == "function" then
        pcall(DetachWindowFromWorldObject, win, attachedId)
    end
    inst.attachedId = nil
end

function UnrealFX.tickFxInstance(inst, elapsed)
    if type(inst) ~= "table" then
        return false
    end
    local win = inst.win
    local image = inst.image or (win and (win .. "Image"))
    if not win or not DoesWindowExist(win) then
        return false
    end

    inst.t = (inst.t or 0) + (tonumber(elapsed) or 0)
    local t = inst.t

    -- Playing FX: chat-bubble projection each tick (no Attach). If the id parks at
    -- screen origin / is off-screen, remount onto current hostile, else self.
    -- The check reads the position the client drew for the PREVIOUS projection, so
    -- it runs before re-projecting and only once one tick has passed since show.
    -- Clients without MoveWindowToWorldObject (Attach) get one check.
    local followId = tonumber(inst.attachedId) or 0
    if followId ~= 0 then
        local ticks = inst.projectTicks or 0
        if ticks >= 1
            and not inst.fellBackToSelf
            and not inst.noSelfFallback
            and (inst.useMoveProject or not inst.stuckChecked)
        then
            inst.stuckChecked = true
            if UnrealFX.isFxWindowStuckAtOrigin(win) then
                local fb = UnrealFX.fallbackFxProjectToHostileOrSelf(win, followId)
                if fb ~= 0 then
                    followId = fb
                    inst.attachedId = fb
                    UnrealFX.markFxDoneWorldId(fb)
                    local selfId = UnrealFX.getSelfWorldObjNum()
                    if selfId ~= 0 and fb == selfId then
                        inst.fellBackToSelf = true
                    end
                end
            end
        end
        if inst.useMoveProject then
            UnrealFX.projectFxToWorldObject(win, followId)
        end
        inst.projectTicks = ticks + 1
    end

    local motion = inst.motion or "grow"
    -- Grow and spin share one intro length (spin only adds rotation).
    local growDur = UnrealFX.FX_GROW_SECONDS
        or UnrealFX.FX_SPIN_GROW_SECONDS
        or 0.45
    local shakeDur = UnrealFX.FX_SHAKE_SECONDS or 0.65
    local holdDur = UnrealFX.FX_HOLD_SECONDS or 0.25
    local fadeDur = UnrealFX.FX_FADE_SECONDS or 1.0
    local shakeEnd = growDur + shakeDur
    local holdEnd = shakeEnd + holdDur
    local total = holdEnd + fadeDur

    if t >= total then
        return false
    end

    -- 1) Grow into configured scale (rel 1.0). spin rotates texture; spiral orbits anchor only.
    if t < growDur then
        inst.phase = "grow"
        local u = t / growDur
        if u < 0 then
            u = 0
        elseif u > 1 then
            u = 1
        end
        if DoesWindowExist(image) then
            -- Ease-out cubic: motion settles before shake.
            local e = 1 - (1 - u) * (1 - u) * (1 - u)
            local dx, dy = 0, 0
            if motion == "spiral" then
                local turns = UnrealFX.FX_SPIRAL_TURNS or 2.0
                local radius0 = (UnrealFX.FX_SPIRAL_RADIUS or 56) * UnrealFX.getFxScale()
                local radius = radius0 * (1 - e)
                local dir = tonumber(inst.spiralDir) or 1
                local ang = dir * 2 * math.pi * turns * e
                dx = radius * math.cos(ang)
                dy = radius * math.sin(ang)
            end
            UnrealFX.anchorFxImageCenter(win, image, dx, dy)

            local scale = UnrealFX.computeFxGrowScale(u)
            if type(WindowSetRelativeScale) == "function" then
                WindowSetRelativeScale(image, scale)
            else
                WindowSetScale(image, scale)
            end
            if motion == "spin" then
                local startDeg = tonumber(inst.spinStartDeg) or (UnrealFX.FX_SPIN_DEGREES or 720)
                UnrealFX.setFxImageRotation(image, startDeg * (1 - e))
            else
                UnrealFX.setFxImageRotation(image, 0)
            end
        end
        UnrealFX.setFxAlpha(win, image, 1.0, inst)
        return true
    end

    -- 2) Shake + pulse at configured scale, then taper into hold.
    if t < shakeEnd then
        if inst.phase == "grow" then
            UnrealFX.resetFxMotionVisuals(win)
        end
        inst.phase = "shake"
        local st = t - growDur
        local u = shakeDur > 0 and (st / shakeDur) or 1
        if u < 0 then
            u = 0
        elseif u > 1 then
            u = 1
        end
        local env = 1 - u
        local envShake = 0.35 + 0.65 * env
        if DoesWindowExist(image) then
            local amp = (UnrealFX.FX_SHAKE_AMP or 20) * UnrealFX.getFxScale() * envShake
            local freq = UnrealFX.FX_SHAKE_FREQ or 32
            local vert = UnrealFX.FX_SHAKE_VERT or 0.55
            local dx = amp * math.sin(2 * math.pi * freq * st)
            local dy = (amp * vert) * math.cos(2 * math.pi * freq * 1.15 * st)
            UnrealFX.anchorFxImageCenter(win, image, dx, dy)

            local pfreq = UnrealFX.FX_PULSE_FREQ or 14
            local pdelta = UnrealFX.FX_PULSE_DELTA or 0.14
            local scale = 1 + pdelta * envShake * math.sin(2 * math.pi * pfreq * st)
            if type(WindowSetRelativeScale) == "function" then
                WindowSetRelativeScale(image, scale)
            else
                WindowSetScale(image, scale)
            end
        end
        UnrealFX.setFxAlpha(win, image, 1.0, inst)
        return true
    end

    if inst.phase == "shake" or inst.phase == "grow" then
        UnrealFX.resetFxMotionVisuals(win)
        inst.phase = "hold"
    end

    -- 3) Brief still hold at configured scale.
    if t < holdEnd then
        inst.phase = "hold"
        UnrealFX.setFxAlpha(win, image, 1.0, inst)
        return true
    end

    -- 4) Fade out while still world-attached.
    inst.phase = "fade"
    local fadeT = (t - holdEnd) / fadeDur
    if fadeT < 0 then
        fadeT = 0
    elseif fadeT > 1 then
        fadeT = 1
    end
    UnrealFX.setFxAlpha(win, image, 1.0 - fadeT, inst)
    return true
end

function UnrealFX.OnFxUpdate(timePassed)
    local elapsed = tonumber(timePassed) or 0
    if elapsed < 0 then
        elapsed = 0
    end
    UnrealFX.fxClock = (UnrealFX.fxClock or 0) + elapsed

    UnrealFX.tickPendingFx(elapsed)

    local active = UnrealFX.fxActive
    if active == nil then
        return
    end
    local i = 1
    while i <= #active do
        local inst = active[i]
        if not UnrealFX.tickFxInstance(inst, elapsed) then
            local doneId = tonumber(inst and inst.attachedId) or 0
            if doneId ~= 0 then
                UnrealFX.markFxDoneWorldId(doneId)
            end
            table.remove(active, i)
            UnrealFX.releaseFxInstance(inst)
        else
            i = i + 1
        end
    end
end

function UnrealFX.hideFx()
    UnrealFX.pendingFxQueue = {}
    local active = UnrealFX.fxActive or {}
    for i = #active, 1, -1 do
        local inst = active[i]
        active[i] = nil
        UnrealFX.releaseFxInstance(inst)
    end
    UnrealFX.fxActive = {}
end

function UnrealFX.getFxTextureEntry(key)
    local list = UnrealFX.FX_TEXTURES
    if type(list) ~= "table" or #list == 0 then
        return nil
    end

    if key and key ~= "" then
        local want = string.lower(key)
        for i = 1, #list do
            local entry = list[i]
            if entry.key == want or entry.label == want then
                return entry
            end
        end
        return nil
    end

    if #list == 1 then
        return list[1]
    end

    -- Prefer a different image than the last one shown.
    local last = UnrealFX.fxLastKey
    local pool = {}
    for i = 1, #list do
        if list[i].key ~= last then
            pool[#pool + 1] = list[i]
        end
    end
    if #pool == 0 then
        pool = list
    end
    return pool[math.random(#pool)]
end

function UnrealFX.listFxTextureKeys()
    local list = UnrealFX.FX_TEXTURES or {}
    local keys = {}
    for i = 1, #list do
        keys[#keys + 1] = list[i].key
    end
    return table.concat(keys, ", ")
end

function UnrealFX.normalizeUnitName(name)
    if name == nil or name == L"" or name == "" then
        return L""
    end

    local wide = name
    if type(name) == "string" then
        wide = towstring(name)
    end

    if wstring and wstring.find and wstring.sub then
        local caret = wstring.find(wide, L"^", 1, true)
        if caret then
            wide = wstring.sub(wide, 1, caret - 1)
        end
    end

    if wstring and wstring.lower then
        wide = wstring.lower(wide)
    end

    return wide
end

function UnrealFX.namesEqual(a, b)
    return UnrealFX.normalizeUnitName(a) == UnrealFX.normalizeUnitName(b)
end

function UnrealFX.rememberWorldObjName(worldObjNum, name)
    local id = tonumber(worldObjNum) or 0
    local key = UnrealFX.normalizeUnitName(name)
    if id == 0 or key == L"" then
        return
    end
    UnrealFX.worldObjByName[key] = id
end

function UnrealFX.readTargetMeta(slot, meta)
    meta = meta or {}
    meta.isPvP = false
    meta.isNPC = nil
    meta.career = 0
    meta.unitType = nil
    if not (TargetInfo and slot) then
        return meta
    end
    if type(TargetInfo.UnitIsPvPFlagged) == "function" then
        meta.isPvP = TargetInfo:UnitIsPvPFlagged(slot) == true
    end
    if type(TargetInfo.UnitIsNPC) == "function" then
        meta.isNPC = TargetInfo:UnitIsNPC(slot) == true
    end
    if type(TargetInfo.UnitCareer) == "function" then
        meta.career = tonumber(TargetInfo:UnitCareer(slot)) or 0
    end
    if type(TargetInfo.UnitType) == "function" then
        meta.unitType = TargetInfo:UnitType(slot)
    end
    return meta
end

-- HP% straight from the cached unit (UnitHealth returns 0 for a missing value).
local function readSlotHp(slot)
    local units = TargetInfo.m_Units
    local unit = type(units) == "table" and units[slot] or nil
    if type(unit) == "table" then
        return tonumber(unit.healthPercent)
    end
    if type(TargetInfo.UnitHealth) == "function" then
        return tonumber(TargetInfo:UnitHealth(slot))
    end
    return nil
end

local function fillTargetSnap(snap, slot, now)
    local id = tonumber(TargetInfo:UnitEntityId(slot)) or 0
    local name = L""
    local hp = nil
    if id ~= 0 then
        name = TargetInfo:UnitName(slot) or L""
        hp = readSlotHp(slot)
    end
    if snap.id ~= id or snap.name ~= name then
        snap.key = UnrealFX.normalizeUnitName(name)
    end
    snap.id = id
    snap.name = name
    snap.hp = hp or -1
    snap.t = now
    if id ~= 0 and hp ~= nil and hp <= 0 and id ~= UnrealFX.getPlayerWorldObjNum() then
        idRingSet(zeroHpRing, id, now)
    end
end

-- Event-time half: optionally refresh TargetInfo (only from OnPlayerTargetUpdated),
-- then copy hostile + mouseover into the reused snapshot tables.
function UnrealFX.snapshotTargets(refresh)
    if not (TargetInfo and type(TargetInfo.UnitName) == "function" and type(TargetInfo.UnitEntityId) == "function") then
        return
    end
    if refresh and type(TargetInfo.UpdateFromClient) == "function" then
        pcall(TargetInfo.UpdateFromClient, TargetInfo)
    end

    local now = UnrealFX.fxClock or 0
    local slot = TargetInfo.HOSTILE_TARGET or "selfhostiletarget"
    local hostile = UnrealFX.targetSnap.hostile
    fillTargetSnap(hostile, slot, now)
    fillTargetSnap(UnrealFX.targetSnap.mouseover, "mouseovertarget", now)

    -- Sticky last hostile: keep the previous one when the slot clears (player death).
    if hostile.id == 0 or hostile.name == L"" then
        return
    end
    local last = UnrealFX.lastHostile
    if last.id ~= hostile.id or last.name ~= hostile.key then
        last.id = hostile.id
        last.name = hostile.key
        UnrealFX.readTargetMeta(slot, last)
    end
    -- Do NOT feed target selection into the named-hit ring / worldObjByName - that made
    -- kill FX stick to a distant living target when AOE killed same-named mobs nearby.
end

-- Read-only half: the last snapshot. Never refreshes TargetInfo.
function UnrealFX.getHostileSnapshot()
    return UnrealFX.targetSnap.hostile
end

function UnrealFX.getMouseoverSnapshot()
    return UnrealFX.targetSnap.mouseover
end

function UnrealFX.OnPlayerTargetUpdated(targetClassification, targetId, targetType)
    -- The only TargetInfo:UpdateFromClient caller; targetId alone is unreliable.
    UnrealFX.snapshotTargets(true)
end

local COMBAT_HIT_META = { fromCombat = true }

-- Cached name for a hit-ring slot; GetNameForObject at most once per id per second.
local function combatHitName(slot, id, now)
    local nameT = hitRing.nameT[slot]
    if nameT and now - nameT < (UnrealFX.FX_NAME_LOOKUP_SECONDS or 1.0) then
        return hitRing.name[slot] or nil, hitRing.key[slot] or nil
    end
    hitRing.nameT[slot] = now
    local name = nil
    if type(GetNameForObject) == "function" then
        local ok, n = pcall(GetNameForObject, id)
        if ok and n and n ~= L"" then
            name = n
        end
    end
    -- Hostile/mouseover snapshot often has the name when GetNameForObject is empty.
    if name == nil then
        local snap = UnrealFX.targetSnap.hostile
        if snap.id ~= id then
            snap = UnrealFX.targetSnap.mouseover
        end
        if snap.id == id and snap.name ~= L"" then
            name = snap.name
        end
    end
    if name == nil then
        return hitRing.name[slot] or nil, hitRing.key[slot] or nil
    end
    if name ~= hitRing.name[slot] then
        hitRing.name[slot] = name
        local key = UnrealFX.normalizeUnitName(name)
        hitRing.key[slot] = key ~= L"" and key or false
    end
    return name, hitRing.key[slot] or nil
end

-- (hitTargetObjectNumber, hitAmount, textType[, abilityId]). Stock passes three
-- arguments; a 4th numeric abilityId is used when the client provides one.
function UnrealFX.OnWorldObjCombatEvent(...)
    local hitTargetObjectNumber, hitAmount, textType, abilityArg = ...
    -- Data only: remember the hit id, damage amount and (throttled) name. The corpse
    -- keeps this worldObjNum; the kill line later matches by name. No window work.
    local id = tonumber(hitTargetObjectNumber) or 0
    if id == 0 or id == UnrealFX.getPlayerWorldObjNum() then
        return
    end

    local now = UnrealFX.fxClock or 0
    local slot = touchCombatHit(id, now)

    -- Outgoing damage (negative amount) for YOUR_HITS chat pairing on kill resolve.
    -- Heals (positive) never produce a kill victim: stop before the name lookup.
    local amount = tonumber(hitAmount) or 0
    if amount > 0 then
        return
    end
    hitRing.dmgT[slot] = now
    if amount < 0 then
        local abilityKey = nil
        if type(abilityArg) == "number" and abilityArg > 0 then
            abilityKey = UnrealFX.getAbilityKeyById(abilityArg)
        end
        UnrealFX.rememberRecentDamageEvent(id, -amount, abilityKey)
    end

    local name, key = combatHitName(slot, id, now)
    if key then
        if UnrealFX.worldObjByName[key] ~= id then
            UnrealFX.worldObjByName[key] = id
        end
        UnrealFX.rememberRecentNamedHit(id, name, COMBAT_HIT_META, key)
    end

    -- Only soft-arm on actual damage; misses/blocks (amount 0) just feed the caches.
    if amount < 0 then
        UnrealFX.armCombatWorldObj(id, slot)
    end
end

function UnrealFX.probeWorldObjName(id, want)
    id = tonumber(id) or 0
    if id == 0 or type(GetNameForObject) ~= "function" then
        return 0
    end
    local ok, name = pcall(GetNameForObject, id)
    if not ok or not name or name == L"" then
        return 0
    end
    UnrealFX.rememberWorldObjName(id, name)
    if want and UnrealFX.namesEqual(name, want) then
        return id
    end
    return 0
end

function UnrealFX.collectEventTrackerIds(into, seen)
    -- CustomUI SCT (and stock EventText) attach floats to tracker.m_TargetObject -
    -- the WORLD_OBJ_COMBAT_EVENT hit id, not the current hostile target. Table keys
    -- are often that id, but incoming SCT lanes use string keys; always prefer m_TargetObject.
    local function addFrom(trackers)
        if type(trackers) ~= "table" then
            return
        end
        for key, tracker in pairs(trackers) do
            local id = 0
            if type(tracker) == "table" then
                id = tonumber(tracker.m_TargetObject) or 0
            end
            if id == 0 then
                id = tonumber(key) or 0
            end
            if id ~= 0 and not seen[id] then
                seen[id] = true
                into[#into + 1] = id
            end
        end
    end
    if EA_System_EventText then
        addFrom(EA_System_EventText.EventTrackers)
    end
    if CustomUI and CustomUI.SCT then
        addFrom(CustomUI.SCT.EventTrackers)
    end
end

function UnrealFX.scanWorldObjByName(want, budget, avoidId)
    want = UnrealFX.normalizeUnitName(want)
    if want == L"" or type(GetNameForObject) ~= "function" then
        return 0
    end

    budget = tonumber(budget) or (UnrealFX.FX_NAME_SCAN_BUDGET or 120)
    if budget < 1 then
        budget = 1
    end
    avoidId = tonumber(avoidId) or 0

    local probed = {}
    local function tryId(id)
        id = tonumber(id) or 0
        if id == 0 or probed[id] then
            return 0
        end
        probed[id] = true
        if avoidId ~= 0 and id == avoidId then
            return 0
        end
        if id == UnrealFX.getPlayerWorldObjNum() then
            return 0
        end
        budget = budget - 1
        if budget < 0 then
            return 0
        end
        return UnrealFX.probeWorldObjName(id, want)
    end

    -- Direct candidates: recent combat ids, name cache values, floating-combat trackers.
    local candidates = {}
    local seen = {}
    for k = 1, hitRing.count do
        local id = idRingAt(hitRing, k)
        if not seen[id] then
            seen[id] = true
            candidates[#candidates + 1] = id
        end
    end
    for _, id in pairs(UnrealFX.worldObjByName or {}) do
        id = tonumber(id) or 0
        if id ~= 0 and not seen[id] then
            seen[id] = true
            candidates[#candidates + 1] = id
        end
    end
    UnrealFX.collectEventTrackerIds(candidates, seen)

    for i = 1, #candidates do
        local hit = tryId(candidates[i])
        if hit ~= 0 then
            return hit
        end
        if budget <= 0 then
            return 0
        end
    end

    -- Neighborhood around seeds (entity ids are not spatial, but often cluster).
    local radius = UnrealFX.FX_NAME_SCAN_RADIUS or 24
    local seeds = {}
    local seedSeen = {}
    local function addSeed(id)
        id = tonumber(id) or 0
        if id == 0 or seedSeen[id] then
            return
        end
        seedSeen[id] = true
        seeds[#seeds + 1] = id
    end
    if GameData and GameData.Player then
        addSeed(GameData.Player.worldObjNum)
    end
    local last = UnrealFX.lastHostile
    if last then
        addSeed(last.id)
    end
    for k = 1, math.min(12, hitRing.count) do
        addSeed((idRingAt(hitRing, k)))
    end

    for s = 1, #seeds do
        local seed = seeds[s]
        for delta = 0, radius do
            local hit = tryId(seed + delta)
            if hit ~= 0 then
                return hit
            end
            if delta > 0 then
                hit = tryId(seed - delta)
                if hit ~= 0 then
                    return hit
                end
            end
            if budget <= 0 then
                return 0
            end
        end
    end

    return 0
end

function UnrealFX.resolveWorldObjForVictim(victimName, opts)
    opts = opts or {}
    local want = UnrealFX.normalizeUnitName(victimName)
    if want == L"" then
        return 0
    end

    local avoidId = tonumber(opts.avoidWorldId) or 0
    if avoidId == 0 and opts.skipCurrentTarget then
        avoidId = UnrealFX.getLivingHostileWorldId()
    end

    local function accept(id)
        id = tonumber(id) or 0
        if id == 0 then
            return 0
        end
        if avoidId ~= 0 and id == avoidId then
            return 0
        end
        if id == UnrealFX.getPlayerWorldObjNum() then
            return 0
        end
        return id
    end

    -- Current target match - skipped for kill FX (opts.skipCurrentTarget) so AOE
    -- corpses are not painted onto a living distant hostile with the same name.
    if not opts.skipCurrentTarget
        and TargetInfo and type(TargetInfo.UnitName) == "function" and type(TargetInfo.UnitEntityId) == "function"
    then
        local slots = getVictimNameSlots()
        for i = 1, #slots do
            local slot = slots[i]
            local name = TargetInfo:UnitName(slot)
            if UnrealFX.namesEqual(name, want) then
                local id = accept(TargetInfo:UnitEntityId(slot))
                if id ~= 0 then
                    UnrealFX.rememberWorldObjName(id, name)
                    return id
                end
            end
        end
    end

    -- Sticky last hostile - defeat FX / killer lookup. Skip when it is the avoided id.
    if not opts.skipCurrentTarget then
        local last = UnrealFX.lastHostile
        if last and last.name == want then
            local id = accept(last.id)
            if id ~= 0 then
                return id
            end
        end
    end

    -- Combat-event name cache (not target selection).
    local cached = UnrealFX.worldObjByName[want]
    cached = accept(cached)
    if cached ~= 0 then
        if type(GetNameForObject) == "function" then
            local ok, name = pcall(GetNameForObject, cached)
            if ok and UnrealFX.namesEqual(name, want) then
                return cached
            end
            -- Name lookup can fail briefly; still trust the cache key match.
            if not ok or not name or name == L"" then
                return cached
            end
        else
            return cached
        end
    end

    if opts.skipScan then
        return 0
    end

    -- Budgeted GetNameForObject scan (trackers + recent combat ids + neighborhoods).
    local scanned = UnrealFX.scanWorldObjByName(
        want,
        UnrealFX.FX_NAME_SCAN_BUDGET,
        avoidId
    )
    scanned = accept(scanned)
    if scanned ~= 0 then
        return scanned
    end

    return 0
end

function UnrealFX.queuePendingFx(fxKey, unitName, opts)
    opts = opts or {}
    local want = UnrealFX.normalizeUnitName(unitName)
    if not fxKey or want == L"" then
        return
    end

    local playerObj = 0
    if GameData and GameData.Player then
        playerObj = tonumber(GameData.Player.worldObjNum) or 0
    end
    local hi = math.max(UnrealFX.nameScanMaxSeen or 0, playerObj)
    local scanLo = math.max(1, hi - 2500)
    local scanHi = hi + 400
    if playerObj > 0 then
        scanLo = math.min(scanLo, math.max(1, playerObj - 400))
        scanHi = math.max(scanHi, playerObj + 400)
    end

    UnrealFX.pendingFxQueue = UnrealFX.pendingFxQueue or {}
    local queue = UnrealFX.pendingFxQueue
    -- Refresh an existing pending resolve for the same name instead of stacking dupes.
    for i = 1, #queue do
        local p = queue[i]
        if p and p.want == want then
            p.fxKey = fxKey
            p.label = UnrealFX.toNarrow(want)
            p.t = 0
            p.scanId = scanLo
            p.scanLo = scanLo
            p.scanHi = scanHi
            p.allowSelf = opts.allowSelf == true
            return
        end
    end

    local maxN = UnrealFX.FX_MAX_INSTANCES or 8
    while #queue >= maxN do
        table.remove(queue, 1)
    end

    queue[#queue + 1] = {
        fxKey = fxKey,
        want = want,
        label = UnrealFX.toNarrow(want),
        t = 0,
        scanId = scanLo,
        scanLo = scanLo,
        scanHi = scanHi,
        allowSelf = opts.allowSelf == true,
    }
end

local PENDING_RESOLVE_OPTS = { skipScan = true, skipCapture = true }

function UnrealFX.tickPendingFx(elapsed)
    local queue = UnrealFX.pendingFxQueue
    if type(queue) ~= "table" or #queue == 0 then
        return
    end

    local dt = tonumber(elapsed) or 0
    local i = 1
    while i <= #queue do
        local pending = queue[i]
        pending.t = (pending.t or 0) + dt

        local worldId = UnrealFX.resolveWorldObjForVictim(pending.want, PENDING_RESOLVE_OPTS)
        if worldId == 0 and type(GetNameForObject) == "function" then
            local perFrame = UnrealFX.FX_PENDING_SCAN_PER_FRAME or 48
            local id = pending.scanId or pending.scanLo or 1
            local hi = pending.scanHi or id
            for _ = 1, perFrame do
                if id > hi then
                    break
                end
                local hit = UnrealFX.probeWorldObjName(id, pending.want)
                id = id + 1
                if hit ~= 0 then
                    worldId = hit
                    break
                end
            end
            pending.scanId = id
        end

        if worldId ~= 0 then
            table.remove(queue, i)
            UnrealFX.showFxOnWorldObject(pending.fxKey, worldId, {
                quiet = true,
                label = pending.label,
            })
        elseif pending.t >= (UnrealFX.FX_PENDING_SECONDS or 0.55) then
            table.remove(queue, i)
            if pending.allowSelf then
                UnrealFX.showFxOnHostileOrSelf(pending.fxKey, {
                    quiet = true,
                    label = pending.label,
                })
            end
        else
            i = i + 1
        end
    end
end

function UnrealFX.mapSoundKeywordToFxKey(keyword)
    local raw = UnrealFX.toNarrow(keyword)
    local sound = string.lower(UnrealFX.trim(raw))
    if sound == "" then
        return nil
    end

    local list = UnrealFX.FX_TEXTURES or {}
    for i = 1, #list do
        local entry = list[i]
        if entry.key == sound or entry.label == sound then
            return entry.key
        end
        local sounds = entry.sounds
        if type(sounds) == "table" then
            for j = 1, #sounds do
                if sounds[j] == sound then
                    return entry.key
                end
            end
        end
    end

    -- No matching TGA for this sound - do not show FX.
    return nil
end

function UnrealFX.showFxOnWorldObject(requestedKey, worldId, opts)
    opts = opts or {}
    worldId = tonumber(worldId) or 0
    if worldId == 0 then
        if not opts.quiet then
            UnrealFX.chatPrint("No world object to attach FX to.")
        end
        return false
    end

    if type(AttachWindowToWorldObject) ~= "function" then
        if not opts.quiet then
            UnrealFX.chatPrint("AttachWindowToWorldObject is unavailable.")
        end
        return false
    end

    local entry = UnrealFX.getFxTextureEntry(requestedKey)
    if not entry then
        if not opts.quiet then
            UnrealFX.chatPrint("Unknown FX. Available: " .. UnrealFX.listFxTextureKeys())
        end
        return false
    end

    -- One FX window per world object (SCT-style). Concurrent kills keep separate overlays.
    -- Do not restart a playing kill FX.
    local existing = UnrealFX.findFxInstanceByWorldId(worldId)
    if existing and not opts.restart then
        return true
    end

    local inst = UnrealFX.acquireFxInstance(worldId)
    if not inst or not inst.win then
        if not opts.quiet then
            UnrealFX.chatPrint("Could not create FX window (reload UI after updating the addon).")
        end
        return false
    end

    local win = inst.win
    local image = inst.image or (win .. "Image")
    local prevId = tonumber(inst.attachedId) or 0
    -- Drop any old Attach so play uses bubble-style Move only (avoids Attach+Move fight).
    if type(DetachWindowFromWorldObject) == "function" then
        if prevId ~= 0 then
            pcall(DetachWindowFromWorldObject, win, prevId)
        end
        if worldId ~= 0 and worldId ~= prevId then
            pcall(DetachWindowFromWorldObject, win, worldId)
        end
    end
    inst.attachedId = nil

    local dispW, dispH = UnrealFX.getFxDisplaySize()
    WindowSetDimensions(win, dispW, dispH)
    if DoesWindowExist(image) then
        WindowSetDimensions(image, dispW, dispH)
        if type(DynamicImageSetTexture) == "function" then
            DynamicImageSetTexture(image, entry.texture, 0, 0)
        end
        if type(DynamicImageSetTextureDimensions) == "function" then
            DynamicImageSetTextureDimensions(image, UnrealFX.FX_TEX_W, UnrealFX.FX_TEX_H)
        end
    end

    if type(WindowStopAlphaAnimation) == "function" then
        pcall(WindowStopAlphaAnimation, win)
        if DoesWindowExist(image) then
            pcall(WindowStopAlphaAnimation, image)
        end
    end
    UnrealFX.resetFxMotionVisuals(win)
    inst.alpha = nil
    UnrealFX.setFxAlpha(win, image, 1.0, inst)

    local useMove = type(MoveWindowToWorldObject) == "function"
    local attachId = worldId
    local selfId = UnrealFX.getSelfWorldObjNum()
    WindowSetShowing(win, true)
    UnrealFX.projectFxToWorldObject(win, attachId)
    if type(ForceUpdateWorldObjectWindow) == "function" then
        pcall(ForceUpdateWorldObjectWindow, attachId, win)
    end
    -- The screen position only updates once the client has drawn the projection,
    -- so the stuck-at-origin check (hostile / self fallback) runs in tickFxInstance.

    local motion = UnrealFX.pickFxMotion(opts)
    local spinStart = 0
    local spiralDir = nil
    if motion == "spin" then
        local turns = UnrealFX.FX_SPIN_DEGREES or 720
        if math.random(2) == 1 then
            turns = -turns
        end
        spinStart = turns
    elseif motion == "spiral" then
        spiralDir = 1
        if math.random(2) == 1 then
            spiralDir = -1
        end
    end

    inst.attachedId = attachId
    inst.key = entry.key
    inst.motion = motion
    inst.spinStartDeg = spinStart
    inst.spiralDir = spiralDir
    inst.useMoveProject = useMove
    inst.phase = "grow"
    inst.t = 0
    inst.noSelfFallback = opts.noSelfFallback == true
    inst.projectTicks = 0
    inst.stuckChecked = false
    inst.fellBackToSelf = selfId ~= 0 and attachId == selfId
    -- Block re-arm / re-FX on the intended corpse even if we displayed on self.
    UnrealFX.markFxDoneWorldId(worldId)
    UnrealFX.consumeCombatHitWorldId(worldId)
    UnrealFX.fxLastKey = entry.key

    if not opts.quiet then
        local who = opts.label or ("worldObj " .. tostring(attachId))
        local soundNote = ""
        if opts.sound and opts.sound ~= "" then
            soundNote = " + sound '" .. tostring(opts.sound) .. "'"
        end
        UnrealFX.chatPrint(
            "Showing FX '"
                .. entry.label
                .. "' ["
                .. motion
                .. "]"
                .. soundNote
                .. " on "
                .. who
                .. ". /ufx fx hide to clear."
        )
    end

    return true
end

function UnrealFX.playKillFx(killType, victimName, opts)
    -- Visual only. Sound is logged once by announcePlayerKill / logPlaybackKeyword.
    opts = opts or {}
    local fxKey = UnrealFX.mapSoundKeywordToFxKey(killType)
    if not fxKey then
        return false
    end

    local worldId = 0
    if opts.defeat then
        worldId = UnrealFX.resolveWorldObjForVictim(victimName)
    else
        -- Combat soft-arm / dead hostile / lastHostile - never a living hostile.
        worldId = UnrealFX.resolveWorldObjForKill(victimName, opts.usedIds)
    end
    if worldId ~= 0 then
        return UnrealFX.showFxOnWorldObject(fxKey, worldId, {
            quiet = true,
            label = UnrealFX.toNarrow(UnrealFX.normalizeUnitName(victimName)),
        })
    end

    if opts.defeat then
        UnrealFX.queuePendingFx(fxKey, victimName, { allowSelf = true })
        return true
    end

    -- Unknown victim world object -> self.
    return UnrealFX.showFxOnSelf(fxKey, {
        quiet = true,
        label = UnrealFX.toNarrow(UnrealFX.normalizeUnitName(victimName)),
    })
end

function UnrealFX.playSoundFx(keyword, worldId)
    local fxKey = UnrealFX.mapSoundKeywordToFxKey(keyword)
    if not fxKey then
        return false
    end

    worldId = tonumber(worldId) or 0
    if worldId == 0 and GameData and GameData.Player then
        worldId = tonumber(GameData.Player.worldObjNum) or 0
    end
    if worldId == 0 then
        return false
    end

    return UnrealFX.showFxOnWorldObject(fxKey, worldId, { quiet = true })
end

function UnrealFX.getFxSoundKeyword(entry)
    if type(entry) ~= "table" then
        return nil
    end

    local sounds = entry.sounds
    if type(sounds) == "table" and #sounds > 0 then
        -- Prefer numbered/variant clips when present (e.g. monsterkill1/2 over bare "monsterkill").
        if #sounds > 1 then
            local pool = {}
            for i = 1, #sounds do
                if sounds[i] ~= entry.key then
                    pool[#pool + 1] = sounds[i]
                end
            end
            if #pool > 0 then
                return pool[math.random(#pool)]
            end
        end
        return sounds[1]
    end

    return entry.key
end

function UnrealFX.showFxTest(requestedKey, motion)
    local worldId = 0
    if GameData and GameData.Player then
        worldId = tonumber(GameData.Player.worldObjNum) or 0
    end
    if worldId == 0 then
        UnrealFX.chatPrint("No player worldObjNum - enter the world first.")
        return
    end

    local entry = UnrealFX.getFxTextureEntry(requestedKey)
    if not entry then
        UnrealFX.chatPrint("Unknown FX. Available: " .. UnrealFX.listFxTextureKeys())
        return
    end

    local soundKey = UnrealFX.getFxSoundKeyword(entry)
    if soundKey then
        UnrealFX.logPlaybackKeyword(soundKey)
    end

    UnrealFX.showFxOnWorldObject(entry.key, worldId, {
        label = "player",
        sound = soundKey,
        restart = true,
        motion = motion,
    })
end

function UnrealFX.handleFxCommand(rest)
    local option = string.lower(UnrealFX.trim(rest))
    if option == "hide" or option == "off" or option == "clear" or option == "stop" then
        UnrealFX.hideFx()
        UnrealFX.chatPrint("FX hidden.")
        return
    end

    if option == "list" then
        UnrealFX.chatPrint("FX images: " .. UnrealFX.listFxTextureKeys())
        return
    end

    local scaleCmd, scaleArg = string.match(option, "^(scale)%s*(.*)$")
    if scaleCmd == "scale" then
        scaleArg = UnrealFX.trim(scaleArg or "")
        if scaleArg == "" or scaleArg == "show" or scaleArg == "?" then
            UnrealFX.chatPrint(
                string.format(
                    "FX scale: %.2f (default %.2f; range %.2f-%.2f). /ufx fx scale <n>",
                    UnrealFX.getFxScale(),
                    UnrealFX.FX_SCALE_DEFAULT or 0.75,
                    UnrealFX.FX_SCALE_MIN or 0.25,
                    UnrealFX.FX_SCALE_MAX or 1.5
                )
            )
            return
        end
        if scaleArg == "reset" or scaleArg == "default" then
            UnrealFX.setFxScale(UnrealFX.FX_SCALE_DEFAULT, true)
            return
        end
        local value = tonumber(scaleArg)
        if not value then
            UnrealFX.chatPrint("Usage: /ufx fx scale [0.25-1.5|reset]")
            return
        end
        UnrealFX.setFxScale(value, true)
        return
    end

    if option == "" or option == "show" or option == "on" or option == "test" or option == "random" then
        UnrealFX.showFxTest(nil)
        return
    end

    -- /ufx fx <key> [grow|spin|spiral]  - motion optional; otherwise random.
    local key, motionArg = string.match(option, "^(%S+)%s+(%S+)$")
    if not key then
        key = option
    end
    if motionArg == "spinning" then
        motionArg = "spin"
    elseif motionArg == "spiraling" or motionArg == "spiralling" then
        motionArg = "spiral"
    elseif motionArg == "punch" or motionArg == "default" then
        motionArg = "grow"
    end
    if motionArg and motionArg ~= "spin" and motionArg ~= "grow" and motionArg ~= "spiral" then
        UnrealFX.chatPrint("Usage: /ufx fx <name> [grow|spin|spiral]")
        return
    end
    UnrealFX.showFxTest(key, motionArg)
end

function UnrealFX.toLowerW(value)
    if not value then
        return L""
    end

    if wstring and wstring.lower then
        return wstring.lower(value)
    end

    local asString = value
    if WStringToString then
        asString = WStringToString(value)
    end

    return towstring(string.lower(tostring(asString)))
end

function UnrealFX.containsAny(haystackW, needles)
    if not haystackW or not needles then
        return false
    end

    for _, needle in ipairs(needles) do
        if needle and wstring.find(haystackW, needle, 1, true) then
            return true
        end
    end

    return false
end

local fortressNeedles = { L"fortress", L"fotress" }
local fortressJoinNeedles = {
    L"reservation",
    L"reserved",
    L"invite",
    L"invitation",
    L"invited",
    L"eligible",
    L"selected",
    L"join",
    L"queue",
    L"queued",
    L"assault",
    L"siege",
    L"instance",
    L"ready",
}
local fortressContextNeedles = {
    L"defender",
    L"attacker",
    L"battle",
    L"siege",
    L"assault",
}
local expiredNeedles = { L"expired" }
local lotdNeedles = { L"land of the dead", L"lotd" }
local reservationNeedles = { L"reservation", L"reserved" }
local ticketNeedles = { L"ticket", L"invitation", L"permit" }

function UnrealFX.shouldAnnounceFortress(textLower)
    if UnrealFX.containsAny(textLower, expiredNeedles)
        and (UnrealFX.containsAny(textLower, fortressNeedles) or UnrealFX.containsAny(textLower, reservationNeedles)) then
        return false
    end

    if UnrealFX.containsAny(textLower, fortressNeedles) and UnrealFX.containsAny(textLower, fortressJoinNeedles) then
        return true
    end

    return UnrealFX.containsAny(textLower, reservationNeedles) and UnrealFX.containsAny(textLower, fortressContextNeedles)
end

function UnrealFX.shouldAnnounceLotd(textLower)
    if UnrealFX.containsAny(textLower, expiredNeedles) and UnrealFX.containsAny(textLower, lotdNeedles) then
        return false
    end

    return UnrealFX.containsAny(textLower, lotdNeedles)
        and (UnrealFX.containsAny(textLower, ticketNeedles) or UnrealFX.containsAny(textLower, reservationNeedles))
end

function UnrealFX.combineTextLower(textList)
    local combinedLower = L""
    for _, alertText in pairs(textList) do
        local textLower = UnrealFX.toLowerW(alertText)
        if textLower ~= L"" then
            if combinedLower ~= L"" then
                combinedLower = combinedLower .. L" "
            end
            combinedLower = combinedLower .. textLower
        end
    end
    return combinedLower
end

function UnrealFX.announceFromTextList(textList)
    if not textList then
        return false
    end

    local combinedLower = UnrealFX.combineTextLower(textList)
    if combinedLower ~= L"" then
        if UnrealFX.shouldAnnounceFortress(combinedLower) then
            if UnrealFX.getFortressAlertsEnabled() then
                UnrealFX.logDeathBlow(L"fortressreservation")
                return true
            end
        end

        if UnrealFX.shouldAnnounceLotd(combinedLower) then
            if UnrealFX.getLotdAlertsEnabled() then
                UnrealFX.logDeathBlow(L"lotdticket")
                return true
            end
        end
    end

    return false
end

function UnrealFX.extractDialogText(dialogText)
    if dialogText == nil then
        return nil
    end

    if type(dialogText) == "table" then
        if dialogText.text ~= nil then
            return dialogText.text
        end
        if dialogText[1] ~= nil then
            return dialogText[1]
        end
    end

    return dialogText
end

function UnrealFX.OnDialogText(dialogText)
    local text = UnrealFX.extractDialogText(dialogText)
    if text == nil or text == L"" then
        return
    end

    UnrealFX.announceFromTextList({ text })
end

function UnrealFX.OnInfoAlertEvent()
    if UnrealFX._dialogUseHook then
        return
    end

    if SystemData and SystemData.Dialogs and SystemData.Dialogs.InfoAlert then
        UnrealFX.OnDialogText(SystemData.Dialogs.InfoAlert)
    end
end

function UnrealFX.OnApplicationOneButtonDialogEvent()
    if UnrealFX._dialogUseHook then
        return
    end

    if SystemData and SystemData.Dialogs and SystemData.Dialogs.AppDlg then
        UnrealFX.OnDialogText(SystemData.Dialogs.AppDlg)
    end
end

function UnrealFX.OnApplicationTwoButtonDialogEvent()
    if UnrealFX._dialogUseHook then
        return
    end

    if SystemData and SystemData.Dialogs and SystemData.Dialogs.AppDlg then
        UnrealFX.OnDialogText(SystemData.Dialogs.AppDlg)
    end
end

function UnrealFX.TryHookDialogManager()
    if UnrealFX._dialogHooked then
        return true
    end

    local dialogManager = DialogManager
    if dialogManager and type(dialogManager.MakeOneButtonDialog) == "function" then
        UnrealFX._dialogHooked = true
        UnrealFX._dialogUseHook = true
        UnrealFX._dialogMakeOneButtonDialog = dialogManager.MakeOneButtonDialog

        dialogManager.MakeOneButtonDialog = function(dialogText, ...)
            local result = UnrealFX._dialogMakeOneButtonDialog(dialogText, ...)
            UnrealFX.OnDialogText(dialogText)
            return result
        end

        if type(dialogManager.MakeTwoButtonDialog) == "function" then
            UnrealFX._dialogMakeTwoButtonDialog = dialogManager.MakeTwoButtonDialog
            dialogManager.MakeTwoButtonDialog = function(dialogText, ...)
                local result = UnrealFX._dialogMakeTwoButtonDialog(dialogText, ...)
                UnrealFX.OnDialogText(dialogText)
                return result
            end
        end

        if type(dialogManager.MakeThreeButtonDialog) == "function" then
            UnrealFX._dialogMakeThreeButtonDialog = dialogManager.MakeThreeButtonDialog
            dialogManager.MakeThreeButtonDialog = function(dialogText, ...)
                local result = UnrealFX._dialogMakeThreeButtonDialog(dialogText, ...)
                UnrealFX.OnDialogText(dialogText)
                return result
            end
        end

        return true
    end

    return false
end

function UnrealFX.OnModulesInitialized()
    UnrealFX.RegisterSlashCommands()
    UnrealFX.printLoginLine()
    UnrealFX.TryHookDialogManager()
    UnrealFX.TryRegisterReadyCheckPacket()
    -- Career/level data is reliably populated by now; re-evaluate in case
    -- Initialize ran before saved settings or player data were restored.
    UnrealFX.updatePullAlertWatch()
    -- Target slot is valid after modules init; Initialize often ran too early for lastHostile.
    UnrealFX.snapshotTargets(false)
    UnrealFX.ensureFxPool()
end

function UnrealFX.TryRegisterReadyCheckPacket()
    if UnrealFX._readyCheckPacketRegistered then
        return true
    end

    if not ror_PacketHandling or type(ror_PacketHandling.Register) ~= "function" then
        return false
    end

    local ok = pcall(ror_PacketHandling.Register, "ReadyCheck:", UnrealFX.OnReadyCheckPacket)
    if not ok then
        return false
    end

    UnrealFX._readyCheckPacketRegistered = true
    return true
end

function UnrealFX.extractReadyCheckTitle(packetText)
    local text = UnrealFX.toNarrow(packetText)
    local title = string.match(text, "^ReadyCheck:Start:([^:]*)") or ""
    title = string.gsub(title, "|bool", "")
    return UnrealFX.trim(title)
end

function UnrealFX.OnReadyCheckPacket(packetText)
    if not UnrealFX.getReadyCheckAlertsEnabled() then
        return
    end

    local text = UnrealFX.toNarrow(packetText)
    if string.find(text, "ReadyCheck:Start:", 1, true) ~= 1 then
        return
    end

    UnrealFX.lastReadyCheckTitle = UnrealFX.extractReadyCheckTitle(text)
    UnrealFX.logDeathBlow(L"readycheck")
end

function UnrealFX.AnnounceScenarioPop()
    local scenarioId = GameData and GameData.ScenarioData and GameData.ScenarioData.startingScenario
    if scenarioId and scenarioId ~= 0 and GetScenarioName then
        local ok, scenarioName = pcall(GetScenarioName, scenarioId)
        if ok and scenarioName and scenarioName ~= L"" then
            if UnrealFX.containsAny(UnrealFX.toLowerW(scenarioName), fortressNeedles) then
                if UnrealFX.getFortressAlertsEnabled() then
                    UnrealFX.logDeathBlow(L"fortressreservation")
                end
                return
            end
        end
    end

    if UnrealFX.getScenarioPopAlertsEnabled() then
        UnrealFX.logDeathBlow(L"scenariopop")
    end
end

function UnrealFX.toNarrow(value)
    if value == nil then
        return ""
    end

    if type(value) == "wstring" and WStringToString then
        local ok, narrowed = pcall(WStringToString, value)
        if ok and narrowed then
            return narrowed
        end
    end

    return tostring(value)
end

function UnrealFX.toWide(value)
    if value == nil then
        return L""
    end

    if type(value) == "wstring" then
        return value
    end

    if towstring then
        local ok, widened = pcall(towstring, tostring(value))
        if ok and widened then
            return widened
        end
    end

    return L""
end

function UnrealFX.makeColorLink(text, color)
    local label = UnrealFX.toNarrow(text)
    local red, green, blue = 255, 255, 255
    if type(color) == "table" then
        red = tonumber(color[1]) or red
        green = tonumber(color[2]) or green
        blue = tonumber(color[3]) or blue
    end
    return string.format("<LINK data=\"0\" color=\"%d,%d,%d\" text=\"%s\">", red, green, blue, label)
end

function UnrealFX.getChatPrefix()
    if UnrealFX._chatPrefixCache then
        return UnrealFX._chatPrefixCache
    end

    local name = UnrealFX.prefixName or "UnrealFX"
    local colored = UnrealFX.makeColorLink(name, UnrealFX.prefixColor)
    UnrealFX._chatPrefixCache = towstring("[" .. colored .. "] ")
    return UnrealFX._chatPrefixCache
end

function UnrealFX.formatHelpHeader(label)
    return UnrealFX.makeColorLink(label, UnrealFX.helpHeaderColor)
end

function UnrealFX.getHelpCommandPrefix()
    return UnrealFX.makeColorLink("/ufx", UnrealFX.helpCommandColor)
end

function UnrealFX.chatPrint(message)
    local output = UnrealFX.getChatPrefix() .. UnrealFX.toWide(message)
    if TextLogAddEntry then
        TextLogAddEntry("Chat", 0, output)
        return
    end
    if EA_ChatWindow and EA_ChatWindow.Print then
        EA_ChatWindow.Print(output)
    end
end

function UnrealFX.trim(value)
    local str = UnrealFX.toNarrow(value)
    str = string.gsub(str, "^%s+", "")
    str = string.gsub(str, "%s+$", "")
    return str
end

function UnrealFX.ensureSettings()
    if type(UnrealFX.settings) ~= "table" then
        UnrealFX.settings = {}
    end
end

function UnrealFX.getSettingBool(settingKey, defaultValue)
    UnrealFX.ensureSettings()
    local value = UnrealFX.settings[settingKey]
    if value == nil then
        value = defaultValue and true or false
        UnrealFX.settings[settingKey] = value
    end
    return value and true or false
end

function UnrealFX.setSettingBool(settingKey, enabled)
    UnrealFX.ensureSettings()
    local value = enabled and true or false
    UnrealFX.settings[settingKey] = value
    return value
end

function UnrealFX.getFxScale()
    UnrealFX.ensureSettings()
    local defaultScale = UnrealFX.FX_SCALE_DEFAULT or 0.75
    local minScale = UnrealFX.FX_SCALE_MIN or 0.25
    local maxScale = UnrealFX.FX_SCALE_MAX or 1.5
    local value = tonumber(UnrealFX.settings.fxScale)
    if value == nil then
        value = defaultScale
        UnrealFX.settings.fxScale = value
    end
    if value < minScale then
        value = minScale
    elseif value > maxScale then
        value = maxScale
    end
    return value
end

function UnrealFX.setFxScale(scale, announce)
    local minScale = UnrealFX.FX_SCALE_MIN or 0.25
    local maxScale = UnrealFX.FX_SCALE_MAX or 1.5
    local value = tonumber(scale)
    if value == nil then
        value = UnrealFX.FX_SCALE_DEFAULT or 0.75
    end
    if value < minScale then
        value = minScale
    elseif value > maxScale then
        value = maxScale
    end
    -- Keep two decimals for SavedVariables readability.
    value = math.floor(value * 100 + 0.5) / 100
    UnrealFX.ensureSettings()
    UnrealFX.settings.fxScale = value
    if announce then
        UnrealFX.chatPrint(string.format("FX scale: %.2f", value))
    end
    return value
end

function UnrealFX.getFxDisplaySize()
    local scale = UnrealFX.getFxScale()
    local w = math.floor((UnrealFX.FX_DISP_W or 456) * scale + 0.5)
    local h = math.floor((UnrealFX.FX_DISP_H or 256) * scale + 0.5)
    if w < 32 then
        w = 32
    end
    if h < 18 then
        h = 18
    end
    return w, h
end

function UnrealFX.getScenarioPopAlertsEnabled()
    return UnrealFX.getSettingBool("scenarioPopAlertsEnabled", true)
end

function UnrealFX.getReadyCheckAlertsEnabled()
    return UnrealFX.getSettingBool("readyCheckAlertsEnabled", true)
end

function UnrealFX.setReadyCheckAlertsEnabled(enabled, announce)
    local value = UnrealFX.setSettingBool("readyCheckAlertsEnabled", enabled)
    if announce then
        UnrealFX.chatPrint("Ready check alerts: " .. (value and "ON" or "OFF"))
    end
end

function UnrealFX.setScenarioPopAlertsEnabled(enabled, announce)
    local value = UnrealFX.setSettingBool("scenarioPopAlertsEnabled", enabled)
    if announce then
        UnrealFX.chatPrint("Scenario pop alerts: " .. (value and "ON" or "OFF"))
    end
end

function UnrealFX.getFortressAlertsEnabled()
    return UnrealFX.getSettingBool("fortressReservationAlertsEnabled", true)
end

function UnrealFX.setFortressAlertsEnabled(enabled, announce)
    local value = UnrealFX.setSettingBool("fortressReservationAlertsEnabled", enabled)
    if announce then
        UnrealFX.chatPrint("Fortress reservation alerts: " .. (value and "ON" or "OFF"))
    end
end

function UnrealFX.getLotdAlertsEnabled()
    return UnrealFX.getSettingBool("lotdTicketAlertsEnabled", true)
end

function UnrealFX.setLotdAlertsEnabled(enabled, announce)
    local value = UnrealFX.setSettingBool("lotdTicketAlertsEnabled", enabled)
    if announce then
        UnrealFX.chatPrint("LotD ticket alerts: " .. (value and "ON" or "OFF"))
    end
end

function UnrealFX.getDefeatAlertsEnabled()
    return UnrealFX.getSettingBool("defeatAlertsEnabled", false)
end

function UnrealFX.setDefeatAlertsEnabled(enabled, announce)
    local value = UnrealFX.setSettingBool("defeatAlertsEnabled", enabled)
    if announce then
        UnrealFX.chatPrint("Defeat alerts: " .. (value and "ON" or "OFF"))
    end
end

function UnrealFX.getPveKillAlertsEnabled()
    return UnrealFX.getSettingBool("pveKillAlertsEnabled", false)
end

function UnrealFX.setPveKillAlertsEnabled(enabled, announce)
    local value = UnrealFX.setSettingBool("pveKillAlertsEnabled", enabled)
    if announce then
        UnrealFX.chatPrint("PVE kill alerts: " .. (value and "ON" or "OFF"))
    end
end

function UnrealFX.getPullAlertConfigForCareer()
    if type(GameData) ~= "table" or type(GameData.Player) ~= "table"
        or type(GameData.Player.career) ~= "table" or type(GameData.CareerLine) ~= "table" then
        return nil
    end

    local careerLine = GameData.Player.career.line
    if careerLine == nil then
        return nil
    end

    for _, config in pairs(UnrealFX.pullAlertConfigs) do
        local configLine = GameData.CareerLine[config.careerKey]
        if configLine ~= nil and configLine == careerLine then
            return config
        end
    end

    return nil
end

function UnrealFX.getPullAlertLevel()
    if type(GameData) ~= "table" or type(GameData.Player) ~= "table" then
        return 0
    end
    return tonumber(GameData.Player.level) or 0
end

function UnrealFX.getPullAlertsEnabled(configKey)
    local config = UnrealFX.pullAlertConfigs[configKey]
    if not config then
        return false
    end
    return UnrealFX.getSettingBool(config.settingKey, false)
end

function UnrealFX.setPullAlertsEnabled(configKey, enabled, announce)
    local config = UnrealFX.pullAlertConfigs[configKey]
    if not config then
        return false
    end

    local value = UnrealFX.setSettingBool(config.settingKey, enabled)
    UnrealFX.updatePullAlertWatch()

    if announce then
        UnrealFX.chatPrint(config.label .. ": " .. (value and "ON" or "OFF"))
        if value and not UnrealFX._pullWatchArmed then
            if UnrealFX.getPullAlertConfigForCareer() ~= config then
                UnrealFX.chatPrint("Note: this alert only plays on a " .. config.careerName .. ".")
            elseif UnrealFX.getPullAlertLevel() < UnrealFX.PULL_ALERT_MIN_LEVEL then
                UnrealFX.chatPrint("Note: this alert arms at level " .. UnrealFX.PULL_ALERT_MIN_LEVEL .. " (toggle again or /reloadui after leveling).")
            end
        end
    end
    return value
end

-- Registers the cast listener only when every gate passes (toggle on,
-- matching career, level 40, event API present); otherwise nothing is
-- registered at all. Level is read directly when this runs (load,
-- /reloadui, or the toggle changing).
function UnrealFX.updatePullAlertWatch()
    local config = UnrealFX.getPullAlertConfigForCareer()
    local enabled = config ~= nil and UnrealFX.getSettingBool(config.settingKey, false)
    local leveled = UnrealFX.getPullAlertLevel() >= UnrealFX.PULL_ALERT_MIN_LEVEL
    local eventAvailable = type(RegisterEventHandler) == "function" and type(UnregisterEventHandler) == "function"
        and type(SystemData) == "table" and type(SystemData.Events) == "table"
        and SystemData.Events.PLAYER_BEGIN_CAST ~= nil

    local wantWatch = enabled and leveled and eventAvailable

    if wantWatch and not UnrealFX._pullWatchArmed then
        RegisterEventHandler(SystemData.Events.PLAYER_BEGIN_CAST, "UnrealFX.OnPullBeginCast")
        UnrealFX._pullWatchArmed = true
    elseif not wantWatch and UnrealFX._pullWatchArmed then
        UnregisterEventHandler(SystemData.Events.PLAYER_BEGIN_CAST, "UnrealFX.OnPullBeginCast")
        UnrealFX._pullWatchArmed = false
    end

    UnrealFX._pullWatchConfig = UnrealFX._pullWatchArmed and config or nil
end

-- PLAYER_BEGIN_CAST fires per cast with the ability id, even for instant
-- abilities, and the game refuses casts that are on cooldown -- so a
-- matching id means the ability fired.
function UnrealFX.OnPullBeginCast(abilityId)
    local watch = UnrealFX._pullWatchConfig
    if watch == nil or abilityId ~= watch.abilityId then
        return
    end
    UnrealFX.logPlaybackKeyword(watch.soundKeyword)
end

function UnrealFX.printPullAlertStatus()
    local config = UnrealFX.getPullAlertConfigForCareer()
    if not config then
        return
    end
    local enabled = UnrealFX.getSettingBool(config.settingKey, false)
    UnrealFX.chatPrint(config.label .. ": " .. (enabled and "ON" or "OFF"))
end

function UnrealFX.printScenarioPopStatus()
    local enabled = UnrealFX.getScenarioPopAlertsEnabled()
    UnrealFX.chatPrint("Scenario pop alerts: " .. (enabled and "ON" or "OFF"))
end

function UnrealFX.printReadyCheckStatus()
    local enabled = UnrealFX.getReadyCheckAlertsEnabled()
    UnrealFX.chatPrint("Ready check alerts: " .. (enabled and "ON" or "OFF"))
end

function UnrealFX.printFortressStatus()
    local enabled = UnrealFX.getFortressAlertsEnabled()
    UnrealFX.chatPrint("Fortress reservation alerts: " .. (enabled and "ON" or "OFF"))
end

function UnrealFX.printLotdStatus()
    local enabled = UnrealFX.getLotdAlertsEnabled()
    UnrealFX.chatPrint("LotD ticket alerts: " .. (enabled and "ON" or "OFF"))
end

function UnrealFX.printDefeatStatus()
    local enabled = UnrealFX.getDefeatAlertsEnabled()
    UnrealFX.chatPrint("Defeat alerts: " .. (enabled and "ON" or "OFF"))
end

function UnrealFX.printPveKillStatus()
    local enabled = UnrealFX.getPveKillAlertsEnabled()
    UnrealFX.chatPrint("PVE kill alerts: " .. (enabled and "ON" or "OFF"))
end

function UnrealFX.printAlertSettings()
    UnrealFX.printReadyCheckStatus()
    UnrealFX.printScenarioPopStatus()
    UnrealFX.printFortressStatus()
    UnrealFX.printLotdStatus()
    UnrealFX.printDefeatStatus()
    UnrealFX.printPveKillStatus()
    UnrealFX.printPullAlertStatus()
end

function UnrealFX.printStatus()
    UnrealFX.chatPrint("Version: " .. UnrealFX.getVersion())
    UnrealFX.printAlertSettings()
end

function UnrealFX.applyAlertOption(option, getter, setter, label)
    local normalized = string.lower(UnrealFX.trim(option))
    if normalized == "" or normalized == "status" then
        UnrealFX.chatPrint(label .. ": " .. (getter() and "ON" or "OFF"))
        return true
    end

    if normalized == "on" or normalized == "enable" or normalized == "enabled" then
        setter(true, true)
        return true
    end

    if normalized == "off" or normalized == "disable" or normalized == "disabled" then
        setter(false, true)
        return true
    end

    if normalized == "toggle" then
        setter(not getter(), true)
        return true
    end

    return false
end

function UnrealFX.normalizeAlertKey(name)
    if name == "readycheck" or name == "ready" or name == "bio" then
        return "readycheck"
    end
    if name == "scenario" or name == "scenariopop" or name == "scen" or name == "pop" then
        return "scenario"
    end
    if name == "fortress" or name == "fortressreservation" then
        return "fortress"
    end
    if name == "lotd" or name == "lotdticket" then
        return "lotd"
    end
    if name == "defeat" or name == "death" then
        return "defeat"
    end
    if name == "pve" or name == "pvekills" or name == "pvekill" or name == "npc" or name == "npckills" then
        return "pve"
    end
    if name == "embrace" or name == "terribleembrace" then
        return "embrace"
    end
    if name == "fetch" then
        return "fetch"
    end
    return ""
end

function UnrealFX.handleAlertCommand(rest)
    local nameRaw, optionRaw = string.match(rest or "", "^(%S+)%s*(.*)$")
    local name = string.lower(UnrealFX.trim(nameRaw))
    local option = UnrealFX.trim(optionRaw)

    if name == "" or name == "status" or name == "list" or name == "show" then
        UnrealFX.printAlertSettings()
        return
    end

    local key = UnrealFX.normalizeAlertKey(name)
    if key == "" then
        UnrealFX.chatPrint("Usage: /ufx alerts [readycheck|scenario|fortress|lotd|defeat|pve|embrace|fetch] [on|off|toggle]")
        return
    end

    local ok = false
    if key == "readycheck" then
        ok = UnrealFX.applyAlertOption(option, UnrealFX.getReadyCheckAlertsEnabled, UnrealFX.setReadyCheckAlertsEnabled, "Ready check alerts")
    elseif key == "scenario" then
        ok = UnrealFX.applyAlertOption(option, UnrealFX.getScenarioPopAlertsEnabled, UnrealFX.setScenarioPopAlertsEnabled, "Scenario pop alerts")
    elseif key == "fortress" then
        ok = UnrealFX.applyAlertOption(option, UnrealFX.getFortressAlertsEnabled, UnrealFX.setFortressAlertsEnabled, "Fortress reservation alerts")
    elseif key == "lotd" then
        ok = UnrealFX.applyAlertOption(option, UnrealFX.getLotdAlertsEnabled, UnrealFX.setLotdAlertsEnabled, "LotD ticket alerts")
    elseif key == "defeat" then
        ok = UnrealFX.applyAlertOption(option, UnrealFX.getDefeatAlertsEnabled, UnrealFX.setDefeatAlertsEnabled, "Defeat alerts")
    elseif key == "pve" then
        ok = UnrealFX.applyAlertOption(option, UnrealFX.getPveKillAlertsEnabled, UnrealFX.setPveKillAlertsEnabled, "PVE kill alerts")
    elseif key == "embrace" or key == "fetch" then
        local getter = function() return UnrealFX.getPullAlertsEnabled(key) end
        local setter = function(enabled, announce) UnrealFX.setPullAlertsEnabled(key, enabled, announce) end
        ok = UnrealFX.applyAlertOption(option, getter, setter, UnrealFX.pullAlertConfigs[key].label)
    end

    if not ok then
        UnrealFX.chatPrint("Usage: /ufx alerts [readycheck|scenario|fortress|lotd|defeat|pve|embrace|fetch] [on|off|toggle]")
    end
end

local slashAliases = {
    ready = "readycheck",
    bio = "readycheck",
    scenario = "scenariopop",
    scen = "scenariopop",
    pop = "scenariopop",
    fortress = "fortressreservation",
    lotd = "lotdticket",
}

local slashKeywords = {
    "firstblood",
    "doublekill",
    "triplekill",
    "ultrakill",
    "killingspree",
    "multikill",
    "monsterkill1",
    "monsterkill2",
    "wickedsick",
    "godlike",
    "annihilation",
    "erradication",
    "extermination",
    "dominating",
    "denied",
    "headshot",
    "holyshit",
    "bloodbath",
    "megakill",
    "ludicrous",
    "rampage",
    "slaughter",
    "unstoppable",
    "defeat",
    "readycheck",
    "scenariopop",
    "fortressreservation",
    "lotdticket",
    "notify",
    "getoverhere",
}

local slashKeywordLookup = {}
for _, keyword in ipairs(slashKeywords) do
    slashKeywordLookup[keyword] = true
end

function UnrealFX.printSlashUsage()
    local cmd = UnrealFX.getHelpCommandPrefix()
    UnrealFX.chatPrint(UnrealFX.formatHelpHeader("Commands"))
    UnrealFX.chatPrint(cmd .. " play <keyword> -- play a known sound keyword (known keywords can omit 'play')")
    UnrealFX.chatPrint(cmd .. " fx [show|hide|list|scale <n>|<name>] -- FX overlay + matching sound on your player")
    UnrealFX.chatPrint(cmd .. " list -- list known keywords and aliases")
    UnrealFX.chatPrint(cmd .. " alerts [readycheck|scenario|fortress|lotd|defeat|pve|embrace|fetch] [on|off|toggle] -- show or change alert toggles")
end

function UnrealFX.printSlashKeywords()
    UnrealFX.chatPrint(UnrealFX.formatHelpHeader("Sound Keywords"))
    UnrealFX.printKeywordList(slashKeywords, "Known: ", 8)
    UnrealFX.chatPrint(UnrealFX.formatHelpHeader("Aliases"))
    UnrealFX.chatPrint("ready/bio -> readycheck")
    UnrealFX.chatPrint("scenario/scen/pop -> scenariopop")
    UnrealFX.chatPrint("fortress -> fortressreservation; lotd -> lotdticket")
end

function UnrealFX.printKeywordList(list, label, chunkSize)
    if type(list) ~= "table" or #list == 0 then
        return
    end

    local size = tonumber(chunkSize) or 8
    local prefix = label or ""
    local total = #list
    local index = 1
    while index <= total do
        local segment = {}
        local stopAt = math.min(total, index + size - 1)
        for i = index, stopAt do
            segment[#segment + 1] = list[i]
        end
        UnrealFX.chatPrint(prefix .. table.concat(segment, ", "))
        prefix = ""
        index = stopAt + 1
    end
end

function UnrealFX.applySlashAlias(keyword)
    local aliased = slashAliases[keyword]
    if aliased then
        return aliased
    end
    return keyword
end

function UnrealFX.resolveKnownKeyword(rawKeyword)
    local keyword = string.lower(UnrealFX.trim(rawKeyword))
    if keyword == "" then
        return nil
    end

    keyword = UnrealFX.applySlashAlias(keyword)
    if slashKeywordLookup[keyword] then
        return keyword
    end

    return nil
end

function UnrealFX.playKeyword(keyword)
    local resolved = UnrealFX.logPlaybackKeyword(keyword)
    -- Prefer attaching to current hostile target when testing a kill FX sound.
    local worldId = UnrealFX.targetSnap.hostile.id
    if worldId == 0 then
        worldId = UnrealFX.targetSnap.mouseover.id
    end
    UnrealFX.playSoundFx(resolved, worldId)
    UnrealFX.chatPrint("Triggered alert: " .. resolved)
end

function UnrealFX.handlePlayCommand(rest)
    local keyword = string.match(rest or "", "^(%S+)")
    keyword = string.lower(UnrealFX.trim(keyword))
    if keyword == "" then
        UnrealFX.chatPrint("Usage: /ufx play <keyword> (use /ufx list for known keywords)")
        return
    end

    local resolved = UnrealFX.resolveKnownKeyword(keyword)
    if not resolved then
        UnrealFX.chatPrint("Unknown keyword. Use /ufx list.")
        return
    end

    UnrealFX.playKeyword(resolved)
end

function UnrealFX.OnSlashCommand(input)
    local asString = string.lower(UnrealFX.trim(input))
    if asString == "" then
        UnrealFX.printSlashUsage()
        return
    end

    local actionRaw, restRaw = string.match(asString, "^(%S+)%s*(.*)$")
    local action = string.lower(actionRaw or "")
    local rest = UnrealFX.trim(restRaw)

    if action == "help" or action == "?" then
        UnrealFX.printSlashUsage()
        return
    end

    if action == "list" or action == "keywords" or action == "sounds" then
        UnrealFX.printSlashKeywords()
        return
    end

    if action == "alerts" or action == "alert" then
        UnrealFX.handleAlertCommand(rest)
        return
    end

    if action == "status" then
        UnrealFX.printStatus()
        return
    end

    if action == "play" or action == "trigger" or action == "test" then
        UnrealFX.handlePlayCommand(rest)
        return
    end

    if action == "fx" or action == "vfx" or action == "effect" then
        UnrealFX.handleFxCommand(rest)
        return
    end

    local keyword = UnrealFX.resolveKnownKeyword(action)
    if keyword then
        UnrealFX.playKeyword(keyword)
        return
    end

    UnrealFX.chatPrint("Unknown command or keyword. Use /ufx help or /ufx list.")
end

-- Registers /ufx and /unrealfx when LibSlash is available. Safe to call again:
-- Initialize tries first, OnModulesInitialized retries once every addon (and so
-- LibSlash, an optional dependency) has loaded. Returns true once registered.
function UnrealFX.RegisterSlashCommands()
    if UnrealFX._slashRegistered then
        return true
    end
    if not (LibSlash and type(LibSlash.RegisterSlashCmd) == "function") then
        return false
    end

    local okShort = pcall(LibSlash.RegisterSlashCmd, "ufx", UnrealFX.OnSlashCommand)
    local okLong = pcall(LibSlash.RegisterSlashCmd, "unrealfx", UnrealFX.OnSlashCommand)
    UnrealFX._slashRegistered = (okShort or okLong) and true or false
    return UnrealFX._slashRegistered
end
