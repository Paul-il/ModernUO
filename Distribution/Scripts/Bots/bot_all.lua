-- bot_all.lua: Universal crafter script â€” assigned to any bot without a personal file
-- Uses bot.index for sector-aware behavior. Identical logic to bot_0.lua.
-- Bots 0-3 are crafters, bot 4 is runner (has its own bot_4.lua).

bot.state.craft_count   = bot.state.craft_count or 0
bot.state.smelt_count   = bot.state.smelt_count or 0
bot.state.mine_trips    = bot.state.mine_trips or 0
bot.state.chop_trips    = bot.state.chop_trips or 0
bot.state.stuck_count   = bot.state.stuck_count or 0
bot.state.last_x        = bot.state.last_x or 0
bot.state.last_y        = bot.state.last_y or 0
bot.state.idle_ticks    = bot.state.idle_ticks or 0
bot.state.phase         = bot.state.phase or "init"

-- Prioritize log-based skills â€” mining has lower ore yield in current environment
local SKILL_ORDER = {"fletching", "carpentry", "tinkering", "blacksmith", "tailoring"}
local INGOT_SKILLS = {tinkering = true, blacksmith = true}
local LOG_SKILLS   = {fletching = true, carpentry = true}

local ORE_GATHER_TARGET  = 15
local LOG_GATHER_TARGET  = 40
local INGOT_CRAFT_MIN    = 3
local LOG_CRAFT_MIN      = 3
local CLOTH_CRAFT_MIN    = 3
local STUCK_THRESHOLD    = 5
local MATERIAL_SIGNAL_THRESHOLD = 100

local function get_level_cap()
    local lvl = bot.level()
    if lvl <= 0 then return 75 end
    local caps = {75, 90, 105, 120, 135, 150}
    if lvl > 6 then return 150 end
    return caps[lvl]
end

local function needs_resource(skill)
    if INGOT_SKILLS[skill] then
        return bot.count_ingots() < INGOT_CRAFT_MIN
    elseif LOG_SKILLS[skill] then
        return bot.count_logs() < LOG_CRAFT_MIN
    elseif skill == "tailoring" then
        return bot.count_cloth() < CLOTH_CRAFT_MIN
    end
    return false
end

local function has_resource(skill)
    if INGOT_SKILLS[skill] then
        return bot.count_ingots() >= INGOT_CRAFT_MIN
    elseif LOG_SKILLS[skill] then
        return bot.count_logs() >= LOG_CRAFT_MIN
    elseif skill == "tailoring" then
        return bot.count_cloth() >= CLOTH_CRAFT_MIN
    end
    return false
end

local function pick_craft_skill()
    local cap = get_level_cap()
    local lowest_val = 999
    local lowest_skill = nil
    local best_ready_val = 999
    local best_ready_skill = nil

    for _, skill in ipairs(SKILL_ORDER) do
        local val = bot.get_skill(skill)
        if val < cap then
            if val < lowest_val then
                lowest_val = val
                lowest_skill = skill
            end
            if val < best_ready_val and has_resource(skill) then
                best_ready_val = val
                best_ready_skill = skill
            end
        end
    end

    if best_ready_skill and (best_ready_val - lowest_val) < 15 then
        return best_ready_skill
    end

    return lowest_skill or "blacksmith"
end

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
    bot.log("Stuck recovery #" .. bot.state.stuck_count)
    bot.state.idle_ticks = 0

    local pos = bot.position()

    if pos.z >= 10 and pos.z <= 35 and pos.x >= 2520 and pos.x <= 2560 then
        bot.log("On bridge area â€” routing via known waypoints")
        for _, wp in ipairs(BRIDGE_WAYPOINTS) do
            bot.walk_to_point(wp.x, wp.y, wp.z)
        end
        return
    end

    if bot.state.stuck_count % 3 == 0 then
        wait(10)
    else
        local offsets = {{3,3}, {-3,3}, {3,-3}, {-3,-3}}
        local pick = offsets[(bot.state.stuck_count % 4) + 1]
        bot.walk_to_point(pos.x + pick[1], pos.y + pick[2], pos.z)
        wait(2)
    end
end

local function ensure_tools()
    local ingots = bot.count_ingots()

    if not bot.has_pickaxe() and ingots >= 4 then
        bot.log("Crafting pickaxe")
        bot.walk_to("forge")
        bot.craft("tinkering", "pickaxe")
        wait(2)
    end

    if not bot.has_hatchet() and ingots >= 4 then
        bot.log("Crafting hatchet")
        bot.walk_to("forge")
        bot.craft("tinkering", "hatchet")
        wait(2)
    end

    if (not bot.has_pickaxe() or not bot.has_hatchet()) and ingots < 4 then
        bot.log("Need tools but only " .. ingots .. " ingots â€” mining for bootstrap")
        bot.walk_to("mine")
        if check_stuck() then recover_from_stuck(); return end
        bot.mine_until(function()
            return bot.count_ore() >= 15 or bot.is_overweight()
        end)
        if bot.count_ore() > 0 then
            bot.walk_to("forge")
            if check_stuck() then recover_from_stuck(); return end
            wait(2)
            bot.smelt_all()
            wait(2)
        end
    end
end

local function gather_ore()
    bot.state.phase = "mining"
    bot.walk_to("mine")
    if check_stuck() then recover_from_stuck(); return end

    local pre_ore = bot.count_ore()
    bot.mine_until(function()
        return bot.count_ore() >= ORE_GATHER_TARGET
            or bot.count_ingots() >= 10
            or bot.is_overweight()
    end)

    bot.state.mine_trips = bot.state.mine_trips + 1

    if bot.count_ore() <= pre_ore then
        bot.log("Mine depleted â€” switching to chop wood")
        gather_logs()
    end
end

local function smelt_ore()
    if bot.count_ore() <= 0 then return end
    bot.state.phase = "smelting"
    bot.log("Smelting " .. bot.count_ore() .. " ore")
    bot.walk_to("forge")
    if check_stuck() then recover_from_stuck(); return end
    wait(2)
    bot.smelt_all()
    bot.state.smelt_count = bot.state.smelt_count + 1
    wait(2)
end

local function gather_logs()
    bot.state.phase = "chopping"
    bot.walk_to("forest")
    if check_stuck() then recover_from_stuck(); return end

    bot.chop_until(function()
        return bot.count_logs() >= LOG_GATHER_TARGET or bot.is_overweight()
    end)

    bot.state.chop_trips = bot.state.chop_trips + 1
end

local function do_crafting(skill)
    bot.state.phase = "crafting"
    if INGOT_SKILLS[skill] then bot.walk_to("forge") end

    local craft_this_round = 0
    while has_resource(skill) and craft_this_round < 50 do
        bot.craft(skill, "")
        bot.state.craft_count = bot.state.craft_count + 1
        craft_this_round = craft_this_round + 1

        if bot.state.craft_count % 25 == 0 then
            bot.emote("*inspects handiwork*")
        end

        bot.use_arms_lore()
        yield()
    end

    bot.log("Crafted " .. craft_this_round .. " (skill: " .. skill ..
            ", val: " .. string.format("%.1f", bot.get_skill(skill)) .. ")")
end

local function signal_resources()
    if bot.count_ingots() >= MATERIAL_SIGNAL_THRESHOLD
       or bot.count_logs() >= MATERIAL_SIGNAL_THRESHOLD then
        bot.request_runner("PickupResources")
        bot.signal("has_materials", tostring(bot.index))
    end
end

local function try_craft_any()
    local cap = get_level_cap()
    for _, skill in ipairs(SKILL_ORDER) do
        if bot.get_skill(skill) < cap and has_resource(skill) then
            do_crafting(skill)
            return true
        end
    end
    return false
end

local ELDER_X, ELDER_Y, ELDER_Z = 2517, 529, 0 -- Минок (владелец отменил перенос №339 в Британию; = NewbieQuestService.ElderX/Y)

local function try_levelup_quest()
    local lvl = bot.class_level()
    if lvl >= 6 then return false end

    local min_skill = bot.min_craft_skill()
    if lvl == 0 and min_skill < 75 then return false end
    if lvl >= 1 then return false end

    bot.log("All skills â‰¥ 75 â€” walking to Elder Vestalar at (" .. ELDER_X .. "," .. ELDER_Y .. ") for levelup quest")
    bot.walk_to_point(ELDER_X, ELDER_Y, ELDER_Z)
    wait(2)

    local pos = bot.position()
    local dx = math.abs(pos.x - ELDER_X)
    local dy = math.abs(pos.y - ELDER_Y)
    if dx <= 8 and dy <= 8 then
        if bot.try_levelup() then
            bot.say("I have reached Level 1!")
            bot.emote("*beams with pride*")
            return true
        end
    end
    return false
end

local function tick()
    if check_stuck() and bot.is_stuck() then
        recover_from_stuck()
        return
    end

    if try_levelup_quest() then
        return
    end

    if try_craft_any() then
        bot.use_arms_lore()
        return
    end

    if bot.count_ore() > 0 then
        smelt_ore()
        if try_craft_any() then return end
    end

    local skill = pick_craft_skill()
    if not has_resource(skill) then
        ensure_tools()
    end

    if INGOT_SKILLS[skill] then
        gather_ore()
        smelt_ore()
    elseif LOG_SKILLS[skill] then
        gather_logs()
    elseif skill == "tailoring" then
        bot.walk_to("vendor")
        wait(3)
    end

    if has_resource(skill) then
        do_crafting(skill)
    end

    signal_resources()
    pcall(bot.use_arms_lore)
    wait(0.5 + math.random() * 0.5)
end

function main()
    bot.log("Universal crafter script v2 loaded â€” " .. bot.name .. " (index " .. bot.index .. ")")
    bot.state.phase = "running"
    bot.state.errors = bot.state.errors or 0

    while true do
        tick()
        yield()
    end
end
