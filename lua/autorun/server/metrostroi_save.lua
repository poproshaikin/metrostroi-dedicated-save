-- Metrostroi: save / load server state
--   * all trains (cars, coupling, positions, skins/numbers, system states)
--   * track switch positions
--   * player positions (and train seats) by SteamID
--
-- Commands (server console, or admins in game):
--   ms_save [name]     save state (default name: "manual")
--   ms_load [name]     remove current trains and load state (default: autosave of current map)
--   ms_saves           list saves
-- Autosave every ms_autosave_interval seconds and on server shutdown (to "autosave_<map>").
-- On server start the autosave of the current map is loaded automatically.

if not SERVER then return end

local DIR = "metrostroi_saves"
file.CreateDir(DIR)

local cv_interval = CreateConVar("ms_autosave_interval", "900", FCVAR_ARCHIVE, "Metrostroi autosave interval, seconds (0 = off)")
local cv_autoload = CreateConVar("ms_autoload", "1", FCVAR_ARCHIVE, "Load the autosave on server start")

local function AutoName() return "autosave_" .. game.GetMap() end
local function Log(...) MsgC(Color(120, 200, 255), "[MS Save] ", color_white, string.format(...), "\n") end

local loading = false
local loadDone = false
local playerRecords = {} -- [steamid64] = {pos, ang, car = Entity|nil, seat = key|nil}

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------
local function IsTrain(ent)
    return IsValid(ent) and ent:GetClass():sub(1, 12) == "gmod_subway_" and ent.Systems ~= nil and ent.FrontBogey ~= nil
end

local function GetTrains()
    local list = {}
    for _, ent in ipairs(ents.GetAll()) do
        if IsTrain(ent) then list[#list + 1] = ent end
    end
    return list
end

local function SkipKey(k)
    return k == "Name"
end

-- Fields that hold CurTime() timestamps: saved as "seconds ago" and shifted on load
local function IsTimeKey(k)
    local l = k:lower()
    return l:find("time") or l:find("timer") or l:find("wait")
end

local function IsNumArray(t)
    local n = #t
    if n == 0 then return false end
    for i = 1, n do if type(t[i]) ~= "number" and type(t[i]) ~= "boolean" then return false end end
    for k in pairs(t) do if type(k) ~= "number" then return false end end
    return true
end

-- Primitive fields of a system (numbers, booleans, numeric arrays)
local function DumpSystem(sys)
    local out = {}
    for k, v in pairs(sys) do
        if type(k) == "string" and not SkipKey(k) then
            local tv = type(v)
            if tv == "number" and IsTimeKey(k) then
                out[k] = { ago = CurTime() - v }
            elseif tv == "number" or tv == "boolean" then
                out[k] = v
            elseif tv == "table" and IsNumArray(v) then
                out[k] = table.Copy(v)
            end
        end
    end
    return out
end

local function RestoreSystem(sys, data)
    for k, v in pairs(data) do
        local cur = sys[k]
        if type(v) == "table" and v.ago then
            -- Timestamp: keep the same elapsed time. If the fresh system already has a
            -- number here it is a configured value (duration), leave it alone.
            if type(cur) ~= "number" then sys[k] = CurTime() - v.ago end
        elseif type(v) == "table" then
            if type(cur) == "table" then
                for i, x in ipairs(v) do cur[i] = x end
            end
        elseif type(cur) == type(v) or cur == nil then
            sys[k] = v
        end
    end
    if sys.Value ~= nil and sys.TargetValue ~= nil then sys.TargetValue = sys.Value end
end

-- Raw snapshot of a system's primitive fields, to roll back a system that breaks
local function Snapshot(sys)
    local s = {}
    for k, v in pairs(sys) do
        local tv = type(v)
        if tv == "number" or tv == "boolean" or tv == "string" then s[k] = v
        elseif tv == "table" and IsNumArray(v) then s[k] = table.Copy(v) end
    end
    return s
end

local function Rollback(sys, snap, restored)
    for k in pairs(restored) do
        if snap[k] == nil and type(sys[k]) ~= "table" then sys[k] = nil end
    end
    for k, v in pairs(snap) do
        if type(v) == "table" and type(sys[k]) == "table" then
            for i, x in ipairs(v) do sys[k][i] = x end
        else
            sys[k] = v
        end
    end
end

-- Restore a system and test-run it once; roll back on error
local function SafeRestoreSystem(ent, sname, sys, data)
    local snap = Snapshot(sys)
    RestoreSystem(sys, data)
    if type(sys.Think) ~= "function" then return true end
    local orig = sys.Think
    local ok, err = pcall(orig, sys, 0.01, 1)
    if not ok then
        Rollback(sys, snap, data)
        Log("System %s of %s could not be restored (%s), reset to default", sname, ent:GetClass(), tostring(err))
        return false
    end
    -- Guard the system for a while: some errors only appear once power is applied
    local guard
    guard = function(self, ...)
        local ok2, err2 = pcall(orig, self, ...)
        if not ok2 then
            sys.Think = orig
            Rollback(sys, snap, data)
            Log("System %s of %s failed after load (%s), reset to default", sname, ent:GetClass(), tostring(err2))
        end
    end
    sys.Think = guard
    timer.Simple(60, function() if sys.Think == guard then sys.Think = orig end end)
    return true
end

-- Systems that are pure physics / derived values: restoring them into a train that now
-- stands still causes current spikes (BV trips, RP lamp). They start from defaults.
local NO_RESTORE = {
    Electric = true, Engines = true, TR = true, Panel = true,
    RheostatController = true, PositionSwitch = true,
}

local NW2_TYPES = { Int = true, Float = true, Bool = true, String = true }

local function DumpNW2(ent)
    local out = {}
    if not ent.GetNW2VarTable then return out end
    for k, v in pairs(ent:GetNW2VarTable() or {}) do
        if type(v) == "table" and NW2_TYPES[v.type] then
            out[#out + 1] = { k = k, t = v.type, v = v.value }
        end
    end
    return out
end

local function RestoreNW2(ent, list)
    for _, e in ipairs(list or {}) do
        local f = ent["SetNW2" .. e.t]
        if f then f(ent, e.k, e.v) end
    end
end

-- Train-level door/flag fields worth keeping (cab doors etc.)
local TRAIN_FIELDS = { "RearDoor", "PassengerDoor", "CabinDoor", "OtsekDoor1", "OtsekDoor2",
    "FrontAutoCouple", "RearAutoCouple", "WagonNumber", "CustomSettings", "Dot5" }

local function PartTransform(e)
    if not IsValid(e) then return nil end
    return { p = e:GetPos(), a = e:GetAngles() }
end

local function SetPart(e, t)
    if not IsValid(e) or not t then return end
    e:SetPos(t.p); e:SetAngles(t.a)
    local phys = e:GetPhysicsObject()
    if IsValid(phys) then phys:SetVelocity(Vector()); phys:SetAngleVelocity(Vector()) end
end

local function FindSeat(veh)
    if not IsValid(veh) then return end
    for _, car in ipairs(GetTrains()) do
        for k, v in pairs(car:GetTable()) do
            if v == veh and type(k) == "string" then return car, k end
        end
    end
end

local function RecordPlayer(ply)
    local rec = { pos = ply:GetPos(), ang = ply:EyeAngles() }
    if ply:InVehicle() then
        local car, key = FindSeat(ply:GetVehicle())
        if car then rec.car, rec.seat = car, key end
    end
    playerRecords[ply:SteamID64()] = rec
end

--------------------------------------------------------------------------------
-- Save
--------------------------------------------------------------------------------
local function Save(name)
    name = (name and name ~= "") and name or "manual"
    local trains = GetTrains()
    local index = {}
    for i, car in ipairs(trains) do index[car] = i end

    local data = { map = game.GetMap(), time = os.time(), cars = {}, couples = {}, blades = {}, switches = {}, players = {} }

    for i, car in ipairs(trains) do
        local c = {
            class = car:GetClass(),
            body = PartTransform(car),
            fb = PartTransform(car.FrontBogey), rb = PartTransform(car.RearBogey),
            fc = PartTransform(car.FrontCouple), rc = PartTransform(car.RearCouple),
            nw2 = DumpNW2(car),
            systems = {},
            fields = {},
            plombs = car.Plombs and table.Copy(car.Plombs) or nil,
            owner = IsValid(car.Owner) and car.Owner:IsPlayer() and car.Owner:SteamID64() or car.MSOwnerSID,
        }
        for sname, sys in pairs(car.Systems) do c.systems[sname] = DumpSystem(sys) end
        for _, f in ipairs(TRAIN_FIELDS) do
            local v = car[f]
            if type(v) == "number" or type(v) == "boolean" then c.fields[f] = v end
        end
        data.cars[i] = c

        -- Coupling links (recorded once per pair)
        for _, side in ipairs({ "Front", "Rear" }) do
            local cp = car[side .. "Couple"]
            if IsValid(cp) and IsValid(cp.CoupledEnt) then
                local other = cp.CoupledEnt
                local ocar = other:GetNW2Entity("TrainEntity")
                local j = index[ocar]
                if j and j > i then
                    local oside = ocar.FrontCouple == other and "Front" or "Rear"
                    data.couples[#data.couples + 1] = { i, side, j, oside }
                end
            end
        end
    end

    -- Track switch blades (map entities: stable MapCreationID)
    for _, d in ipairs(ents.FindByClass("prop_door_rotating")) do
        if d:GetName():find("switch") or d:GetName():find("swh") or d:GetName():find("swit") then
            local id = d:MapCreationID()
            if id and id >= 0 then
                data.blades[#data.blades + 1] = { id = id, s = d:GetSaveTable().m_eDoorState or 0 }
            end
        end
    end
    -- Metrostroi switch logic
    for _, sw in ipairs(ents.FindByClass("gmod_track_switch")) do
        data.switches[#data.switches + 1] = {
            p = sw:GetPos(), alt = sw.AlternateTrack == true,
            locked = sw.LockedSignal, nochange = sw.NotChangePos == true,
        }
    end

    -- Players: online players now, plus remembered offline ones
    for _, ply in ipairs(player.GetHumans()) do RecordPlayer(ply) end
    for sid, rec in pairs(playerRecords) do
        local r = { pos = rec.pos, ang = rec.ang }
        if IsValid(rec.car) and index[rec.car] then r.car, r.seat = index[rec.car], rec.seat end
        data.players[sid] = r
    end

    -- Other addons can store their own state with the save:
    --   hook.Add("MetrostroiSave_Save", id, function(ext, cars, index) ext.myaddon = {...} end)
    -- cars = saved cars in order, index[car] = its number in the save (use numbers, not entities)
    data.ext = {}
    local ok, err = pcall(hook.Run, "MetrostroiSave_Save", data.ext, trains, index)
    if not ok then Log("An addon failed to save its state: %s", tostring(err)) end

    file.Write(DIR .. "/" .. name .. ".txt", util.TableToJSON(data))
    Log("Saved '%s': %d cars, %d couplings, %d players", name, #data.cars, #data.couples, table.Count(data.players))
    return true
end

--------------------------------------------------------------------------------
-- Load
--------------------------------------------------------------------------------
local function ApplyPlayer(ply)
    if not IsValid(ply) or not ply:Alive() then return end
    local rec = playerRecords[ply:SteamID64()]
    if not rec then return end
    if IsValid(rec.car) and rec.seat and IsValid(rec.car[rec.seat]) and rec.car[rec.seat]:IsVehicle()
        and not IsValid(rec.car[rec.seat]:GetDriver()) then
        ply:EnterVehicle(rec.car[rec.seat])
    elseif rec.pos then
        ply:SetPos(rec.pos)
        if rec.ang then ply:SetEyeAngles(rec.ang) end
    end
end

local function Load(name)
    name = (name and name ~= "") and name or AutoName()
    local raw = file.Read(DIR .. "/" .. name .. ".txt", "DATA")
    if not raw then Log("No save '%s'", name) return false end
    local data = util.JSONToTable(raw)
    if not data then Log("Save '%s' is corrupted", name) return false end
    if data.map ~= game.GetMap() then
        Log("Save '%s' is for map %s, current map is %s", name, tostring(data.map), game.GetMap())
        return false
    end

    loading, loadDone = true, false
    for _, car in ipairs(GetTrains()) do SafeRemoveEntity(car) end

    -- 1) Spawn cars and place body, bogeys and couplers
    local cars = {}
    for i, c in ipairs(data.cars or {}) do
        local ent = ents.Create(c.class)
        if IsValid(ent) then
            ent:SetPos(c.body.p); ent:SetAngles(c.body.a)
            ent:Spawn()
            ent:Activate()
            -- Place the car and let Metrostroi put it on the rails below it, like the spawner:
            -- body at the saved spot, bogeys/couplers at their default offsets (the rerailer
            -- computes the body height from where the bogeys are), then RerailTrain.
            local function TryRerail()
                if not IsValid(ent) then return true end
                SetPart(ent, c.body)
                for _, part in ipairs({ ent.FrontBogey, ent.RearBogey, ent.FrontCouple, ent.RearCouple }) do
                    if IsValid(part) and part.SpawnPos then
                        part:SetPos(ent:LocalToWorld(part.SpawnPos))
                        if part.SpawnAng then part:SetAngles(ent:LocalToWorldAngles(part.SpawnAng)) end
                    end
                end
                return Metrostroi.RerailTrain and Metrostroi.RerailTrain(ent)
            end
            if not TryRerail() then
                -- Retry once a moment later (right after map start the car may not be ready)
                timer.Simple(0.5, function()
                    if not TryRerail() and IsValid(ent) then
                        Log("Rerail failed for car %d (%s), using saved positions", i, c.class)
                        SetPart(ent, c.body)
                        SetPart(ent.FrontBogey, c.fb); SetPart(ent.RearBogey, c.rb)
                        SetPart(ent.FrontCouple, c.fc); SetPart(ent.RearCouple, c.rc)
                    end
                end)
            end
            -- Owner (needed for rerail and other owner-only actions)
            ent.MSOwnerSID = c.owner
            if c.owner then
                local owner = player.GetBySteamID64(c.owner)
                if IsValid(owner) then ent.Owner = owner end
            end
            -- Hold the train in place until systems are restored
            ent.IgnoreEngine = true
            for _, b in ipairs({ ent.FrontBogey, ent.RearBogey }) do
                if IsValid(b) then b.BrakeCylinderPressure = 3; b.MotorPower = 0; b.PneumaticBrakeForce = 50000 end
            end
            cars[i] = ent
        else
            Log("Can't create %s (addon missing?)", tostring(c.class))
        end
    end

    -- 2) Couple (after the rerailer has released the cars, ~1-1.5 s)
    timer.Simple(2.5, function()
        for _, l in ipairs(data.couples or {}) do
            local a, b = cars[l[1]], cars[l[3]]
            if IsValid(a) and IsValid(b) then
                local ca, cb = a[l[2] .. "Couple"], b[l[4] .. "Couple"]
                if IsValid(ca) and IsValid(cb) and not ca.CoupledEnt and not cb.CoupledEnt then
                    ca:Couple(cb)
                end
            end
        end
    end)

    -- 3) Restore skins, numbers and system states (after the trains' first think)
    timer.Simple(3.5, function()
        for i, c in pairs(data.cars or {}) do
            local ent = cars[i]
            if IsValid(ent) then
                -- TrainSpawnerUpdate turns spawner *choices* into final looks (ARS panel,
                -- KV, BPSN...), seeded by the wagon number. Our NW2 values are already
                -- final, so: restore number/flags, let it run (server-side config),
                -- then write the saved final values back over whatever it changed.
                for f, v in pairs(c.fields or {}) do ent[f] = v end
                RestoreNW2(ent, c.nw2)
                if ent.TrainSpawnerUpdate then pcall(ent.TrainSpawnerUpdate, ent) end
                RestoreNW2(ent, c.nw2)
                if ent.UpdateTextures then pcall(ent.UpdateTextures, ent) end
                for sname, sdata in pairs(c.systems or {}) do
                    local sys = ent.Systems[sname]
                    if sys and not NO_RESTORE[sname] then SafeRestoreSystem(ent, sname, sys, sdata) end
                end
                for f, v in pairs(c.fields or {}) do ent[f] = v end
                if c.plombs then
                    ent.Plombs = c.plombs
                    ent.Plombs.Init = nil
                end
            end
        end
    end)

    -- 4) Release the trains, restore switches and players
    timer.Simple(5.5, function()
        for _, ent in pairs(cars) do if IsValid(ent) then ent.IgnoreEngine = false end end

        local byId = {}
        for _, b in ipairs(data.blades or {}) do byId[b.id] = b.s end
        for _, d in ipairs(ents.FindByClass("prop_door_rotating")) do
            local s = byId[d:MapCreationID()]
            if s ~= nil then d:Fire((s == 1 or s == 2) and "Open" or "Close", "", 0) end
        end
        for _, saved in ipairs(data.switches or {}) do
            for _, sw in ipairs(ents.FindInSphere(saved.p, 16)) do
                if sw:GetClass() == "gmod_track_switch" then
                    sw.NotChangePos = saved.nochange
                    sw.LockedSignal = saved.locked
                    if not saved.nochange then sw:SendSignal(saved.alt and "alt" or "main", sw:GetChannel()) end
                end
            end
        end

        playerRecords = {}
        for sid, r in pairs(data.players or {}) do
            playerRecords[sid] = { pos = r.pos, ang = r.ang, car = r.car and cars[r.car] or nil, seat = r.seat }
        end
        loading, loadDone = false, true
        for _, ply in ipairs(player.GetHumans()) do
            if not ply.MSRestored then ply.MSRestored = true; ApplyPlayer(ply) end
        end
        -- Trains are coupled and running again: let other addons restore their state
        --   hook.Add("MetrostroiSave_Load", id, function(ext, cars, savedAt) ... end)
        -- cars[n] = the new entity of car number n; savedAt = os.time() of the save
        local ok, err = pcall(hook.Run, "MetrostroiSave_Load", data.ext or {}, cars, data.time)
        if not ok then Log("An addon failed to restore its state: %s", tostring(err)) end
        Log("Loaded '%s': %d cars", name, table.Count(cars))
    end)
    return true
end

--------------------------------------------------------------------------------
-- Commands
--------------------------------------------------------------------------------
local function Allowed(ply) return not IsValid(ply) or ply:IsAdmin() end
local function Reply(ply, msg) if IsValid(ply) then ply:ChatPrint("[MS Save] " .. msg) end Log("%s", msg) end

concommand.Add("ms_save", function(ply, _, args)
    if not Allowed(ply) then return end
    if loading then Reply(ply, "Loading in progress, try later") return end
    Save(args[1])
    Reply(ply, "Saved " .. (args[1] or "manual"))
end)

concommand.Add("ms_load", function(ply, _, args)
    if not Allowed(ply) then return end
    if loading then Reply(ply, "Loading already in progress") return end
    for _, p in ipairs(player.GetHumans()) do p.MSRestored = false end
    if not Load(args[1]) then Reply(ply, "Load failed, see server console") end
end)

concommand.Add("ms_saves", function(ply)
    if not Allowed(ply) then return end
    local files = file.Find(DIR .. "/*.txt", "DATA", "datedesc")
    for _, f in ipairs(files) do
        Reply(ply, f:gsub("%.txt$", "") .. "  " .. os.date("%Y-%m-%d %H:%M", file.Time(DIR .. "/" .. f, "DATA")))
    end
    if #files == 0 then Reply(ply, "No saves") end
end)

--------------------------------------------------------------------------------
-- Hooks: players, autosave, autoload
--------------------------------------------------------------------------------
hook.Add("PlayerDisconnected", "MetrostroiSave", function(ply)
    if not loading then RecordPlayer(ply) end
end)

-- Give loaded cars back to their owner when he (re)joins
hook.Add("PlayerInitialSpawn", "MetrostroiSaveOwner", function(ply)
    local sid = ply:SteamID64()
    for _, car in ipairs(GetTrains()) do
        if car.MSOwnerSID == sid and not IsValid(car.Owner) then car.Owner = ply end
    end
end)

hook.Add("PlayerSpawn", "MetrostroiSave", function(ply)
    if ply.MSRestored or ply:IsBot() then return end
    local tries = 0
    local id = "MSRestore" .. ply:EntIndex()
    timer.Create(id, 1, 60, function()
        tries = tries + 1
        if not IsValid(ply) then timer.Remove(id) return end
        if loading then return end -- wait until trains are loaded
        ply.MSRestored = true
        timer.Remove(id)
        ApplyPlayer(ply)
    end)
end)

local function StartAutosaveTimer()
    timer.Create("MetrostroiAutosave", math.max(cv_interval:GetFloat(), 30), 0, function()
        if cv_interval:GetFloat() <= 0 or loading then return end
        Save(AutoName())
    end)
end
cvars.AddChangeCallback("ms_autosave_interval", StartAutosaveTimer, "MetrostroiSave")

hook.Add("ShutDown", "MetrostroiSave", function()
    if not loading and #GetTrains() > 0 then Save(AutoName()) end
end)

hook.Add("InitPostEntity", "MetrostroiSave", function()
    StartAutosaveTimer()
    if not cv_autoload:GetBool() then return end
    -- Give Metrostroi time to build its rail network and switches
    timer.Simple(10, function()
        local raw = file.Read(DIR .. "/" .. AutoName() .. ".txt", "DATA")
        local data = raw and util.JSONToTable(raw)
        if data and data.map == game.GetMap() and #GetTrains() == 0 then
            Log("Autoloading autosave from %s", os.date("%Y-%m-%d %H:%M", data.time or 0))
            Load(AutoName())
        end
    end)
end)
