-- nw_all.lua — generic NewWorld bot behavior (any class without its own nw_<class>.lua).
--
-- Hot-reloaded live by NewWorldScriptWatcher (no server restart). main() is a
-- coroutine: act verbs yield the tick, readers return immediately. A bound
-- script OWNS the bot — stop the Python runtime ([Bots) while scripting so the
-- two brains don't fight over the same agent.
--
-- COMBAT-ONLY bot (no crafting/gathering). This generic file: survive
-- (cure/heal/bandage), threat-target + focus-fire a foe, ring it from a free flank
-- tile, and engage; stand down when clear. Class-specific tactics live in
-- nw_mage.lua / nw_warrior.lua / nw_ranger.lua (and nw_thief/bard/hunter), which
-- override this for their class.
--
-- Round-2 (TODO.md): NW2-TARGETING (threat score, not lowest-HP), NW2-FOCUS-
-- HYSTERESIS (committed focus + damped leader election — no per-tick thrash),
-- NW2-FORMATION (melee bots ring a foe instead of stacking).

local HEAL_HP = 0.5
local MELEE_RANGE = 1.5   -- Euclidean: a diagonal-adjacent foe (~1.41) is already in reach
local FORMATION_RANGE = 4 -- NW2-FORMATION: only ring the foe from a flank within this range (avoid long-range exact-tile chase)
local CHASE_CAP = 14      -- drop a committed off-card focus beyond this many tiles (don't sprint across the map / abandon the squad)

-- ===== NW2-TARGETING: threat model (operator may tune W_* after live obs) =====
-- Pure function over the cached nearby_enemies card — NO new Map scan. Higher = first.
local W_CASTER     = 6     -- interrupt/kill a caster
local W_WOUNDED    = 4     -- finish the low-HP foe
local W_NEAR       = 12    -- proximity reference point (dist cards cap ~24)
local W_PROX       = 0.6   -- >0 prefers CLOSE foes (melee); kiters flip this negative
local W_PARALYZED  = 3     -- deprioritize an already-CC'd target
local W_CONTROLLED = 2     -- deprioritize a pet (go for its master)
local W_HITME      = 5     -- prioritize whoever is hitting ME (peel); 0 skips the per-foe read
local STICKY_MARGIN = 3    -- only abandon the committed target if another beats it by this much

local function score_foe(e)
  if not e then return -1e9 end
  local s = 0
  if e.is_casting then s = s + W_CASTER end
  s = s + (1 - (e.hp_ratio or 1)) * W_WOUNDED
  s = s + (W_NEAR - (e.dist or W_NEAR)) * W_PROX
  if e.paralyzed then s = s - W_PARALYZED end
  if e.is_controlled then s = s - W_CONTROLLED end
  if W_HITME > 0 and e.serial
     and tostring(bot.target_combatant(e.serial) or "0") == tostring(bot.serial) then
    s = s + W_HITME
  end
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

local function card_for(list, serial)
  for _, e in ipairs(list) do
    if tostring(e.serial) == tostring(serial) then return e end
  end
  return nil
end

-- Tribe focus-fire (P2): the leader (lowest serial among nearby allies, incl. me)
-- broadcasts the focus target; followers commit to it. NW2-FOCUS-HYSTERESIS: damp the
-- election so a bot briefly roaming through the 12-tile radius can't yank leadership and
-- thrash the broadcast — a lower rival must persist >=2 ticks before we yield.
local function is_leader(allies)
  -- A DESIGNATED tribe leader (главарь, set by [NWScript spawnsquad/setleader) overrides the
  -- lowest-serial election entirely: that one bot leads, everyone else follows.
  local tl = bot.tribe_leader()
  if tl then return tostring(bot.serial) == tostring(tl) end
  local me = tonumber(bot.serial) or 0
  local lowest = me
  for _, a in ipairs(allies) do
    local s = tonumber(a.serial) or 0
    if s ~= 0 and s < lowest then lowest = s end
  end
  if lowest == me then
    bot.state.lead_rival = nil
    bot.state.lead_rival_n = 0
    return true
  end
  if tostring(bot.state.lead_rival or "") == tostring(lowest) then
    bot.state.lead_rival_n = (bot.state.lead_rival_n or 0) + 1
  else
    bot.state.lead_rival = lowest
    bot.state.lead_rival_n = 1
  end
  return (bot.state.lead_rival_n or 0) < 2   -- still leader until the rival sticks 2 ticks
end

-- Build a foe table {serial,x,y,z,dist} from a bare serial (a signalled / off-card focus
-- has no card) via the target_* readers. nil if the target is gone/unreachable.
local function foe_from_serial(s)
  if not (s and bot.target_alive(s)) then return nil end
  local p = bot.target_position(s)
  if not p then return nil end
  return { serial = s, x = p.x, y = p.y, z = p.z, dist = bot.target_distance(s) }
end

-- NW2-FOCUS-HYSTERESIS + targeting stickiness. Commits a focus in bot.state.focus and
-- HOLDS it across ticks (followers hold the leader's broadcast; the leader holds its own
-- sticky threat-pick), releasing only when the target dies / is unattackable or a fresh
-- foe decisively outscores it. Returns a foe card (or a rebuilt off-card card), or nil.
local function decide_foe(list, leader)
  local fs = bot.state.focus
  -- #11 focus-fire: a FOLLOWER converges on the leader's broadcast over its OWN sticky commit unless its
  -- own target is decisively better (anti-thrash via STICKY_MARGIN). The leader never adopts its own
  -- broadcast. This concentrates the squad's fire even before anyone is hit (squad_defend only fires once
  -- a teammate IS under attack). Reachability-capped like the off-card chase; once adopted, fs==sig so it
  -- won't re-trigger next tick (no flip-flop).
  if not leader then
    local sig = bot.check_signal("focus")
    if sig and tostring(sig) ~= tostring(fs) and bot.target_alive(sig) and bot.can_attack(sig) then
      local sigcard = card_for(list, sig) or foe_from_serial(sig)
      if sigcard and (not sigcard.dist or sigcard.dist <= CHASE_CAP) then
        local held = (fs and bot.target_alive(fs)) and (card_for(list, fs) or foe_from_serial(fs)) or nil
        if not held or score_foe(sigcard) >= score_foe(held) - STICKY_MARGIN then
          bot.state.focus = sig
          return sigcard
        end
      end
    end
  end
  if fs and bot.target_alive(fs) and bot.can_attack(fs) then
    local keep = card_for(list, fs)
    if keep then
      local best = pick_foe(list)
      if best and score_foe(best) > score_foe(keep) + STICKY_MARGIN then
        bot.state.focus = best.serial
        return best
      end
      return keep
    end
    -- committed focus out of the 10-tile scan → pursue by serial only within the chase cap;
    -- beyond it, drop the commit and fall through to re-pick a LOCAL foe (don't chase across the map).
    local off = foe_from_serial(fs)
    if off and off.dist and off.dist <= CHASE_CAP then return off end
    bot.state.focus = nil
  end
  -- no valid commitment: leader self-picks, follower adopts the broadcast
  local foe
  if leader then
    foe = pick_foe(list) or bot.find_target(10)
  else
    local sig = bot.check_signal("focus")
    if sig and bot.can_attack(sig) then foe = card_for(list, sig) or foe_from_serial(sig) end
    foe = foe or pick_foe(list) or bot.find_target(10)
  end
  if foe then bot.state.focus = foe.serial end
  return foe
end

-- NW2-FORMATION: when closing to melee, ring the foe from a FREE adjacent tile instead of
-- every bot stacking on one tile / body-blocking. Pure Lua over the cached nearby_allies
-- positions; ONE walk_to, re-decided next tick. Returns nil when solo (keep plain approach)
-- or when every flank is taken (caller falls back to the default chase).
local FLANK = { {1,0},{-1,0},{0,1},{0,-1},{1,1},{1,-1},{-1,1},{-1,-1} }
local function melee_slot(foe, allies)
  if #allies == 0 then return nil end
  local occ = {}
  for _, a in ipairs(allies) do
    if a.x and a.y then occ[a.x .. ":" .. a.y] = true end
  end
  local p = bot.position()
  local best, bestd = nil, 1e9
  for _, o in ipairs(FLANK) do
    local tx, ty = foe.x + o[1], foe.y + o[2]
    if not occ[tx .. ":" .. ty] then
      local dx, dy = tx - p.x, ty - p.y
      local d = dx * dx + dy * dy
      if d < bestd then best, bestd = { x = tx, y = ty }, d end
    end
  end
  return best
end

-- DEFEND: the first enemy currently attacking a TEAMMATE (nearby_allies excludes self) is the squad's
-- top-priority kill — everyone converges on it, kills it, THEN resumes. Pure reads over the cached enemy
-- cards + target_combatant. nil = no teammate under attack (fall through to the normal threat pick).
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
-- attacker in its own 10-tile scan — drops everything and helps ("сразу идти убивать того кто бьёт
-- мага"). Built from the global target_* readers (no per-brain dependency); validated by can_attack.
-- Because every brain reads the SAME serial, it also makes the squad focus-fire one target.
local function squad_defend_card()
  local s = bot.squad_defend()
  if not s or not bot.can_attack(s) then return nil end
  local p = bot.target_position(s)
  if not p then return nil end
  -- #10: enrich with the cast-cascade fields so a MagicReflect / ManaVampire / Paralyze branch reads
  -- the squad-defend focus correctly (these were nil on this card -> always falsy -> cascade degraded).
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
        wait(1)                                -- nothing useful to do under paralyze; don't melee
      end

    elseif bot.is_poisoned() and bot.has_potion("cure") and bot.best_cure_strength() >= bot.poison_level() then
      bot.drink("cure")                        -- only if a cure STRONG ENOUGH exists (else consumed + 7s lockout)

    elseif bot.hp_ratio() < HEAL_HP then
      bot.signal("protect", bot.serial)          -- ask a free ally to peel my attacker (signal doesn't yield)
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
      -- COMBAT. Compute leadership ONCE per tick (is_leader has damping side-effects).
      local allies = bot.nearby_allies(12)                   -- ONE ally scan/tick (nearby_allies is uncached) — shared by leader-pick + formation + defend
      local leader = is_leader(allies)
      local enemies = bot.nearby_enemies(10)
      -- DEFEND FIRST: if anything is hitting a TEAMMATE, the whole squad converges on it and kills it
      -- before doing anything else ("если кого-то бьют, все подключаются"). Else normal focus-fire.
      local foe = squad_defend_card() or defend_pick(enemies, allies) or decide_foe(enemies, leader)
      if foe then
        if leader then bot.signal("focus", foe.serial) end   -- publish the held focus for followers
        if not bot.warmode() then bot.set_warmode(true) end  -- set_warmode YIELDS (~0.5s pace); only when needed
        if foe.dist and foe.dist > MELEE_RANGE then
          local p = bot.position()
          local slot = (foe.dist <= FORMATION_RANGE) and melee_slot(foe, allies) or nil  -- ring up only at the convergence point
          if slot then
            bot.walk_to(slot.x, slot.y, p.z, 0)              -- NW2-FORMATION: ring the foe from a distinct free tile
          else
            bot.walk_to(foe.x, foe.y, p.z, 1)                -- far / solo / all flanks taken → plain approach
          end
        else
          bot.attack(foe.serial)               -- adjacent → auto-swings
        end
      else
        -- No foe of my own: release any stale commit; am I asked to PROTECT a low-HP ally?
        bot.state.focus = nil
        local ally = bot.consume_signal("protect")           -- consume = ONE rescuer claims it
        local atk = ally and bot.target_combatant(ally) or nil
        if atk and bot.can_attack(atk) then
          if not bot.warmode() then bot.set_warmode(true) end
          bot.attack(atk)                        -- peel the ally's attacker
        elseif bot.patrol_active() then
          -- Graveyard patrol clear-branch (C# resolves the goal). Combat/defend handled above.
          bot.set_warmode(false)
          local g = bot.patrol_target()
          if g and g.kind == "sweep" then
            -- in the graveyard between fights: grab corpse GOLD + items, AND keep roaming the corners
            bot.state.idle_n = (bot.state.idle_n or 0) + 1
            if bot.state.idle_n % 2 == 0 then bot.loot_smart() else bot.walk_to(g.x, g.y, g.z, g.range) end
          elseif g then
            bot.walk_to(g.x, g.y, g.z, g.range)              -- outbound / return → march together
          else
            bot.loot()
          end
        else
          bot.set_warmode(false)
          bot.state.idle_n = (bot.state.idle_n or 0) + 1
          if bot.state.idle_n % 2 == 0 then bot.equip_upgrades() else bot.loot() end                             -- idle: loot a corpse within 3 tiles (gold + items) after a kill; yields like wait if none
        end
      end
    end

    yield()
  end
end
