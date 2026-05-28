-- bot_squad.lua: ROLE-AWARE unified squad script
-- Auto-detects bot.role() each tick:
--   Focus      → master pipeline (pick skill, craft +1, signal team)
--   Supporter  → gather material for whoever is Focus, alternating current+next
-- One file for all crafter bots (bot_0/1/2/3 all run this).
-- No more script swapping when Focus bot rotates after each L1 achievement.

bot.state.craft_count = bot.state.craft_count or 0
bot.state.harvest_count = bot.state.harvest_count or 0
bot.state.last_x = bot.state.last_x or 0
bot.state.last_y = bot.state.last_y or 0
bot.state.idle_ticks = bot.state.idle_ticks or 0
bot.state.stuck_count = bot.state.stuck_count or 0
bot.state.current_target = bot.state.current_target or ""
bot.state.last_role = bot.state.last_role or ""

local SKILL_ORDER = {"carpentry", "blacksmith", "fletching", "tinkering"}
local INGOT_SKILLS = {tinkering = true, blacksmith = true}
local LOG_SKILLS   = {fletching = true, carpentry = true}

local STUCK_THRESHOLD = 5
local SIGNAL_THRESHOLD = 10
local ELDER_X, ELDER_Y, ELDER_Z = 2517, 529, 0

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
    bot.state.idle_ticks = 0
    local pos = bot.position()
    if pos.z >= 10 and pos.z <= 35 and pos.x >= 2520 and pos.x <= 2560 then
        for _, wp in ipairs(BRIDGE_WAYPOINTS) do
            bot.walk_to_point(wp.x, wp.y, wp.z)
        end
        return
    end
    if bot.state.stuck_count % 3 == 0 then
        wait(10)
    else
        bot.walk_to_point(pos.x + 3, pos.y + 3, pos.z)
        wait(2)
    end
end

local function get_skill_value(skill)
    return bot.get_skill(skill)
end

local function material_for_skill(skill)
    if INGOT_SKILLS[skill] then return "ingots" end
    if LOG_SKILLS[skill] then return "logs" end
    if skill == "tailoring" then return "cloth" end
    return ""
end

local function count_material(skill)
    if INGOT_SKILLS[skill] then return bot.count_ingots() end
    if LOG_SKILLS[skill] then return bot.count_logs() end
    if skill == "tailoring" then return bot.count_cloth() end
    return 0
end

-- =========================================================================
-- MASTER (Focus) behavior
-- =========================================================================

local function estimate_material_for_plus_one(skill_value)
    local base = 30
    if skill_value > 60 then
        base = base + math.floor((skill_value - 60) * 3)
    end
    return base
end

local function pick_target_skill()
    local highest_val = -1
    local highest_skill = nil
    for _, skill in ipairs(SKILL_ORDER) do
        local v = get_skill_value(skill)
        if v < 75 and v > highest_val then
            highest_val = v
            highest_skill = skill
        end
    end
    return highest_skill, highest_val
end

local function pick_next_target_skill(current)
    local second_highest = -1
    local second_skill = nil
    for _, skill in ipairs(SKILL_ORDER) do
        if skill ~= current then
            local v = get_skill_value(skill)
            if v < 75 and v > second_highest then
                second_highest = v
                second_skill = skill
            end
        end
    end
    return second_skill
end

local function log_self_learning(skill)
    local attempts = bot.recipe_total_attempts(skill)
    if attempts > 0 and attempts % 20 == 0 then
        local rate = bot.recipe_best_success_rate(skill)
        bot.log(string.format("[learn] %s: %d attempts, best success rate %.0f%%",
            skill, attempts, rate * 100))
    end
end

local function try_levelup_quest()
    if bot.class_level() >= 1 then return false end
    if bot.min_craft_skill() < 75 then return false end

    bot.log("All skills >= 75! Walking to Elder Vestalar for L1 quest")
    bot.walk_to_point(ELDER_X, ELDER_Y, ELDER_Z)
    wait(3)

    if bot.try_levelup() then
        bot.say("I have reached Level 1!")
        bot.emote("*beams with pride*")
        return true
    end
    return false
end

local function do_crafting(skill)
    bot.state.phase = "crafting"
    if INGOT_SKILLS[skill] then bot.walk_to("forge") end
    if check_stuck() then recover_from_stuck(); return end

    local craft_round = 0
    local start_skill = get_skill_value(skill)
    while craft_round < 30 do
        local v = get_skill_value(skill)
        if v >= 75 then break end
        if v >= start_skill + 1.0 then break end

        if INGOT_SKILLS[skill] and bot.count_ingots() < 3 then break end
        if LOG_SKILLS[skill] and bot.count_logs() < 3 then break end
        if skill == "tailoring" and bot.count_cloth() < 3 then break end

        bot.craft(skill, "")
        bot.state.craft_count = bot.state.craft_count + 1
        craft_round = craft_round + 1
        bot.use_arms_lore()
        yield()
    end

    local end_skill = get_skill_value(skill)
    bot.log(string.format("Craft batch done: %s %.1f->%.1f (+%.1f) [%d attempts]",
        skill, start_skill, end_skill, end_skill - start_skill, craft_round))
end

local function gather_for(skill)
    bot.state.phase = "gathering"
    if INGOT_SKILLS[skill] then
        bot.walk_to("mine")
        if check_stuck() then recover_from_stuck(); return end
        bot.mine_until(function()
            return bot.count_ore() >= 20 or bot.count_ingots() >= 10 or bot.is_overweight()
        end)
        if bot.count_ore() > 0 then
            bot.walk_to("forge")
            if check_stuck() then recover_from_stuck(); return end
            wait(2)
            bot.smelt_all()
            wait(2)
        end
    elseif LOG_SKILLS[skill] then
        bot.walk_to("forest")
        if check_stuck() then recover_from_stuck(); return end
        bot.chop_until(function()
            return bot.count_logs() >= 30 or bot.is_overweight()
        end)
    end
end

local function master_tick()
    if try_levelup_quest() then return end

    local target_skill, target_val = pick_target_skill()
    if not target_skill then
        -- All skills at 75 but somehow not L1 yet — keep trying quest
        bot.log("All craft skills at 75 — walking to Elder for L1")
        bot.walk_to_point(ELDER_X, ELDER_Y, ELDER_Z)
        wait(5)
        bot.try_levelup()
        return
    end

    bot.signal("master_skill", target_skill)
    bot.signal("master_material", material_for_skill(target_skill))

    local next_skill = pick_next_target_skill(target_skill)
    if next_skill then
        bot.signal("next_master_skill", next_skill)
        bot.signal("next_master_material", material_for_skill(next_skill))
    end

    log_self_learning(target_skill)

    if bot.state.current_target ~= target_skill then
        bot.state.current_target = target_skill
        bot.log(string.format("New target: %s (currently %.1f, target +1 = %.1f)",
            target_skill, target_val, target_val + 1.0))
    end

    if count_material(target_skill) >= 3 then
        do_crafting(target_skill)
    else
        local team_count = bot.team_material_count(target_skill)
        bot.log(string.format("Need %s: my pack empty (team=%d), gathering myself",
            target_skill, team_count))
        gather_for(target_skill)
    end

    bot.use_arms_lore()
    wait(0.5 + math.random() * 0.5)
end

-- =========================================================================
-- SUPPORTER behavior
-- =========================================================================

local function pick_gather_target()
    local cur_material = bot.check_signal("master_material")
    local next_material = bot.check_signal("next_master_material")
    local cur = cur_material and tostring(cur_material) or nil
    local nxt = next_material and tostring(next_material) or nil

    local cycle = (bot.state.harvest_count or 0) % 3
    if cycle == 0 or cycle == 1 then
        if cur == "ingots" then return "mine"
        elseif cur == "logs" then return "forest"
        end
    else
        if nxt == "ingots" then return "mine"
        elseif nxt == "logs" then return "forest"
        end
    end
    return "forest"
end

local function gather_ore()
    bot.state.phase = "mining-for-master"
    bot.log("Mining ore for team")
    bot.walk_to("mine")
    if check_stuck() then recover_from_stuck(); return end
    bot.mine_until(function()
        return bot.count_ore() >= 30 or bot.is_overweight()
    end)
    bot.state.harvest_count = bot.state.harvest_count + 1
    if bot.count_ore() > 0 then
        bot.walk_to("forge")
        if check_stuck() then recover_from_stuck(); return end
        wait(2)
        bot.smelt_all()
        wait(2)
    end
end

local function gather_logs()
    bot.state.phase = "chopping-for-master"
    bot.log("Chopping logs for team")
    bot.walk_to("forest")
    if check_stuck() then recover_from_stuck(); return end
    bot.chop_until(function()
        return bot.count_logs() >= 30 or bot.is_overweight()
    end)
    bot.state.harvest_count = bot.state.harvest_count + 1
end

local function deliver_to_master()
    if bot.count_ingots() >= 10 or bot.count_logs() >= 10 then
        bot.request_runner("PickupResources")
        bot.signal("has_materials", tostring(bot.index))
    end
    if bot.is_overweight() or bot.count_ingots() >= SIGNAL_THRESHOLD or bot.count_logs() >= SIGNAL_THRESHOLD then
        bot.log("Going to forge to drop materials for master")
        bot.walk_to("forge")
        if check_stuck() then recover_from_stuck(); return end
        wait(3)
    end
end

local function supporter_tick()
    -- Tool check
    if not bot.has_pickaxe() and bot.count_ingots() >= 4 then
        bot.walk_to("forge")
        bot.craft("tinkering", "pickaxe")
        wait(2)
    end
    if not bot.has_hatchet() and bot.count_ingots() >= 4 then
        bot.walk_to("forge")
        bot.craft("tinkering", "hatchet")
        wait(2)
    end

    if not bot.has_pickaxe() then
        bot.walk_to("mine")
        if check_stuck() then recover_from_stuck(); return end
        bot.mine()
        wait(2)
        return
    end

    local target = pick_gather_target()
    if target == "mine" then
        gather_ore()
    else
        gather_logs()
    end

    deliver_to_master()
    bot.use_arms_lore()
    wait(0.5 + math.random() * 0.5)
end

-- =========================================================================
-- DISPATCH: role-aware tick
-- =========================================================================

local function tick()
    if check_stuck() and bot.is_stuck() then
        recover_from_stuck()
        return
    end

    local role = bot.role()
    if role ~= bot.state.last_role then
        bot.log(string.format("Role changed: %s -> %s", bot.state.last_role, role))
        bot.state.last_role = role
        bot.state.current_target = ""
        bot.state.idle_ticks = 0
    end

    if role == "Focus" then
        master_tick()
    elseif role == "Supporter" then
        supporter_tick()
    else
        wait(2)
    end
end

function main()
    bot.log("Role-aware squad script loaded — " .. bot.name .. " (role=" .. bot.role() .. ")")
    while true do
        tick()
        yield()
    end
end
