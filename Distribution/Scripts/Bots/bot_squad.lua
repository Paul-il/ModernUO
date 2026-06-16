-- bot_squad.lua: ROLE-AWARE unified squad script
-- Auto-detects bot.role() each tick:
--   Focus      â†’ master pipeline (pick skill, craft +1, signal team)
--   Supporter  â†’ gather material for whoever is Focus, alternating current+next
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

-- Single source of truth for the squad's craft skills. SKILL_ORDER,
-- INGOT_SKILLS, LOG_SKILLS and SKILL_MATERIAL all derive from this table.
-- ORDER IS OBSERVABLE: pick_target_skill breaks skill-value ties by
-- first-in-order, so do NOT reorder these entries.
local SKILL_CONFIG = {
    { name = "carpentry",  material = "logs"   },
    { name = "blacksmith", material = "ingots" },
    { name = "fletching",  material = "logs"   },
    { name = "tinkering",  material = "ingots" },
}

local SKILL_ORDER = {}
local INGOT_SKILLS = {}
local LOG_SKILLS = {}
local SKILL_MATERIAL = {}
for _, def in ipairs(SKILL_CONFIG) do
    SKILL_ORDER[#SKILL_ORDER + 1] = def.name
    SKILL_MATERIAL[def.name] = def.material
    if def.material == "ingots" then INGOT_SKILLS[def.name] = true end
    if def.material == "logs"   then LOG_SKILLS[def.name]   = true end
end

local STUCK_THRESHOLD = 5
local ELDER_X, ELDER_Y, ELDER_Z = 2517, 529, 0 -- Минок (владелец отменил перенос №339 в Британию; = NewbieQuestService.ElderX/Y)

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
        wait(3)
    else
        bot.walk_to_point(pos.x + 3, pos.y + 3, pos.z)
        wait(2)
    end
end

-- 2026-05-29 TOOL-STARVATION RECOVERY (MINE, don't buy â€” operator rule).
-- Root cause was twofold and is fixed in C#: (1) bot harvest tools broke far too
-- fast (vanilla Pickaxe=50 uses â‰ˆ 10 min of mining), and (2) the script craft()
-- path couldn't reliably replace them (item name ignored, Pickaxe-force trainee-
-- only, Hatchet never). Now bots get DURABLE tools (BotPlayerMobile.BotToolUses)
-- and a reliable bot.craft_tool() that crafts the EXACT tool â€” from MINED ingots.
-- Bots NEVER buy ingots; they mine their own. make_tool only crafts a replacement
-- from ingots already in pack; if there are none, the caller goes mining.
-- craft_tool is nil until the restart that loads the new DLL â†’ safe no-op till then.
local function make_tool(which)
    -- which = "pickaxe" | "hatchet". Returns true once the tool is in the pack.
    if not bot.craft_tool then return false end          -- pre-restart: no reliable path
    if bot.get_skill("tinkering") < 30 then return false end
    if bot.count_ingots() < 4 then return false end      -- need MINED ingots; caller mines
    bot.walk_to("forge")
    bot.craft_tool(which)
    wait(2)
    if which == "pickaxe" then return bot.has_pickaxe() else return bot.has_hatchet() end
end

local function get_skill_value(skill)
    return bot.get_skill(skill)
end

local function material_for_skill(skill)
    if SKILL_MATERIAL[skill] then return SKILL_MATERIAL[skill] end
    if skill == "tailoring" then return "cloth" end
    return ""
end

local function count_material(skill)
    if INGOT_SKILLS[skill] then return bot.count_ingots() end
    if LOG_SKILLS[skill] then return bot.count_logs() end
    if skill == "tailoring" then return bot.count_cloth() end
    return 0
end

-- Skill -> harvest-tool gate. Centralizes the pickaxe/hatchet check the master
-- decision branch repeats. Tailoring / unknown skills have no harvest tool, so
-- they are never tool-gated. (Supporter tool checks stay material-keyed on the
-- master_material signal by design â€” they don't know the master's skill name.)
local function has_tool_for_skill(skill)
    if INGOT_SKILLS[skill] then return bot.has_pickaxe() end
    if LOG_SKILLS[skill] then return bot.has_hatchet() end
    return true
end

-- =========================================================================
-- MASTER (Focus) behavior
-- =========================================================================

local function can_train_skill(skill)
    -- 2026-05-28: previously this returned true if bot had the gathering
    -- TOOL even with no material â€” picked skills that couldn't actually
    -- craft. Now requires either (a) material in pack OR (b) team has
    -- material ready (deliverable via Rai). Tool alone isn't enough â€”
    -- master can't progress without material to consume.
    -- 2026-05-29: ingot-skills are always considered trainable â€” the bot MINES its
    -- own ingots with its (durable) pickaxe. The master/supporter mine-loop supplies
    -- them; if the pickaxe is somehow lost the bot waits for share_tool. No buying.
    if INGOT_SKILLS[skill] then
        return true
    end
    -- 2026-05-29 FIX: log-skills require logs IN PACK or a HATCHET to chop them.
    -- Do NOT count team_material_count (bank logs): when the squad is tool-starved
    -- the runner can't deliver those, so counting them made the trainee pick a
    -- log-skill it could never actually supply â†’ permanent stall. Without a hatchet,
    -- carpentry/fletching are NOT trainable, so pick_target_skill falls through to a
    -- mineable ingot-skill instead of idling on an unsupplyable log-skill.
    if LOG_SKILLS[skill] then
        return bot.count_logs() >= 4 or bot.has_hatchet()
    end
    return true
end

local function pick_target_skill()
    local highest_val = -1
    local highest_skill = nil
    -- Prefer skills bot CAN train (has tools/material) first
    for _, skill in ipairs(SKILL_ORDER) do
        local v = get_skill_value(skill)
        if v < 75 and v > highest_val and can_train_skill(skill) then
            highest_val = v
            highest_skill = skill
        end
    end
    -- 2026-05-29 fallback: nothing has material. Prefer an INGOT-skill
    -- (Blacksmith/Tinkering) â€” the bot MINES its own ore for those (durable
    -- pickaxe), and the trainee's PickBestRecipe force-logic also mints Pickaxes
    -- that share_tool hands to supporters â†’ the mining economy keeps flowing. A
    -- log-skill fallback (carpentry/fletching) needs a Hatchet to chop, so prefer
    -- the mineable ingot-skill rather than idling on an unsupplyable log-skill.
    if not highest_skill then
        for _, skill in ipairs(SKILL_ORDER) do
            if INGOT_SKILLS[skill] then
                local v = get_skill_value(skill)
                if v < 75 and v > highest_val then
                    highest_val = v
                    highest_skill = skill
                end
            end
        end
    end
    -- Last resort: any below-75 skill (e.g. all ingot-skills already capped).
    if not highest_skill then
        for _, skill in ipairs(SKILL_ORDER) do
            local v = get_skill_value(skill)
            if v < 75 and v > highest_val then
                highest_val = v
                highest_skill = skill
            end
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
    -- 2026-05-29: ALL craft skills go to forge (not just INGOT_SKILLS).
    -- Pembroke had 30 logs but brain held her in Mine for 12 min because
    -- walk_to("forge") only fired for INGOT_SKILLS path. Forge is the
    -- crafting station for all skills.
    bot.walk_to("forge")
    if check_stuck() then recover_from_stuck(); return end

    local craft_round = 0
    local start_skill = get_skill_value(skill)
    while craft_round < 30 do
        local v = get_skill_value(skill)
        if v >= 75 then break end
        if v >= start_skill + 1.0 then break end

        -- 2026-05-28: bumped thresholds to match top-tier recipe needs.
        -- At sv >= 60 best fletching recipe is Crossbow (7 logs). With
        -- only 3 logs, brain fell back to Shaft (1 log) which gives ~0
        -- gain past FL=40. Same for carpentry (Studded armor, etc).
        -- Better to wait for Rai delivery than waste logs on Shaft.
        local v_sk = get_skill_value(skill)
        -- 2026-05-29: lowered to 4 (was 5/7). At log=4 Pembroke could craft
        -- Painting (1-2 logs) but blocked. Better to attempt with what we
        -- have than block indefinitely.
        local min_log = (LOG_SKILLS[skill] and v_sk >= 60) and 4 or 3
        local min_ing = (INGOT_SKILLS[skill] and v_sk >= 60) and 4 or 3
        if INGOT_SKILLS[skill] and bot.count_ingots() < min_ing then break end
        if LOG_SKILLS[skill] and bot.count_logs() < min_log then break end
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

local function ensure_master_tools()
    -- 2026-05-29: produce SPARE tools for team-sharing too. Was: only craft
    -- if master himself missing. Supporters can be tool-less even when
    -- master has 1 of each â€” share_tool needs a spare. Master at svâ‰¥30 TK
    -- with â‰¥4 ingots crafts a spare every cycle until packed (cap @ 5).
    local has_pick = bot.has_pickaxe()
    local has_hat = bot.has_hatchet()
    -- 2026-05-29: prioritize OWN tools first. Was crafting spare pickaxe when
    -- missing hatchet. Now: missing pickaxe â†’ craft; missing hatchet â†’ craft;
    -- only then spare.
    if (not has_pick) and bot.count_ingots() >= 4 and bot.get_skill("tinkering") >= 30 then
        bot.log("Master crafting pickaxe (no pickaxe, have ingots)")
        bot.walk_to("forge")
        make_tool("pickaxe")  -- craft_tool: KEEPS a durable pickaxe (not recycled like craft())
        wait(2)
    elseif (not has_hat) and bot.count_ingots() >= 4 and bot.get_skill("tinkering") >= 30 then
        bot.log("Master crafting hatchet (no hatchet, have ingots)")
        bot.walk_to("forge")
        make_tool("hatchet")  -- craft_tool: KEEPS a durable hatchet (not recycled like craft())
        wait(2)
    elseif has_pick and has_hat and bot.count_ingots() >= 8 and bot.get_skill("tinkering") >= 30
       and (bot.state.current_target == "blacksmith" or bot.state.current_target == "tinkering") then
        -- 2026-05-29: spare pickaxe only when target is BS/TK. CP/FL/TL bot
        -- shouldn't waste ingots on pickaxes â€” needed for its own CP recipes.
        bot.log("Master crafting spare pickaxe for team (ingots=" .. bot.count_ingots() .. ")")
        bot.walk_to("forge")
        make_tool("pickaxe")  -- craft_tool: KEEPS a durable pickaxe (not recycled like craft())
        wait(2)
    end
end

local function master_tick()
    bot.state.master_tick_n = (bot.state.master_tick_n or 0) + 1
    if bot.state.master_tick_n % 20 == 1 then
        bot.log(string.format("[debug] master_tick #%d target=%s pickaxe=%s hatchet=%s ing=%d log=%d",
            bot.state.master_tick_n, tostring(bot.state.current_target),
            tostring(bot.has_pickaxe()), tostring(bot.has_hatchet()),
            bot.count_ingots(), bot.count_logs()))
    end

    -- 2026-05-29: anti-brain-override. Always force walk to forge at top
    -- of master_tick when we have crafting material. Brain GuildBrain
    -- OrePush mode was pulling master into Mine even with full pack.
    if bot.count_logs() >= 4 or bot.count_ingots() >= 4 or bot.count_cloth() >= 4 then
        bot.walk_to("forge")
    end

    ensure_master_tools()

    -- Share spare tools with toolless teammates (bootstrap)
    -- 2026-05-28: throttle to every 12 ticks (~1 min). C# share_tool logs
    -- "no spare" each call when master has no extra, which was spamming
    -- the focus log every 5-7s. Real sharing opportunities are rare â€”
    -- after master crafts pickaxe/hatchet there's a window of N ticks
    -- before they're consumed, 1-min poll catches them.
    if bot.state.master_tick_n % 12 == 0 then
        local pickaxes_given = bot.share_tool("pickaxe") or 0
        local hatchets_given = bot.share_tool("hatchet") or 0
        if pickaxes_given > 0 or hatchets_given > 0 then
            bot.log(string.format("Shared with team: %d pickaxes, %d hatchets",
                pickaxes_given, hatchets_given))
        end
    end

    if try_levelup_quest() then return end

    local target_skill, target_val = pick_target_skill()
    if not target_skill then
        -- All skills at 75 but somehow not L1 yet â€” keep trying quest
        bot.log("All craft skills at 75 â€” walking to Elder for L1")
        bot.walk_to_point(ELDER_X, ELDER_Y, ELDER_Z)
        wait(3)
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

    if bot.state.master_tick_n % 20 == 1 then
        bot.log(string.format("[signals] master_skill=%s material=%s next_skill=%s next_material=%s",
            target_skill, material_for_skill(target_skill),
            tostring(next_skill), next_skill and material_for_skill(next_skill) or "nil"))
    end

    log_self_learning(target_skill)

    if bot.state.current_target ~= target_skill then
        bot.state.current_target = target_skill
        bot.log(string.format("New target: %s (currently %.1f, target +1 = %.1f)",
            target_skill, target_val, target_val + 1.0))
    end

    -- 2026-05-29: tighten threshold to match do_crafting's per-skill minimum.
    -- Was: enter crafting if material >= 3. With sv>=60 (Crossbow needs 7),
    -- do_crafting would immediately break â€” burning CPU on no-op loop.
    local target_v = get_skill_value(target_skill)
    local enter_min = 3
    if target_v >= 60 and (INGOT_SKILLS[target_skill] or LOG_SKILLS[target_skill]) then
        -- 2026-05-29: lowered to 4 to match do_crafting threshold.
        enter_min = 4
    end
    if count_material(target_skill) >= enter_min then
        bot.state.wait_ticks = 0  -- crafting â†’ not stuck
        do_crafting(target_skill)
    else
        -- 2026-05-28: don't self-gather if Rai is delivering. Master ran
        -- to forest with no hatchet, blacklisted GoChop, idle-loop for 5 min.
        -- Wait at forge for Rai instead. Only self-gather if:
        --   (a) supporters truly empty (team_count < 4 AND no bootstrap visible)
        --   (b) AND master has the required tool
        local team_count = bot.team_material_count(target_skill)
        local has_tool = has_tool_for_skill(target_skill)

        -- 2026-05-29: track stuck time. If supporters can't deliver for 5+
        -- minutes (master in wait branch for that long), master self-gathers
        -- IF they have the tool. Solves Cherice-stuck-on-boulder lockup
        -- where team_count reports bank logs but no real supply moves.
        bot.state.wait_ticks = (bot.state.wait_ticks or 0) + 1

        if team_count >= 4 and bot.state.wait_ticks < 30 then
            -- Rai will deliver. Don't idle â€” stockpile team tools while
            -- waiting. Master TK=75 can mass-produce pickaxes/hatchets
            -- from spare ingots, growing ArmsLore on the side. This kills
            -- the "tools wear out â†’ bootstrap mining cycle" deadlock by
            -- maintaining a tool reserve.
            -- 2026-05-28 productivity upgrade: idle time = production time.
            if bot.state.master_tick_n % 10 == 1 then
                bot.log(string.format("Need %s: pack empty, team=%d ready â€” stockpiling tools at forge (wait=%ds)",
                    target_skill, team_count, bot.state.wait_ticks * 5))
            end
            bot.walk_to("forge")
            if bot.get_skill("tinkering") >= 30 and bot.count_ingots() >= 4 then
                -- 2026-05-29 FIX: gate at 4 (ScriptCraftTool needs 4 ingots) â€” was
                -- >=2, which made make_tool a no-op spin at ing 2-3 (never crafts,
                -- never consumes). Craft tools while waiting. share_tool distributes.
                -- Alternate pickaxe/hatchet so neither runs out.
                if bot.state.master_tick_n % 2 == 0 then
                    make_tool("pickaxe")  -- craft_tool: KEEPS a durable pickaxe (not recycled like craft())
                else
                    make_tool("hatchet")  -- craft_tool: KEEPS a durable hatchet (not recycled like craft())
                end
            else
                bot.use_arms_lore()
                wait(2)
            end
        elseif has_tool then
            bot.log(string.format("Need %s: pack empty (team=%d), self-gathering (wait_ticks=%d)",
                target_skill, team_count, bot.state.wait_ticks or 0))
            bot.state.wait_ticks = 0  -- reset after gather attempt
            gather_for(target_skill)
        else
            -- 2026-05-29: focus bootstrap. If focus has pickaxe (but missing
            -- hatchet for log skill, etc.) â†’ mine briefly â†’ ingots â†’ craft
            -- the missing tool â†’ continue. Mirrors supporter bootstrap.
            -- Avoids the "focus waits indefinitely for share_tool that never
            -- comes" deadlock seen with Pembroke.
            if bot.has_pickaxe() and bot.get_skill("tinkering") >= 30 then
                if bot.state.master_tick_n % 10 == 1 then
                    bot.log(string.format("Need %s: no tool â€” bootstrap mining for ingots", target_skill))
                end
                bot.walk_to("mine")
                bot.mine_until(function()
                    return bot.count_ore() >= 5 or bot.is_overweight()
                end)
                if bot.count_ore() > 0 then
                    bot.walk_to("forge")
                    bot.smelt_all()
                    wait(1)
                end
            else
                -- 2026-05-29 (MINE, don't buy): no gather tool in hand and no team
                -- material. With durable tools this is rare; when it happens, craft
                -- the missing tool from MINED ingots if we have any (shared/leftover),
                -- otherwise wait for share_tool from a teammate (durable tools mean a
                -- teammate almost always has a spare). Never buy ingots/cloth.
                local need = LOG_SKILLS[target_skill] and "hatchet" or "pickaxe"
                if make_tool(need) then
                    bot.log(string.format("Need %s: crafted %s from ingots â€” resuming", target_skill, need))
                else
                    if bot.state.master_tick_n % 10 == 1 then
                        bot.log(string.format("Need %s: no tool, no ingots â€” waiting for share_tool (ArmsLore)", target_skill))
                    end
                    bot.walk_to("forge")
                    bot.use_arms_lore()
                    wait(3)
                end
            end
        end
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
    -- 2026-05-28: supporters NEVER directly deliver to master. The runner
    -- (Rai) is the sole material courier per operator spec: "Rai Ð´Ð¾Ð»Ð¶ÐµÐ½
    -- Ð¸ Ñ‚Ð¾Ð»ÑŒÐºÐ¾ Ð¾Ð½ Ð´Ð¾Ð»Ð¶ÐµÐ½ Ð´Ð¾ÑÑ‚Ð°Ð²Ð»ÑÑ‚ÑŒ Ð²ÑÐµ Ð¼Ð°Ñ‚ÐµÑ€Ð¸Ð°Ð»Ñ‹". Supporters just
    -- accumulate and signal readiness; Rai polls signals and runs the
    -- pickupâ†’deliver cycle for everyone.
    local need_self_ingots = 0
    if not bot.has_pickaxe() and bot.get_skill("tinkering") >= 30 then
        need_self_ingots = need_self_ingots + 4
    end
    if not bot.has_hatchet() and bot.get_skill("tinkering") >= 30 then
        need_self_ingots = need_self_ingots + 4
    end

    local excess_ingots = bot.count_ingots() - need_self_ingots
    -- 2026-05-28 operator spec: "Ð¼Ð¸Ð½Ð¸Ð¼ÑƒÐ¼ 100 Ð·Ð° Ñ€Ð°Ð·" â€” but supporters with
    -- broken mining (no tool, mine depleted) may never hit 100. Use a
    -- tiered threshold: signal at 50 for bulk-cycle eligibility, runner
    -- still gates on count_bot_material via its own 100/50 check.
    if excess_ingots >= 50 or bot.count_logs() >= 50 then
        bot.signal("has_materials", tostring(bot.index))
        bot.request_runner("PickupResources")
    end
end

local function supporter_tick()
    bot.state.sup_tick_n = (bot.state.sup_tick_n or 0) + 1
    if bot.state.sup_tick_n % 20 == 1 then
        bot.log(string.format("[debug] supporter_tick #%d pickaxe=%s hatchet=%s ingots=%d logs=%d",
            bot.state.sup_tick_n,
            tostring(bot.has_pickaxe()), tostring(bot.has_hatchet()),
            bot.count_ingots(), bot.count_logs()))
    end

    -- Tool check
    if not bot.has_pickaxe() and bot.count_ingots() >= 4 then
        bot.walk_to("forge")
        make_tool("pickaxe")  -- craft_tool: KEEPS a durable pickaxe (not recycled like craft())
        wait(2)
    end
    if not bot.has_hatchet() and bot.count_ingots() >= 4 then
        bot.walk_to("forge")
        make_tool("hatchet")  -- craft_tool: KEEPS a durable hatchet (not recycled like craft())
        wait(2)
    end

    -- Read what master needs FIRST
    local cur_material = bot.check_signal("master_material")
    local cur = cur_material and tostring(cur_material) or "ingots"

    -- 2026-05-29: anti-brain-override. If brain pulls supporter to mine but
    -- focus needs logs, force walk to forest. Same fix as master walk_to_forge.
    if cur == "logs" and bot.has_hatchet() then
        bot.walk_to("forest")
    end

    if bot.state.sup_tick_n % 20 == 1 then
        bot.log(string.format("[signals-read] raw=%s parsed=%s",
            tostring(cur_material), cur))
    end

    -- 2026-05-28 operator rule: supporters NEVER gather material the focus
    -- doesn't need. If master trains Tinkering (cur="ingots") and a supporter
    -- has no pickaxe â†’ wait or self-craft pickaxe, but NEVER chop logs.
    -- Logs would just sit unused in supporter's pack while focus starves.
    if cur == "ingots" then
        if bot.has_pickaxe() then
            gather_ore()
        elseif bot.count_ingots() >= 4 and bot.get_skill("tinkering") >= 30 then
            bot.log("Self-crafting pickaxe")
            bot.walk_to("forge")
            make_tool("pickaxe")  -- craft_tool: KEEPS a durable pickaxe (not recycled like craft())
            wait(2)
        else
            -- 2026-05-29 DEADLOCK ESCAPE: buy ingots + craft a pickaxe via the
            -- reliable craft_tool API instead of idling forever. No-op until the
            -- restart that registers craft_tool, then this resumes mining.
            if make_tool("pickaxe") then
                bot.log("Bootstrapped pickaxe by buying ingots â€” resuming mining")
            else
                -- Wait at forge for share_tool. Do NOT fall through to chopping.
                -- 2026-05-28: ArmsLore during forced wait â€” turn idle into +skill.
                if bot.state.sup_tick_n % 10 == 1 then
                    bot.log("No pickaxe â€” waiting at forge (training ArmsLore meanwhile)")
                end
                bot.walk_to("forge")
                bot.use_arms_lore()
                wait(3)
            end
        end
    elseif cur == "logs" then
        if bot.has_hatchet() then
            gather_logs()
        elseif bot.count_ingots() >= 4 and bot.get_skill("tinkering") >= 30 then
            -- 2026-05-29 FIX: gate at 4 ingots â€” ScriptCraftTool (the craft_tool
            -- C# path) requires 4 ingots (BotBrainTimer.cs:12271 "need 4 ingots").
            -- The 2026-05-28 change to >=2 (wrongly assuming a 2-ingot hatchet
            -- recipe) made make_tool a SILENT NO-OP at ing 2-3: it never crafted,
            -- never consumed ingots, and blocked the bootstrap-mine fall-through
            -- below â†’ choppers span "Self-crafting hatchet (ingots=2)" forever,
            -- lost the whole log supply, focus starved. At <4 ingots we now fall
            -- through to the bootstrap-mine branch to top up to 4 first.
            bot.log("Self-crafting hatchet (ingots=" .. bot.count_ingots() .. ")")
            bot.walk_to("forge")
            make_tool("hatchet")  -- craft_tool: KEEPS a durable hatchet (not recycled like craft())
            wait(2)
        elseif bot.has_pickaxe() and bot.get_skill("tinkering") >= 30 then
            -- 2026-05-28 bootstrap: supporter has pickaxe but no hatchet AND
            -- no ingots â†’ mine briefly to bootstrap the hatchet. Short
            -- session (5 ore) instead of full gather_ore (30 ore) so we
            -- return to tick-top quickly to check ingot count and craft.
            -- Mine-exhausted areas were trapping bots inside the 30-ore
            -- mine_until predicate, never reaching the smelt/craft phase.
            if bot.state.sup_tick_n % 10 == 1 then
                bot.log("Bootstrap: mining briefly for ingots to craft hatchet")
            end
            bot.walk_to("mine")
            if check_stuck() then recover_from_stuck(); return end
            bot.mine_until(function()
                return bot.count_ore() >= 5 or bot.is_overweight()
            end)
            if bot.count_ore() > 0 then
                bot.walk_to("forge")
                wait(2)
                bot.smelt_all()
                wait(2)
            end
        else
            -- 2026-05-29 DEADLOCK ESCAPE: buy ingots + craft a hatchet (reliable
            -- craft_tool path) so the bot can chop, instead of idling forever.
            if make_tool("hatchet") then
                bot.log("Bootstrapped hatchet by buying ingots â€” resuming chopping")
            else
                -- True deadlock: no hatchet, no ingots, no pickaxe. Wait for share_tool.
                -- 2026-05-28: ArmsLore during forced wait â€” turn idle into +skill.
                if bot.state.sup_tick_n % 10 == 1 then
                    bot.log("No hatchet, no pickaxe â€” waiting (training ArmsLore meanwhile)")
                end
                bot.walk_to("forge")
                bot.use_arms_lore()
                wait(3)
            end
        end
    else
        -- cur == "cloth" or unknown â€” supporters can't meaningfully help
        -- with cloth pipeline (that's master's quest-based path). Wait.
        if bot.state.sup_tick_n % 10 == 1 then
            bot.log("Focus needs " .. tostring(cur) .. " â€” supporter can't help, waiting")
        end
        bot.walk_to("forge")
        wait(3)
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
        -- Clear stale master signals when stepping down from Focus
        if role ~= "Focus" then
            bot.signal("master_skill", nil)
            bot.signal("master_material", nil)
            bot.signal("next_master_skill", nil)
            bot.signal("next_master_material", nil)
            bot.log("Cleared stale master signals")
        end
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
    bot.log("Role-aware squad script loaded â€” " .. bot.name .. " (role=" .. bot.role() .. ")")
    -- Force role-change handler to re-fire on script load (clears stale signals)
    bot.state.last_role = ""
    while true do
        tick()
        yield()
    end
end
