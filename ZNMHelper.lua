_addon.name = 'ZNMHelper'
_addon.author = 'n0gr1p / OpenAI'
_addon.version = '0.1.0'
_addon.commands = {'znmh', 'znmhelper'}

local packets = require('packets')
local res = require('resources')
local config = require('config')

local defaults = {
    -- Optional leader restriction; by default whoever runs //znmh start leads.
    leader = '',
    -- Only explicit user overrides go here. Old per-stage saved recipients are ignored.
    recipient_overrides = {},
    -- Configure per NM before starting. Exact item names are resolved via Windower resources.
    stages = {
        vulpangue = {pop = 'Hellcage Butterfly', mob = 'Vulpangue', trophy = "Vulpangue's Wing"},
        irizima = {pop = 'Senorita Pamama', mob = 'Iriz Ima', trophy = "Iriz Ima's Hide"},
        lamia = {pop = 'Myrrh', mob = 'Experimental Lamia', trophy = 'Ex. Lamia Armband'},
        mahjlaef = {pop = 'Exorcism Treatise', mob = 'Mahjlaef the Paintorn', trophy = "Mahjlaef's Staff"},
        nuhn = {pop = 'Rose Scampi', mob = 'Nuhn', trophy = "Nuhn's Esca"},
        armedgears = {pop = 'Ferrite', mob = 'Armed Gears', trophy = "A. Gears' Fragment"},
        gotohzha = {pop = 'Sheep Botfly', mob = 'Gotoh Zha the Redolent', trophy = "G. Zha's Necklace"},
        dea = {pop = 'Olzhiryan Cactus', mob = 'Dea', trophy = "Dea's Horn"},
        chigre = {pop = 'Spoilt Blood', mob = 'Chigre', trophy = 'Chigre'},
        verdelet = {pop = 'Mint Drop', mob = 'Verdelet', trophy = "Verdelet's Wing"},
        tyger = {pop = 'Singed Buffalo', mob = 'Tyger', trophy = "Tyger's Tail"},
        tinnin = {pop = 'Monkey Wine', mob = 'Tinnin', trophy = "Tinnin's Fang"},
    },
}
local settings = config.load(defaults)
settings.recipient_overrides = settings.recipient_overrides or {}
local running, stage, waiting, seen_mob, last_owner = false, nil, false, false, ''
local last_pop_time, last_seen_time, last_query = 0, 0, 0
local pending_stage, pending_retry_at, last_pending_log = nil, 0, 0
local pending_fresh_seen, pending_fresh_target = nil, nil
local awaiting_ack, selected_owner = false, nil
local end_of_queue = false
local peers, last_lotted = {}, {}
local claimed_owner, session_leader = nil, nil
-- Followers do not set "running": they must explicitly receive START to enable
-- loot handling, and STOP always disarms it, even if stage/recipient stay cached.
local loot_active = false
-- Allow time for the NM and treasure pool to settle before assigning another
-- popper. Respawn readiness is checked on the selected popper, not timed here.
local delay_after_kill = 12
local retry_interval = 2
local fresh_pop_delay = 20
local max_spawn_wait = 25
local target_range = 6
-- Debug observations are local to each client and never trigger a target or trade.
local pop_debug = false
local debug_last_poll = 0
local debug_last_state = nil
local debug_file, debug_file_path = nil, nil

local function now() return os.time() end
local function me()
    local p = windower.ffxi.get_player()
    return p and p.name or nil
end
local function log(s) windower.add_to_chat(207, '[ZNMH] '..tostring(s)) end
local function send(kind, ...)
    local parts = {'ZNMH1', kind}
    for _, v in ipairs({...}) do parts[#parts+1] = tostring(v) end
    windower.send_ipc_message(table.concat(parts, '|'))
end
local function split(s)
    local out = {}
    for v in (s..'|'):gmatch('(.-)|') do out[#out+1] = v end
    return out
end
local function item_id(name)
    local target = name:lower()
    for id, item in pairs(res.items) do
        if type(id) == 'number' and item and (item.en or item.english) and (item.en or item.english):lower() == target then
            return id
        end
    end
    return nil
end
local function owned_in_inventory(id)
    local inv = windower.ffxi.get_items(0)
    if not inv then return nil end
    for index = 1, (inv.max or 80) do
        local x = inv[index]
        if x and x.id == id and x.count > 0 then return index, x.count end
    end
    return nil
end
local function pop_available()
    if not stage or not settings.stages[stage] then return false end
    local id = item_id(settings.stages[stage].pop)
    return id and owned_in_inventory(id) ~= nil
end
local function nearby_mob(name)
    local p = windower.ffxi.get_mob_by_target('me')
    if not p then return false end
    for _, mob in pairs(windower.ffxi.get_mob_array() or {}) do
        if mob and mob.name == name and mob.hpp and mob.hpp > 0 and mob.distance and mob.distance < 2500 then
            return true
        end
    end
    return false
end
local function has_treasure(item_name)
    if not item_name or item_name == '' then return false end
    local id = item_id(item_name)
    if not id then return false end
    local all = windower.ffxi.get_items()
    for slot = 0, 9 do
        local v = all and all.treasure and all.treasure[slot]
        if v and v.item_id == id then return true end
    end
    return false
end
-- Persist automatic loot decisions independently of the optional pop-debug log.
-- Entries describe commands issued, not proof that the game accepted the lot.
local loot_audit_error_reported = false
local function audit_loot_request(action, trophy, recipient, slot)
    local player_name = tostring(me() or 'Unknown'):gsub('[^%w_-]', '_')
    local path = windower.addon_path..'data/ZNMHelper_loot_'..player_name..'_'..os.date('%Y%m%d')..'.csv'
    local file, err = io.open(path, 'a+')
    if not file then
        if not loot_audit_error_reported then
            log('LOOT AUDIT ERROR: '..tostring(err))
            loot_audit_error_reported = true
        end
        return
    end
    local function csv_cell(value)
        local value_text = tostring(value or '')
        if value_text:find('[,"]') or value_text:find(string.char(10), 1, true)
            or value_text:find(string.char(13), 1, true) then
            return '"'..value_text:gsub('"', '""')..'"'
        end
        return value_text
    end
    local ok, write_err = pcall(function()
        if file:seek('end') == 0 then
            assert(file:write('time,character,action,stage,trophy,recipient,claimed_owner,slot,loot_active'..string.char(10)))
        end
        local fields = {os.date('%Y-%m-%dT%H:%M:%S'), me() or '', action,
            stage or '', trophy or '', recipient or '', claimed_owner or '', slot, loot_active}
        for i = 1, #fields do fields[i] = csv_cell(fields[i]) end
        assert(file:write(table.concat(fields, ',')..string.char(10)))
        assert(file:flush())
    end)
    file:close()
    if not ok and not loot_audit_error_reported then
        log('LOOT AUDIT ERROR: '..tostring(write_err))
        loot_audit_error_reported = true
    end
end
local function trophy_recipient(stage_key)
    -- Never infer entitlement from a saved stage definition: older settings.xml
    -- files contain hardcoded recipients from the former one-off farming plan.
    -- No trophy is routed until this session identifies the actual popper.
    if not claimed_owner then return nil end
    local override = settings.recipient_overrides[stage_key]
    if override and override ~= '' and override:lower() ~= 'owner' then
        return override
    end
    return claimed_owner
end

local function is_session_leader()
    return session_leader and me()
        and session_leader:lower() == me():lower()
end

local function lot_trophy()
    if not loot_active or not stage or not settings.stages[stage] then return end
    local cfg = settings.stages[stage]
    if not cfg.trophy or cfg.trophy == '' then return end
    local recipient = trophy_recipient(stage)
    if not recipient then return end
    local id = item_id(cfg.trophy)
    if not id then return end
    local items = windower.ffxi.get_items()
    for slot = 0, 9 do
        local v = items and items.treasure and items.treasure[slot]
        if v and v.item_id == id then
            local fingerprint = stage..':'..slot..':'..tostring(v.item_id)..':'..tostring(v.timestamp or v.drop_time or 0)
            if not last_lotted[fingerprint] then
                last_lotted[fingerprint] = true
                if me():lower() == recipient:lower() then
                    audit_loot_request('REQUEST_LOT', cfg.trophy, recipient, slot)
                    windower.ffxi.lot_item(slot)
                    log('Lotting '..cfg.trophy..' for '..me())
                else
                    audit_loot_request('REQUEST_PASS', cfg.trophy, recipient, slot)
                    windower.ffxi.pass_item(slot)
                end
            end
        end
    end
end
-- Keep the diagnostic stream separate from game chat. CSV is per character and
-- append-only; flush after every record so a client crash loses at most an
-- in-flight sample. Sampling is bounded to once per second.
local debug_header = 'time,character,event,stage,count,id,index,valid_target,status,spawn_type,target_type,hpp,is_npc,distance_sq,x,y,z,running,waiting,seen_nm,awaiting_ack,pending_stage'

local function debug_csv_value(value)
    if value == nil then return '' end
    local s = tostring(value)
    if s:find('[,"]') or s:find(string.char(10), 1, true) or s:find(string.char(13), 1, true) then
        return '"'..s:gsub('"', '""')..'"'
    end
    return s
end

local function debug_close_file()
    if debug_file then pcall(function() debug_file:flush(); debug_file:close() end) end
    debug_file = nil
end

local function debug_open_file()
    if debug_file then return true end
    local name = tostring(me() or 'Unknown'):gsub('[^%w_-]', '_')
    local path = windower.addon_path..'data/ZNMHelper_pop_'..name..'_'..os.date('%Y%m%d')..'.csv'
    local file, err = io.open(path, 'a+')
    if not file then
        log('POP DEBUG ERROR: cannot open file: '..tostring(err))
        return false
    end
    local size = file:seek('end')
    if size == 0 then
        local written, write_err = file:write(debug_header..string.char(10))
        if not written then
            log('POP DEBUG ERROR: cannot write header: '..tostring(write_err))
            file:close()
            return false
        end
    end
    local flushed, flush_err = file:flush()
    if not flushed then
        log('POP DEBUG ERROR: cannot flush header: '..tostring(flush_err))
        file:close()
        return false
    end
    debug_file, debug_file_path = file, path
    return true
end

local function debug_pop_snapshot()
    local nearest, count = nil, 0
    -- get_mob_array does not require any character to select the ???.
    for _, mob in pairs(windower.ffxi.get_mob_array() or {}) do
        if mob and mob.name == '???' and mob.distance
            and mob.distance <= target_range * target_range then
            count = count + 1
            if not nearest or mob.distance < nearest.distance then nearest = mob end
        end
    end
    if not nearest then return 'none', {0} end
    local fields = {
        count, nearest.id, nearest.index, nearest.valid_target,
        nearest.status, nearest.spawn_type, nearest.target_type,
        nearest.hpp, nearest.is_npc, nearest.distance,
        nearest.x, nearest.y, nearest.z,
    }
    -- Include identity and all readiness-like flags, but ignore coordinate
    -- jitter when determining whether a state actually changed.
    local state = table.concat({
        tostring(count), tostring(nearest.id), tostring(nearest.index),
        tostring(nearest.valid_target), tostring(nearest.status),
        tostring(nearest.spawn_type), tostring(nearest.target_type),
        tostring(nearest.hpp), tostring(nearest.is_npc)
    }, '|')
    return state, fields
end

local function debug_write_record(event, fields)
    if not debug_open_file() then pop_debug = false; return false end
    local row = {
        os.date('%Y-%m-%dT%H:%M:%S'), me() or '', event, stage or '',
    }
    for index = 1, 13 do
        local value = fields[index]
        row[#row+1] = value == nil and '' or value
    end
    row[#row+1] = running
    row[#row+1] = waiting
    row[#row+1] = seen_mob
    row[#row+1] = awaiting_ack
    row[#row+1] = pending_stage or ''
    for i = 1, #row do row[i] = debug_csv_value(row[i]) end
    local ok, err = debug_file:write(table.concat(row, ',')..string.char(10))
    if ok then ok, err = debug_file:flush() end
    if not ok then
        log('POP DEBUG ERROR: file write/flush failed: '..tostring(err)..'; stopping diagnostics')
        pop_debug = false
        debug_close_file()
        return false
    end
    return true
end

local function debug_pop_tick()
    if not pop_debug or now() == debug_last_poll then return end
    debug_last_poll = now()
    local state, fields = debug_pop_snapshot()
    local event = state ~= debug_last_state and 'CHANGE' or 'SAMPLE'
    if debug_write_record(event, fields) then debug_last_state = state end
end

windower.register_event('unload', function()
    debug_close_file()
end)

local function guarded_pop(requested_stage)
    local cfg = settings.stages[requested_stage]
    if not cfg then return false, 'Unknown stage' end
    local player = windower.ffxi.get_player()
    if not player then return false, 'Character not ready' end
    local id = item_id(cfg.pop)
    if not id then return false, 'Unknown pop item: '..cfg.pop, true end
    local slot = owned_in_inventory(id)
    if not slot then return false, 'No '..cfg.pop..' in main Inventory', true end

    -- Resolve the entity directly; no need to select or retarget the ???.
    local t, matches = nil, 0
    for _, mob in pairs(windower.ffxi.get_mob_array() or {}) do
        if mob and mob.name == '???' and mob.id and mob.index
            and mob.distance and mob.distance <= target_range * target_range then
            matches = matches + 1
            t = mob
        end
    end
    if matches == 0 then
        pending_fresh_seen, pending_fresh_target = nil, nil
        return false, 'Waiting for nearby ???'
    end
    if matches > 1 then
        pending_fresh_seen, pending_fresh_target = nil, nil
        return false, 'Multiple nearby ??? targets: cannot choose safely', true
    end
    -- A visible ??? may still be in its cooldown state. Require the selected
    -- popper to observe valid_target=true for 20 continuous seconds.
    if t.valid_target ~= true then
        pending_fresh_seen, pending_fresh_target = nil, nil
        return false, 'Waiting for nearby ??? valid_target=true'
    end
    local target_key = tostring(t.id)..':'..tostring(t.index)
    if pending_fresh_target ~= target_key then
        pending_fresh_target, pending_fresh_seen = target_key, now()
    end
    local remaining = fresh_pop_delay - (now() - pending_fresh_seen)
    if remaining > 0 then
        return false, '??? valid_target=true; safety buffer '..remaining..'s remaining'
    end

    if player.status ~= 0 then return false, 'Not idle' end
    local pkt = packets.new('outgoing', 0x036, {
        ['Target'] = t.id,
        ['Target Index'] = t.index,
        ['Item Count 1'] = 1,
        ['Item Index 1'] = slot,
        ['Number of Items'] = 1,
    })
    packets.inject(pkt)
    log('Sent '..cfg.pop..' trade to nearby ???; awaiting NM spawn')
    send('POPPED', requested_stage, me())
    return true
end

local function queue_pop(requested_stage)
    pending_stage = requested_stage
    pending_fresh_seen, pending_fresh_target = nil, nil
    pending_retry_at, last_pending_log = 0, 0
end

local function service_pending_pop()
    if not pending_stage or now() < pending_retry_at then return end
    pending_retry_at = now() + retry_interval
    local success, reason, fatal = guarded_pop(pending_stage)
    if success then
        -- Windower IPC broadcasts to other instances, not necessarily this sender.
        if running and is_session_leader() and waiting and awaiting_ack
            and selected_owner == me() and pending_stage == stage then
            awaiting_ack, last_pop_time = false, now()
            log('Local trade sent; waiting for '..settings.stages[stage].mob)
        end
        pending_stage = nil
    elseif fatal then
        log('STOP: '..reason)
        send('POPFAIL', pending_stage, me(), reason)
        pending_stage = nil
    elseif now() - last_pending_log >= 15 then
        log(reason..'; retrying automatically')
        last_pending_log = now()
    end
end

local function broadcast_status()
    if not stage then return end
    send('QUERY', stage)
end
local function choose_owner()
    local options = {}
    if pop_available() then options[#options+1] = me() end
    for name, data in pairs(peers) do
        if data.ready and now() - data.time < 12 then options[#options+1] = name end
    end
    table.sort(options)
    if #options == 0 then return nil end
    for _, name in ipairs(options) do if name > last_owner then return name end end
    return options[1]
end
local function stop(reason)
    running, waiting, seen_mob, awaiting_ack, pending_stage = false, false, false, false, nil
    loot_active, claimed_owner, session_leader, last_lotted = false, nil, nil, {}
    pending_fresh_seen, pending_fresh_target = nil, nil
    if reason then log('STOP: '..reason) end
    send('STOP')
end
local function advance()
    if not running or waiting or end_of_queue then return end
    local owner = choose_owner()
    if not owner then
        end_of_queue = true
        return stop('No valid pop items remaining across reported characters; rotation finished')
    end
    last_owner, waiting, seen_mob, awaiting_ack, selected_owner = owner, true, false, true, owner
    claimed_owner = owner
    -- Ownership is assigned for every stage, including Tier IV pops.
    -- Never mutate/persist the stage description when a popper is selected.
    send('CLAIM', stage, owner)
    log('Next '..settings.stages[stage].mob..' pop: '..owner)
    if owner == me() then queue_pop(stage) else send('POP', stage, owner) end
end

windower.register_event('ipc message', function(raw)
    local p = split(raw)
    if p[1] ~= 'ZNMH1' then return end
    if p[2] == 'QUERY' and settings.stages[p[3]] then
        -- A delayed/out-of-stage QUERY must never reassign an active loot stage.
        if loot_active and stage ~= p[3] then return end
        stage = p[3]
        local id = item_id(settings.stages[stage].pop)
        send('READY', stage, me(), id and owned_in_inventory(id) and '1' or '0')
        if running and is_session_leader() and claimed_owner then
            send('CLAIM', stage, claimed_owner)
        end
        lot_trophy()
    elseif p[2] == 'START' and settings.stages[p[3]] and p[4] and p[4] ~= '' then
        stage, session_leader = p[3], p[4]
        loot_active, claimed_owner, last_lotted = true, nil, {}
    elseif p[2] == 'READY' and running and p[3] == stage and p[4] ~= me() then
        peers[p[4]] = {ready = p[5] == '1', time = now()}
    elseif p[2] == 'POP' and p[4] == me() and loot_active and p[3] == stage then
        claimed_owner = me()
        queue_pop(stage)
    elseif p[2] == 'POPPED' and running and waiting and awaiting_ack and p[3] == stage and p[4] == selected_owner then
        awaiting_ack, last_pop_time = false, now()
        log('Trade sent by '..p[4]..'; waiting for '..settings.stages[stage].mob)
    elseif p[2] == 'POPFAIL' and running and waiting and awaiting_ack and p[3] == stage and p[4] == selected_owner then
        stop('Pop failed on '..p[4]..': '..tostring(p[5]))
    elseif p[2] == 'STOP' then
        running, waiting, awaiting_ack, pending_stage = false, false, false, nil
        loot_active, claimed_owner, session_leader, last_lotted = false, nil, nil, {}
        pending_fresh_seen, pending_fresh_target = nil, nil
    elseif p[2] == 'STAGE' and settings.stages[p[3]] then
        stage = p[3]
        -- STAGE is configuration, not permission to lot. START must follow.
        loot_active, claimed_owner, last_lotted = false, nil, {}
    elseif p[2] == 'CLAIM' and loot_active and stage == p[3] and settings.stages[p[3]]
        and p[4] and p[4] ~= '' then
        if claimed_owner ~= p[4] then last_lotted = {} end
        claimed_owner = p[4]
    elseif p[2] == 'CONFIG' and settings.stages[p[3]] and p[4] and p[4] ~= '' then
        settings.recipient_overrides[p[3]] = p[4]
        settings:save()
        last_lotted = {}
    end
end)

windower.register_event('prerender', function()
    if not me() then return end
    lot_trophy()
    debug_pop_tick()
    service_pending_pop()
    if not running or not is_session_leader() then return end
    if now() - last_query > 6 then broadcast_status(); last_query = now() end
    if not waiting then return end
    if awaiting_ack then return end -- Respawn/idle retries must not start the NM spawn timeout.
    local mob = nearby_mob(settings.stages[stage].mob)
    if mob then
        seen_mob, last_seen_time = true, now()
    elseif seen_mob and now() - last_seen_time >= delay_after_kill then
        if has_treasure(settings.stages[stage].trophy) then return end
        waiting, seen_mob = false, false
        advance()
    elseif not seen_mob and now() - last_pop_time > max_spawn_wait then
        stop('No NM spawn observed; inspect pop target, inventory, and chat before retrying')
    end
end)

windower.register_event('addon command', function(cmd, ...)
    local args = {...}
    cmd = (cmd or 'help'):lower()
    if cmd == 'help' then
        log('setup: optional //znmh leader Name; //znmh stage chigre')
        log('loot: default=popper; optional //znmh recipient <stage> Name|owner')
        log('start: //znmh start chigre (leader only); //znmh stop; //znmh status')
        log('diagnostic: //znmh debugpop on|off|once (per-character 1Hz CSV file)')
        log('Pop owners must be near one unambiguous ??? and keep pops in main Inventory.')
    elseif cmd == 'debugpop' then
        local option = (args[1] or 'once'):lower()
        if option == 'on' then
            if not debug_open_file() then return end
            pop_debug, debug_last_state, debug_last_poll = true, nil, now()
            local state, fields = debug_pop_snapshot()
            if not debug_write_record('START', fields) then return end
            debug_last_state = state
            log('POP DEBUG writing 1Hz CSV to '..debug_file_path)
        elseif option == 'off' then
            pop_debug = false
            if debug_file then
                local _, fields = debug_pop_snapshot()
                debug_write_record('STOP', fields)
                debug_close_file()
            end
            log('POP DEBUG stopped; file: '..tostring(debug_file_path))
        elseif option == 'once' then
            local _, fields = debug_pop_snapshot()
            if debug_write_record('MANUAL', fields) then
                log('POP DEBUG snapshot written to '..debug_file_path)
            end
            if not pop_debug then debug_close_file() end
        else
            log('Usage: //znmh debugpop on|off|once')
        end
    elseif cmd == 'leader' and args[1] then
        settings.leader = args[1]:lower() == 'any' and '' or args[1]
        settings:save()
        log('Allowed run leader: '..(settings.leader ~= '' and settings.leader or 'any character'))
    elseif cmd == 'recipient' and args[1] and args[2] and settings.stages[args[1]:lower()] then
        local key = args[1]:lower()
        if loot_active then return log('Stop the active run before changing trophy recipient') end
        local recipient = args[2]:lower() == 'owner' and 'owner' or args[2]
        settings.recipient_overrides[key] = recipient
        settings:save()
        send('CONFIG', key, recipient)
        log('Trophy '..key..' recipient policy: '..recipient)
    elseif cmd == 'stage' and args[1] and settings.stages[args[1]:lower()] then
        if loot_active then return log('Stop the active ZNM run before changing stage') end
        stage = args[1]:lower()
        loot_active, claimed_owner, last_lotted = false, nil, {}
        send('STAGE', stage)
        log('Stage '..stage)
    elseif cmd == 'start' and args[1] then
        if settings.leader ~= '' and me():lower() ~= settings.leader:lower() then
            return log('Start restricted to '..settings.leader..'; //znmh leader any to clear')
        end
        local key = args[1]:lower()
        if not settings.stages[key] then return log('Unknown stage '..key) end
        stage, running, waiting, seen_mob, last_owner, peers, end_of_queue = key, true, false, false, '', {}, false
        claimed_owner, loot_active, session_leader = nil, true, me()
        awaiting_ack, selected_owner, pending_stage = false, nil, nil
        pending_fresh_seen, pending_fresh_target, last_pop_time = nil, nil, 0
        send('STAGE', stage)
        send('START', stage, me())
        broadcast_status()
        last_query = now()
        log('Armed '..key..'; collecting peer readiness (first pop in 3 seconds)')
        coroutine.schedule(function() if running and not waiting then advance() end end, 3)
    elseif cmd == 'stop' then
        stop('manual stop')
    elseif cmd == 'status' then
        log('stage='..tostring(stage)..' leader='..tostring(session_leader)..' restriction='..tostring(settings.leader)..' active='..tostring(running)..' loot_active='..tostring(loot_active)..' claimed_owner='..tostring(claimed_owner)..' waiting='..tostring(waiting)..' awaiting_trade='..tostring(awaiting_ack)..' local_retry='..tostring(pending_stage))
        if stage then
            log('pop='..settings.stages[stage].pop..' trophy_recipient='..tostring(trophy_recipient(stage) or 'awaiting popper')..' override='..tostring(settings.recipient_overrides[stage] or 'owner'))
        end
    else log('Unknown command; //znmh help') end
end)
