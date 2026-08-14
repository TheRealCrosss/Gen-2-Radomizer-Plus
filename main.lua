-- Trainer Rematch 2 — Gold v8.0.0
--
-- Clean native Gen 2 / GameShark-style implementation.
--
-- Gold's normal trainer script is:
--   faceplayer
--   trainerflagaction CHECK_FLAG
--   iftrue -> scripttalkafter
--   loadtemptrainer
--   encountermusic
--   opentext
--   trainertext SEEN
--   waitbutton
--   closetext
--   loadtemptrainer
--   startbattle
--   reloadmapafterbattle
--   trainerflagaction SET_FLAG
--   scripttalkafter
--
-- The cartridge GameShark rebattle code redirects the script program counter
-- past the "already beaten?" decision and back into the common trainer battle
-- path. This mod mirrors that exactly for ONE armed interaction: it uses the
-- real Gold World and native Gen 2 VM, but starts the trainer script immediately
-- after the defeated-check branch.
--
-- No save flags are cleared. No NPC ids/events are changed. No battle is built
-- by this mod.

return function(mod)
  local TextBox = require("src.render.TextBox")
  local Overworld = require("src.world.OverworldController")
  local Pokemon = require("src.pokemon.Pokemon")
  local ListMenu = require("src.ui.ListMenu")

  local installed = false
  local previousTalkTo = nil
  local rematchPromptOpen = false
  local bypassPromptOnce = nil

  -- -----------------------------------------------------------------------
  -- Persistent settings
  -- -----------------------------------------------------------------------
  --
  -- These settings intentionally do NOT use the MODS/Mod Manager option rows.
  -- The uploaded Gen3 Battle UI mod proves that this packaged Gold build
  -- reliably persists settings when an in-game START-menu screen writes through
  -- SaveData using loader.fs.  Use that exact path here.
  local DEFAULT_MONEY = 100
  local DEFAULT_XP = 100
  local DEFAULT_PROGRESSIVE = true

  local liveGame = nil
  local settingsLoaded = false
  local settings = {
    moneyPct = DEFAULT_MONEY,
    xpPct = DEFAULT_XP,
    progressive = DEFAULT_PROGRESSIVE,
    trainerProgress = {},
  }

  local rematchBattlePending = false
  local activeRematchBattle = nil

  local function clampPct(value, fallback)
    value = tonumber(value)
    if value == nil then value = fallback end
    value = math.floor(value / 10 + 0.5) * 10
    if value < 0 then value = 0 end
    if value > 100 then value = 100 end
    return value
  end

  local function copyProgress(src)
    local out = {}
    if type(src) == "table" then
      for k, v in pairs(src) do
        out[tostring(k)] = math.max(0, tonumber(v) or 0)
      end
    end
    return out
  end

  local function bucketFor(game)
    local loader = game and game.mods
    if not loader then return nil end
    loader.modOptions = loader.modOptions or {}
    loader.modOptions[mod.id] = loader.modOptions[mod.id] or {}
    return loader.modOptions[mod.id]
  end

  local function writeSettings(game)
    local loader = game and game.mods
    if not loader then return false end

    local bucket = bucketFor(game)
    if not bucket then return false end

    bucket.moneyPct = settings.moneyPct
    bucket.xpPct = settings.xpPct
    bucket.progressive = settings.progressive
    bucket.trainerProgress = copyProgress(settings.trainerProgress)

    -- Exact persistence pattern used by the working Gen3 Battle UI mod:
    -- SaveData + the engine-owned loader.fs.
    local okSave = pcall(function()
      local SaveData = require("src.core.SaveData")
      local fs = loader.fs
      if not (fs and fs.write) then return end

      local opts = SaveData.loadOptions(fs)
      opts.modOptions = opts.modOptions or {}
      opts.modOptions[mod.id] = opts.modOptions[mod.id] or {}

      local persisted = opts.modOptions[mod.id]
      persisted.moneyPct = settings.moneyPct
      persisted.xpPct = settings.xpPct
      persisted.progressive = settings.progressive
      persisted.trainerProgress = copyProgress(settings.trainerProgress)

      SaveData.saveOptions(opts, fs)
    end)

    -- Match the engine's normal runtime notification contract.
    pcall(function()
      if loader.events and loader.events.emit then
        loader.events:emit("mod.options_changed", {
          mod = mod.id,
          key = "_rematch_settings",
          value = true,
        })
      end
    end)

    return okSave
  end

  local function loadSettings(game)
    if settingsLoaded and game == liveGame then return end
    liveGame = game or liveGame
    if not liveGame then return end

    local bucket = bucketFor(liveGame) or {}

    settings.moneyPct = clampPct(bucket.moneyPct, DEFAULT_MONEY)
    settings.xpPct = clampPct(bucket.xpPct, DEFAULT_XP)

    if type(bucket.progressive) == "boolean" then
      settings.progressive = bucket.progressive
    else
      settings.progressive = DEFAULT_PROGRESSIVE
    end

    if type(bucket.trainerProgress) == "table" then
      settings.trainerProgress = copyProgress(bucket.trainerProgress)
    else
      -- One-time migration from older v8.3/v8.4 builds.
      local legacy = mod.save:get("trainerProgress", {})
      settings.trainerProgress = copyProgress(legacy)
    end

    settingsLoaded = true

    -- Seed missing values immediately so a fresh install has an on-disk record
    -- containing 100 / 100 / ON.
    if bucket.moneyPct == nil
       or bucket.xpPct == nil
       or bucket.progressive == nil
       or bucket.trainerProgress == nil then
      writeSettings(liveGame)
    end
  end

  local function optionPct(key, fallback)
    if key == "money" then return clampPct(settings.moneyPct, fallback) end
    if key == "xp" then return clampPct(settings.xpPct, fallback) end
    return fallback
  end

  local function progressionEnabled()
    return settings.progressive == true
  end

  local function getProgress()
    return settings.trainerProgress
  end

  local function persistProgress(progress)
    settings.trainerProgress = copyProgress(progress)
    if liveGame then writeSettings(liveGame) end
    -- Keep the legacy save bucket synchronized for downgrade safety.
    mod.save:set("trainerProgress", settings.trainerProgress)
  end

  local function resetProgress()
    settings.trainerProgress = {}
    persistProgress(settings.trainerProgress)
  end

  local function setSetting(game, key, value)
    loadSettings(game)

    if key == "moneyPct" then
      settings.moneyPct = clampPct(value, DEFAULT_MONEY)
    elseif key == "xpPct" then
      settings.xpPct = clampPct(value, DEFAULT_XP)
    elseif key == "progressive" then
      local previous = settings.progressive
      settings.progressive = value == true
      if previous == true and settings.progressive == false then
        settings.trainerProgress = {}
        mod.save:set("trainerProgress", {})
      end
    else
      return false
    end

    return writeSettings(game)
  end

  local function nextPct(value)
    value = clampPct(value, 100)
    if value >= 100 then return 0 end
    return value + 10
  end

  local function openRematchSettings(game)
    loadSettings(game)

    local items = {
      { key = "moneyPct", label = "REMATCH MONEY", right = tostring(settings.moneyPct) .. "%" },
      { key = "xpPct", label = "REMATCH XP", right = tostring(settings.xpPct) .. "%" },
      { key = "progressive", label = "PROGRESSIVE LEVELS",
        right = settings.progressive and "ON" or "OFF" },
      { key = "back", label = "BACK" },
    }

    local menu
    menu = ListMenu.new(game, "REMATCH SETTINGS", items, {
      wrap = true,
      footer = "A: CHANGE  B: BACK",
      onChoose = function(item, list)
        if not item then return end

        if item.key == "back" then
          game.stack:pop()
          return
        elseif item.key == "moneyPct" then
          setSetting(game, "moneyPct", nextPct(settings.moneyPct))
          item.right = tostring(settings.moneyPct) .. "%"
        elseif item.key == "xpPct" then
          setSetting(game, "xpPct", nextPct(settings.xpPct))
          item.right = tostring(settings.xpPct) .. "%"
        elseif item.key == "progressive" then
          setSetting(game, "progressive", not settings.progressive)
          item.right = settings.progressive and "ON" or "OFF"
        end
      end,
    })

    game.stack:push(menu)
  end


  -- -----------------------------------------------------------------------
  -- Progressive rematch teams
  -- -----------------------------------------------------------------------

  local pendingProgressKey = nil
  local pendingProgressStep = nil
  local pendingProgressParty = nil

  local function copySlot(slot)
    local outSlot = {}
    for k, v in pairs(slot) do
      if type(v) == "table" then
        local t = {}
        for k2, v2 in pairs(v) do t[k2] = v2 end
        outSlot[k] = t
      else
        outSlot[k] = v
      end
    end
    return outSlot
  end

  local GOLD_EVOLUTIONS = {
    ABRA = { { level = 16, species = "KADABRA" } },
    BAYLEEF = { { level = 32, species = "MEGANIUM" } },
    BELLSPROUT = { { level = 21, species = "WEEPINBELL" } },
    BULBASAUR = { { level = 16, species = "IVYSAUR" } },
    CATERPIE = { { level = 7, species = "METAPOD" } },
    CHARMANDER = { { level = 16, species = "CHARMELEON" } },
    CHARMELEON = { { level = 36, species = "CHARIZARD" } },
    CHIKORITA = { { level = 16, species = "BAYLEEF" } },
    CHINCHOU = { { level = 27, species = "LANTURN" } },
    CROCONAW = { { level = 30, species = "FERALIGATR" } },
    CUBONE = { { level = 28, species = "MAROWAK" } },
    CYNDAQUIL = { { level = 14, species = "QUILAVA" } },
    DIGLETT = { { level = 26, species = "DUGTRIO" } },
    DODUO = { { level = 31, species = "DODRIO" } },
    DRAGONAIR = { { level = 55, species = "DRAGONITE" } },
    DRATINI = { { level = 30, species = "DRAGONAIR" } },
    DROWZEE = { { level = 26, species = "HYPNO" } },
    EKANS = { { level = 22, species = "ARBOK" } },
    ELEKID = { { level = 30, species = "ELECTABUZZ" } },
    FLAAFFY = { { level = 30, species = "AMPHAROS" } },
    GASTLY = { { level = 25, species = "HAUNTER" } },
    GEODUDE = { { level = 25, species = "GRAVELER" } },
    GOLDEEN = { { level = 33, species = "SEAKING" } },
    GRAVELER = { { level = 45, species = "GOLEM" } },
    GRIMER = { { level = 38, species = "MUK" } },
    HAUNTER = { { level = 45, species = "GENGAR" } },
    HOOTHOOT = { { level = 20, species = "NOCTOWL" } },
    HOPPIP = { { level = 18, species = "SKIPLOOM" } },
    HORSEA = { { level = 32, species = "SEADRA" } },
    HOUNDOUR = { { level = 24, species = "HOUNDOOM" } },
    IVYSAUR = { { level = 32, species = "VENUSAUR" } },
    KABUTO = { { level = 40, species = "KABUTOPS" } },
    KADABRA = { { level = 45, species = "ALAKAZAM" } },
    KAKUNA = { { level = 10, species = "BEEDRILL" } },
    KOFFING = { { level = 35, species = "WEEZING" } },
    KRABBY = { { level = 28, species = "KINGLER" } },
    LARVITAR = { { level = 30, species = "PUPITAR" } },
    LEDYBA = { { level = 18, species = "LEDIAN" } },
    MACHOKE = { { level = 45, species = "MACHAMP" } },
    MACHOP = { { level = 28, species = "MACHOKE" } },
    MAGBY = { { level = 30, species = "MAGMAR" } },
    MAGIKARP = { { level = 20, species = "GYARADOS" } },
    MAGNEMITE = { { level = 30, species = "MAGNETON" } },
    MANKEY = { { level = 28, species = "PRIMEAPE" } },
    MAREEP = { { level = 15, species = "FLAAFFY" } },
    MARILL = { { level = 18, species = "AZUMARILL" } },
    MEOWTH = { { level = 28, species = "PERSIAN" } },
    METAPOD = { { level = 10, species = "BUTTERFREE" } },
    NATU = { { level = 25, species = "XATU" } },
    NIDORAN_F = { { level = 16, species = "NIDORINA" } },
    NIDORAN_M = { { level = 16, species = "NIDORINO" } },
    ODDISH = { { level = 21, species = "GLOOM" } },
    OMANYTE = { { level = 40, species = "OMASTAR" } },
    ONIX = { { level = 45, species = "STEELIX" } },
    PARAS = { { level = 24, species = "PARASECT" } },
    PHANPY = { { level = 25, species = "DONPHAN" } },
    PIDGEOTTO = { { level = 36, species = "PIDGEOT" } },
    PIDGEY = { { level = 18, species = "PIDGEOTTO" } },
    PINECO = { { level = 31, species = "FORRETRESS" } },
    POLIWAG = { { level = 25, species = "POLIWHIRL" } },
    POLIWHIRL = { { level = 45, species = "POLITOED" } },
    PONYTA = { { level = 40, species = "RAPIDASH" } },
    PORYGON = { { level = 45, species = "PORYGON2" } },
    PSYDUCK = { { level = 33, species = "GOLDUCK" } },
    PUPITAR = { { level = 55, species = "TYRANITAR" } },
    QUILAVA = { { level = 36, species = "TYPHLOSION" } },
    RATTATA = { { level = 20, species = "RATICATE" } },
    REMORAID = { { level = 25, species = "OCTILLERY" } },
    RHYHORN = { { level = 42, species = "RHYDON" } },
    SANDSHREW = { { level = 22, species = "SANDSLASH" } },
    SCYTHER = { { level = 45, species = "SCIZOR" } },
    SEADRA = { { level = 45, species = "KINGDRA" } },
    SEEL = { { level = 34, species = "DEWGONG" } },
    SENTRET = { { level = 15, species = "FURRET" } },
    SKIPLOOM = { { level = 27, species = "JUMPLUFF" } },
    SLOWPOKE = { { level = 37, species = "SLOWBRO" }, { level = 45, species = "SLOWKING" } },
    SLUGMA = { { level = 38, species = "MAGCARGO" } },
    SMOOCHUM = { { level = 30, species = "JYNX" } },
    SNUBBULL = { { level = 23, species = "GRANBULL" } },
    SPEAROW = { { level = 20, species = "FEAROW" } },
    SPINARAK = { { level = 22, species = "ARIADOS" } },
    SQUIRTLE = { { level = 16, species = "WARTORTLE" } },
    SWINUB = { { level = 33, species = "PILOSWINE" } },
    TEDDIURSA = { { level = 30, species = "URSARING" } },
    TENTACOOL = { { level = 30, species = "TENTACRUEL" } },
    TOTODILE = { { level = 18, species = "CROCONAW" } },
    VENONAT = { { level = 31, species = "VENOMOTH" } },
    VOLTORB = { { level = 30, species = "ELECTRODE" } },
    WARTORTLE = { { level = 36, species = "BLASTOISE" } },
    WEEDLE = { { level = 7, species = "KAKUNA" } },
    WOOPER = { { level = 20, species = "QUAGSIRE" } },
    ZUBAT = { { level = 22, species = "GOLBAT" } },
  }

  local function normalizeSpecies(species)
    return tostring(species or ""):upper():gsub("[^A-Z0-9_]", "_")
  end

  local function preserveSpeciesCase(original, evolved)
    if type(original) == "string" and original == original:lower() then
      return evolved:lower()
    end
    return evolved
  end

  local function evolvedSpeciesAtLevel(startSpecies, startLevel, targetLevel)
    local original = startSpecies
    local species = normalizeSpecies(startSpecies)
    local fromLevel = math.max(1, tonumber(startLevel) or 1)
    local toLevel = math.max(fromLevel, tonumber(targetLevel) or fromLevel)

    for level = fromLevel + 1, toLevel do
      local guard = 0
      while guard < 8 do
        guard = guard + 1
        local nextSpecies = nil
        for _, evo in ipairs(GOLD_EVOLUTIONS[species] or {}) do
          if level >= tonumber(evo.level) then
            nextSpecies = evo.species
            break
          end
        end
        if not nextSpecies or nextSpecies == species then break end
        species = nextSpecies
      end
    end

    return preserveSpeciesCase(original, species)
  end

  local function nativeMovesAtLevel(species, level, fallbackMoves)
    local registry = mod.content and mod.content.pokemon
    local def = nil

    if registry and type(registry.get) == "function" then
      local candidates = {
        species,
        tostring(species or ""):upper(),
        tostring(species or ""):lower(),
      }
      for _, id in ipairs(candidates) do
        local ok, row = pcall(registry.get, registry, id)
        if ok and row then
          def = row
          break
        end
      end
    end

    if def and type(def.level1Moves) == "table"
       and type(def.learnset) == "table" then
      local ok, moves = pcall(Pokemon.movesAtLevel, def, tonumber(level) or 1)
      if ok and type(moves) == "table" and #moves > 0 then
        return moves
      end
    end

    -- Never create a no-move trainer. If lookup fails on this packaged cache,
    -- retain the trainer's original legal moves.
    if type(fallbackMoves) == "table" and #fallbackMoves > 0 then
      local copy = {}
      for _, move in ipairs(fallbackMoves) do copy[#copy + 1] = move end
      return copy
    end

    return nil
  end

  local function buildProgressiveParty(baseParty, step)
    local upgraded = {}

    for i, slot in ipairs(baseParty or {}) do
      local copy = copySlot(slot)
      local originalLevel = tonumber(slot.level) or 1
      local targetLevel = math.min(100, originalLevel + step)
      local finalSpecies = evolvedSpeciesAtLevel(
        slot.species, originalLevel, targetLevel)

      copy.level = targetLevel
      copy.species = finalSpecies

      -- If the species changed through progression, do not keep the trainer
      -- slot's original species-derived display name.  Some imported trainer
      -- records cache that name separately from `species`, which is why an
      -- evolved HYPNO could still be labeled DROWZEE.
      if tostring(finalSpecies) ~= tostring(slot.species) then
        copy.name = nil
        copy.nickname = nil
        copy.nick = nil
        copy.displayName = nil
        copy.speciesName = nil
      end

      -- IMPORTANT: do not carry an old stored stat/HP block forward after the
      -- level/species changes. BattleState treats slot.stats as authoritative.
      -- Clearing these makes Pokemon.new + Stats.calc rebuild the enemy at the
      -- new level/species, and BattleState then starts it at mon.stats.hp.
      copy.stats = nil
      copy.hp = nil
      copy.exp = nil
      copy.status = nil

      -- Build an explicit natural moveset from the supplied Gold source.
      -- Relying on nil here caused this packaged build to create enemies with
      -- no usable moves, so they fell back to STRUGGLE.
      -- Ask the engine for exactly the moves this live Gold species would know
      -- at the upgraded level. BattleState then performs its normal native
      -- slot.moves -> {id, pp} conversion before the battler is constructed.
      copy.moves = nativeMovesAtLevel(finalSpecies, targetLevel, slot.moves)

      upgraded[i] = copy
    end

    return upgraded
  end

  -- BattleState calls this hook before Pokemon.new constructs the enemy team.
  -- It is the safest place to scale a rematch because shared trainer data is
  -- never mutated.
  mod.hooks:wrap("trainer.party", function(next, oppClass, partyIndex, partyDef)
    local baseParty = next(oppClass, partyIndex, partyDef) or partyDef

    if not rematchBattlePending or not progressionEnabled() then
      return baseParty
    end

    local key = tostring(oppClass) .. "#" .. tostring(partyIndex or 1)
    local progress = getProgress()
    local step = math.min(100, (tonumber(progress[key]) or 0) + 1)

    progress[key] = step
    persistProgress(progress)

    pendingProgressKey = key
    pendingProgressStep = step

    local upgraded = buildProgressiveParty(baseParty, step)
    pendingProgressParty = upgraded
    return upgraded
  end)

  -- Gold's native TalkToTrainer script with ONLY these two commands removed:
  --   trainerflagaction CHECK_FLAG
  --   iftrue scripttalkafter
  local REMATCH_SCRIPT = {
    { op = "faceplayer" },
    { op = "loadtemptrainer" },
    { op = "encountermusic" },
    { op = "opentext" },
    { op = "trainertext", index = 0 },
    { op = "waitbutton" },
    { op = "closetext" },
    { op = "loadtemptrainer" },
    { op = "startbattle" },
    { op = "reloadmapafterbattle" },
    { op = "trainerflagaction", action = 1 }, -- SET_FLAG
    { op = "scripttalkafter" },
  }


  -- Gym leaders are script objects rather than trainer objects in Gold.
  -- Match them by gym map and the leader object's original coordinates.
  local GYM_LEADERS = {
    VIOLETGYM       = { x=5, y=1,  class=1,  member=1, name="FALKNER" },
    AZALEAGYM       = { x=5, y=7,  class=3,  member=1, name="BUGSY" },
    GOLDENRODGYM    = { x=8, y=3,  class=2,  member=1, name="WHITNEY" },
    ECRUTEAKGYM     = { x=5, y=1,  class=4,  member=1, name="MORTY" },
    CIANWOODGYM     = { x=4, y=1,  class=7,  member=1, name="CHUCK" },
    OLIVINEGYM      = { x=5, y=3,  class=6,  member=1, name="JASMINE" },
    MAHOGANYGYM     = { x=5, y=3,  class=5,  member=1, name="PRYCE" },
    BLACKTHORNGYM1F = { x=5, y=3,  class=8,  member=1, name="CLAIR" },
    PEWTERGYM       = { x=5, y=1,  class=17, member=1, name="BROCK" },
    CERULEANGYM     = { x=5, y=3,  class=18, member=1, name="MISTY" },
    VERMILIONGYM    = { x=5, y=2,  class=19, member=1, name="LT. SURGE" },
    CELADONGYM      = { x=5, y=3,  class=21, member=1, name="ERIKA" },
    FUCHSIAGYM      = { x=1, y=10, class=26, member=1, name="JANINE" },
    SAFFRONGYM      = { x=9, y=8,  class=35, member=1, name="SABRINA" },
    SEAFOAMGYM      = { x=5, y=2,  class=46, member=1, name="BLAINE" },
    VIRIDIANGYM     = { x=5, y=3,  class=64, member=1, name="BLUE" },
  }

  local function normMapId(id)
    return tostring(id or ""):upper():gsub("[^A-Z0-9]", "")
  end

  local function gymLeaderFor(world, npc)
    if not world or not npc then return nil end
    local mapId = world.map and world.map.id
    local def = npc.def or {}
    local x = npc.cellX or def.x
    local y = npc.cellY or def.y
    local leader = GYM_LEADERS[normMapId(mapId)]
    if leader and tonumber(x) == leader.x and tonumber(y) == leader.y then
      return leader
    end
    return nil
  end

  local function gymRematchScript(leader)
    return {
      { op = "faceplayer" },
      { op = "loadtrainer", class = leader.class, member = leader.member },
      { op = "startbattle" },
      { op = "reloadmapafterbattle" },
      { op = "end" },
    }
  end

  local function show(game, text)
    if game and game.stack and type(game.stack.push) == "function" then
      game.stack:push(TextBox.new(game, text))
    end
  end

  local function facingTarget(game)
    local world = game and game.world
    if not (world and world.player and type(world.npcAtCell) == "function") then
      return nil, nil
    end
    local x, y = world.player:facingCell()
    local npc = world:npcAtCell(x, y)
    if not npc or not npc.def then return nil, nil end
    if type(npc.def.trainer) == "table" then
      return npc, { kind = "trainer" }
    end
    local leader = gymLeaderFor(world, npc)
    if leader then return npc, { kind = "gym", leader = leader } end
    return nil, nil
  end

  local function trainerTarget(world, npc)
    if not npc or not npc.def then return nil end
    local d = npc.def

    -- The native rematch path can expose a normalized `trainer` record.
    if type(d.trainer) == "table" then
      return {
        kind = "trainer",
        npc = npc,
        class = d.trainer.class,
        member = d.trainer.member,
      }
    end

    -- Gold's actual Overworld.talkTo interaction path exposes these flattened
    -- fields instead. This is the shape used by the earlier working Gold
    -- rematch interception code.
    if d.trainerClass ~= nil then
      return {
        kind = "trainer",
        npc = npc,
        class = d.trainerClass,
        member = d.trainerParty or d.trainerMember or 1,
      }
    end

    local leader = gymLeaderFor(world, npc)
    if leader then
      return {
        kind = "gym",
        npc = npc,
        class = leader.class,
        member = leader.member,
        leader = leader,
      }
    end

    return nil
  end

  local function normalTrainerDefeated(world, npc)
    if not world or not npc then return false end

    if type(world.trainerDefeated) == "function" then
      local ok, defeated = pcall(world.trainerDefeated, world, npc)
      if ok then return defeated == true end
    end

    if type(Overworld.trainerDefeated) == "function" then
      local ok, defeated = pcall(Overworld.trainerDefeated, world, npc)
      if ok then return defeated == true end
    end

    -- Last-resort exact save check from the source. This catches packaged
    -- compatibility builds where the helper is not exported on this object.
    local game = liveGame
    local save = game and game.save
    if save and type(save.defeatedTrainers) == "table"
       and npc.id ~= nil and save.defeatedTrainers[npc.id] then
      return true
    end

    return false
  end

  local function gymLeaderDefeated(world, target)
    if not world or not target or target.kind ~= "gym" then return false end

    -- Gym leaders are script objects, so ask the map's normal leader script
    -- state rather than treating them like ordinary trainer objects.
    --
    -- The Gold save keeps badges as the stable post-victory state. Each gym
    -- leader corresponds to exactly one badge; using that is safer than
    -- replaying/checking the map's story script just to decide whether to offer
    -- a rematch.
    local save = liveGame and liveGame.save
    local player = save and save.player
    local johto = player and player.badges or {}
    local kanto = player and player.kantoBadges or {}

    local badgeForClass = {
      [1]  = johto.ZEPHYR,
      [2]  = johto.PLAIN,
      [3]  = johto.HIVE,
      [4]  = johto.FOG,
      [5]  = johto.GLACIER,
      [6]  = johto.MINERAL,
      [7]  = johto.STORM,
      [8]  = johto.RISING,

      [17] = kanto.BOULDER,
      [18] = kanto.CASCADE,
      [19] = kanto.THUNDER,
      [21] = kanto.RAINBOW,
      [26] = kanto.SOUL,
      [35] = kanto.MARSH,
      [46] = kanto.VOLCANO,
      [64] = kanto.EARTH,
    }

    return badgeForClass[tonumber(target.class)] == true
  end

  local function targetDefeated(world, target)
    if not target then return false end
    if target.kind == "trainer" then
      return normalTrainerDefeated(world, target.npc)
    end
    return gymLeaderDefeated(world, target)
  end


  local function startRematch(world, target)
    if not world or not target then return false end

    rematchBattlePending = true

    local ok, result
    if target.kind == "trainer" then
      if type(world.startTrainerScript) ~= "function" then
        rematchBattlePending = false
        return false
      end

      local d = target.npc and target.npc.def
      local originalTrainer = d and d.trainer
      if d and type(d.trainer) ~= "table" then
        d.trainer = {
          class = target.class,
          member = target.member,
        }
      end

      ok, result = pcall(
        world.startTrainerScript,
        world,
        target.npc,
        REMATCH_SCRIPT,
        nil
      )

      if d then d.trainer = originalTrainer end
    else
      if not world.vm or type(world.vm.start) ~= "function" then
        rematchBattlePending = false
        return false
      end

      world.talkNpc = target.npc
      if type(world.freezeNpc) == "function" then
        world:freezeNpc(target.npc)
      end
      world.vm.lastTalked = ((target.npc.def and target.npc.def.index) or 0) + 1

      ok, result = pcall(
        world.vm.start,
        world.vm,
        gymRematchScript(target.leader)
      )
    end

    if not ok or result == false then
      rematchBattlePending = false
      return false
    end

    return true
  end

  local function vanillaPostDefeat(world, npc)
    -- Re-enter the original talk dispatch exactly once. The bypass marker keeps
    -- our wrapper from opening the rematch prompt again, so Gold runs the NPC's
    -- ordinary already-defeated dialogue/script.
    bypassPromptOnce = npc
    if type(previousTalkTo) == "function" then
      return previousTalkTo(world, npc)
    end
    return false
  end

  local function promptRematch(world, target)
    if rematchPromptOpen or not liveGame then return false end
    rematchPromptOpen = true

    local npc = target.npc
    if type(world.freezeNpc) == "function" then
      pcall(world.freezeNpc, world, npc)
    elseif npc then
      npc.frozen = true
    end

    if npc and type(npc.facePlayer) == "function" and world.player then
      pcall(npc.facePlayer, npc, world.player)
    end

    local function finishFreeze()
      if type(world.unfreezeNpc) == "function" then
        pcall(world.unfreezeNpc, world, npc)
      elseif npc then
        npc.frozen = false
      end
    end

    liveGame.stack:push(TextBox.new(
      liveGame,
      "Want a rematch?",
      nil,
      {
        choice = function(yes)
          rematchPromptOpen = false

          if yes then
            -- startRematch/freezing is owned by the native trainer script from
            -- this point forward.
            local started = startRematch(world, target)
            if not started then
              finishFreeze()
              vanillaPostDefeat(world, npc)
            end
          else
            finishFreeze()
            vanillaPostDefeat(world, npc)
          end
        end,
      }
    ))

    return true
  end

  local function install()
    if installed then return true end
    if type(Overworld) ~= "table" then return false end

    previousTalkTo = Overworld.talkTo

    Overworld.talkTo = function(world, npc)
      -- A NO answer deliberately hands the same interaction back to vanilla.
      if bypassPromptOnce == npc then
        bypassPromptOnce = nil
        if type(previousTalkTo) == "function" then
          return previousTalkTo(world, npc)
        end
        return false
      end

      local target = trainerTarget(world, npc)
      if not target or not targetDefeated(world, target) then
        if type(previousTalkTo) == "function" then
          return previousTalkTo(world, npc)
        end
        return false
      end

      return promptRematch(world, target)
    end

    installed = true
    return true
  end

  install()

  -- Retry from a known live hook in case the compatibility facade is populated
  -- after mod entry in this packaged build.
  -- Packaged Gold fallback: some interaction paths can run a script directly
  -- instead of calling the compatibility `Overworld.talkTo`. Intercept the
  -- A-button interaction body before vanilla only when the faced NPC is a
  -- defeated trainer/leader.
  mod.hooks:wrap("world.interact", function(next, world, ...)
    if not world or rematchPromptOpen then
      return next(world, ...)
    end

    local player = world.player
    local npc = nil
    if player and type(player.facingCell) == "function"
       and type(world.npcAtCell) == "function" then
      local x, y = player:facingCell()
      npc = world:npcAtCell(x, y)
    end

    local target = trainerTarget(world, npc)
    if target and targetDefeated(world, target) then
      return promptRematch(world, target)
    end

    return next(world, ...)
  end, 1000)

  mod.hooks:wrap("input.step", function(next, game, dt)
    if game then
      if liveGame ~= game then
        liveGame = game
        settingsLoaded = false
      end
      loadSettings(game)
    end
    install()
    return next(game, dt)
  end, -1000)



  -- Gold's battle engine emits the actual BattleState after the native
  -- `startbattle` command creates it.  The pending flag above identifies
  -- exactly the next trainer battle as our rematch; normal trainer and wild
  -- battles are untouched.
  mod.events:on("battle.started", function(ev)
    if not rematchBattlePending or not ev or ev.kind ~= "trainer"
       or not ev.battle then
      return
    end

    rematchBattlePending = false
    activeRematchBattle = ev.battle
    local battle = ev.battle
    battle._trainerRematch2 = true
    battle._trainerRematch2ProgressKey = pendingProgressKey
    battle._trainerRematch2ProgressStep = pendingProgressStep

    pendingProgressKey = nil
    pendingProgressStep = nil
    pendingProgressParty = nil

    -- Trainer prize money is calculated at victory from
    -- `battle.trainer.baseMoney * lastEnemyLevel` (x4 for Gen 2).
    -- Use a tiny per-battle proxy so the shared trainer data is never changed.
    local pct = optionPct("money", 100)
    local realTrainer = battle.trainer
    if type(realTrainer) == "table"
       and type(realTrainer.baseMoney) == "number"
       and pct ~= 100 then
      battle._trainerRematch2OriginalTrainer = realTrainer
      battle.trainer = setmetatable({
        baseMoney = math.floor(realTrainer.baseMoney * pct / 100),
      }, { __index = realTrainer })
    end
  end)

  mod.events:on("battle.ended", function(ev)
    if ev and ev.battle and ev.battle == activeRematchBattle then
      activeRematchBattle = nil
    end
  end)

  -- Experience.lua exposes the final normal EXP calculation as `exp.gain`.
  -- Scale that returned amount only while the tagged rematch battle is active.
  -- Stat EXP is left alone; this slider controls ordinary experience points.
  mod.hooks:wrap("exp.gain", function(next, ctx)
    local gained = next(ctx)
    if not activeRematchBattle or not activeRematchBattle._trainerRematch2 then
      return gained
    end

    local pct = optionPct("xp", 100)
    if pct == 100 then return gained end
    return math.floor((tonumber(gained) or 0) * pct / 100)
  end)

  mod.hooks:wrap("ui.start_menu.items", function(next, game, items)
    liveGame = game or liveGame
    loadSettings(game)

    local outItems = next(game, items)
    if type(outItems) ~= "table" then return outItems end

    local clean = {}
    for _, item in ipairs(outItems) do
      local label = type(item) == "table" and item.label or nil
      if label ~= "REMATCH TRAINER" and label ~= "REMATCH SETTINGS" then
        clean[#clean + 1] = item
      end
    end

    local settingsRow = {
      label = "REMATCH SETTINGS",
      keepOpen = true,
      onSelect = function(g)
        openRematchSettings(g or game)
      end,
    }

    local final, inserted = {}, false
    for _, item in ipairs(clean) do
      if not inserted and type(item) == "table" and item.label == "MODS" then
        final[#final + 1] = settingsRow
        inserted = true
      end
      final[#final + 1] = item
    end

    if not inserted then
      final[#final + 1] = settingsRow
    end

    return final
  end, 1000)


  mod.exports.isInstalled = function()
    return installed
  end
end
