-- nw_hunter.lua — NewWorld Hunter: CASTER-HYBRID. COMBAT-ONLY.
--
-- Class skills (ZuluClass.cs:164): full Magery + Meditation + MagicResist (caster) + Archery +
-- Swords/Fencing/Macing/Tactics/Parry/Healing (melee) + Stealth/Hiding. So it casts like a MAGE.
--
-- Doctrine (operator spec 2026-05-30): full mage cascade; at range it nukes/CCs and SHOOTS the bow
-- when out of mana; when an enemy closes to melee it SWITCHES to shield + Kryss and fights.
-- Weapon switch via the equip_ranged / equip_melee adapter actions (gear provisioned by
-- equip_combat_gear: Bow equipped + Kryss + HeaterShield in pack + reagents + arrows).
--
-- Hot-reloaded live. Round-2 shared layer: follows the tribe leader's focus (tribe_card).

local HEAL_HP     = 0.5
local KITE_DIST   = 3            -- step back to keep casting/shooting room if a foe is this close
local MELEE_RANGE = 1.5          -- at/below this → switch to shield+Kryss and melee
local KITE_STEP   = 1
local CAST_BACKOFF = 6           -- NW2-FIZZLE: stop casting this many ticks after a post-delay fizzle
local MAGERY_MIN   = 50          -- NW2-FIZZLE: don't attempt ANY spell below this Magery (else fizzle-loop); shoot the bow instead

-- ===== NW2-TARGETING: threat model (ranged caster) =====
local W_CASTER     = 8
local W_WOUNDED    = 4
local W_NEAR       = 12
local W_PROX       = 0.15
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

-- ONE-tile stutter-step AWAY (range 0 → arrives next tick → re-decide every tick).
local function kite_step(foe)
  local p = bot.position()
  local dx, dy = sign(p.x - foe.x), sign(p.y - foe.y)
  if dx == 0 and dy == 0 then dx = 1 end
  bot.walk_to(p.x + dx * KITE_STEP, p.y + dy * KITE_STEP, p.z, 0)
end

-- ONE tile TOWARD the foe (no-LOS → round the obstacle).
local function step_toward(foe)
  local p = bot.position()
  local dx, dy = sign(foe.x - p.x), sign(foe.y - p.y)
  if dx == 0 and dy == 0 then return end
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

local NUKES = { "FlameStrike", "EnergyBolt", "Lightning", "Fireball", "MagicArrow" }
local function best_nuke()
  for _, s in ipairs(NUKES) do
    if bot.can_cast(s) then return s end
  end
  return nil
end

-- NW2-FIZZLE: back off ALL casts a few ticks after a post-delay fizzle (then shoot/melee instead).
local function note_fail(fail)
  local b = bot.state.cast_block or 0
  if b > 0 then bot.state.cast_block = b - 1 end       -- decay BEFORE set → a fresh fizzle gets the FULL CAST_BACKOFF ticks (no off-by-one)
  if fail == "cast_fizzled" then bot.state.cast_block = CAST_BACKOFF end
end
local function casting_blocked()
  return (bot.state.cast_block or 0) > 0
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
  -- #10: enrich with the cast-cascade fields so MagicReflect / ManaVampire / Paralyze read the
  -- squad-defend focus correctly (these were nil on this card -> always falsy -> cascade degraded).
  return { serial = s, x = p.x, y = p.y, z = p.z, dist = bot.target_distance(s),
           is_casting = bot.target_casting(s), paralyzed = bot.target_paralyzed(s),
           hp_ratio = bot.target_hp_ratio(s) }
end

function main()
  while true do
    local fail = bot.last_failure_reason()
    note_fail(fail)
    local cast_ok = (fail ~= "cast_did_not_start") and not casting_blocked()
                    and bot.skill("Magery") >= MAGERY_MIN   -- low-Magery hunter → no fizzle-loop, shoot the bow
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
      elseif cast_ok and bot.can_cast("GreaterHeal") then bot.cast_self("GreaterHeal")   -- hunter has full Magery
      elseif bot.has_bandage() then bot.bandage_self()
      elseif bot.hp_ratio() < 0.30 and bot.state.home_x then
        bot.set_warmode(false)
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
        bot.state.opener_done = nil
        bot.state.debuffed = nil
        bot.state.mode = nil                     -- reset ranged/melee memo → next fight re-decides (don't start mis-armed in stale melee mode)
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
        bot.state.focus = foe.serial
        if not bot.warmode() then bot.set_warmode(true) end

        -- #14: deadband the melee/ranged choice so a foe dancing across the boundary can't thrash
        -- equip_melee/equip_ranged (each swap is a wasted turn, no attack that tick). Enter melee at
        -- <= MELEE_RANGE; only LEAVE melee once the foe passes KITE_DIST. Between the two, keep mode.
        local d = foe.dist or 99
        local want_melee = (bot.state.mode == "melee") and (d <= KITE_DIST) or (d <= MELEE_RANGE)

        if want_melee then
          -- Enemy in melee → switch to shield + Kryss, then fight. Switch yields; attack next tick.
          if bot.state.mode ~= "melee" then
            bot.state.mode = "melee"
            bot.act("equip_melee", {})
          else
            bot.attack(foe.serial)
          end

        else
          -- AT RANGE → ensure the bow is up, then run the mage cascade; shoot when we can't cast.
          if bot.state.mode ~= "ranged" then
            bot.state.mode = "ranged"
            bot.act("equip_ranged", {})

          elseif foe.dist and foe.dist <= KITE_DIST then
            kite_step(foe)                                   -- reopen casting/shooting room
          elseif not bot.los(foe.serial) then
            step_toward(foe)

          -- DOCTRINE CASCADE (one cast/tick). NAME TRAP: SPELL "MagicReflect" / BUFF "MagicReflection".
          elseif foe.is_casting and not bot.has_buff("MagicReflection")
                 and bot.can_cast("MagicReflect") and cast_ok then
            bot.cast_self("MagicReflect")
          elseif not bot.state.opener_done and not bot.has_buff("Protection")
                 and bot.can_cast("Protection") and cast_ok then
            bot.cast_self("Protection"); bot.state.opener_done = true
          elseif foe.dist and foe.dist > KITE_DIST and not foe.paralyzed
                 and bot.can_cast("Paralyze") and cast_ok then
            bot.cast("Paralyze", foe.serial)                 -- lock a ranged foe to open a window
          elseif tostring(bot.state.debuffed or "") ~= tostring(foe.serial) and cast_ok
                 and ((foe.is_casting and bot.can_cast("ManaVampire")) or bot.can_cast("Curse")) then
            if foe.is_casting and bot.can_cast("ManaVampire") then
              bot.cast("ManaVampire", foe.serial)
            else
              bot.cast("Curse", foe.serial)
            end
            bot.state.debuffed = foe.serial

          else
            -- A PLAIN bow is auto-disarmed when we cast (ClearHandsOnCast → Mobile.ClearHand). A
            -- channeling bow is NOT: Mobile.ClearHand keeps any weapon whose AllowEquippedCast is true —
            -- MYSTICAL / STYGIAN bows (BaseWeapon.cs:2397) + GM bows (e.g. VampiricBow) channel, so for
            -- THEM equipped_weapon() stays true after a cast and this re-equip branch never fires (they
            -- cast-then-shoot seamlessly). With a plain bow ("пока мистикала нет") we re-equip only when we
            -- actually need to SHOOT — caster-primary, so no weapon flicker between consecutive casts.
            local nuke = cast_ok and best_nuke() or nil
            if nuke then
              bot.cast(nuke, foe.serial)                     -- cast (plain bow → server moves it to the pack; mystical bow → stays)
            elseif not bot.equipped_weapon() then
              bot.act("equip_ranged", {})                    -- a plain-bow cast disarmed it → re-equip, shoot next tick
            else
              bot.attack(foe.serial)                         -- bow in hand → SHOOT
            end
          end
        end
      end
    end

    yield()
  end
end
