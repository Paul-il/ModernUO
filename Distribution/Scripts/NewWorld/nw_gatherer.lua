-- nw_gatherer.lua — NewWorld self-sustaining miner. Hot-reloaded live.
--
-- Loop: find ore -> walk -> mine -> (overweight/threshold) smelt at forge ->
--       walk to bank -> open_bank -> deposit -> back to mining; relocate on
--       depletion via last_failure_reason + bot.mark_depleted.
--
-- Bind:  [NWScript all nw_gatherer.lua    (does NOT auto-bind by filename — the
--        watcher only auto-binds nw_<warrior|mage|ranger|thief|bard|hunter>/nw_all).
--        A bound script OWNS the bot — stop the Python runtime ([Bots) so the two
--        brains don't fight over movement.
--
-- ⚠️ OPERATOR: fill the forge + bank coordinates for YOUR world below. The
--    placeholder 0,0,0 will path to an invalid tile and the smelt/bank run will
--    never complete. FORGE_ = a public forge/anvil; BANK_ = a banker or bank box.
local FORGE_X, FORGE_Y, FORGE_Z = 0, 0, 0      -- TODO operator: a public forge
local BANK_X,  BANK_Y,  BANK_Z  = 0, 0, 0      -- TODO operator: nearest banker / bank box
local ORE_THRESHOLD = 10                        -- ore stacks before a smelt run
local HEAL_HP       = 0.5

local function survive()
  if bot.is_dead() then bot.resurrect(); wait(2); return true end
  if bot.is_bandaging() then wait(1); return true end          -- heal in progress: don't re-issue / interrupt the ~5s timer
  if bot.is_poisoned() and bot.has_potion("cure")
     and bot.best_cure_strength() >= bot.poison_level() then    -- only a strong-enough cure (else consumed + 7s lockout)
    bot.drink("cure"); return true
  end
  if bot.hp_ratio() < HEAL_HP then
    if bot.has_potion("heal") then bot.drink("heal")
    elseif bot.has_bandage() then bot.bandage_self() end        -- gated by is_bandaging above → no spam
    return true
  end
  return false
end

function main()
  bot.set_warmode(false)
  -- #9: a smelt/bank run needs REAL forge + bank coords. With the placeholder 0,0,0 the bot would
  -- walk_to (0,0) (map NW corner) forever the moment it filled up and never mine again. Only run the
  -- smelt/bank loop when configured; otherwise degrade to harmless mine-until-full (warned once below).
  local configured = (FORGE_X ~= 0 or FORGE_Y ~= 0) and (BANK_X ~= 0 or BANK_Y ~= 0)
  while true do
    local fail = bot.last_failure_reason()

    if survive() then
      -- handled this tick

    -- A depleted vein: the spot we just mined is empty. Flag it so find_ore
    -- skips it, then fall through to relocate next tick.
    elseif fail == "harvest_resources_empty" then
      if bot.state.last_x then bot.mark_depleted(bot.state.last_x, bot.state.last_y) end

    -- Full enough OR overweight: do a smelt + bank run (only with real coords - see #9).
    elseif configured and (bot.is_overweight() or bot.count_type("IronOre") >= ORE_THRESHOLD) then
      -- 1) smelt at the home forge
      bot.walk_to(FORGE_X, FORGE_Y, FORGE_Z, 1)
      if not bot.is_moving() then
        bot.smelt()
        if fail == "forge_not_in_range" then wait(1) end
      end
      -- 2) bank the ingots (and anything else) once the ore is gone
      if bot.count_type("IronOre") == 0 then
        bot.walk_to(BANK_X, BANK_Y, BANK_Z, 1)
        if not bot.is_moving() then
          bot.open_bank()
          bot.deposit()
        end
      end

    else
      -- #9: if we're full but FORGE_/BANK_ are unset we land here (not marching to 0,0). Warn once.
      if not configured and (bot.is_overweight() or bot.count_type("IronOre") >= ORE_THRESHOLD)
         and not bot.state.warned_unconfigured then
        bot.state.warned_unconfigured = true
        bot.log("nw_gatherer: FORGE_/BANK_ coords unset (0,0,0) - mining only, no smelt/bank run. Set them to enable.")
      end
      -- Mine: locate -> walk -> swing. find_ore skips cooled tiles (returns nil).
      local v = bot.find_ore(18)
      if v then
        bot.state.last_x, bot.state.last_y = v.x, v.y   -- scalars => survive a hot-reload
        if v.dist > 2 then
          bot.walk_to(v.x, v.y, v.z, 1)                 -- range 1 < harvest MaxRange 2
        else
          bot.mine()
          -- No tool? craft one (warrior/ranger carry Blacksmithy/Mining).
          if fail == "harvest_tool_not_found" then
            bot.craft("blacksmithy", "Pickaxe")
          end
        end
      else
        -- Nothing minable nearby (or all on cooldown) — wander to relocate.
        local p = bot.position()
        bot.walk_to(p.x + 8, p.y + 8, p.z, 0)
        wait(1)
      end
    end

    yield()
  end
end
