-- nw_ranger.lua — NewWorld Ranger: ranged kiter. Keep distance, shoot the foe,
-- step away when it closes; survive via potions/bandage. COMBAT-ONLY bot.
--
-- Hot-reloaded live. Round-2 (TODO.md): NW2-TARGETING (threat score over nearby_enemies
-- so the ranger joins focus/threat instead of nearest-only), NW2-KITE-RECOVER (when a
-- fast foe can't be out-kited, STAND and shoot instead of back-pedaling into a wall).

local HEAL_HP   = 0.5
local KEEP_DIST = 4             -- preferred engagement distance
local AWAY      = 1             -- ONE tile/tick stutter-step back (re-decide every tick)
local GIVEUP_N  = 3             -- NW2-KITE-RECOVER: step-backs without opening distance before we stand & fight

-- ===== NW2-TARGETING: threat model (ranged-tuned) =====
local W_CASTER     = 8
local W_WOUNDED    = 4
local W_NEAR       = 12
local W_PROX       = 0.15        -- ranged → only a mild pull toward closer foes
local W_PARALYZED  = 2
local W_CONTROLLED = 2

local function sign(d)
  if d > 0 then return 1 elseif d < 0 then return -1 else return 0 end
end

local function score_foe(e)
  if not e then return -1e9 end
  local s = 0
  if e.is_casting then s = s + W_CASTER end
  s = s + (1 - (e.hp_ratio or 1)) * W_WOUNDED
  s = s + (W_NEAR - (e.dist or W_NEAR)) * W_PROX
  if e.paralyzed then s = s - W_PARALYZED end
  if e.is_controlled then s = s - W_CONTROLLED end
  return s
end

local function pick_foe(list)
  local best, bs = nil, -1e9
  for _, e in ipairs(list) do
    local sc = score_foe(e)
    if sc > bs then best, bs = e, sc end
  end
  return best
end

-- ONE-tile stutter-step AWAY from the foe (range 0 = that exact tile, so the WalkTo
-- await clears next tick and main() re-decides every tick instead of a 5-tile run).
local function step_back(foe)
  local p = bot.position()
  local dx, dy = sign(p.x - foe.x), sign(p.y - foe.y)
  if dx == 0 and dy == 0 then dx = 1 end   -- stacked: pick a direction
  bot.walk_to(p.x + dx * AWAY, p.y + dy * AWAY, p.z, 0)
end

-- ONE tile TOWARD the foe (used on no-LOS — round the obstacle to open a sightline).
local function step_toward(foe)
  local p = bot.position()
  local dx, dy = sign(foe.x - p.x), sign(foe.y - p.y)
  if dx == 0 and dy == 0 then return end   -- already stacked: never walk_to(self)
  -- A* is collision-pathed, not LOS-pathed → a straight 1-tile step can "dance" against a wall that
  -- blocks sight but not movement. So take a few 1-tile steps (re-decided each tick), then GIVE UP the
  -- manual stepping and hand it to A*: walk_to(foe, range 1) paths AROUND the obstacle to an adjacent
  -- tile, which almost always regains LOS. Per-foe counter; step_toward only runs while LOS is blocked,
  -- so it self-resets when LOS returns / the foe changes (the giveup also avoids the old self-tile strafe).
  if tostring(bot.state.nolos_foe or "") ~= tostring(foe.serial) then
    bot.state.nolos_foe = foe.serial
    bot.state.nolos_n = 0
  end
  local n = (bot.state.nolos_n or 0) + 1
  bot.state.nolos_n = n
  if n >= 4 then
    bot.walk_to(foe.x, foe.y, foe.z, 1)        -- give up manual stepping → let A* route around to adjacent
  else
    bot.walk_to(p.x + dx, p.y + dy, p.z, 0)    -- one tile toward, re-decide next tick
  end
end

-- NW2-KITE-RECOVER: true when we keep stepping back but the foe matches our speed — the
-- distance never opens. After GIVEUP_N such ticks, stop kiting and fight where we stand
-- (a fast melee foe out-runs a perma-backpedal into terrain). Tracked per-foe in bot.state.
local function kite_stuck(foe)
  if tostring(bot.state.kite_foe or "") ~= tostring(foe.serial) then
    bot.state.kite_foe = foe.serial
    bot.state.kite_last_dist = foe.dist
    bot.state.kite_stuck_n = 0
    return false
  end
  local last = bot.state.kite_last_dist
  bot.state.kite_last_dist = foe.dist
  if last and foe.dist and foe.dist > last + 0.1 then
    bot.state.kite_stuck_n = 0       -- we opened distance → kiting works
    return false
  end
  local n = (bot.state.kite_stuck_n or 0) + 1
  bot.state.kite_stuck_n = n
  return n >= GIVEUP_N
end

-- Follow the tribe leader's broadcast focus if attackable + in range (shared-brain concentration).
local function tribe_card(list)
  local fs = bot.check_signal("focus")
  if fs and bot.can_attack(fs) then
    for _, e in ipairs(list) do
      if tostring(e.serial) == tostring(fs) then return e end
    end
  end
  return nil
end

-- DEFEND: first enemy attacking a TEAMMATE (nearby_allies excludes self) = top-priority kill. nil = none.
local function defend_pick(enemies, allies)
  if not enemies or #enemies == 0 or not allies or #allies == 0 then return nil end
  local guard = {}
  for _, a in ipairs(allies) do guard[tostring(a.serial)] = true end
  for _, e in ipairs(enemies) do
    local tc = bot.target_combatant(e.serial)
    if tc and guard[tostring(tc)] and bot.can_attack(e.serial) then return e end
  end
  return nil
end

-- SQUAD DEFEND (C#-elected over the WHOLE squad, mage first): the monster hitting the squishiest
-- teammate. Converge on it BEFORE any local pick so even a FAR bot — who can't SEE the mage's
-- attacker in its own scan — drops everything and helps ("сразу идти убивать того кто бьёт мага").
-- Built from the global target_* readers (no per-brain dependency); validated by can_attack.
-- Because every brain reads the SAME serial, it also makes the squad focus-fire one target.
local function squad_defend_card()
  local s = bot.squad_defend()
  if not s or not bot.can_attack(s) then return nil end
  local p = bot.target_position(s)
  if not p then return nil end
  -- #10: enrich with the cast-cascade fields for parity (score/branch reads on the squad-defend focus).
  return { serial = s, x = p.x, y = p.y, z = p.z, dist = bot.target_distance(s),
           is_casting = bot.target_casting(s), paralyzed = bot.target_paralyzed(s),
           hp_ratio = bot.target_hp_ratio(s) }
end

function main()
  while true do
    local fail = bot.last_failure_reason()
    if not bot.state.home_x then bot.set_home() end   -- anchor = first safe spot we saw

    if bot.is_dead() then
      bot.resurrect()
      wait(2)

    elseif bot.is_bandaging() then
      wait(1)                                  -- heal in progress: don't re-issue / interrupt the ~5s timer

    elseif bot.is_paralyzed() then
      -- movement/bandage/cast all blocked under paralyze; only POTIONS work.
      if bot.is_poisoned() and bot.best_cure_strength() >= bot.poison_level() and bot.has_potion("cure") then
        bot.drink("cure")
      elseif bot.hp_ratio() < HEAL_HP and bot.has_potion("heal") then
        bot.drink("heal")
      else
        wait(1)                                -- nothing useful to do under paralyze; don't shoot/kite
      end

    elseif bot.is_poisoned() and bot.has_potion("cure") and bot.best_cure_strength() >= bot.poison_level() then
      bot.drink("cure")                        -- only if a cure STRONG ENOUGH exists (else consumed + 7s lockout)

    elseif bot.hp_ratio() < HEAL_HP then
      if bot.has_potion("heal") then
        bot.drink("heal")
      elseif bot.has_bandage() then
        bot.bandage_self()                     -- ~5s heal; is_bandaging() gate above prevents spam
      elseif bot.hp_ratio() < 0.30 and bot.state.home_x then
        bot.set_warmode(false)                 -- critical + no resources: retreat to the home anchor
        bot.flee(bot.state.home_x, bot.state.home_y, bot.state.home_z, 1)
      else
        wait(1)
      end

    else
      local enemies = bot.nearby_enemies(12)
      local allies = bot.nearby_allies(10)
      -- DEFEND FIRST: peel anything hitting a TEAMMATE before our own pick (converge, kill, then resume).
      local foe = squad_defend_card() or defend_pick(enemies, allies) or tribe_card(enemies) or pick_foe(enemies) or bot.find_target(12)
      if not foe then
        bot.set_warmode(false)
        bot.state.kite_stuck_n = 0             -- disengaged → reset give-up tracking
        if bot.patrol_active() then
          local g = bot.patrol_target()
          if g and g.kind == "sweep" then
            bot.state.idle_n = (bot.state.idle_n or 0) + 1
            if bot.state.idle_n % 2 == 0 then bot.loot_smart() else bot.walk_to(g.x, g.y, g.z, g.range) end  -- GOLD + my upgrades, leave the rest; roam
          elseif g then
            bot.walk_to(g.x, g.y, g.z, g.range)              -- outbound / return → march together
          else
            bot.loot()
          end
        else
          bot.state.idle_n = (bot.state.idle_n or 0) + 1
          if bot.state.idle_n % 2 == 0 then bot.equip_upgrades() else bot.loot() end                             -- idle: loot a corpse within 3 tiles (gold + items) after a kill; yields like wait if none
        end
      else
        if not bot.warmode() then bot.set_warmode(true) end  -- set_warmode YIELDS (~0.5s pace); only when needed
        if foe.dist and foe.dist <= KEEP_DIST then
          if not bot.los(foe.serial) then
            step_toward(foe)                      -- #12: close foe behind a wall -> round the obstacle (step_toward escalates to A*), don't back-pedal into terrain with no sightline (the shot would fizzle)
          elseif kite_stuck(foe) then
            bot.attack(foe.serial)              -- NW2-KITE-RECOVER: can't open distance → stand and shoot
          else
            step_back(foe)                       -- too close → ONE step out, re-decide next tick
          end
        elseif not bot.los(foe.serial) then
          step_toward(foe)                        -- no sightline → close one tile to round the obstacle
        else
          bot.state.kite_stuck_n = 0             -- at good range → reset, then fire
          bot.attack(foe.serial)                  -- LOS + range → archery auto-fires
        end
      end
    end

    yield()
  end
end
