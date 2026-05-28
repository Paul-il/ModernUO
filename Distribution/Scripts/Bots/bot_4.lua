-- bot_4.lua: Runner Bot — material shuttle between miners/crafters and bank
-- Priority: pickup requests > proactive supply > self-gather
-- Uses handshake-aware navigation: walk_to crafter → walk_to bank/focus

bot.state.deliveries     = bot.state.deliveries or 0
bot.state.gather_trips   = bot.state.gather_trips or 0
bot.state.stuck_count    = bot.state.stuck_count or 0
bot.state.last_x         = bot.state.last_x or 0
bot.state.last_y         = bot.state.last_y or 0
bot.state.idle_ticks     = bot.state.idle_ticks or 0
bot.state.patrol_idx     = bot.state.patrol_idx or 0
bot.state.idle_rounds    = bot.state.idle_rounds or 0
bot.state.phase          = bot.state.phase or "init"

local STUCK_THRESHOLD   = 5
local BANK_INGOT_THRESH = 20
local BANK_LOG_THRESH   = 20
local SELF_MINE_TARGET  = 20

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

local BRIDGE_WAYPOINTS = {
    {x=2525, y=515, z=0},
    {x=2525, y=501, z=15},
    {x=2551, y=501, z=15},
}

local function recover_from_stuck()
    bot.state.stuck_count = bot.state.stuck_count + 1
    bot.log("Runner stuck recovery #" .. bot.state.stuck_count)
    bot.state.idle_ticks = 0

    local pos = bot.position()

    if pos.x >= 2505 and pos.x <= 2515 and pos.y >= 535 and pos.y <= 545 then
        bot.log("Near bank wall — routing via BankStreet north")
        bot.walk_to_point(2525, 515, 0)
        wait(3)
        bot.walk_to("bank")
        return
    end

    if pos.z >= 10 and pos.z <= 35 and pos.x >= 2520 and pos.x <= 2560 then
        bot.log("On bridge area — routing via known waypoints")
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

local function has_pickup_request()
    local sig = bot.check_signal("has_materials")
    return sig ~= nil
end

local function handle_pickup_request()
    bot.state.phase = "pickup"
    bot.log("Pickup request — bank→forge supply run")

    bot.walk_to("bank")
    if check_stuck() then recover_from_stuck(); return end
    wait(3)

    bot.walk_to("forge")
    if check_stuck() then recover_from_stuck(); return end
    wait(3)

    bot.state.deliveries = bot.state.deliveries + 1
    bot.log("Delivery #" .. bot.state.deliveries .. " complete")
end

local function supply_run()
    bot.state.phase = "supply"
    bot.log("Proactive supply: bank→forge resource delivery")

    bot.walk_to("bank")
    if check_stuck() then recover_from_stuck(); return end
    wait(5)

    if bot.count_ingots() > 0 or bot.count_logs() > 0 then
        bot.walk_to("forge")
        if check_stuck() then recover_from_stuck(); return end
        wait(5)
        bot.log("Delivered resources to forge area")
    end

    bot.state.deliveries = bot.state.deliveries + 1
end

local function patrol_cycle()
    bot.state.phase = "patrol"
    bot.state.patrol_idx = bot.state.patrol_idx + 1

    -- Runner stays on surface (z=0) to avoid z-layer crossing stucks
    local cycle = bot.state.patrol_idx % 3

    if cycle == 0 then
        bot.log("Patrol: bank deposit")
        bot.walk_to("bank")
        if check_stuck() then recover_from_stuck(); return end
        wait(3)

    elseif cycle == 1 then
        bot.log("Patrol: forest check")
        bot.walk_to("forest")
        if check_stuck() then recover_from_stuck(); return end
        wait(3)

    else
        bot.log("Patrol: vendor area")
        bot.walk_to("vendor")
        if check_stuck() then recover_from_stuck(); return end
        wait(3)
    end
end

local function self_gather()
    bot.state.phase = "self_gather"

    local mining_skill = bot.get_skill("mining")
    if mining_skill >= 20 and bot.count_ingots() < BANK_INGOT_THRESH then
        bot.log("Runner self-gather: mining ore (MN=" .. string.format("%.0f", mining_skill) .. ")")
        bot.walk_to("mine")
        if check_stuck() then recover_from_stuck(); return end

        bot.mine_until(function()
            return bot.count_ore() >= SELF_MINE_TARGET or bot.is_overweight()
        end)

        if bot.count_ore() > 0 then
            bot.walk_to("forge")
            bot.smelt_all()
        end

        bot.state.gather_trips = bot.state.gather_trips + 1
    elseif mining_skill < 20 then
        bot.log("Runner: Mining too low (" .. string.format("%.0f", mining_skill) .. "), skipping self-gather — patrol instead")
        patrol_cycle()
        return
    end

    if bot.is_overweight() or bot.count_ingots() >= BANK_INGOT_THRESH then
        bot.log("Runner: depositing to bank")
        bot.walk_to("bank")
        if check_stuck() then recover_from_stuck(); return end
        wait(2)
    end
end

local function tick()
    if check_stuck() and bot.is_stuck() then
        recover_from_stuck()
        return
    end

    if has_pickup_request() then
        handle_pickup_request()
        return
    end

    if bot.is_overweight() then
        bot.log("Overweight — depositing to bank")
        bot.walk_to("bank")
        if check_stuck() then recover_from_stuck(); return end
        wait(2)
        return
    end

    -- Alternate between supply runs and patrols
    if bot.state.deliveries % 3 == 0 then
        supply_run()
    else
        patrol_cycle()
    end

    bot.use_arms_lore()
    wait(2 + math.random() * 2)
end

function main()
    bot.log("Runner script v1 loaded — " .. bot.name)
    bot.state.phase = "running"
    bot.emote("*stretches and gets ready to run*")

    while true do
        tick()
        yield()
    end
end
