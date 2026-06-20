-- nw_bard.lua — NewWorld Bard: control-first HYBRID CASTER. COMBAT-ONLY.
--
-- Hot-reloaded live. A bound script OWNS the bot — stop the Python runtime ([Bots).
--
-- Class skills (ZuluClass.cs): Meditation + full MAGERY + Discordance + Inscribe + Musicianship +
-- Peacemaking + Provocation + ARCHERY. So the bard is a control + caster-ARCHER triple-threat:
-- CONTROLS (Bard skills, played from a Lute in the pack), casts like a MAGE, AND shoots a bow.
-- equip_combat_gear gives it a MYSTICAL bow (channels — casting doesn't disarm it), reagents, and
-- LEATHER armor (low magic-efficiency penalty — it's a Meditation caster, studded would ~2× the penalty).
--
-- Doctrine (operator spec 2026-05-30): control first, then cast, shoot when out of mana.
--   overwhelmed (3+ foes / low HP) → Peacemaking (calm the area, buy time)
--   a fresh pair of distinct foes  → Provocation (turn them on each other; then back off)
--   first contact on the focus     → Discordance (the bard's signature debuff, once)
--   then the MAGE CASCADE          → MagicReflect a caster · Paralyze a ranged foe · nuke ladder
--   out of mana                    → SHOOT the bow (Archery) — the bard's no-mana damage, not fists
-- Survive via potions / bandage / self-heal (+ flee-to-home in the ladder).
--
-- Round-2 (TODO.md): NW2-TARGETING (threat score for the focus), NW2-FIZZLE (gate every cast on
-- Magery skill + back off after a post-delay fizzle). REQUIRES the Part-B verbs (use_skill /
-- use_skill_on / provoke) + bot.skill — they deploy with the C# build on the operator restart.

local HEAL_HP         = 0.5
local MELEE_RANGE     = 1.5
local MAGERY_MIN      = 50      -- NW2-FIZZLE: don't cast (heal OR nuke) below this Magery — a low-skill bard sticks to control + fists
local CAST_BACKOFF    = 6       -- NW2-FIZZLE: ticks to stop casting after a post-delay fizzle
local PROVOKE_BACKOFF = 8       -- ticks between Provocation re-issues (the skill has a use-delay; let the provoked fight play out)

-- ===== NW2-TARGETING: threat model =====
local W_CASTER     = 6
local W_WOUNDED    = 4
local W_NEAR       = 10
local W_PROX       = 0.3
local W_PARALYZED  = 3
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

-- ONE tile TOWARD the foe (no-LOS → round the obstacle to open a sightline for the nuke).
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

-- Damage ladder: cast the highest-tier nuke the current mana allows (verified SpellEntry names;
-- can_cast() gates on mana/recovery/frozen/alive). Same ladder the mage/hunter run.
local NUKES = { "FlameStrike", "EnergyBolt", "Lightning", "Fireball", "MagicArrow" }
local function best_nuke()
  for _, s in ipairs(NUKES) do
    if bot.can_cast(s) then return s end
  end
  return nil
end

-- NW2-FIZZLE: back off ALL casts a few ticks after a post-delay fizzle; decay the provoke cooldown.
local function note_fail(fail)
  local b = bot.state.cast_block or 0
  if b > 0 then bot.state.cast_block = b - 1 end       -- decay BEFORE set → a fresh fizzle gets the FULL CAST_BACKOFF ticks (no off-by-one)
  if fail == "cast_fizzled" then bot.state.cast_block = CAST_BACKOFF end
  local pb = bot.state.provoke_block or 0
  if pb > 0 then bot.state.provoke_block = pb - 1 end
  local kb = bot.state.peace_block or 0
  if kb > 0 then bot.state.peace_block = kb - 1 end
end

-- Casts are OK this tick unless: the last intent didn't start, we're in a fizzle backoff,
-- or Magery is too low to land them (a low-skill bard relies on control skills + fists).
local function cast_ready(fail)
  return (fail ~= "cast_did_not_start")
     and (bot.state.cast_block or 0) == 0
     and bot.skill("Magery") >= MAGERY_MIN
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

-- DEFEND: first enemy attacking a TEAMMATE (nearby_allies excludes self) = top-priority focus. nil = none.
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
  -- #10: enrich with the cast-cascade fields so MagicReflect / Paralyze read the squad-defend focus
  -- correctly (these were nil on this card -> always falsy -> cascade degraded).
  return { serial = s, x = p.x, y = p.y, z = p.z, dist = bot.target_distance(s),
           is_casting = bot.target_casting(s), paralyzed = bot.target_paralyzed(s),
           hp_ratio = bot.target_hp_ratio(s) }
end

function main()
  while true do
    local fail = bot.last_failure_reason()
    note_fail(fail)
    local cast_ok = cast_ready(fail)
    if not bot.state.home_x then bot.set_home() end

    if bot.is_dead() then
      bot.resurrect(); wait(2)

    elseif bot.is_bandaging() then
      wait(1)

    elseif bot.is_paralyzed() then
      if bot.is_poisoned() and bot.best_cure_strength() >= bot.poison_level() and bot.has_potion("cure") then
        bot.drink("cure")
      elseif bot.hp_ratio() < HEAL_HP and bot.has_potion("heal") then
        bot.drink("heal")
      else
        wait(1)
      end

    elseif bot.is_poisoned() and bot.has_potion("cure") and bot.best_cure_strength() >= bot.poison_level() then
      bot.drink("cure")

    elseif bot.hp_ratio() < HEAL_HP then
      if bot.has_potion("heal") then bot.drink("heal")
      elseif cast_ok and bot.can_cast("GreaterHeal") then bot.cast_self("GreaterHeal")   -- only if Magery is high enough
      elseif bot.has_bandage() then bot.bandage_self()
      elseif bot.hp_ratio() < 0.30 and bot.state.home_x then
        bot.set_warmode(false)
        bot.flee(bot.state.home_x, bot.state.home_y, bot.state.home_z, 1)
      else
        wait(1)
      end

    else
      local enemies = bot.nearby_enemies(10)
      local allies = bot.nearby_allies(10)
      -- DEFEND FIRST: peel anything hitting a TEAMMATE (sets the focus to nuke/shoot; control still helps).
      local foe = squad_defend_card() or defend_pick(enemies, allies) or tribe_card(enemies) or pick_foe(enemies)
      local n = #enemies
      if not foe then
        bot.set_warmode(false)
        bot.state.discorded = nil                -- reset first-contact memo for the next fight
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
          if bot.state.idle_n % 2 == 0 then bot.equip_upgrades() else bot.loot() end                               -- idle: loot a corpse within 3 tiles (gold + items) after a kill; yields like wait if none
        end
      else
        if not bot.warmode() then bot.set_warmode(true) end  -- set_warmode YIELDS (~0.5s pace); only when needed

        if (n >= 3 or bot.hp_ratio() < 0.4) and (bot.state.peace_block or 0) == 0 and bot.can_use_skill() then
          bot.use_skill("Peacemaking")           -- overwhelmed → calm the area, buy time
          bot.state.peace_block = 8              -- then BACK OFF ~8 ticks → fall through to provoke/nuke/shoot between calms (don't spam Peacemaking & contribute zero damage)

        elseif n >= 2 and enemies[1].serial ~= enemies[2].serial
               and bot.can_attack(enemies[1].serial) and bot.can_attack(enemies[2].serial)
               and (bot.state.provoke_block or 0) == 0 and bot.can_use_skill() then
          bot.provoke(enemies[1].serial, enemies[2].serial)   -- 2 DISTINCT foes → turn them on each other, then back off
          bot.state.provoke_block = PROVOKE_BACKOFF

        elseif tostring(bot.state.discorded or "") ~= tostring(foe.serial) and bot.can_use_skill() then
          bot.use_skill_on("Discordance", foe.serial)         -- first contact on this focus → signature debuff
          bot.state.discorded = foe.serial

        elseif not bot.los(foe.serial) then
          step_toward(foe)                                    -- no sightline → close one tile to open the nuke

        -- MAGE CASCADE (one cast/tick). NAME TRAP: cast SPELL "MagicReflect"; the BUFF is "MagicReflection".
        elseif foe.is_casting and not bot.has_buff("MagicReflection")
               and bot.can_cast("MagicReflect") and cast_ok then
          bot.cast_self("MagicReflect")                       -- bounce a casting foe's spell
        elseif foe.dist and foe.dist > MELEE_RANGE and not foe.paralyzed
               and bot.can_cast("Paralyze") and cast_ok then
          bot.cast("Paralyze", foe.serial)                    -- lock a ranged foe to open a nuke window

        else
          local nuke = cast_ok and best_nuke() or nil
          if nuke then
            bot.cast(nuke, foe.serial)                        -- cast (Mystical bow channels; a plain bow → pack)
          elseif not bot.equipped_weapon() then
            bot.act("equip_ranged", {})                       -- a plain-bow cast stripped it → re-equip to shoot
          else
            bot.attack(foe.serial)                            -- out of mana → SHOOT the bow (Archery), not fists
          end
        end
      end
    end

    yield()
  end
end
