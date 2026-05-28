-- bot_4.lua — Runner (Rai). Sole material courier between supporters and focus.
--
-- 2026-05-28 operator spec rewrite:
--   "Rai должен и только он должен доставлять все материалы, он для этого
--   и создан... не другие каждый кому то... только он. Патруль просто так
--   не нужен. Он должен делать все для того чтоб у крафтов был ресурс
--   любой который им нужен намного быстрее."
--
-- Architecture:
--   1. Tight pickup→deliver loop, no patrol filler.
--   2. find_supporter_with_most(material) picks the most-loaded supporter.
--   3. walk to that supporter → take_from_bot → walk to focus → give_to_focus.
--   4. Round-robin between ingots and logs each cycle so no material starves.
--   5. Idle (5s wait) only when ALL supporters are empty AND focus is full.
--
-- Single instance — no other bot delivers. Supporters only signal readiness.

bot.state.deliveries     = bot.state.deliveries or 0
bot.state.stuck_count    = bot.state.stuck_count or 0
bot.state.last_x         = bot.state.last_x or 0
bot.state.last_y         = bot.state.last_y or 0
bot.state.idle_ticks     = bot.state.idle_ticks or 0
bot.state.idle_rounds    = bot.state.idle_rounds or 0
bot.state.phase          = bot.state.phase or "init"
bot.state.material_focus = bot.state.material_focus or "ingots"

local STUCK_THRESHOLD = 5

local BRIDGE_WAYPOINTS = {
    {x=2525, y=515, z=0},
    {x=2525, y=501, z=15},
    {x=2551, y=501, z=15},
}

local function check_stuck()
    local pos = bot.position()
    if pos.x == bot.state.last_x and pos.y == bot.state.last_y then
        bot.state.idle_ticks = bot.state.idle_ticks + 1
    else
        bot.state.idle_ticks = 0
        bot.state.last_x = pos.x
        bot.state.last_y = pos.y
    end
    return bot.state.idle_ticks >= STUCK_THRESHOLD
end

local function recover_from_stuck()
    bot.state.stuck_count = bot.state.stuck_count + 1
    bot.log("Runner stuck recovery #" .. bot.state.stuck_count)
    bot.state.idle_ticks = 0
    local pos = bot.position()
    if pos.x >= 2505 and pos.x <= 2515 and pos.y >= 535 and pos.y <= 545 then
        bot.log("Near bank wall — routing via BankStreet north")
        bot.walk_to_point(2525, 515, 0)
        wait(3)
        return
    end
    if pos.z >= 10 and pos.z <= 35 and pos.x >= 2520 and pos.x <= 2560 then
        bot.log("On bridge — routing via known waypoints")
        for _, wp in ipairs(BRIDGE_WAYPOINTS) do
            bot.walk_to_point(wp.x, wp.y, wp.z)
        end
        return
    end
    if bot.state.stuck_count % 3 == 0 then
        wait(10)
    else
        local offsets = {{5,0}, {0,5}, {-5,0}, {0,-5}}
        local pick = offsets[(bot.state.stuck_count % 4) + 1]
        bot.walk_to_point(pos.x + pick[1], pos.y + pick[2], pos.z)
        wait(2)
    end
end

-- 2026-05-28: focus-aware material selection. Read master_material signal
-- (set by master_tick when picking current target skill). If focus is
-- training Tinkering, master_material = "ingots" — Rai brings ingots,
-- not logs. Avoids the bug where Rai shuttled 48 logs to a TK trainee
-- who couldn't use them. Falls back to "ingots" if no signal yet.
local function get_focus_material()
    local sig = bot.check_signal("master_material")
    if not sig then return "ingots" end
    local m = tostring(sig)
    if m == "logs" or m == "ingots" or m == "cloth" then
        return m
    end
    return "ingots"
end

-- Walk to the same zone as the target bot. Approximation good enough for the
-- give/take APIs which transfer regardless of distance — but staying near the
-- worker keeps the bot ai visible and avoids navigation cliffs.
local function walk_to_bot_zone(target_index)
    local zone = bot.get_bot_zone(target_index)
    if not zone or zone == "" then return end
    -- Map zone enum to one of our waypoints. Supporters are usually in
    -- Mine (when mining) or Forest (when chopping).
    local zone_lower = string.lower(tostring(zone))
    if string.find(zone_lower, "mine") or string.find(zone_lower, "forge") then
        bot.walk_to("mine")
    elseif string.find(zone_lower, "forest") then
        bot.walk_to("forest")
    elseif string.find(zone_lower, "bank") or string.find(zone_lower, "vendor") then
        bot.walk_to("bank")
    else
        bot.walk_to("forge")
    end
end

-- 2026-05-28 operator spec: "минимум 100 за раз". Below this threshold
-- the courier-cycle cost (two long walks + smelt/bank wait) outweighs the
-- delivered throughput. Supporters keep accumulating; Rai only acts on
-- bulk loads worth shuttling.
local BULK_MIN = 100

-- One full cycle: pick most-loaded supporter, take materials, deliver to focus.
local function run_delivery_cycle(material)
    local target = bot.find_supporter_with_most(material)
    if target == nil or target < 0 then return false end

    -- Skip if the most-loaded supporter doesn't have a bulk-worthy load.
    -- Avoids "Rai bouncing every 20 logs" thrash the operator flagged.
    local available = bot.count_bot_material(target, material) or 0
    if available < BULK_MIN then
        if bot.state.idle_rounds % 10 == 1 then
            bot.log(string.format("Bot#%d has only %d %s (need %d) — wait for accumulation",
                target, available, material, BULK_MIN))
        end
        return false
    end

    bot.state.phase = "pickup"
    bot.log(string.format("Pickup cycle: %s from Bot#%d", material, target))

    walk_to_bot_zone(target)
    if check_stuck() then recover_from_stuck(); return false end

    local taken = bot.take_from_bot(target, material, 100) or 0
    if taken == 0 then
        -- supporter emptied between signal and arrival; not a stuck event
        bot.log(string.format("Bot#%d already empty on %s — skip", target, material))
        return false
    end
    bot.log(string.format("Picked up %d %s from Bot#%d", taken, material, target))

    -- Deliver leg: walk to forge area where focus crafts, then transfer.
    bot.state.phase = "deliver"
    bot.walk_to("forge")
    if check_stuck() then recover_from_stuck(); return false end

    local given = bot.give_to_focus(material, taken) or 0
    bot.state.deliveries = bot.state.deliveries + 1
    bot.log(string.format("Delivered %d %s to focus (cycle #%d)",
        given, material, bot.state.deliveries))

    bot.use_arms_lore()
    return true
end

local function tick()
    if check_stuck() and bot.is_stuck() then
        recover_from_stuck()
        return
    end

    -- Only deliver what focus actually needs. No round-robin "fairness" —
    -- if Redford trains Tinkering (ingots), Rai brings ingots, never logs.
    local m = get_focus_material()
    if run_delivery_cycle(m) then return end

    -- Focus material exhausted. Don't switch to other material — focus
    -- can't use it. Idle until supporters gather what's needed.
    bot.state.idle_rounds = (bot.state.idle_rounds or 0) + 1
    if bot.state.idle_rounds % 6 == 1 then
        bot.log(string.format("No supporter has %d+ %s for focus — idle", BULK_MIN, m))
    end
    wait(4)
end

function main()
    bot.log("Runner script v2 loaded — Rai (sole material courier)")
    bot.state.last_role = ""
    while true do
        tick()
        yield()
    end
end
