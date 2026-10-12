_addon.name = 'ZNMHelper'
_addon.author = 'n0gr1p / OpenAI'
_addon.version = '0.1.0'
_addon.commands = {'znmh', 'znmhelper'}

local packets = require('packets')
local res = require('resources')
local config = require('config')

local defaults = {
    leader = 'Niightsiide',
    -- Configure per NM before starting. Exact item names are resolved via Windower resources.
    stages = {
        vulpangue = {pop = 'Hellcage Butterfly', mob = 'Vulpangue', trophy = "Vulpangue's Wing", recipient = 'Etamame'},
        irizima = {pop = 'Senorita Pamama', mob = 'Iriz Ima', trophy = "Iriz Ima's Hide", recipient = 'Etamame'},
        lamia = {pop = 'Myrrh', mob = 'Experimental Lamia', trophy = 'Ex. Lamia Armband', recipient = 'owner'},
        mahjlaef = {pop = 'Exorcism Treatise', mob = 'Mahjlaef the Paintorn', trophy = "Mahjlaef's Staff", recipient = 'owner'},
        nuhn = {pop = 'Rose Scampi', mob = 'Nuhn', trophy = "Nuhn's Esca", recipient = 'owner'},
        armedgears = {pop = 'Ferrite', mob = 'Armed Gears', trophy = "A. Gears' Fragment", recipient = 'Etamame'},
        gotohzha = {pop = 'Sheep Botfly', mob = 'Gotoh Zha the Redolent', trophy = "G. Zha's Necklace", recipient = 'Etamame'},
        dea = {pop = 'Olzhiryan Cactus', mob = 'Dea', trophy = "Dea's Horn", recipient = 'Etamame'},
        chigre = {pop = 'Spoilt Blood', mob = 'Chigre', trophy = 'Chigre', recipient = 'owner'},
        verdelet = {pop = 'Mint Drop', mob = 'Verdelet', trophy = "Verdelet's Wing", recipient = 'owner'},
        tyger = {pop = 'Singed Buffalo', mob = 'Tyger', trophy = "Tyger's Tail", recipient = ''},
        tinnin = {pop = 'Monkey Wine', mob = 'Tinnin', trophy = "Tinnin's Fang", recipient = 'Niightsiide'},
    },
}
local settings = config.load(defaults)
local running, stage, waiting, seen_mob, last_owner = false, nil, false, false, ''
local last_pop_time, last_seen_time, last_query = 0, 0, 0
local peers, last_lotted = {}, {}
local owner_lot = {chigre=true, verdelet=true, lamia=true, mahjlaef=true, nuhn=true}
local delay_after_kill = 12
local max_spawn_wait = 25
local target_range = 6

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
local function lot_trophy()
    if not stage or not settings.stages[stage] then return end
    local cfg = settings.stages[stage]
    if not cfg.trophy or cfg.trophy == '' or not cfg.recipient or cfg.recipient == '' or cfg.recipient == 'owner' then return end
    local id = item_id(cfg.trophy)
    if not id then return end
    local items = windower.ffxi.get_items()
    for slot = 1, 10 do
        local v = items and items.treasure and items.treasure[slot]
        if v and v.item_id == id then
            local fingerprint = stage..':'..slot..':'..tostring(v.item_id)..':'..tostring(v.timestamp or v.drop_time or 0)
            if not last_lotted[fingerprint] then
                last_lotted[fingerprint] = true
                if me():lower() == cfg.recipient:lower() then
                    windower.ffxi.lot_item(slot)
                    log('Lotting '..cfg.trophy..' for '..me())
                else
                    windower.ffxi.pass_item(slot)
                end
            end
        end
    end
end
local function guarded_pop(requested_stage)
    local cfg = settings.stages[requested_stage]
    if not cfg then return log('Unknown stage: '..tostring(requested_stage)) end
    if windower.ffxi.get_player().status ~= 0 then return log('Not idle; refusing pop') end
    local t = windower.ffxi.get_mob_by_target('t')
    if not t or t.name ~= '???' or not t.distance or t.distance > target_range * target_range then
        return log('Target the correct nearby ??? on this character; pop refused')
    end
    local id = item_id(cfg.pop)
    if not id then return log('Unknown item in resources: '..cfg.pop) end
    local slot = owned_in_inventory(id)
    if not slot then return log('No '..cfg.pop..' in main Inventory') end
    local pkt = packets.new('outgoing', 0x036, {
        ['Target'] = t.id,
        ['Target Index'] = t.index,
        ['Item Count 1'] = 1,
        ['Item Index 1'] = slot,
        ['Number of Items'] = 1,
    })
    packets.inject(pkt)
    log('Traded '..cfg.pop..' to targeted ???; waiting for game result')
    send('POPPED', requested_stage, me())
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
    running, waiting, seen_mob = false, false, false
    if reason then log('STOP: '..reason) end
    send('STOP')
end
local function advance()
    if not running or waiting then return end
    local owner = choose_owner()
    if not owner then return stop('No client reports a usable pop item in main Inventory') end
    last_owner, last_pop_time, waiting, seen_mob = owner, now(), true, false
    if owner_lot[stage] then
        settings.stages[stage].recipient = owner
        -- This is a per-kill assignment, not a saved fixed recipient.
        send('CLAIM', stage, owner)
    end
    log('Next '..settings.stages[stage].mob..' pop: '..owner)
    if owner == me() then guarded_pop(stage) else send('POP', stage, owner) end
end

windower.register_event('ipc message', function(raw)
    local p = split(raw)
    if p[1] ~= 'ZNMH1' then return end
    if p[2] == 'QUERY' and settings.stages[p[3]] then
        stage = p[3]
        local id = item_id(settings.stages[stage].pop)
        send('READY', stage, me(), id and owned_in_inventory(id) and '1' or '0')
        lot_trophy()
    elseif p[2] == 'READY' and running and p[3] == stage and p[4] ~= me() then
        peers[p[4]] = {ready = p[5] == '1', time = now()}
    elseif p[2] == 'POP' and p[4] == me() then
        stage = p[3]
        guarded_pop(stage)
    elseif p[2] == 'STOP' then
        running, waiting = false, false
    elseif p[2] == 'STAGE' then
        stage = p[3]
        last_lotted = {}
    elseif p[2] == 'CLAIM' and settings.stages[p[3]] then
        settings.stages[p[3]].recipient = p[4]
        last_lotted = {}
    elseif p[2] == 'CONFIG' and settings.stages[p[3]] then
        settings.stages[p[3]].recipient = p[4]
        settings:save()
        last_lotted = {}
    end
end)

windower.register_event('prerender', function()
    if not me() then return end
    lot_trophy()
    if not running or me():lower() ~= settings.leader:lower() then return end
    if now() - last_query > 6 then broadcast_status(); last_query = now() end
    if not waiting then return end
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
        log('setup: //znmh leader Niightsiide (on each client); //znmh stage chigre')
        log('loot: //znmh recipient chigre Nyoourke (broadcasts recipient for this stage)')
        log('start: //znmh start chigre (leader only); //znmh stop; //znmh status')
        log('All pop owners must target the correct ??? and keep the pop in main Inventory.')
    elseif cmd == 'leader' and args[1] then
        settings.leader = args[1]; settings:save(); log('Leader: '..args[1])
    elseif cmd == 'recipient' and args[1] and args[2] and settings.stages[args[1]:lower()] then
        local key = args[1]:lower()
        settings.stages[key].recipient = args[2]
        settings:save()
        send('CONFIG', key, args[2])
        log('Trophy '..key..' assigned to '..args[2])
    elseif cmd == 'stage' and args[1] and settings.stages[args[1]:lower()] then
        stage = args[1]:lower(); send('STAGE', stage); log('Stage '..stage)
    elseif cmd == 'start' and args[1] then
        if me():lower() ~= settings.leader:lower() then return log('Start on leader only') end
        local key = args[1]:lower()
        if not settings.stages[key] then return log('Unknown stage '..key) end
        stage, running, waiting, seen_mob, last_owner, peers = key, true, false, false, '', {}
        send('STAGE', stage)
        broadcast_status()
        last_query = now()
        log('Armed '..key..'; collecting peer readiness (first pop in 3 seconds)')
        coroutine.schedule(function() if running and not waiting then advance() end end, 3)
    elseif cmd == 'stop' then
        stop('manual stop')
    elseif cmd == 'status' then
        log('stage='..tostring(stage)..' leader='..settings.leader..' active='..tostring(running)..' waiting='..tostring(waiting))
        if stage then log('pop='..settings.stages[stage].pop..' recipient='..tostring(settings.stages[stage].recipient)) end
    else log('Unknown command; //znmh help') end
end)
