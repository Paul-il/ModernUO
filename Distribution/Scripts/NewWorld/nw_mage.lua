-- nw_mage.lua — NewWorld Mage: survive, kite melee, nuke at range, punish/lock casters.
--
-- Hot-reloaded live by NewWorldScriptWatcher (save the file → ~1.5s debounce →
-- behavior changes, no server restart). main() is a coroutine: act verbs
-- (drink/cast/walk_to/attack) yield the tick; readers (hp_ratio/find_target/…)
-- return immediately. bot.state persists across reloads. COMBAT-ONLY bot.
--
-- Round-2 (TODO.md): NW2-TARGETING (threat score over nearby_enemies), NW2-MAGE-CC
-- (Paralyze a RANGED foe by standoff distance, not the transient is_casting the
-- MagicReflect branch already consumes), NW2-FIZZLE (a post-delay fizzle backs off ALL
-- casts for a few ticks → the mage pivots to melee instead of fizzle-looping a nuke).

local HEAL_HP   = 0.55          -- self-heal below this HP ratio
local KITE_DIST = 3             -- open distance if a foe is this close
local KITE_STEP = 1             -- ONE tile/tick stutter-step (re-decide every tick, no 1.5-3s walk blackout)
local MELEE_RANGE = 1.5         -- Euclidean: a diagonal-adjacent foe (~1.41) is already in reach
local CAST_BACKOFF = 6          -- NW2-FIZZLE: ticks to stop casting after a post-delay fizzle (pivot to melee)
local HEAL      = "GreaterHeal"

-- ===== NW2-TARGETING: threat model (ranged-nuker tuned; casters are the priority) =====
local W_CASTER     = 9     -- a ranged caster is the mage's top target
local W_WOUNDED    = 4     -- finish the low-HP foe
local W_NEAR       = 12    -- proximity reference point
local W_PROX       = 0.15  -- ranged → only a mild pull toward closer foes
local W_PARALYZED  = 3     -- deprioritize an already-CC'd target
local W_CONTROLLED = 2     -- deprioritize a pet

local function sign(d)
  if d > 0 then return 1 elseif d < 0 then return -1 else return 0 end
end

-- ONE-tile stutter-step AWAY from the foe's real position. range 0 = exactly that
-- tile, so the WalkTo await clears next manager tick (~1 step ~200ms) and main()
-- re-decides every tick instead of blacking out for a 6-tile run (1.5-3s).
local function kite_step(foe)
  local p = bot.position()
  local dx, dy = sign(p.x - foe.x), sign(p.y - foe.y)
  if dx == 0 and dy == 0 then dx = 1 end   -- stacked: pick a direction
  bot.walk_to(p.x + dx * KITE_STEP, p.y + dy * KITE_STEP, p.z, 0)
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

-- NW2-TARGETING: threat score (pure fn over the cached card — no new scan).
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

-- Damage ladder: cast the highest-tier nuke the current mana allows. Every entry
-- is a verified SpellEntry name (FlameStrike=50/EnergyBolt=41/Lightning=29/
-- Fireball=17/MagicArrow=04). can_cast() gates on mana/recovery/frozen/alive.
local NUKES = { "FlameStrike", "EnergyBolt", "Lightning", "Fireball", "MagicArrow" }
local function best_nuke()
  for _, s in ipairs(NUKES) do
    if bot.can_cast(s) then return s end
  end
  return nil
end

-- Commit to a focus: prefer the still-present/alive focus serial over re-picking
-- (so the mage doesn't flip-flop targets), else the best-scoring threat.
local function pick_focus(list)
  local fs = bot.state.focus
  if fs then
    for _, e in ipairs(list) do
      if tostring(e.serial) == tostring(fs) then return e end
    end
  end
  return pick_foe(list)
end

-- NW2-FIZZLE: after a post-cast-delay fizzle (reagents/skill), back off ALL casts for a
-- few ticks so a resource-short mage pivots to melee instead of re-fizzling every cycle.
-- The C# hook sets last_failure_reason()=="cast_fizzled" when CheckSequence() fails late.
local function note_fail(fail)
  local b = bot.state.cast_block or 0
  if b > 0 then bot.state.cast_block = b - 1 end       -- decay BEFORE set → a fresh fizzle gets the FULL CAST_BACKOFF ticks (no off-by-one)
  if fail == "cast_fizzled" then bot.state.cast_block = CAST_BACKOFF end
end
local function casting_blocked()
  return (bot.state.cast_block or 0) > 0
end

-- Follow the tribe leader's broadcast focus if it's an attackable enemy in range (shared-brain
-- concentration — the главарь directs the whole squad's fire). nil → fall back to own pick.
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
-- teammate. Nuke/converge on it BEFORE any local pick so even a FAR bot — who can't SEE the mage's
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
    local fail = bot.last_failure_reason()   -- read-once-clear; reacted to below
    note_fail(fail)
    local cast_ok = (fail ~= "cast_did_not_start") and not casting_blocked()
    if not bot.state.home_x then bot.set_home() end   -- anchor = first safe spot we saw

    if bot.is_dead() then
      bot.resurrect()                          -- manager also auto-rezzes after 10s
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
        wait(1)                                -- nothing useful to do under paralyze; don't cast/melee
      end

    elseif bot.is_poisoned() and bot.has_potion("cure") and bot.best_cure_strength() >= bot.poison_level() then
      bot.drink("cure")                        -- only if a cure STRONG ENOUGH exists (else consumed + 7s lockout)

    elseif bot.hp_ratio() < HEAL_HP then
      -- Potion first (instant, uninterruptible); else cast if mana allows AND casting isn't
      -- backed off (a fizzle means GreaterHeal would fizzle too → go straight to bandage); else flee.
      if bot.has_potion("heal") then
        bot.drink("heal")
      elseif cast_ok and bot.can_cast(HEAL) then
        bot.cast_self(HEAL)
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
      -- DEFEND FIRST: if a TEAMMATE is being hit, nuke that attacker before our own pick (protect the squishy).
      local foe = squad_defend_card() or defend_pick(enemies, allies) or tribe_card(enemies) or pick_focus(enemies) or bot.find_target(12)
      if not foe then
        -- No enemies: stand down + reset the per-fight memo so a new fight re-applies
        -- the opener/debuff. (focus/opener_done/debuffed_focus are flat scalars.)
        bot.set_warmode(false)
        bot.state.focus = nil
        bot.state.opener_done = nil
        bot.state.debuffed_focus = nil
        if bot.patrol_active() then
          -- Patrol. Buff the party (Bless drip) ONLY while SWEEPING the graveyard — NOT during the
          -- outbound march: casting costs walk-ticks, so a buffing mage straggles behind the squad and
          -- wedges at a chokepoint (live-observed 2026-05-31). On the march/return it just walks and
          -- keeps pace. "если никого нет — маг бафает": at the graveyard, between fights, it drips Bless
          -- onto each ally in turn (cast_ok folds in the fizzle/Magery gate; reagents auto-topped by C#).
          local g = bot.patrol_target()
          if g and g.kind == "sweep" then
            local bcd = (bot.state.buff_cd or 0) - 1
            if bcd <= 0 and #allies > 0 and cast_ok and bot.can_cast("Bless") then
              local bi = ((bot.state.buff_i or 0) % #allies) + 1
              bot.state.buff_i = bi
              bot.state.buff_cd = 8               -- next Bless in ~a few ticks → cycles the whole party
              bot.cast("Bless", allies[bi].serial)
            else
              bot.state.buff_cd = (bcd > 0) and bcd or 8
              bot.state.idle_n = (bot.state.idle_n or 0) + 1
              local ik = bot.state.idle_n % 3
              if ik == 0 then bot.loot_smart()                 -- GOLD + my upgrades, leave the rest
              elseif ik == 1 then bot.identify_loot()          -- Item Identification on looted magic items ("маг распознаёт")
              else bot.walk_to(g.x, g.y, g.z, g.range) end     -- roam with the deathball between buffs
            end
          elseif g then
            bot.walk_to(g.x, g.y, g.z, g.range)   -- outbound / return → keep pace with the squad (no buffing)
          else
            bot.loot()
          end
        else
          bot.state.idle_n = (bot.state.idle_n or 0) + 1
          local ik = bot.state.idle_n % 3
          if ik == 0 then bot.equip_upgrades() elseif ik == 1 then bot.identify_loot() else bot.loot() end                               -- idle: loot a corpse within 3 tiles (gold + items) after a kill; yields like wait if none
        end
      else
        bot.state.focus = foe.serial             -- commit (survives ticks/reload as a string)
        if not bot.warmode() then bot.set_warmode(true) end  -- set_warmode YIELDS (~0.5s pace); only when needed
        if foe.dist and foe.dist <= KITE_DIST then
          kite_step(foe)                          -- enemy in melee → ONE step out, re-decide next tick
        elseif not bot.los(foe.serial) then
          step_toward(foe)                        -- no sightline → close one tile to round the obstacle

        -- DOCTRINE CASCADE (one cast/tick; each cast yields, so the opener sequences
        -- naturally across ticks). NAME TRAP: cast SPELL "MagicReflect"; the BUFF icon
        -- has_buff() checks is "MagicReflection". cast_ok folds in the P0-1 pre-cast
        -- guard AND the NW2-FIZZLE post-delay backoff.
        elseif foe.is_casting and not bot.has_buff("MagicReflection")
               and bot.can_cast("MagicReflect") and cast_ok then
          bot.cast_self("MagicReflect")           -- defensive: bounce a casting foe's spell
        elseif not bot.state.opener_done and not bot.has_buff("Protection")
               and bot.can_cast("Protection") and cast_ok then
          bot.cast_self("Protection"); bot.state.opener_done = true   -- once-per-fight opener
        elseif foe.dist and foe.dist > KITE_DIST and not foe.paralyzed
               and bot.can_cast("Paralyze") and cast_ok then
          bot.cast("Paralyze", foe.serial)        -- NW2-MAGE-CC: lock a RANGED foe to open a nuke window
        elseif tostring(bot.state.debuffed_focus or "") ~= tostring(foe.serial)
               and cast_ok
               and ((foe.is_casting and bot.can_cast("ManaVampire")) or bot.can_cast("Curse")) then
          -- one debuff per focus per fight: ManaVampire drains a caster, else Curse
          if foe.is_casting and bot.can_cast("ManaVampire") then
            bot.cast("ManaVampire", foe.serial)
          else
            bot.cast("Curse", foe.serial)
          end
          bot.state.debuffed_focus = foe.serial

        else
          -- Out of mana, or NW2-FIZZLE backed-off. A 0-ARMOR mage must NOT wade into melee to throw
          -- fists (1.25x, no class bonus — near-useless, and it gets the glass cannon killed). Instead
          -- KITE to stay alive and let Meditation regen mana, then resume the cascade next mana tick.
          local nuke = cast_ok and best_nuke() or nil
          if nuke then
            bot.cast(nuke, foe.serial)
          elseif foe.dist and foe.dist <= KITE_DIST then
            kite_step(foe)                          -- foe close + no mana → open distance, regen, re-nuke
          else
            wait(1)                                 -- at range, no mana → hold + regen (never chase in to fist)
          end
        end
      end
    end

    yield()
  end
end
