-- Gen 2 Randomizer+ — Gold v2.00
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
  local Stats = require("src.pokemon.Stats")
  local ListMenu = require("src.ui.ListMenu")
  local Gen2Mon = require("src.battle.gen2.Mon")

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
  local DEFAULT_RANDOM_FIRST_POKEMON = false
  local DEFAULT_RANDOM_FIRST_STATS_MOVES = false
  local DEFAULT_RANDOM_POKEMON = false
  local DEFAULT_RANDOM_STATS_MOVES = false
  local DEFAULT_RANDOM_WILD_POKEMON = false
  local DEFAULT_RANDOM_WILD_STATS_MOVES = false
  local DEFAULT_RANDOM_TYPES = false
  local DEFAULT_RANDOM_STARTERS = false
  local DEFAULT_RANDOM_MOVE_LEARNSET = false
  local DEFAULT_RANDOM_WORLD_ITEMS = false
  local DEFAULT_RANDOM_TMS = false
  local DEFAULT_RANDOM_STARTER_MOVES = false

  local liveGame = nil
  local pendingLearnsetPartyProbe = false
  local pendingLearnsetSafeInit = false
  local syncWildEncounterOverlay = nil
  local syncRandomTypes = nil
  local syncOwnedRandomLearnsets = nil
  local reconcileRandomLearnsets = nil
  local syncRandomWorldItems = nil
  local syncRandomTMs = nil
  local settingsLoaded = false
  local settings = {
    moneyPct = DEFAULT_MONEY,
    xpPct = DEFAULT_XP,
    progressive = DEFAULT_PROGRESSIVE,
    randomFirstPokemon = DEFAULT_RANDOM_FIRST_POKEMON,
    randomFirstStatsMoves = DEFAULT_RANDOM_FIRST_STATS_MOVES,
    randomPokemon = DEFAULT_RANDOM_POKEMON,
    randomStatsMoves = DEFAULT_RANDOM_STATS_MOVES,
    randomWildPokemon = DEFAULT_RANDOM_WILD_POKEMON,
    randomWildStatsMoves = DEFAULT_RANDOM_WILD_STATS_MOVES,
    randomTypes = DEFAULT_RANDOM_TYPES,
    randomStarters = DEFAULT_RANDOM_STARTERS,
    randomMoveLearnset = DEFAULT_RANDOM_MOVE_LEARNSET,
    randomWorldItems = DEFAULT_RANDOM_WORLD_ITEMS,
    randomTMs = DEFAULT_RANDOM_TMS,
    randomStarterMoves = DEFAULT_RANDOM_STARTER_MOVES,
    randomTypeMap = {},
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

  local function copyTypeMap(src)
    local out = {}
    if type(src) == "table" then
      for species, types in pairs(src) do
        if type(types) == "table" and type(types[1]) == "string" then
          out[tostring(species)] = { types[1], types[2] }
          if out[tostring(species)][2] == nil then
            out[tostring(species)][2] = nil
          end
        end
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
    bucket.randomFirstPokemon = settings.randomFirstPokemon
    bucket.randomFirstStatsMoves = settings.randomFirstStatsMoves
    bucket.randomPokemon = settings.randomPokemon
    bucket.randomStatsMoves = settings.randomStatsMoves
    bucket.randomWildPokemon = settings.randomWildPokemon
    bucket.randomWildStatsMoves = settings.randomWildStatsMoves
    bucket.randomTypes = settings.randomTypes
    bucket.randomStarters = settings.randomStarters
    bucket.randomMoveLearnset = settings.randomMoveLearnset
    bucket.randomWorldItems = settings.randomWorldItems
    bucket.randomTMs = settings.randomTMs
    bucket.randomStarterMoves = settings.randomStarterMoves
    bucket.randomTypeMap = copyTypeMap(settings.randomTypeMap)
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
      persisted.randomFirstPokemon = settings.randomFirstPokemon
      persisted.randomFirstStatsMoves = settings.randomFirstStatsMoves
      persisted.randomPokemon = settings.randomPokemon
      persisted.randomStatsMoves = settings.randomStatsMoves
      persisted.randomWildPokemon = settings.randomWildPokemon
      persisted.randomWildStatsMoves = settings.randomWildStatsMoves
      persisted.randomTypes = settings.randomTypes
      persisted.randomStarters = settings.randomStarters
      persisted.randomMoveLearnset = settings.randomMoveLearnset
      persisted.randomWorldItems = settings.randomWorldItems
      persisted.randomTMs = settings.randomTMs
      persisted.randomStarterMoves = settings.randomStarterMoves
      persisted.randomTypeMap = copyTypeMap(settings.randomTypeMap)
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

    if type(bucket.randomPokemon) == "boolean" then
      settings.randomPokemon = bucket.randomPokemon
    else
      settings.randomPokemon = DEFAULT_RANDOM_POKEMON
    end

    if type(bucket.randomStatsMoves) == "boolean" then
      settings.randomStatsMoves = bucket.randomStatsMoves
    else
      settings.randomStatsMoves = DEFAULT_RANDOM_STATS_MOVES
    end

    if type(bucket.randomWildPokemon) == "boolean" then
      settings.randomWildPokemon = bucket.randomWildPokemon
    else
      settings.randomWildPokemon = DEFAULT_RANDOM_WILD_POKEMON
    end

    if type(bucket.randomWildStatsMoves) == "boolean" then
      settings.randomWildStatsMoves = bucket.randomWildStatsMoves
    else
      settings.randomWildStatsMoves = DEFAULT_RANDOM_WILD_STATS_MOVES
    end

    if type(bucket.randomTypes) == "boolean" then
      settings.randomTypes = bucket.randomTypes
    else
      settings.randomTypes = DEFAULT_RANDOM_TYPES
    end

    if type(bucket.randomStarters) == "boolean" then
      settings.randomStarters = bucket.randomStarters
    else
      settings.randomStarters = DEFAULT_RANDOM_STARTERS
    end
    if type(bucket.randomMoveLearnset) == "boolean" then
      settings.randomMoveLearnset = bucket.randomMoveLearnset
    else
      settings.randomMoveLearnset = DEFAULT_RANDOM_MOVE_LEARNSET
    end
    if type(bucket.randomWorldItems) == "boolean" then
      settings.randomWorldItems = bucket.randomWorldItems
    else
      settings.randomWorldItems = DEFAULT_RANDOM_WORLD_ITEMS
    end
    if type(bucket.randomTMs) == "boolean" then
      settings.randomTMs = bucket.randomTMs
    else
      settings.randomTMs = DEFAULT_RANDOM_TMS
    end
    if type(bucket.randomStarterMoves) == "boolean" then
      settings.randomStarterMoves = bucket.randomStarterMoves
    else
      settings.randomStarterMoves = DEFAULT_RANDOM_STARTER_MOVES
    end
    settings.randomTypeMap = copyTypeMap(bucket.randomTypeMap)

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
       or bucket.randomFirstPokemon == nil
       or bucket.randomFirstStatsMoves == nil
       or bucket.randomPokemon == nil
       or bucket.randomStatsMoves == nil
       or bucket.randomWildPokemon == nil
       or bucket.randomWildStatsMoves == nil
       or bucket.randomTypes == nil
       or bucket.randomStarters == nil
       or bucket.randomMoveLearnset == nil
       or bucket.randomWorldItems == nil
       or bucket.randomTMs == nil
       or bucket.randomStarterMoves == nil
       or bucket.randomTypeMap == nil
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

  -- Random Learnset diagnostic probe (v2.0.13)
  -- Purposefully tiny: prove that the Randomizer+ settings screen can reach
  -- and mutate the exact owned Gen 2 Mon in game.save.party.

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
    elseif key == "randomFirstPokemon" then
      settings.randomFirstPokemon = value == true
    elseif key == "randomFirstStatsMoves" then
      settings.randomFirstStatsMoves = value == true
    elseif key == "randomPokemon" then
      settings.randomPokemon = value == true
    elseif key == "randomStatsMoves" then
      settings.randomStatsMoves = value == true
    elseif key == "randomWildPokemon" then
      settings.randomWildPokemon = value == true
    elseif key == "randomWildStatsMoves" then
      settings.randomWildStatsMoves = value == true
      if syncWildEncounterOverlay then syncWildEncounterOverlay(game) end
    elseif key == "randomTypes" then
      settings.randomTypes = value == true
      if syncRandomTypes then syncRandomTypes(game, true) end
    elseif key == "randomStarters" then
      settings.randomStarters = value == true
    elseif key == "randomMoveLearnset" then
      settings.randomMoveLearnset = value == true
      pendingLearnsetPartyProbe = settings.randomMoveLearnset == true
    elseif key == "randomWorldItems" then
      settings.randomWorldItems = value == true
      if syncRandomWorldItems then syncRandomWorldItems(game) end
    elseif key == "randomTMs" then
      settings.randomTMs = value == true
      if syncRandomTMs then syncRandomTMs(game, true) end
    elseif key == "randomStarterMoves" then
      settings.randomStarterMoves = value == true
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

  -- -----------------------------------------------------------------------
  -- Randomizer+ high-resolution neon settings dashboard
  -- -----------------------------------------------------------------------
  -- Draw directly in window space after resetting Recomp's game transform.
  -- Unlike the old 160x144 dashboard, fonts are created at actual screen
  -- pixel sizes, which keeps text sharp at desktop resolutions.
  local function openRematchSettings(game)
    loadSettings(game)

    local categories = {
      {
        name = "TRAINER BATTLES",
        short = "TRAINER",
        rows = {
          { key="randomFirstPokemon",    label="FIRST BATTLE POKEMON",          kind="toggle" },
          { key="randomFirstStatsMoves", label="FIRST BATTLE STATS / MOVES",    kind="toggle" },
          { key="randomPokemon",         label="REMATCH RANDOM POKEMON",         kind="toggle" },
          { key="randomStatsMoves",      label="REMATCH RANDOM STATS / MOVES",   kind="toggle" },
          { key="progressive",           label="PROGRESSIVE LEVELS (REMATCHES)", kind="toggle" },
          { key="moneyPct",              label="TRAINER MONEY (REMATCHES)",       kind="percent" },
          { key="xpPct",                 label="EXP REWARDS (REMATCHES)",         kind="percent" },
        },
      },
      {
        name = "WILD POKEMON",
        short = "WILD",
        rows = {
          { key="randomWildPokemon",    label="RANDOMIZE WILD POKEMON",       kind="toggle" },
          { key="randomWildStatsMoves", label="RANDOMIZE WILD STATS / MOVES", kind="toggle" },
        },
      },
      {
        name = "STARTER POKEMON",
        short = "STARTER",
        rows = {
          { key="randomStarters",     label="RANDOMIZE STARTER POKEMON", kind="toggle" },
          { key="randomStarterMoves", label="RANDOMIZE STARTING MOVES",  kind="toggle" },
        },
      },
      {
        name = "POKEMON TRAITS",
        short = "TRAITS",
        rows = {
          { key="randomTypes",        label="RANDOMIZE POKEMON TYPES", kind="toggle" },
          { key="randomMoveLearnset", label="RANDOMIZE LEARNSETS",     kind="toggle" },
        },
      },
      {
        name = "ITEMS & TMS",
        short = "ITEMS & TMS",
        rows = {
          { key="randomWorldItems", label="RANDOMIZE WORLD ITEMS", kind="toggle" },
          { key="randomTMs",        label="RANDOMIZED TMS",        kind="toggle" },
        },
      },
    }

    local state = {
      game = game,
      isOpaque = true,
      category = 1,
      index = 1,
      fontCache = {},
      __g2RandomizerSettings = true,
    }

    local function getValue(row)
      if row.key == "moneyPct" then return tostring(settings.moneyPct) .. "%" end
      if row.key == "xpPct" then return tostring(settings.xpPct) .. "%" end
      return settings[row.key] and "ON" or "OFF"
    end

    local function changeCurrent(self)
      local row = categories[self.category].rows[self.index]
      if not row then return end

      if row.kind == "percent" then
        if row.key == "moneyPct" then
          setSetting(self.game, row.key, nextPct(settings.moneyPct))
        else
          setSetting(self.game, row.key, nextPct(settings.xpPct))
        end
      else
        setSetting(self.game, row.key, not settings[row.key])
      end
    end

    local function close(self)
      if pendingLearnsetPartyProbe and settings.randomMoveLearnset then
        pendingLearnsetPartyProbe = false
        pendingLearnsetSafeInit = true
      end
      self.game.stack:pop()
    end

    local function switchCategory(self, delta)
      self.category = ((self.category - 1 + delta) % #categories) + 1
      self.index = 1
    end

    function state:update()
      local input = self.game and self.game.input
      if not input then return end
      local rows = categories[self.category].rows

      if input:wasPressed("left") then
        switchCategory(self, -1)
      elseif input:wasPressed("right") then
        switchCategory(self, 1)
      elseif input:wasPressed("up") then
        self.index = self.index > 1 and self.index - 1 or #rows
      elseif input:wasPressed("down") then
        self.index = self.index < #rows and self.index + 1 or 1
      elseif input:wasPressed("a") then
        changeCurrent(self)
      elseif input:wasPressed("b") or input:wasPressed("start") then
        close(self)
      end
    end

    local function font(self, px, bold)
      px = math.max(10, math.floor(px + 0.5))
      local key = tostring(px) .. (bold and "b" or "")
      if self.fontCache[key] then return self.fontCache[key] end

      -- Use the engine/default font at native screen resolution.  LÖVE's
      -- generated font texture is sampled 1:1 here, not magnified.
      local ok, f = pcall(love.graphics.newFont, px)
      if ok and f then
        pcall(function() f:setFilter("nearest", "nearest", 1) end)
        self.fontCache[key] = f
        return f
      end
      return love.graphics.getFont()
    end

    local function setFont(self, px)
      love.graphics.setFont(font(self, px))
    end

    local function rect(mode, x, y, w, h, radius)
      love.graphics.rectangle(mode,
        math.floor(x + 0.5), math.floor(y + 0.5),
        math.floor(w + 0.5), math.floor(h + 0.5),
        radius or 0, radius or 0)
    end

    local function printText(self, str, x, y, px, color)
      setFont(self, px)
      love.graphics.setColor(color[1], color[2], color[3], color[4] or 1)
      love.graphics.print(tostring(str), math.floor(x + 0.5), math.floor(y + 0.5))
    end

    local function centerText(self, str, x, y, w, px, color)
      setFont(self, px)
      love.graphics.setColor(color[1], color[2], color[3], color[4] or 1)
      love.graphics.printf(tostring(str),
        math.floor(x + 0.5), math.floor(y + 0.5),
        math.floor(w + 0.5), "center")
    end

    local BLACK      = {0.010, 0.012, 0.010, 1}
    local PANEL      = {0.025, 0.032, 0.025, 1}
    local PANEL2     = {0.045, 0.060, 0.043, 1}
    local GREEN      = {0.34, 1.00, 0.02, 1}
    local GREEN_DIM  = {0.16, 0.55, 0.04, 1}
    local GREEN_DARK = {0.08, 0.20, 0.04, 1}
    local WHITE      = {0.95, 0.97, 0.94, 1}
    local MUTED      = {0.55, 0.61, 0.54, 1}

    function state:draw()
      local lg = love.graphics
      local w, h = lg.getDimensions()

      -- Reset Recomp's native game transform and render in true window pixels.
      lg.push("all")
      lg.origin()
      lg.setLineStyle("rough")

      lg.clear(BLACK)

      local margin = math.max(18, math.floor(math.min(w, h) * 0.025))
      local headerH = math.floor(h * 0.115)
      local tabsH = math.floor(h * 0.135)
      local footerH = math.floor(h * 0.105)
      local contentTop = margin + headerH + 8 + tabsH + 8
      local contentBottom = h - margin - footerH - 8
      local contentH = contentBottom - contentTop

      -- Outer neon frame.
      lg.setColor(GREEN_DIM)
      lg.setLineWidth(math.max(2, math.floor(h * 0.003)))
      rect("line", margin, margin, w - margin * 2, h - margin * 2, 10)

      -- Header
      lg.setColor(PANEL)
      rect("fill", margin + 5, margin + 5, w - margin * 2 - 10, headerH - 5, 8)
      lg.setColor(GREEN_DIM)
      rect("line", margin + 5, margin + 5, w - margin * 2 - 10, headerH - 5, 8)

      local titlePx = math.max(24, math.floor(headerH * 0.42))
      local plusPx = math.max(24, math.floor(headerH * 0.48))
      printText(self, "RANDOMIZER", margin + 28, margin + 14, titlePx, WHITE)

      setFont(self, titlePx)
      local titleW = lg.getFont():getWidth("RANDOMIZER")
      printText(self, "+", margin + 34 + titleW, margin + 8, plusPx, GREEN)

      local settingsPx = math.max(14, math.floor(headerH * 0.20))
      printText(self, "SETTINGS", margin + 40 + titleW + plusPx, margin + headerH * 0.48, settingsPx, MUTED)

      -- Small accent slashes like the visual reference.
      lg.setColor(GREEN)
      local slashY = margin + headerH * 0.55
      for i = 0, 3 do
        local sx = margin + 8 + i * 16
        lg.setLineWidth(4)
        lg.line(sx, slashY + 8, sx + 10, slashY - 2)
      end

      -- Category tabs.
      local tabY = margin + headerH + 8
      local innerW = w - margin * 2 - 10
      local tabGap = 4
      local tabW = (innerW - tabGap * (#categories - 1)) / #categories
      local tabX0 = margin + 5

      for i, cat in ipairs(categories) do
        local x = tabX0 + (i - 1) * (tabW + tabGap)
        local active = i == self.category
        lg.setColor(active and GREEN_DARK or PANEL)
        rect("fill", x, tabY, tabW, tabsH, 5)
        lg.setColor(active and GREEN or GREEN_DIM)
        rect("line", x, tabY, tabW, tabsH, 5)

        local catPx = math.max(12, math.floor(tabsH * 0.19))
        local textColor = active and GREEN or WHITE
        centerText(self, cat.short, x + 4, tabY + tabsH * 0.50, tabW - 8, catPx, textColor)

        -- Minimal icon glyphs above labels; no raster scaling.
        local iconPx = math.max(18, math.floor(tabsH * 0.28))
        local icon = ({ "◆", "✦", "●", "★", "■" })[i]
        centerText(self, icon, x, tabY + tabsH * 0.10, tabW, iconPx, active and GREEN or GREEN_DIM)
      end

      -- Main panel.
      lg.setColor(PANEL)
      rect("fill", margin + 5, contentTop, w - margin * 2 - 10, contentH, 8)
      lg.setColor(GREEN_DIM)
      rect("line", margin + 5, contentTop, w - margin * 2 - 10, contentH, 8)

      local cat = categories[self.category]
      local headingPx = math.max(18, math.floor(contentH * 0.07))
      centerText(self, cat.name .. " OPTIONS",
        margin + 20, contentTop + 12, w - margin * 2 - 40,
        headingPx, GREEN)

      local rows = cat.rows
      local rowsTop = contentTop + headingPx + 30
      local rowGap = math.max(6, math.floor(contentH * 0.018))
      local available = contentBottom - rowsTop - 12
      local rowH = math.min(
        math.floor((available - rowGap * (#rows - 1)) / #rows),
        math.floor(h * 0.085)
      )
      rowH = math.max(42, rowH)

      for i, row in ipairs(rows) do
        local y = rowsTop + (i - 1) * (rowH + rowGap)
        local selected = i == self.index

        lg.setColor(selected and PANEL2 or BLACK)
        rect("fill", margin + 26, y, w - margin * 2 - 52, rowH, 4)

        lg.setColor(selected and GREEN or GREEN_DARK)
        rect("line", margin + 26, y, w - margin * 2 - 52, rowH, 4)

        if selected then
          lg.setColor(GREEN)
          rect("fill", margin + 26, y, 5, rowH, 2)
        end

        local labelPx = math.max(15, math.floor(rowH * 0.33))
        printText(self, row.label, margin + 48, y + (rowH - labelPx) * 0.42, labelPx, WHITE)

        -- Dot leader separation gives the settings-list look while keeping the
        -- actual value in a dedicated badge.
        lg.setColor(selected and GREEN_DIM or {0.18,0.20,0.18,1})
        lg.setLineWidth(2)
        local dotStart = w * 0.58
        local dotEnd = w - margin - 150
        if dotEnd > dotStart then
          local yy = y + rowH * 0.52
          for dx = dotStart, dotEnd, 10 do
            lg.points(math.floor(dx), math.floor(yy))
          end
        end

        local badgeW = math.max(94, math.floor(w * 0.105))
        local badgeH = math.floor(rowH * 0.70)
        local badgeX = w - margin - badgeW - 34
        local badgeY = y + (rowH - badgeH) / 2
        lg.setColor(GREEN_DARK)
        rect("fill", badgeX, badgeY, badgeW, badgeH, 4)
        lg.setColor(GREEN)
        rect("line", badgeX, badgeY, badgeW, badgeH, 4)

        local value = getValue(row)
        local valuePx = math.max(15, math.floor(badgeH * 0.44))
        centerText(self, value, badgeX, badgeY + (badgeH - valuePx) * 0.32, badgeW, valuePx, GREEN)
      end

      -- Footer: deliberately no Y/reset-category action.
      local fy = h - margin - footerH + 3
      lg.setColor(PANEL)
      rect("fill", margin + 5, fy, w - margin * 2 - 10, footerH - 8, 7)
      lg.setColor(GREEN_DIM)
      rect("line", margin + 5, fy, w - margin * 2 - 10, footerH - 8, 7)

      local footPx = math.max(13, math.floor(footerH * 0.23))
      local baseY = fy + (footerH - footPx) * 0.32

      printText(self, "D-PAD", margin + 35, baseY, footPx, GREEN)
      printText(self, "NAVIGATE", margin + 105, baseY, footPx, WHITE)

      local aX = w * 0.39
      printText(self, "A", aX, baseY, footPx, GREEN)
      printText(self, "TOGGLE / SELECT", aX + 34, baseY, footPx, WHITE)

      local bX = w * 0.73
      printText(self, "B", bX, baseY, footPx, GREEN)
      printText(self, "BACK", bX + 34, baseY, footPx, WHITE)

      lg.setColor(1,1,1,1)
      lg.pop()
    end

    function state:drawsWidescreen() return false end
    function state:wantsFillScale() return false end
    function state:drawWidescreen() return end

    game.stack:push(state)
  end


  -- -----------------------------------------------------------------------
  -- Random World + Hidden Items (Gold) -- v2.1.0 test
  -- -----------------------------------------------------------------------
  -- Gold exposes visible item-ball pairs as `itemball = { item, quantity }`
  -- and hidden BGEVENT_ITEM pairs as `hiddenItem = { item, event }`.
  -- Only those map records are changed; NPC gifts and scripted giveitem rewards
  -- remain untouched.
  local WORLD_ITEM_SAVE_KEY = "random_world_item_assignments_v1"
  local worldItemAssignments = mod.save:get(WORLD_ITEM_SAVE_KEY, {})
  if type(worldItemAssignments) ~= "table" then worldItemAssignments = {} end
  local worldItemOriginals = setmetatable({}, { __mode = "k" })

  local function worldItemDef(data, id)
    local items = data and data.items
    if type(items) ~= "table" or id == nil then return nil end
    local direct = items[id]
    if type(direct) == "table" then return direct end
    for key, def in pairs(items) do
      if type(def) == "table"
         and (def.id == id or def.index == id or tostring(key) == tostring(id)) then
        return def
      end
    end
    return nil
  end

  local function isWorldKeyItem(data, id)
    local def = worldItemDef(data, id)
    return type(def) == "table" and def.pocket == "KEY_ITEM"
  end

  -- Gold HMs occupy raw item indexes 0xF3..0xF9 (HM01..HM07).
  -- They share the TM_HM pocket with ordinary TMs, so pocket alone cannot
  -- distinguish them. Protect the numeric HM range explicitly.
  local function isWorldHM(data, id)
    local index = nil
    local def = worldItemDef(data, id)
    if type(def) == "table" then index = tonumber(def.index) end
    if not index then index = tonumber(id) end
    return index ~= nil and index >= 0xF3 and index <= 0xF9
  end

  -- Unused Gen 2 item slots display as TERU-SAMA. These placeholder
  -- cartridge entries are not real obtainable items, so never randomize them.
  local WORLD_PLACEHOLDER_ITEMS = {
    [0x19]=true, [0x2D]=true, [0x32]=true, [0x46]=true, [0x5A]=true,
    [0x64]=true, [0x73]=true, [0x74]=true, [0x78]=true, [0x81]=true,
    [0x87]=true, [0x88]=true, [0x89]=true, [0x8D]=true, [0x8E]=true,
    [0x91]=true, [0x93]=true, [0x94]=true, [0x95]=true, [0x99]=true,
    [0x9A]=true, [0x9B]=true, [0xA2]=true, [0xAB]=true, [0xB0]=true,
    [0xB3]=true, [0xBE]=true, [0xC3]=true, [0xDC]=true, [0xFA]=true,
  }

  local function isWorldPlaceholderItem(data, id)
    local index = nil
    local def = worldItemDef(data, id)
    if type(def) == "table" then index = tonumber(def.index) end
    if not index then index = tonumber(id) end
    return index ~= nil and WORLD_PLACEHOLDER_ITEMS[index] == true
  end

  local function isWorldProtectedItem(data, id)
    return isWorldKeyItem(data, id)
        or isWorldHM(data, id)
        or isWorldPlaceholderItem(data, id)
  end

  -- Map item-ball and hidden-item records store the cartridge's raw one-byte
  -- item INDEX, not the string id used as the key in game.data.items.  Keep
  -- every replacement in that numeric representation so the Gen 2 VM can
  -- resolve the proper item id/name when the pickup is collected.
  local function worldItemIndex(data, value)
    local def = worldItemDef(data, value)
    if type(def) ~= "table" then return nil end
    local index = tonumber(def.index)
    if index and index >= 1 and index <= 0xff then return index end
    return nil
  end

  local function worldItemPool(data)
    local pool = {}
    local items = data and data.items
    if type(items) ~= "table" then return pool end
    for _, def in pairs(items) do
      if type(def) == "table" then
        local pocket = def.pocket
        if pocket == "ITEM" or pocket == "BALL" or pocket == "TM_HM" then
          local index = tonumber(def.index)
          if index and index >= 1 and index <= 0xff
             and not isWorldProtectedItem(data, index) then
            pool[#pool + 1] = index
          end
        end
      end
    end
    return pool
  end

  local function worldItemRandom(n)
    if n <= 1 then return 1 end
    if love and love.math and type(love.math.random) == "function" then
      return love.math.random(1, n)
    end
    return math.random(1, n)
  end

  local function replacementForWorldLocation(key, original, data)
    local saved = worldItemAssignments[key]
    if saved ~= nil then
      -- v2.1.0 test #1 could persist string ids (for example PROTEIN).
      -- Convert those old assignments to the raw numeric item index on read.
      local savedIndex = worldItemIndex(data, saved)
      if savedIndex and not isWorldProtectedItem(data, savedIndex) then
        if saved ~= savedIndex then
          worldItemAssignments[key] = savedIndex
          mod.save:set(WORLD_ITEM_SAVE_KEY, worldItemAssignments)
        end
        return savedIndex
      end
    end
    local pool = worldItemPool(data)
    if #pool == 0 then return original end
    local chosen = pool[worldItemRandom(#pool)]
    worldItemAssignments[key] = chosen
    mod.save:set(WORLD_ITEM_SAVE_KEY, worldItemAssignments)
    return chosen
  end

  local function restoreRandomWorldItems()
    for record, original in pairs(worldItemOriginals) do
      if type(record) == "table" then record.item = original end
    end
    worldItemOriginals = setmetatable({}, { __mode = "k" })
  end

  local function patchWorldRecord(record, locationKey, data)
    if type(record) ~= "table" or record.item == nil then return false end
    local original = worldItemOriginals[record] or record.item

    -- Story/key pickups and all seven HMs stay exactly vanilla.
    if isWorldProtectedItem(data, original) then return false end

    if worldItemOriginals[record] == nil then
      worldItemOriginals[record] = original
    end
    record.item = replacementForWorldLocation(locationKey, original, data)
    return true
  end

  local function patchMapWorldItems(game)
    if not settings.randomWorldItems then
      restoreRandomWorldItems()
      return false
    end
    local world = game and game.world
    local map = world and world.map
    local def = map and map.def
    local data = game and game.data
    if type(def) ~= "table" or type(data) ~= "table" then return false end

    local mapId = tostring(map.id or def.id or "UNKNOWN")
    local seen = {}

    local function walk(t, path, depth)
      if type(t) ~= "table" or seen[t] or depth > 7 then return end
      seen[t] = true

      if type(t.itemball) == "table" and t.itemball.item ~= nil then
        local rec = t.itemball
        local original = worldItemOriginals[rec] or rec.item
        local key = table.concat({
          mapId, "BALL", tostring(t.x or "?"), tostring(t.y or "?"),
          tostring(t.event or t.flag or t.id or path), tostring(original)
        }, ":")
        patchWorldRecord(rec, key, data)
      end

      if type(t.hiddenItem) == "table" and t.hiddenItem.item ~= nil then
        local rec = t.hiddenItem
        local original = worldItemOriginals[rec] or rec.item
        local key = table.concat({
          mapId, "HIDDEN", tostring(t.x or "?"), tostring(t.y or "?"),
          tostring(rec.event or t.event or path), tostring(original)
        }, ":")
        patchWorldRecord(rec, key, data)
      end

      for k, v in pairs(t) do
        if type(v) == "table" and k ~= "itemball" and k ~= "hiddenItem" then
          walk(v, path .. "/" .. tostring(k), depth + 1)
        end
      end
    end

    walk(def, "map", 0)
    return true
  end

  syncRandomWorldItems = function(game)
    if settings.randomWorldItems then
      return patchMapWorldItems(game)
    end
    restoreRandomWorldItems()
    return true
  end

  -- -----------------------------------------------------------------------
  -- Randomized TMs (Gold) -- v2.1.0 test
  -- -----------------------------------------------------------------------
  -- TM01..TM50 are randomized once per playthrough except TM02 (HEADBUTT)
  -- and TM08 (ROCK_SMASH), which remain vanilla for overworld progression.
  -- HM01..HM07 are never changed. HM moves, HEADBUTT, and ROCK_SMASH are
  -- excluded from the random pool so no other TM can duplicate them.
  -- Gen 2 stores species compatibility by TM/HM NUMBER.  Recomp exposes the
  -- decoded move ids instead, so preserve the original compatible slots and
  -- project the newly assigned move for each compatible TM number.
  local RANDOM_TM_SAVE_KEY = "random_tm_moves_v1"
  local randomTMAssignments = mod.save:get(RANDOM_TM_SAVE_KEY, {})
  if type(randomTMAssignments) ~= "table" then randomTMAssignments = {} end
  local tmBaselines = setmetatable({}, { __mode = "k" })
  local tmAppliedSignature = setmetatable({}, { __mode = "k" })

  local function tmRandom(a, b)
    if love and love.math and type(love.math.random) == "function" then
      return love.math.random(a, b)
    end
    return math.random(a, b)
  end

  local function ensureTMBaseline(game)
    local data = game and game.data
    if not (data and type(data.items) == "table" and type(data.pokemon) == "table") then
      return nil
    end
    local baseline = tmBaselines[data]
    if baseline then return baseline end

    baseline = { slots = {}, pokemon = {} }
    for itemId, def in pairs(data.items) do
      if type(def) == "table" and tonumber(def.tmNumber) then
        local n = tonumber(def.tmNumber)
        if n >= 1 and n <= 57 and def.teaches then
          baseline.slots[n] = { itemId = itemId, move = def.teaches }
        end
      end
    end
    for species, def in pairs(data.pokemon) do
      if type(species) == "string" and type(def) == "table" then
        local compat = {}
        for _, move in ipairs(def.tmhm or {}) do compat[#compat + 1] = move end
        baseline.pokemon[species] = compat
      end
    end
    tmBaselines[data] = baseline
    return baseline
  end

  local PROTECTED_TM_SLOTS = { [2] = true, [8] = true }

  local function protectedTMMoves(baseline)
    local protected = {}
    -- Story/field-critical TMs must remain vanilla:
    -- TM02 = HEADBUTT and TM08 = ROCK_SMASH.
    for n in pairs(PROTECTED_TM_SLOTS) do
      local slot = baseline.slots[n]
      if slot and slot.move then protected[slot.move] = true end
    end
    return protected
  end

  local function randomTMPool(data, baseline)
    local pool, seen, blockedMoves = {}, {}, protectedTMMoves(baseline)
    for n = 51, 57 do
      local slot = baseline.slots[n]
      if slot and slot.move then blockedMoves[slot.move] = true end
    end
    for moveId, def in pairs(data.moves or {}) do
      local id = type(moveId) == "string" and moveId
        or (type(def) == "table" and def.id) or nil
      if id and type(def) == "table" and not blockedMoves[id] and not seen[id] then
        -- Only actual extracted moves. Metadata/scalars in the table have no
        -- usable move definition/name and are therefore ignored.
        if def.name ~= nil or def.power ~= nil or def.type ~= nil or def.index ~= nil then
          seen[id] = true
          pool[#pool + 1] = id
        end
      end
    end
    return pool
  end

  local function assignmentsValid(data, baseline)
    if type(randomTMAssignments) ~= "table" then return false end
    local pool = randomTMPool(data, baseline)
    local allowed = {}
    for _, id in ipairs(pool) do allowed[id] = true end
    local seen = {}
    for n = 1, 50 do
      local id = randomTMAssignments[n] or randomTMAssignments[tostring(n)]
      local slot = baseline.slots[n]
      if PROTECTED_TM_SLOTS[n] then
        if not slot or id ~= slot.move then return false end
      else
        if not id or not allowed[id] or seen[id] then return false end
        seen[id] = true
      end
    end
    return true
  end

  local function generateRandomTMs(data, baseline)
    local pool = randomTMPool(data, baseline)
    local randomizedCount = 48
    if #pool < randomizedCount then return false end

    -- Select without replacement for the 48 randomized slots. TM02 and TM08
    -- are copied directly from the vanilla baseline.
    for i = 1, randomizedCount do
      local j = tmRandom(i, #pool)
      pool[i], pool[j] = pool[j], pool[i]
    end

    randomTMAssignments = {}
    local poolIndex = 1
    for n = 1, 50 do
      local slot = baseline.slots[n]
      if PROTECTED_TM_SLOTS[n] then
        randomTMAssignments[n] = slot and slot.move or nil
      else
        randomTMAssignments[n] = pool[poolIndex]
        poolIndex = poolIndex + 1
      end
    end
    mod.save:set(RANDOM_TM_SAVE_KEY, randomTMAssignments)
    return true
  end

  local function restoreTMBaseline(game, baseline)
    local data = game and game.data
    if not data then return false end
    for n = 1, 57 do
      local slot = baseline.slots[n]
      local def = slot and data.items[slot.itemId]
      if type(def) == "table" then def.teaches = slot.move end
    end
    for species, compat in pairs(baseline.pokemon) do
      local def = data.pokemon[species]
      if type(def) == "table" then
        local copy = {}
        for _, move in ipairs(compat) do copy[#copy + 1] = move end
        def.tmhm = copy
      end
    end
    tmAppliedSignature[data] = "OFF"
    return true
  end

  local function tmAssignmentSignature()
    local parts = {}
    for n = 1, 50 do parts[n] = tostring(randomTMAssignments[n] or randomTMAssignments[tostring(n)] or "") end
    return table.concat(parts, "|")
  end

  syncRandomTMs = function(game, force)
    game = game or liveGame
    local data = game and game.data
    local baseline = ensureTMBaseline(game)
    if not (data and baseline) then return false end

    if not settings.randomTMs then
      if force or tmAppliedSignature[data] ~= "OFF" then
        return restoreTMBaseline(game, baseline)
      end
      return true
    end

    if not assignmentsValid(data, baseline) then
      if not generateRandomTMs(data, baseline) then return false end
    end

    local signature = tmAssignmentSignature()
    if not force and tmAppliedSignature[data] == signature then return true end

    -- Change only the 50 TM teach moves.  HMs remain vanilla.
    for n = 1, 50 do
      local slot = baseline.slots[n]
      local def = slot and data.items[slot.itemId]
      local move = randomTMAssignments[n] or randomTMAssignments[tostring(n)]
      if type(def) == "table" and move then def.teaches = move end
    end
    for n = 51, 57 do
      local slot = baseline.slots[n]
      local def = slot and data.items[slot.itemId]
      if type(def) == "table" then def.teaches = slot.move end
    end

    -- Translate vanilla slot compatibility to each slot's newly assigned move.
    for species, originalCompat in pairs(baseline.pokemon) do
      local def = data.pokemon[species]
      if type(def) == "table" then
        local oldAllowed = {}
        for _, move in ipairs(originalCompat) do oldAllowed[move] = true end
        local compat, seen = {}, {}
        for n = 1, 50 do
          local slot = baseline.slots[n]
          if slot and oldAllowed[slot.move] then
            local newMove = randomTMAssignments[n] or randomTMAssignments[tostring(n)]
            if newMove and not seen[newMove] then
              seen[newMove] = true
              compat[#compat + 1] = newMove
            end
          end
        end
        -- HMs are unchanged, including their original compatibility.
        for n = 51, 57 do
          local slot = baseline.slots[n]
          if slot and oldAllowed[slot.move] and not seen[slot.move] then
            seen[slot.move] = true
            compat[#compat + 1] = slot.move
          end
        end
        def.tmhm = compat
      end
    end

    tmAppliedSignature[data] = signature
    return true
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

  local function resolveLiveMove(moveId)
    local game = liveGame
    local moveData = game and game.data and game.data.moves
    if type(moveData) ~= "table" or moveId == nil then return nil, nil end

    -- Best case: the species learnset already uses the live move-table key.
    local direct = moveData[moveId]
    if type(direct) == "table" then return moveId, direct end

    local raw = tostring(moveId)
    local upper = raw:upper()
    local lower = raw:lower()
    if type(moveData[upper]) == "table" then return upper, moveData[upper] end
    if type(moveData[lower]) == "table" then return lower, moveData[lower] end

    -- Gold caches/mod registries have used more than one id spelling over time.
    -- Match all identity fields without assuming which one is the table key.
    local function norm(v)
      return tostring(v or ""):upper():gsub("[^A-Z0-9]", "")
    end
    local wanted = norm(moveId)
    if wanted == "" then return nil, nil end

    for key, def in pairs(moveData) do
      if type(def) == "table" then
        if norm(key) == wanted or norm(def.id) == wanted
           or norm(def.key) == wanted or norm(def.name) == wanted then
          return key, def
        end
      end
    end

    local registry = mod.content and mod.content.moves
    if registry and type(registry.each) == "function" then
      for registryId, def in registry:each() do
        if type(def) == "table"
           and (norm(registryId) == wanted or norm(def.id) == wanted
             or norm(def.key) == wanted or norm(def.name) == wanted) then
          local live = moveData[registryId]
          if type(live) == "table" then return registryId, live end
          -- Never inject registry definitions into game.data.moves here.
          -- That table is shared by the running game; mutating it during a
          -- randomized rematch can corrupt later normal trainer battles.
          -- If this registry id is not already native to the live move table,
          -- keep searching/return unresolved rather than changing engine data.
        end
      end
    end

    return nil, nil
  end

  local GOLD_LEVELUP_LEARNSETS

  local function goldSourceMovesAtLevel(species, level)
    local rows = GOLD_LEVELUP_LEARNSETS[normalizeSpecies(species)]
    if type(rows) ~= "table" then return nil end

    local learned = {}
    local function add(id)
      if type(id) ~= "string" or id == "" then return end
      for i, present in ipairs(learned) do
        if present == id then
          -- FillMoves ignores a move already present; preserve its original
          -- position exactly like the cartridge routine.
          return
        end
      end
      learned[#learned + 1] = id
      if #learned > 4 then table.remove(learned, 1) end
    end

    local targetLevel = tonumber(level) or 1
    for _, row in ipairs(rows) do
      if tonumber(row[1]) and row[1] <= targetLevel then
        add(row[2])
      else
        break
      end
    end

    if #learned == 0 then return nil end

    -- Resolve the cartridge constants against the live move table so the
    -- returned IDs are exactly what BattleState expects in this build.
    local resolved = {}
    for _, id in ipairs(learned) do
      local liveId, mdef = resolveLiveMove(id)
      if liveId ~= nil and type(mdef) == "table"
         and tonumber(mdef.pp) and tonumber(mdef.pp) > 0 then
        resolved[#resolved + 1] = liveId
      end
    end
    return #resolved > 0 and resolved or nil
  end

  local function nativeMovesAtLevel(species, level, fallbackMoves)
    local game = liveGame
    local data = game and game.data
    local targetLevel = tonumber(level) or 1

    -- Randomized Gold trainers use the cartridge learnset table embedded above.
    -- These are the exact MOVE constants from pokegold, the same namespace used
    -- by explicit trainer moves that already work in this recomp build.
    local sourceMoves = goldSourceMovesAtLevel(species, targetLevel)
    if sourceMoves then return sourceMoves end

    -- Compatibility fallback: use the live generated species definition.
    -- This is the same data that
    -- Pokemon.new() sees inside BattleState, so its learnset ids are already in
    -- the engine's preferred representation for this imported Gold cache.
    if data and type(data.pokemon) == "table" then
      local candidates = {
        species,
        tostring(species or ""):upper(),
        tostring(species or ""):lower(),
      }
      for _, speciesId in ipairs(candidates) do
        local def = data.pokemon[speciesId]
        if type(def) == "table" then
          local ok, ids = pcall(Pokemon.movesAtLevel, def, targetLevel)
          if ok and type(ids) == "table" and #ids > 0 then
            local resolved = {}
            for _, id in ipairs(ids) do
              local liveId, mdef = resolveLiveMove(id)
              if liveId ~= nil and type(mdef) == "table"
                 and tonumber(mdef.pp) and tonumber(mdef.pp) > 0 then
                resolved[#resolved + 1] = liveId
              end
            end
            if #resolved > 0 then return resolved end
          end
        end
      end
    end

    -- Registry fallback for older builds where the live species table is not
    -- available to mods yet.
    local registry = mod.content and mod.content.pokemon
    local speciesNorm = normalizeSpecies(species)
    local entry = nil
    if registry and type(registry.each) == "function" then
      for id, def in registry:each() do
        if normalizeSpecies(id) == speciesNorm then entry = def break end
      end
    end

    if type(entry) == "table" then
      local rawMoves = {}
      local function add(move)
        if move == nil then return end
        for _, present in ipairs(rawMoves) do if present == move then return end end
        rawMoves[#rawMoves + 1] = move
      end
      for _, move in ipairs(entry.level1Moves or {}) do add(move) end
      for _, learned in ipairs(entry.learnset or {}) do
        if type(learned) == "table" and tonumber(learned.level)
           and tonumber(learned.level) <= targetLevel then add(learned.move) end
      end
      while #rawMoves > 4 do table.remove(rawMoves, 1) end

      local resolved = {}
      for _, id in ipairs(rawMoves) do
        local liveId, mdef = resolveLiveMove(id)
        if liveId ~= nil and type(mdef) == "table"
           and tonumber(mdef.pp) and tonumber(mdef.pp) > 0 then
          resolved[#resolved + 1] = liveId
        end
      end
      if #resolved > 0 then return resolved end
    end

    if type(fallbackMoves) == "table" and #fallbackMoves > 0 then
      local resolved = {}
      for _, id in ipairs(fallbackMoves) do
        local liveId, mdef = resolveLiveMove(id)
        if liveId ~= nil and type(mdef) == "table"
           and tonumber(mdef.pp) and tonumber(mdef.pp) > 0 then
          resolved[#resolved + 1] = liveId
        end
      end
      if #resolved > 0 then return resolved end
    end

    return nil
  end


  -- Preserve the exact pre-randomizer move path for original/progressive teams.
  -- v1.1.8 used Pokemon.new() here and that path was already stable in battle.
  local function originalTrainerMovesAtLevel(species, level, fallbackMoves)
    local game = liveGame
    local data = game and game.data

    if data and data.pokemon then
      local candidates = {
        species,
        tostring(species or ""):upper(),
        tostring(species or ""):lower(),
      }

      for _, speciesId in ipairs(candidates) do
        if data.pokemon[speciesId] then
          local ok, mon = pcall(
            Pokemon.new,
            data,
            speciesId,
            tonumber(level) or 1
          )

          if ok and type(mon) == "table"
             and type(mon.moves) == "table"
             and #mon.moves > 0 then
            local ids = {}
            for _, move in ipairs(mon.moves) do
              if type(move) == "table" and move.id and data.moves[move.id] then
                ids[#ids + 1] = move.id
              end
            end
            if #ids > 0 then return ids end
          end
        end
      end
    end

    if type(fallbackMoves) == "table" and #fallbackMoves > 0 then
      local copy = {}
      for _, id in ipairs(fallbackMoves) do
        if type(id) == "string" then copy[#copy + 1] = id end
      end
      if #copy > 0 then return copy end
    end

    return nil
  end

  local moveAliasesReady = false

  local function ensureMoveAliases()
    if moveAliasesReady then return true end

    local game = liveGame
    local moveData = game and game.data and game.data.moves
    if type(moveData) ~= "table" then return false end

    local pending = {}

    -- First derive aliases from the live move table itself. Gen2 caches may use
    -- generated registry ids while keeping the cartridge constant in `key`.
    for id, def in pairs(moveData) do
      if type(id) == "string" and type(def) == "table" then
        local key = def.key
        local canonicalId = def.id

        if type(key) == "string" and key ~= "" and moveData[key] == nil then
          pending[key] = def
        end
        if type(canonicalId) == "string"
           and canonicalId ~= ""
           and moveData[canonicalId] == nil then
          pending[canonicalId] = def
        end
      end
    end

    -- The merged mod registry is another authoritative view of the same move
    -- records. Use it to bridge cases where game.data uses a generated id but
    -- the registry exposes the cartridge key explicitly.
    local registry = mod.content and mod.content.moves
    if registry and type(registry.each) == "function" then
      for registryId, def in registry:each() do
        if type(def) == "table" then
          local liveDef = moveData[registryId] or def

          local candidates = {
            registryId,
            def.key,
            def.id,
          }

          for _, alias in ipairs(candidates) do
            if type(alias) == "string"
               and alias ~= ""
               and moveData[alias] == nil then
              pending[alias] = liveDef
            end
          end
        end
      end
    end

    for alias, def in pairs(pending) do
      moveData[alias] = def
    end

    moveAliasesReady = true
    return true
  end

  local GOLD_SPECIES_IDS = {
    "BULBASAUR",
    "IVYSAUR",
    "VENUSAUR",
    "CHARMANDER",
    "CHARMELEON",
    "CHARIZARD",
    "SQUIRTLE",
    "WARTORTLE",
    "BLASTOISE",
    "CATERPIE",
    "METAPOD",
    "BUTTERFREE",
    "WEEDLE",
    "KAKUNA",
    "BEEDRILL",
    "PIDGEY",
    "PIDGEOTTO",
    "PIDGEOT",
    "RATTATA",
    "RATICATE",
    "SPEAROW",
    "FEAROW",
    "EKANS",
    "ARBOK",
    "PIKACHU",
    "RAICHU",
    "SANDSHREW",
    "SANDSLASH",
    "NIDORAN_F",
    "NIDORINA",
    "NIDOQUEEN",
    "NIDORAN_M",
    "NIDORINO",
    "NIDOKING",
    "CLEFAIRY",
    "CLEFABLE",
    "VULPIX",
    "NINETALES",
    "JIGGLYPUFF",
    "WIGGLYTUFF",
    "ZUBAT",
    "GOLBAT",
    "ODDISH",
    "GLOOM",
    "VILEPLUME",
    "PARAS",
    "PARASECT",
    "VENONAT",
    "VENOMOTH",
    "DIGLETT",
    "DUGTRIO",
    "MEOWTH",
    "PERSIAN",
    "PSYDUCK",
    "GOLDUCK",
    "MANKEY",
    "PRIMEAPE",
    "GROWLITHE",
    "ARCANINE",
    "POLIWAG",
    "POLIWHIRL",
    "POLIWRATH",
    "ABRA",
    "KADABRA",
    "ALAKAZAM",
    "MACHOP",
    "MACHOKE",
    "MACHAMP",
    "BELLSPROUT",
    "WEEPINBELL",
    "VICTREEBEL",
    "TENTACOOL",
    "TENTACRUEL",
    "GEODUDE",
    "GRAVELER",
    "GOLEM",
    "PONYTA",
    "RAPIDASH",
    "SLOWPOKE",
    "SLOWBRO",
    "MAGNEMITE",
    "MAGNETON",
    "FARFETCH_D",
    "DODUO",
    "DODRIO",
    "SEEL",
    "DEWGONG",
    "GRIMER",
    "MUK",
    "SHELLDER",
    "CLOYSTER",
    "GASTLY",
    "HAUNTER",
    "GENGAR",
    "ONIX",
    "DROWZEE",
    "HYPNO",
    "KRABBY",
    "KINGLER",
    "VOLTORB",
    "ELECTRODE",
    "EXEGGCUTE",
    "EXEGGUTOR",
    "CUBONE",
    "MAROWAK",
    "HITMONLEE",
    "HITMONCHAN",
    "LICKITUNG",
    "KOFFING",
    "WEEZING",
    "RHYHORN",
    "RHYDON",
    "CHANSEY",
    "TANGELA",
    "KANGASKHAN",
    "HORSEA",
    "SEADRA",
    "GOLDEEN",
    "SEAKING",
    "STARYU",
    "STARMIE",
    "MR__MIME",
    "SCYTHER",
    "JYNX",
    "ELECTABUZZ",
    "MAGMAR",
    "PINSIR",
    "TAUROS",
    "MAGIKARP",
    "GYARADOS",
    "LAPRAS",
    "DITTO",
    "EEVEE",
    "VAPOREON",
    "JOLTEON",
    "FLAREON",
    "PORYGON",
    "OMANYTE",
    "OMASTAR",
    "KABUTO",
    "KABUTOPS",
    "AERODACTYL",
    "SNORLAX",
    "ARTICUNO",
    "ZAPDOS",
    "MOLTRES",
    "DRATINI",
    "DRAGONAIR",
    "DRAGONITE",
    "MEWTWO",
    "MEW",
    "CHIKORITA",
    "BAYLEEF",
    "MEGANIUM",
    "CYNDAQUIL",
    "QUILAVA",
    "TYPHLOSION",
    "TOTODILE",
    "CROCONAW",
    "FERALIGATR",
    "SENTRET",
    "FURRET",
    "HOOTHOOT",
    "NOCTOWL",
    "LEDYBA",
    "LEDIAN",
    "SPINARAK",
    "ARIADOS",
    "CROBAT",
    "CHINCHOU",
    "LANTURN",
    "PICHU",
    "CLEFFA",
    "IGGLYBUFF",
    "TOGEPI",
    "TOGETIC",
    "NATU",
    "XATU",
    "MAREEP",
    "FLAAFFY",
    "AMPHAROS",
    "BELLOSSOM",
    "MARILL",
    "AZUMARILL",
    "SUDOWOODO",
    "POLITOED",
    "HOPPIP",
    "SKIPLOOM",
    "JUMPLUFF",
    "AIPOM",
    "SUNKERN",
    "SUNFLORA",
    "YANMA",
    "WOOPER",
    "QUAGSIRE",
    "ESPEON",
    "UMBREON",
    "MURKROW",
    "SLOWKING",
    "MISDREAVUS",
    "UNOWN",
    "WOBBUFFET",
    "GIRAFARIG",
    "PINECO",
    "FORRETRESS",
    "DUNSPARCE",
    "GLIGAR",
    "STEELIX",
    "SNUBBULL",
    "GRANBULL",
    "QWILFISH",
    "SCIZOR",
    "SHUCKLE",
    "HERACROSS",
    "SNEASEL",
    "TEDDIURSA",
    "URSARING",
    "SLUGMA",
    "MAGCARGO",
    "SWINUB",
    "PILOSWINE",
    "CORSOLA",
    "REMORAID",
    "OCTILLERY",
    "DELIBIRD",
    "MANTINE",
    "SKARMORY",
    "HOUNDOUR",
    "HOUNDOOM",
    "KINGDRA",
    "PHANPY",
    "DONPHAN",
    "PORYGON2",
    "STANTLER",
    "SMEARGLE",
    "TYROGUE",
    "HITMONTOP",
    "SMOOCHUM",
    "ELEKID",
    "MAGBY",
    "MILTANK",
    "BLISSEY",
    "RAIKOU",
    "ENTEI",
    "SUICUNE",
    "LARVITAR",
    "PUPITAR",
    "TYRANITAR",
    "LUGIA",
    "HO_OH",
    "CELEBI",
  }

  -- Canonical Pokémon Gold level-up learnsets extracted directly from
  -- data/pokemon/evos_attacks.asm in the user-provided pokegold source.
  -- Each row is { level, MOVE_CONSTANT }. This deliberately bypasses
  -- recomp-generated species learnsets for randomized trainer Pokémon.
  GOLD_LEVELUP_LEARNSETS = {
    BULBASAUR = { {1,"TACKLE"}, {4,"GROWL"}, {7,"LEECH_SEED"}, {10,"VINE_WHIP"}, {15,"POISONPOWDER"}, {15,"SLEEP_POWDER"}, {20,"RAZOR_LEAF"}, {25,"SWEET_SCENT"}, {32,"GROWTH"}, {39,"SYNTHESIS"}, {46,"SOLARBEAM"} },
    IVYSAUR = { {1,"TACKLE"}, {1,"GROWL"}, {1,"LEECH_SEED"}, {4,"GROWL"}, {7,"LEECH_SEED"}, {10,"VINE_WHIP"}, {15,"POISONPOWDER"}, {15,"SLEEP_POWDER"}, {22,"RAZOR_LEAF"}, {29,"SWEET_SCENT"}, {38,"GROWTH"}, {47,"SYNTHESIS"}, {56,"SOLARBEAM"} },
    VENUSAUR = { {1,"TACKLE"}, {1,"GROWL"}, {1,"LEECH_SEED"}, {1,"VINE_WHIP"}, {4,"GROWL"}, {7,"LEECH_SEED"}, {10,"VINE_WHIP"}, {15,"POISONPOWDER"}, {15,"SLEEP_POWDER"}, {22,"RAZOR_LEAF"}, {29,"SWEET_SCENT"}, {41,"GROWTH"}, {53,"SYNTHESIS"}, {65,"SOLARBEAM"} },
    CHARMANDER = { {1,"SCRATCH"}, {1,"GROWL"}, {7,"EMBER"}, {13,"SMOKESCREEN"}, {19,"RAGE"}, {25,"SCARY_FACE"}, {31,"FLAMETHROWER"}, {37,"SLASH"}, {43,"DRAGON_RAGE"}, {49,"FIRE_SPIN"} },
    CHARMELEON = { {1,"SCRATCH"}, {1,"GROWL"}, {1,"EMBER"}, {7,"EMBER"}, {13,"SMOKESCREEN"}, {20,"RAGE"}, {27,"SCARY_FACE"}, {34,"FLAMETHROWER"}, {41,"SLASH"}, {48,"DRAGON_RAGE"}, {55,"FIRE_SPIN"} },
    CHARIZARD = { {1,"SCRATCH"}, {1,"GROWL"}, {1,"EMBER"}, {1,"SMOKESCREEN"}, {7,"EMBER"}, {13,"SMOKESCREEN"}, {20,"RAGE"}, {27,"SCARY_FACE"}, {34,"FLAMETHROWER"}, {36,"WING_ATTACK"}, {44,"SLASH"}, {54,"DRAGON_RAGE"}, {64,"FIRE_SPIN"} },
    SQUIRTLE = { {1,"TACKLE"}, {4,"TAIL_WHIP"}, {7,"BUBBLE"}, {10,"WITHDRAW"}, {13,"WATER_GUN"}, {18,"BITE"}, {23,"RAPID_SPIN"}, {28,"PROTECT"}, {33,"RAIN_DANCE"}, {40,"SKULL_BASH"}, {47,"HYDRO_PUMP"} },
    WARTORTLE = { {1,"TACKLE"}, {1,"TAIL_WHIP"}, {1,"BUBBLE"}, {4,"TAIL_WHIP"}, {7,"BUBBLE"}, {10,"WITHDRAW"}, {13,"WATER_GUN"}, {19,"BITE"}, {25,"RAPID_SPIN"}, {31,"PROTECT"}, {37,"RAIN_DANCE"}, {45,"SKULL_BASH"}, {53,"HYDRO_PUMP"} },
    BLASTOISE = { {1,"TACKLE"}, {1,"TAIL_WHIP"}, {1,"BUBBLE"}, {1,"WITHDRAW"}, {4,"TAIL_WHIP"}, {7,"BUBBLE"}, {10,"WITHDRAW"}, {13,"WATER_GUN"}, {19,"BITE"}, {25,"RAPID_SPIN"}, {31,"PROTECT"}, {42,"RAIN_DANCE"}, {55,"SKULL_BASH"}, {68,"HYDRO_PUMP"} },
    CATERPIE = { {1,"TACKLE"}, {1,"STRING_SHOT"} },
    METAPOD = { {1,"HARDEN"}, {7,"HARDEN"} },
    BUTTERFREE = { {1,"CONFUSION"}, {10,"CONFUSION"}, {13,"POISONPOWDER"}, {14,"STUN_SPORE"}, {15,"SLEEP_POWDER"}, {18,"SUPERSONIC"}, {23,"WHIRLWIND"}, {28,"GUST"}, {34,"PSYBEAM"}, {40,"SAFEGUARD"} },
    WEEDLE = { {1,"POISON_STING"}, {1,"STRING_SHOT"} },
    KAKUNA = { {1,"HARDEN"}, {7,"HARDEN"} },
    BEEDRILL = { {1,"FURY_ATTACK"}, {10,"FURY_ATTACK"}, {15,"FOCUS_ENERGY"}, {20,"TWINEEDLE"}, {25,"RAGE"}, {30,"PURSUIT"}, {35,"PIN_MISSILE"}, {40,"AGILITY"} },
    PIDGEY = { {1,"TACKLE"}, {5,"SAND_ATTACK"}, {9,"GUST"}, {15,"QUICK_ATTACK"}, {21,"WHIRLWIND"}, {29,"WING_ATTACK"}, {37,"AGILITY"}, {47,"MIRROR_MOVE"} },
    PIDGEOTTO = { {1,"TACKLE"}, {1,"SAND_ATTACK"}, {1,"GUST"}, {5,"SAND_ATTACK"}, {9,"GUST"}, {15,"QUICK_ATTACK"}, {23,"WHIRLWIND"}, {33,"WING_ATTACK"}, {43,"AGILITY"}, {55,"MIRROR_MOVE"} },
    PIDGEOT = { {1,"TACKLE"}, {1,"SAND_ATTACK"}, {1,"GUST"}, {1,"QUICK_ATTACK"}, {5,"SAND_ATTACK"}, {9,"GUST"}, {15,"QUICK_ATTACK"}, {23,"WHIRLWIND"}, {33,"WING_ATTACK"}, {46,"AGILITY"}, {61,"MIRROR_MOVE"} },
    RATTATA = { {1,"TACKLE"}, {1,"TAIL_WHIP"}, {7,"QUICK_ATTACK"}, {13,"HYPER_FANG"}, {20,"FOCUS_ENERGY"}, {27,"PURSUIT"}, {34,"SUPER_FANG"} },
    RATICATE = { {1,"TACKLE"}, {1,"TAIL_WHIP"}, {1,"QUICK_ATTACK"}, {7,"QUICK_ATTACK"}, {13,"HYPER_FANG"}, {20,"SCARY_FACE"}, {30,"PURSUIT"}, {40,"SUPER_FANG"} },
    SPEAROW = { {1,"PECK"}, {1,"GROWL"}, {7,"LEER"}, {13,"FURY_ATTACK"}, {25,"PURSUIT"}, {31,"MIRROR_MOVE"}, {37,"DRILL_PECK"}, {43,"AGILITY"} },
    FEAROW = { {1,"PECK"}, {1,"GROWL"}, {1,"LEER"}, {1,"FURY_ATTACK"}, {7,"LEER"}, {13,"FURY_ATTACK"}, {26,"PURSUIT"}, {32,"MIRROR_MOVE"}, {40,"DRILL_PECK"}, {47,"AGILITY"} },
    EKANS = { {1,"WRAP"}, {1,"LEER"}, {9,"POISON_STING"}, {15,"BITE"}, {23,"GLARE"}, {29,"SCREECH"}, {37,"ACID"}, {43,"HAZE"} },
    ARBOK = { {1,"WRAP"}, {1,"LEER"}, {1,"POISON_STING"}, {1,"BITE"}, {9,"POISON_STING"}, {15,"BITE"}, {25,"GLARE"}, {33,"SCREECH"}, {43,"ACID"}, {51,"HAZE"} },
    PIKACHU = { {1,"THUNDERSHOCK"}, {1,"GROWL"}, {6,"TAIL_WHIP"}, {8,"THUNDER_WAVE"}, {11,"QUICK_ATTACK"}, {15,"DOUBLE_TEAM"}, {20,"SLAM"}, {26,"THUNDERBOLT"}, {33,"AGILITY"}, {41,"THUNDER"}, {50,"LIGHT_SCREEN"} },
    RAICHU = { {1,"THUNDERSHOCK"}, {1,"TAIL_WHIP"}, {1,"QUICK_ATTACK"}, {1,"THUNDERBOLT"} },
    SANDSHREW = { {1,"SCRATCH"}, {6,"DEFENSE_CURL"}, {11,"SAND_ATTACK"}, {17,"POISON_STING"}, {23,"SLASH"}, {30,"SWIFT"}, {37,"FURY_SWIPES"}, {45,"SANDSTORM"} },
    SANDSLASH = { {1,"SCRATCH"}, {1,"DEFENSE_CURL"}, {1,"SAND_ATTACK"}, {6,"DEFENSE_CURL"}, {11,"SAND_ATTACK"}, {17,"POISON_STING"}, {24,"SLASH"}, {33,"SWIFT"}, {42,"FURY_SWIPES"}, {52,"SANDSTORM"} },
    NIDORAN_F = { {1,"GROWL"}, {1,"TACKLE"}, {8,"SCRATCH"}, {12,"DOUBLE_KICK"}, {17,"POISON_STING"}, {23,"TAIL_WHIP"}, {30,"BITE"}, {38,"FURY_SWIPES"} },
    NIDORINA = { {1,"GROWL"}, {1,"TACKLE"}, {8,"SCRATCH"}, {12,"DOUBLE_KICK"}, {19,"POISON_STING"}, {27,"TAIL_WHIP"}, {36,"BITE"}, {46,"FURY_SWIPES"} },
    NIDOQUEEN = { {1,"TACKLE"}, {1,"SCRATCH"}, {1,"DOUBLE_KICK"}, {1,"TAIL_WHIP"}, {23,"BODY_SLAM"} },
    NIDORAN_M = { {1,"LEER"}, {1,"TACKLE"}, {8,"HORN_ATTACK"}, {12,"DOUBLE_KICK"}, {17,"POISON_STING"}, {23,"FOCUS_ENERGY"}, {30,"FURY_ATTACK"}, {38,"HORN_DRILL"} },
    NIDORINO = { {1,"LEER"}, {1,"TACKLE"}, {8,"HORN_ATTACK"}, {12,"DOUBLE_KICK"}, {19,"POISON_STING"}, {27,"FOCUS_ENERGY"}, {36,"FURY_ATTACK"}, {46,"HORN_DRILL"} },
    NIDOKING = { {1,"TACKLE"}, {1,"HORN_ATTACK"}, {1,"DOUBLE_KICK"}, {1,"POISON_STING"}, {23,"THRASH"} },
    CLEFAIRY = { {1,"POUND"}, {1,"GROWL"}, {4,"ENCORE"}, {8,"SING"}, {13,"DOUBLESLAP"}, {19,"MINIMIZE"}, {26,"DEFENSE_CURL"}, {34,"METRONOME"}, {43,"MOONLIGHT"}, {53,"LIGHT_SCREEN"} },
    CLEFABLE = { {1,"SING"}, {1,"DOUBLESLAP"}, {1,"METRONOME"}, {1,"MOONLIGHT"} },
    VULPIX = { {1,"EMBER"}, {1,"TAIL_WHIP"}, {7,"QUICK_ATTACK"}, {13,"ROAR"}, {19,"CONFUSE_RAY"}, {25,"SAFEGUARD"}, {31,"FLAMETHROWER"}, {37,"FIRE_SPIN"} },
    NINETALES = { {1,"EMBER"}, {1,"QUICK_ATTACK"}, {1,"CONFUSE_RAY"}, {1,"SAFEGUARD"}, {43,"FIRE_SPIN"} },
    JIGGLYPUFF = { {1,"SING"}, {4,"DEFENSE_CURL"}, {9,"POUND"}, {14,"DISABLE"}, {19,"ROLLOUT"}, {24,"DOUBLESLAP"}, {29,"REST"}, {34,"BODY_SLAM"}, {39,"DOUBLE_EDGE"} },
    WIGGLYTUFF = { {1,"SING"}, {1,"DISABLE"}, {1,"DEFENSE_CURL"}, {1,"DOUBLESLAP"} },
    ZUBAT = { {1,"LEECH_LIFE"}, {6,"SUPERSONIC"}, {12,"BITE"}, {19,"CONFUSE_RAY"}, {27,"WING_ATTACK"}, {36,"MEAN_LOOK"}, {46,"HAZE"} },
    GOLBAT = { {1,"SCREECH"}, {1,"LEECH_LIFE"}, {1,"SUPERSONIC"}, {6,"SUPERSONIC"}, {12,"BITE"}, {19,"CONFUSE_RAY"}, {30,"WING_ATTACK"}, {42,"MEAN_LOOK"}, {55,"HAZE"} },
    ODDISH = { {1,"ABSORB"}, {7,"SWEET_SCENT"}, {14,"POISONPOWDER"}, {16,"STUN_SPORE"}, {18,"SLEEP_POWDER"}, {23,"ACID"}, {32,"MOONLIGHT"}, {39,"PETAL_DANCE"} },
    GLOOM = { {1,"ABSORB"}, {1,"SWEET_SCENT"}, {1,"POISONPOWDER"}, {7,"SWEET_SCENT"}, {14,"POISONPOWDER"}, {16,"STUN_SPORE"}, {18,"SLEEP_POWDER"}, {24,"ACID"}, {35,"MOONLIGHT"}, {44,"PETAL_DANCE"} },
    VILEPLUME = { {1,"ABSORB"}, {1,"SWEET_SCENT"}, {1,"STUN_SPORE"}, {1,"PETAL_DANCE"} },
    PARAS = { {1,"SCRATCH"}, {7,"STUN_SPORE"}, {13,"POISONPOWDER"}, {19,"LEECH_LIFE"}, {25,"SPORE"}, {31,"SLASH"}, {37,"GROWTH"}, {43,"GIGA_DRAIN"} },
    PARASECT = { {1,"SCRATCH"}, {1,"STUN_SPORE"}, {1,"POISONPOWDER"}, {7,"STUN_SPORE"}, {13,"POISONPOWDER"}, {19,"LEECH_LIFE"}, {28,"SPORE"}, {37,"SLASH"}, {46,"GROWTH"}, {55,"GIGA_DRAIN"} },
    VENONAT = { {1,"TACKLE"}, {1,"DISABLE"}, {1,"FORESIGHT"}, {9,"SUPERSONIC"}, {17,"CONFUSION"}, {20,"POISONPOWDER"}, {25,"LEECH_LIFE"}, {28,"STUN_SPORE"}, {33,"PSYBEAM"}, {36,"SLEEP_POWDER"}, {41,"PSYCHIC_M"} },
    VENOMOTH = { {1,"TACKLE"}, {1,"DISABLE"}, {1,"FORESIGHT"}, {1,"SUPERSONIC"}, {9,"SUPERSONIC"}, {17,"CONFUSION"}, {20,"POISONPOWDER"}, {25,"LEECH_LIFE"}, {28,"STUN_SPORE"}, {31,"GUST"}, {36,"PSYBEAM"}, {42,"SLEEP_POWDER"}, {52,"PSYCHIC_M"} },
    DIGLETT = { {1,"SCRATCH"}, {5,"GROWL"}, {9,"MAGNITUDE"}, {17,"DIG"}, {25,"SAND_ATTACK"}, {33,"SLASH"}, {41,"EARTHQUAKE"}, {49,"FISSURE"} },
    DUGTRIO = { {1,"SCRATCH"}, {1,"GROWL"}, {1,"MAGNITUDE"}, {5,"GROWL"}, {9,"MAGNITUDE"}, {17,"DIG"}, {25,"SAND_ATTACK"}, {37,"SLASH"}, {49,"EARTHQUAKE"}, {61,"FISSURE"} },
    MEOWTH = { {1,"SCRATCH"}, {1,"GROWL"}, {11,"BITE"}, {20,"PAY_DAY"}, {28,"FAINT_ATTACK"}, {35,"SCREECH"}, {41,"FURY_SWIPES"}, {46,"SLASH"} },
    PERSIAN = { {1,"SCRATCH"}, {1,"GROWL"}, {1,"BITE"}, {11,"BITE"}, {20,"PAY_DAY"}, {29,"FAINT_ATTACK"}, {38,"SCREECH"}, {46,"FURY_SWIPES"}, {53,"SLASH"} },
    PSYDUCK = { {1,"SCRATCH"}, {5,"TAIL_WHIP"}, {10,"DISABLE"}, {16,"CONFUSION"}, {23,"SCREECH"}, {31,"PSYCH_UP"}, {40,"FURY_SWIPES"}, {50,"HYDRO_PUMP"} },
    GOLDUCK = { {1,"SCRATCH"}, {1,"TAIL_WHIP"}, {1,"DISABLE"}, {1,"CONFUSION"}, {5,"TAIL_WHIP"}, {10,"DISABLE"}, {16,"CONFUSION"}, {23,"SCREECH"}, {31,"PSYCH_UP"}, {44,"FURY_SWIPES"}, {58,"HYDRO_PUMP"} },
    MANKEY = { {1,"SCRATCH"}, {1,"LEER"}, {9,"LOW_KICK"}, {15,"KARATE_CHOP"}, {21,"FURY_SWIPES"}, {27,"FOCUS_ENERGY"}, {33,"SEISMIC_TOSS"}, {39,"CROSS_CHOP"}, {45,"SCREECH"}, {51,"THRASH"} },
    PRIMEAPE = { {1,"SCRATCH"}, {1,"LEER"}, {1,"LOW_KICK"}, {1,"RAGE"}, {9,"LOW_KICK"}, {15,"KARATE_CHOP"}, {21,"FURY_SWIPES"}, {27,"FOCUS_ENERGY"}, {28,"RAGE"}, {36,"SEISMIC_TOSS"}, {45,"CROSS_CHOP"}, {54,"SCREECH"}, {63,"THRASH"} },
    GROWLITHE = { {1,"BITE"}, {1,"ROAR"}, {9,"EMBER"}, {18,"LEER"}, {26,"TAKE_DOWN"}, {34,"FLAME_WHEEL"}, {42,"AGILITY"}, {50,"FLAMETHROWER"} },
    ARCANINE = { {1,"ROAR"}, {1,"LEER"}, {1,"TAKE_DOWN"}, {1,"FLAME_WHEEL"}, {50,"EXTREMESPEED"} },
    POLIWAG = { {1,"BUBBLE"}, {7,"HYPNOSIS"}, {13,"WATER_GUN"}, {19,"DOUBLESLAP"}, {25,"RAIN_DANCE"}, {31,"BODY_SLAM"}, {37,"BELLY_DRUM"}, {43,"HYDRO_PUMP"} },
    POLIWHIRL = { {1,"BUBBLE"}, {1,"HYPNOSIS"}, {1,"WATER_GUN"}, {7,"HYPNOSIS"}, {13,"WATER_GUN"}, {19,"DOUBLESLAP"}, {27,"RAIN_DANCE"}, {35,"BODY_SLAM"}, {43,"BELLY_DRUM"}, {51,"HYDRO_PUMP"} },
    POLIWRATH = { {1,"WATER_GUN"}, {1,"HYPNOSIS"}, {1,"DOUBLESLAP"}, {1,"SUBMISSION"}, {35,"SUBMISSION"}, {51,"MIND_READER"} },
    ABRA = { {1,"TELEPORT"} },
    KADABRA = { {1,"TELEPORT"}, {1,"KINESIS"}, {1,"CONFUSION"}, {16,"CONFUSION"}, {18,"DISABLE"}, {21,"PSYBEAM"}, {26,"RECOVER"}, {31,"FUTURE_SIGHT"}, {38,"PSYCHIC_M"}, {45,"REFLECT"} },
    ALAKAZAM = { {1,"TELEPORT"}, {1,"KINESIS"}, {1,"CONFUSION"}, {16,"CONFUSION"}, {18,"DISABLE"}, {21,"PSYBEAM"}, {26,"RECOVER"}, {31,"FUTURE_SIGHT"}, {38,"PSYCHIC_M"}, {45,"REFLECT"} },
    MACHOP = { {1,"LOW_KICK"}, {1,"LEER"}, {7,"FOCUS_ENERGY"}, {13,"KARATE_CHOP"}, {19,"SEISMIC_TOSS"}, {25,"FORESIGHT"}, {31,"VITAL_THROW"}, {37,"CROSS_CHOP"}, {43,"SCARY_FACE"}, {49,"SUBMISSION"} },
    MACHOKE = { {1,"LOW_KICK"}, {1,"LEER"}, {1,"FOCUS_ENERGY"}, {8,"FOCUS_ENERGY"}, {15,"KARATE_CHOP"}, {19,"SEISMIC_TOSS"}, {25,"FORESIGHT"}, {34,"VITAL_THROW"}, {43,"CROSS_CHOP"}, {52,"SCARY_FACE"}, {61,"SUBMISSION"} },
    MACHAMP = { {1,"LOW_KICK"}, {1,"LEER"}, {1,"FOCUS_ENERGY"}, {8,"FOCUS_ENERGY"}, {15,"KARATE_CHOP"}, {19,"SEISMIC_TOSS"}, {25,"FORESIGHT"}, {34,"VITAL_THROW"}, {43,"CROSS_CHOP"}, {52,"SCARY_FACE"}, {61,"SUBMISSION"} },
    BELLSPROUT = { {1,"VINE_WHIP"}, {6,"GROWTH"}, {11,"WRAP"}, {15,"SLEEP_POWDER"}, {17,"POISONPOWDER"}, {19,"STUN_SPORE"}, {23,"ACID"}, {30,"SWEET_SCENT"}, {37,"RAZOR_LEAF"}, {45,"SLAM"} },
    WEEPINBELL = { {1,"VINE_WHIP"}, {1,"GROWTH"}, {1,"WRAP"}, {6,"GROWTH"}, {11,"WRAP"}, {15,"SLEEP_POWDER"}, {17,"POISONPOWDER"}, {19,"STUN_SPORE"}, {24,"ACID"}, {33,"SWEET_SCENT"}, {42,"RAZOR_LEAF"}, {54,"SLAM"} },
    VICTREEBEL = { {1,"VINE_WHIP"}, {1,"SLEEP_POWDER"}, {1,"SWEET_SCENT"}, {1,"RAZOR_LEAF"} },
    TENTACOOL = { {1,"POISON_STING"}, {6,"SUPERSONIC"}, {12,"CONSTRICT"}, {19,"ACID"}, {25,"BUBBLEBEAM"}, {30,"WRAP"}, {36,"BARRIER"}, {43,"SCREECH"}, {49,"HYDRO_PUMP"} },
    TENTACRUEL = { {1,"POISON_STING"}, {1,"SUPERSONIC"}, {1,"CONSTRICT"}, {6,"SUPERSONIC"}, {12,"CONSTRICT"}, {19,"ACID"}, {25,"BUBBLEBEAM"}, {30,"WRAP"}, {38,"BARRIER"}, {47,"SCREECH"}, {55,"HYDRO_PUMP"} },
    GEODUDE = { {1,"TACKLE"}, {6,"DEFENSE_CURL"}, {11,"ROCK_THROW"}, {16,"MAGNITUDE"}, {21,"SELFDESTRUCT"}, {26,"HARDEN"}, {31,"ROLLOUT"}, {36,"EARTHQUAKE"}, {41,"EXPLOSION"} },
    GRAVELER = { {1,"TACKLE"}, {1,"DEFENSE_CURL"}, {1,"ROCK_THROW"}, {6,"DEFENSE_CURL"}, {11,"ROCK_THROW"}, {16,"MAGNITUDE"}, {21,"SELFDESTRUCT"}, {27,"HARDEN"}, {34,"ROLLOUT"}, {41,"EARTHQUAKE"}, {48,"EXPLOSION"} },
    GOLEM = { {1,"TACKLE"}, {1,"DEFENSE_CURL"}, {1,"ROCK_THROW"}, {1,"MAGNITUDE"}, {6,"DEFENSE_CURL"}, {11,"ROCK_THROW"}, {16,"MAGNITUDE"}, {21,"SELFDESTRUCT"}, {27,"HARDEN"}, {34,"ROLLOUT"}, {41,"EARTHQUAKE"}, {48,"EXPLOSION"} },
    PONYTA = { {1,"TACKLE"}, {4,"GROWL"}, {8,"TAIL_WHIP"}, {13,"EMBER"}, {19,"STOMP"}, {26,"FIRE_SPIN"}, {34,"TAKE_DOWN"}, {43,"AGILITY"}, {53,"FIRE_BLAST"} },
    RAPIDASH = { {1,"TACKLE"}, {1,"GROWL"}, {1,"TAIL_WHIP"}, {1,"EMBER"}, {4,"GROWL"}, {8,"TAIL_WHIP"}, {13,"EMBER"}, {19,"STOMP"}, {26,"FIRE_SPIN"}, {34,"TAKE_DOWN"}, {40,"FURY_ATTACK"}, {47,"AGILITY"}, {61,"FIRE_BLAST"} },
    SLOWPOKE = { {1,"CURSE"}, {1,"TACKLE"}, {6,"GROWL"}, {15,"WATER_GUN"}, {20,"CONFUSION"}, {29,"DISABLE"}, {34,"HEADBUTT"}, {43,"AMNESIA"}, {48,"PSYCHIC_M"} },
    SLOWBRO = { {1,"CURSE"}, {1,"TACKLE"}, {1,"GROWL"}, {1,"WATER_GUN"}, {6,"GROWL"}, {15,"WATER_GUN"}, {20,"CONFUSION"}, {29,"DISABLE"}, {34,"HEADBUTT"}, {37,"WITHDRAW"}, {46,"AMNESIA"}, {54,"PSYCHIC_M"} },
    MAGNEMITE = { {1,"TACKLE"}, {6,"THUNDERSHOCK"}, {11,"SUPERSONIC"}, {16,"SONICBOOM"}, {21,"THUNDER_WAVE"}, {27,"LOCK_ON"}, {33,"SWIFT"}, {39,"SCREECH"}, {45,"ZAP_CANNON"} },
    MAGNETON = { {1,"TACKLE"}, {1,"THUNDERSHOCK"}, {1,"SUPERSONIC"}, {1,"SONICBOOM"}, {6,"THUNDERSHOCK"}, {11,"SUPERSONIC"}, {16,"SONICBOOM"}, {21,"THUNDER_WAVE"}, {27,"LOCK_ON"}, {35,"SWIFT"}, {43,"SCREECH"}, {53,"ZAP_CANNON"} },
    FARFETCH_D = { {1,"PECK"}, {7,"SAND_ATTACK"}, {13,"LEER"}, {19,"FURY_ATTACK"}, {25,"SWORDS_DANCE"}, {31,"AGILITY"}, {37,"SLASH"}, {44,"FALSE_SWIPE"} },
    DODUO = { {1,"PECK"}, {1,"GROWL"}, {9,"PURSUIT"}, {13,"FURY_ATTACK"}, {21,"TRI_ATTACK"}, {25,"RAGE"}, {33,"DRILL_PECK"}, {37,"AGILITY"} },
    DODRIO = { {1,"PECK"}, {1,"GROWL"}, {1,"PURSUIT"}, {1,"FURY_ATTACK"}, {9,"PURSUIT"}, {13,"FURY_ATTACK"}, {21,"TRI_ATTACK"}, {25,"RAGE"}, {38,"DRILL_PECK"}, {47,"AGILITY"} },
    SEEL = { {1,"HEADBUTT"}, {5,"GROWL"}, {16,"AURORA_BEAM"}, {21,"REST"}, {32,"TAKE_DOWN"}, {37,"ICE_BEAM"}, {48,"SAFEGUARD"} },
    DEWGONG = { {1,"HEADBUTT"}, {1,"GROWL"}, {1,"AURORA_BEAM"}, {5,"GROWL"}, {16,"AURORA_BEAM"}, {21,"REST"}, {32,"TAKE_DOWN"}, {43,"ICE_BEAM"}, {60,"SAFEGUARD"} },
    GRIMER = { {1,"POISON_GAS"}, {1,"POUND"}, {5,"HARDEN"}, {10,"DISABLE"}, {16,"SLUDGE"}, {23,"MINIMIZE"}, {31,"SCREECH"}, {40,"ACID_ARMOR"}, {50,"SLUDGE_BOMB"} },
    MUK = { {1,"POISON_GAS"}, {1,"POUND"}, {1,"HARDEN"}, {33,"HARDEN"}, {37,"DISABLE"}, {45,"SLUDGE"}, {23,"MINIMIZE"}, {31,"SCREECH"}, {45,"ACID_ARMOR"}, {60,"SLUDGE_BOMB"} },
    SHELLDER = { {1,"TACKLE"}, {1,"WITHDRAW"}, {9,"SUPERSONIC"}, {17,"AURORA_BEAM"}, {25,"PROTECT"}, {33,"LEER"}, {41,"CLAMP"}, {49,"ICE_BEAM"} },
    CLOYSTER = { {1,"WITHDRAW"}, {1,"SUPERSONIC"}, {1,"AURORA_BEAM"}, {1,"PROTECT"}, {41,"SPIKE_CANNON"} },
    GASTLY = { {1,"HYPNOSIS"}, {1,"LICK"}, {8,"SPITE"}, {13,"MEAN_LOOK"}, {16,"CURSE"}, {21,"NIGHT_SHADE"}, {28,"CONFUSE_RAY"}, {33,"DREAM_EATER"}, {36,"DESTINY_BOND"} },
    HAUNTER = { {1,"HYPNOSIS"}, {1,"LICK"}, {1,"SPITE"}, {8,"SPITE"}, {13,"MEAN_LOOK"}, {16,"CURSE"}, {21,"NIGHT_SHADE"}, {31,"CONFUSE_RAY"}, {39,"DREAM_EATER"}, {48,"DESTINY_BOND"} },
    GENGAR = { {1,"HYPNOSIS"}, {1,"LICK"}, {1,"SPITE"}, {8,"SPITE"}, {13,"MEAN_LOOK"}, {16,"CURSE"}, {21,"NIGHT_SHADE"}, {31,"CONFUSE_RAY"}, {39,"DREAM_EATER"}, {48,"DESTINY_BOND"} },
    ONIX = { {1,"TACKLE"}, {1,"SCREECH"}, {10,"BIND"}, {14,"ROCK_THROW"}, {23,"HARDEN"}, {27,"RAGE"}, {36,"SANDSTORM"}, {40,"SLAM"} },
    DROWZEE = { {1,"POUND"}, {1,"HYPNOSIS"}, {10,"DISABLE"}, {18,"CONFUSION"}, {25,"HEADBUTT"}, {31,"POISON_GAS"}, {36,"MEDITATE"}, {40,"PSYCHIC_M"}, {43,"PSYCH_UP"}, {45,"FUTURE_SIGHT"} },
    HYPNO = { {1,"POUND"}, {1,"HYPNOSIS"}, {1,"DISABLE"}, {1,"CONFUSION"}, {10,"DISABLE"}, {18,"CONFUSION"}, {25,"HEADBUTT"}, {33,"POISON_GAS"}, {40,"MEDITATE"}, {49,"PSYCHIC_M"}, {55,"PSYCH_UP"}, {60,"FUTURE_SIGHT"} },
    KRABBY = { {1,"BUBBLE"}, {5,"LEER"}, {12,"VICEGRIP"}, {16,"HARDEN"}, {23,"STOMP"}, {27,"GUILLOTINE"}, {34,"PROTECT"}, {41,"CRABHAMMER"} },
    KINGLER = { {1,"BUBBLE"}, {1,"LEER"}, {1,"VICEGRIP"}, {5,"LEER"}, {12,"VICEGRIP"}, {16,"HARDEN"}, {23,"STOMP"}, {27,"GUILLOTINE"}, {38,"PROTECT"}, {49,"CRABHAMMER"} },
    VOLTORB = { {1,"TACKLE"}, {9,"SCREECH"}, {17,"SONICBOOM"}, {23,"SELFDESTRUCT"}, {29,"ROLLOUT"}, {33,"LIGHT_SCREEN"}, {37,"SWIFT"}, {39,"EXPLOSION"}, {41,"MIRROR_COAT"} },
    ELECTRODE = { {1,"TACKLE"}, {1,"SCREECH"}, {1,"SONICBOOM"}, {1,"SELFDESTRUCT"}, {9,"SCREECH"}, {17,"SONICBOOM"}, {23,"SELFDESTRUCT"}, {29,"ROLLOUT"}, {34,"LIGHT_SCREEN"}, {40,"SWIFT"}, {44,"EXPLOSION"}, {48,"MIRROR_COAT"} },
    EXEGGCUTE = { {1,"BARRAGE"}, {1,"HYPNOSIS"}, {7,"REFLECT"}, {13,"LEECH_SEED"}, {19,"CONFUSION"}, {25,"STUN_SPORE"}, {31,"POISONPOWDER"}, {37,"SLEEP_POWDER"}, {43,"SOLARBEAM"} },
    EXEGGUTOR = { {1,"BARRAGE"}, {1,"HYPNOSIS"}, {1,"CONFUSION"}, {19,"STOMP"}, {31,"EGG_BOMB"} },
    CUBONE = { {1,"GROWL"}, {5,"TAIL_WHIP"}, {9,"BONE_CLUB"}, {13,"HEADBUTT"}, {17,"LEER"}, {21,"FOCUS_ENERGY"}, {25,"BONEMERANG"}, {29,"RAGE"}, {33,"FALSE_SWIPE"}, {37,"THRASH"}, {41,"BONE_RUSH"} },
    MAROWAK = { {1,"GROWL"}, {1,"TAIL_WHIP"}, {1,"BONE_CLUB"}, {1,"HEADBUTT"}, {5,"TAIL_WHIP"}, {9,"BONE_CLUB"}, {13,"HEADBUTT"}, {17,"LEER"}, {21,"FOCUS_ENERGY"}, {25,"BONEMERANG"}, {32,"RAGE"}, {39,"FALSE_SWIPE"}, {46,"THRASH"}, {53,"BONE_RUSH"} },
    HITMONLEE = { {1,"DOUBLE_KICK"}, {6,"MEDITATE"}, {11,"ROLLING_KICK"}, {16,"JUMP_KICK"}, {21,"FOCUS_ENERGY"}, {26,"HI_JUMP_KICK"}, {31,"MIND_READER"}, {36,"FORESIGHT"}, {41,"ENDURE"}, {46,"MEGA_KICK"}, {51,"REVERSAL"} },
    HITMONCHAN = { {1,"COMET_PUNCH"}, {7,"AGILITY"}, {13,"PURSUIT"}, {26,"THUNDERPUNCH"}, {26,"ICE_PUNCH"}, {26,"FIRE_PUNCH"}, {32,"MACH_PUNCH"}, {38,"MEGA_PUNCH"}, {44,"DETECT"}, {50,"COUNTER"} },
    LICKITUNG = { {1,"LICK"}, {7,"SUPERSONIC"}, {13,"DEFENSE_CURL"}, {19,"STOMP"}, {25,"WRAP"}, {31,"DISABLE"}, {37,"SLAM"}, {43,"SCREECH"} },
    KOFFING = { {1,"POISON_GAS"}, {1,"TACKLE"}, {9,"SMOG"}, {17,"SELFDESTRUCT"}, {21,"SLUDGE"}, {25,"SMOKESCREEN"}, {33,"HAZE"}, {41,"EXPLOSION"}, {45,"DESTINY_BOND"} },
    WEEZING = { {1,"POISON_GAS"}, {1,"TACKLE"}, {1,"SMOG"}, {1,"SELFDESTRUCT"}, {9,"SMOG"}, {17,"SELFDESTRUCT"}, {21,"SLUDGE"}, {25,"SMOKESCREEN"}, {33,"HAZE"}, {44,"EXPLOSION"}, {51,"DESTINY_BOND"} },
    RHYHORN = { {1,"HORN_ATTACK"}, {1,"TAIL_WHIP"}, {13,"STOMP"}, {19,"FURY_ATTACK"}, {31,"SCARY_FACE"}, {37,"HORN_DRILL"}, {49,"TAKE_DOWN"}, {55,"EARTHQUAKE"} },
    RHYDON = { {1,"HORN_ATTACK"}, {1,"TAIL_WHIP"}, {1,"STOMP"}, {1,"FURY_ATTACK"}, {13,"STOMP"}, {19,"FURY_ATTACK"}, {31,"SCARY_FACE"}, {37,"HORN_DRILL"}, {54,"TAKE_DOWN"}, {65,"EARTHQUAKE"} },
    CHANSEY = { {1,"POUND"}, {5,"GROWL"}, {9,"TAIL_WHIP"}, {13,"SOFTBOILED"}, {17,"DOUBLESLAP"}, {23,"MINIMIZE"}, {29,"SING"}, {35,"EGG_BOMB"}, {41,"DEFENSE_CURL"}, {49,"LIGHT_SCREEN"}, {57,"DOUBLE_EDGE"} },
    TANGELA = { {1,"CONSTRICT"}, {4,"SLEEP_POWDER"}, {10,"ABSORB"}, {13,"POISONPOWDER"}, {19,"VINE_WHIP"}, {25,"BIND"}, {31,"MEGA_DRAIN"}, {34,"STUN_SPORE"}, {40,"SLAM"}, {46,"GROWTH"} },
    KANGASKHAN = { {1,"COMET_PUNCH"}, {7,"LEER"}, {13,"BITE"}, {19,"TAIL_WHIP"}, {25,"MEGA_PUNCH"}, {31,"RAGE"}, {37,"ENDURE"}, {43,"DIZZY_PUNCH"}, {49,"REVERSAL"} },
    HORSEA = { {1,"BUBBLE"}, {8,"SMOKESCREEN"}, {15,"LEER"}, {22,"WATER_GUN"}, {29,"TWISTER"}, {36,"AGILITY"}, {43,"HYDRO_PUMP"} },
    SEADRA = { {1,"BUBBLE"}, {1,"SMOKESCREEN"}, {1,"LEER"}, {1,"WATER_GUN"}, {8,"SMOKESCREEN"}, {15,"LEER"}, {22,"WATER_GUN"}, {29,"TWISTER"}, {40,"AGILITY"}, {51,"HYDRO_PUMP"} },
    GOLDEEN = { {1,"PECK"}, {1,"TAIL_WHIP"}, {10,"SUPERSONIC"}, {15,"HORN_ATTACK"}, {24,"FLAIL"}, {29,"FURY_ATTACK"}, {38,"WATERFALL"}, {43,"HORN_DRILL"}, {52,"AGILITY"} },
    SEAKING = { {1,"PECK"}, {1,"TAIL_WHIP"}, {1,"TAIL_WHIP"}, {10,"SUPERSONIC"}, {15,"HORN_ATTACK"}, {24,"FLAIL"}, {29,"FURY_ATTACK"}, {41,"WATERFALL"}, {49,"HORN_DRILL"}, {61,"AGILITY"} },
    STARYU = { {1,"TACKLE"}, {1,"HARDEN"}, {7,"WATER_GUN"}, {13,"RAPID_SPIN"}, {19,"RECOVER"}, {25,"SWIFT"}, {31,"BUBBLEBEAM"}, {37,"MINIMIZE"}, {43,"LIGHT_SCREEN"}, {50,"HYDRO_PUMP"} },
    STARMIE = { {1,"TACKLE"}, {1,"RAPID_SPIN"}, {1,"RECOVER"}, {1,"BUBBLEBEAM"}, {37,"CONFUSE_RAY"} },
    MR__MIME = { {1,"BARRIER"}, {6,"CONFUSION"}, {11,"SUBSTITUTE"}, {16,"MEDITATE"}, {21,"DOUBLESLAP"}, {26,"LIGHT_SCREEN"}, {26,"REFLECT"}, {31,"ENCORE"}, {36,"PSYBEAM"}, {41,"BATON_PASS"}, {46,"SAFEGUARD"} },
    SCYTHER = { {1,"QUICK_ATTACK"}, {1,"LEER"}, {6,"FOCUS_ENERGY"}, {12,"PURSUIT"}, {18,"FALSE_SWIPE"}, {24,"AGILITY"}, {30,"WING_ATTACK"}, {36,"SLASH"}, {42,"SWORDS_DANCE"}, {48,"DOUBLE_TEAM"} },
    JYNX = { {1,"POUND"}, {1,"LICK"}, {1,"LOVELY_KISS"}, {1,"POWDER_SNOW"}, {9,"LOVELY_KISS"}, {13,"POWDER_SNOW"}, {21,"DOUBLESLAP"}, {25,"ICE_PUNCH"}, {35,"MEAN_LOOK"}, {41,"BODY_SLAM"}, {51,"PERISH_SONG"}, {57,"BLIZZARD"} },
    ELECTABUZZ = { {1,"QUICK_ATTACK"}, {1,"LEER"}, {1,"THUNDERPUNCH"}, {9,"THUNDERPUNCH"}, {17,"LIGHT_SCREEN"}, {25,"SWIFT"}, {36,"SCREECH"}, {47,"THUNDERBOLT"}, {58,"THUNDER"} },
    MAGMAR = { {1,"EMBER"}, {1,"LEER"}, {1,"SMOG"}, {1,"FIRE_PUNCH"}, {7,"LEER"}, {13,"SMOG"}, {19,"FIRE_PUNCH"}, {25,"SMOKESCREEN"}, {33,"SUNNY_DAY"}, {41,"FLAMETHROWER"}, {49,"CONFUSE_RAY"}, {57,"FIRE_BLAST"} },
    PINSIR = { {1,"VICEGRIP"}, {7,"FOCUS_ENERGY"}, {13,"BIND"}, {19,"SEISMIC_TOSS"}, {25,"HARDEN"}, {31,"GUILLOTINE"}, {37,"SUBMISSION"}, {43,"SWORDS_DANCE"} },
    TAUROS = { {1,"TACKLE"}, {4,"TAIL_WHIP"}, {8,"RAGE"}, {13,"HORN_ATTACK"}, {19,"SCARY_FACE"}, {26,"PURSUIT"}, {34,"REST"}, {43,"THRASH"}, {53,"TAKE_DOWN"} },
    MAGIKARP = { {1,"SPLASH"}, {15,"TACKLE"}, {30,"FLAIL"} },
    GYARADOS = { {1,"THRASH"}, {20,"BITE"}, {25,"DRAGON_RAGE"}, {30,"LEER"}, {35,"TWISTER"}, {40,"HYDRO_PUMP"}, {45,"RAIN_DANCE"}, {50,"HYPER_BEAM"} },
    LAPRAS = { {1,"WATER_GUN"}, {1,"GROWL"}, {1,"SING"}, {8,"MIST"}, {15,"BODY_SLAM"}, {22,"CONFUSE_RAY"}, {29,"PERISH_SONG"}, {36,"ICE_BEAM"}, {43,"RAIN_DANCE"}, {50,"SAFEGUARD"}, {57,"HYDRO_PUMP"} },
    DITTO = { {1,"TRANSFORM"} },
    EEVEE = { {1,"TACKLE"}, {1,"TAIL_WHIP"}, {8,"SAND_ATTACK"}, {16,"GROWL"}, {23,"QUICK_ATTACK"}, {30,"BITE"}, {36,"FOCUS_ENERGY"}, {42,"TAKE_DOWN"} },
    VAPOREON = { {1,"TACKLE"}, {1,"TAIL_WHIP"}, {8,"SAND_ATTACK"}, {16,"WATER_GUN"}, {23,"QUICK_ATTACK"}, {30,"BITE"}, {36,"AURORA_BEAM"}, {42,"HAZE"}, {47,"ACID_ARMOR"}, {52,"HYDRO_PUMP"} },
    JOLTEON = { {1,"TACKLE"}, {1,"TAIL_WHIP"}, {8,"SAND_ATTACK"}, {16,"THUNDERSHOCK"}, {23,"QUICK_ATTACK"}, {30,"DOUBLE_KICK"}, {36,"PIN_MISSILE"}, {42,"THUNDER_WAVE"}, {47,"AGILITY"}, {52,"THUNDER"} },
    FLAREON = { {1,"TACKLE"}, {1,"TAIL_WHIP"}, {8,"SAND_ATTACK"}, {16,"EMBER"}, {23,"QUICK_ATTACK"}, {30,"BITE"}, {36,"FIRE_SPIN"}, {42,"SMOG"}, {47,"LEER"}, {52,"FLAMETHROWER"} },
    PORYGON = { {1,"CONVERSION2"}, {1,"TACKLE"}, {1,"CONVERSION"}, {9,"AGILITY"}, {12,"PSYBEAM"}, {20,"RECOVER"}, {24,"SHARPEN"}, {32,"LOCK_ON"}, {36,"TRI_ATTACK"}, {44,"ZAP_CANNON"} },
    OMANYTE = { {1,"CONSTRICT"}, {1,"WITHDRAW"}, {13,"BITE"}, {19,"WATER_GUN"}, {31,"LEER"}, {37,"PROTECT"}, {49,"ANCIENTPOWER"}, {55,"HYDRO_PUMP"} },
    OMASTAR = { {1,"CONSTRICT"}, {1,"WITHDRAW"}, {1,"BITE"}, {13,"BITE"}, {19,"WATER_GUN"}, {31,"LEER"}, {37,"PROTECT"}, {40,"SPIKE_CANNON"}, {54,"ANCIENTPOWER"}, {65,"HYDRO_PUMP"} },
    KABUTO = { {1,"SCRATCH"}, {1,"HARDEN"}, {10,"ABSORB"}, {19,"LEER"}, {28,"SAND_ATTACK"}, {37,"ENDURE"}, {46,"MEGA_DRAIN"}, {55,"ANCIENTPOWER"} },
    KABUTOPS = { {1,"SCRATCH"}, {1,"HARDEN"}, {1,"ABSORB"}, {10,"ABSORB"}, {19,"LEER"}, {28,"SAND_ATTACK"}, {37,"ENDURE"}, {40,"SLASH"}, {51,"MEGA_DRAIN"}, {65,"ANCIENTPOWER"} },
    AERODACTYL = { {1,"WING_ATTACK"}, {8,"AGILITY"}, {15,"BITE"}, {22,"SUPERSONIC"}, {29,"ANCIENTPOWER"}, {36,"SCARY_FACE"}, {43,"TAKE_DOWN"}, {50,"HYPER_BEAM"} },
    SNORLAX = { {1,"TACKLE"}, {8,"AMNESIA"}, {15,"DEFENSE_CURL"}, {22,"BELLY_DRUM"}, {29,"HEADBUTT"}, {36,"SNORE"}, {36,"REST"}, {43,"BODY_SLAM"}, {50,"ROLLOUT"}, {57,"HYPER_BEAM"} },
    ARTICUNO = { {1,"GUST"}, {1,"POWDER_SNOW"}, {13,"MIST"}, {25,"AGILITY"}, {37,"MIND_READER"}, {49,"ICE_BEAM"}, {61,"REFLECT"}, {73,"BLIZZARD"} },
    ZAPDOS = { {1,"PECK"}, {1,"THUNDERSHOCK"}, {13,"THUNDER_WAVE"}, {25,"AGILITY"}, {37,"DETECT"}, {49,"DRILL_PECK"}, {61,"LIGHT_SCREEN"}, {73,"THUNDER"} },
    MOLTRES = { {1,"WING_ATTACK"}, {1,"EMBER"}, {13,"FIRE_SPIN"}, {25,"AGILITY"}, {37,"ENDURE"}, {49,"FLAMETHROWER"}, {61,"SAFEGUARD"}, {73,"SKY_ATTACK"} },
    DRATINI = { {1,"WRAP"}, {1,"LEER"}, {8,"THUNDER_WAVE"}, {15,"TWISTER"}, {22,"DRAGON_RAGE"}, {29,"SLAM"}, {36,"AGILITY"}, {43,"SAFEGUARD"}, {50,"OUTRAGE"}, {57,"HYPER_BEAM"} },
    DRAGONAIR = { {1,"WRAP"}, {1,"LEER"}, {1,"THUNDER_WAVE"}, {1,"TWISTER"}, {8,"THUNDER_WAVE"}, {15,"TWISTER"}, {22,"DRAGON_RAGE"}, {29,"SLAM"}, {38,"AGILITY"}, {47,"SAFEGUARD"}, {56,"OUTRAGE"}, {65,"HYPER_BEAM"} },
    DRAGONITE = { {1,"WRAP"}, {1,"LEER"}, {1,"THUNDER_WAVE"}, {1,"TWISTER"}, {8,"THUNDER_WAVE"}, {15,"TWISTER"}, {22,"DRAGON_RAGE"}, {29,"SLAM"}, {38,"AGILITY"}, {47,"SAFEGUARD"}, {55,"WING_ATTACK"}, {61,"OUTRAGE"}, {75,"HYPER_BEAM"} },
    MEWTWO = { {1,"CONFUSION"}, {1,"DISABLE"}, {11,"BARRIER"}, {22,"SWIFT"}, {33,"PSYCH_UP"}, {44,"FUTURE_SIGHT"}, {55,"MIST"}, {66,"PSYCHIC_M"}, {77,"AMNESIA"}, {88,"RECOVER"}, {99,"SAFEGUARD"} },
    MEW = { {1,"POUND"}, {10,"TRANSFORM"}, {20,"MEGA_PUNCH"}, {30,"METRONOME"}, {40,"PSYCHIC_M"}, {50,"ANCIENTPOWER"} },
    CHIKORITA = { {1,"TACKLE"}, {1,"GROWL"}, {8,"RAZOR_LEAF"}, {12,"REFLECT"}, {15,"POISONPOWDER"}, {22,"SYNTHESIS"}, {29,"BODY_SLAM"}, {36,"LIGHT_SCREEN"}, {43,"SAFEGUARD"}, {50,"SOLARBEAM"} },
    BAYLEEF = { {1,"TACKLE"}, {1,"GROWL"}, {1,"RAZOR_LEAF"}, {1,"REFLECT"}, {8,"RAZOR_LEAF"}, {12,"REFLECT"}, {15,"POISONPOWDER"}, {23,"SYNTHESIS"}, {31,"BODY_SLAM"}, {39,"LIGHT_SCREEN"}, {47,"SAFEGUARD"}, {55,"SOLARBEAM"} },
    MEGANIUM = { {1,"TACKLE"}, {1,"GROWL"}, {1,"RAZOR_LEAF"}, {1,"REFLECT"}, {8,"RAZOR_LEAF"}, {12,"REFLECT"}, {15,"POISONPOWDER"}, {23,"SYNTHESIS"}, {31,"BODY_SLAM"}, {41,"LIGHT_SCREEN"}, {51,"SAFEGUARD"}, {61,"SOLARBEAM"} },
    CYNDAQUIL = { {1,"TACKLE"}, {1,"LEER"}, {6,"SMOKESCREEN"}, {12,"EMBER"}, {19,"QUICK_ATTACK"}, {27,"FLAME_WHEEL"}, {36,"SWIFT"}, {46,"FLAMETHROWER"} },
    QUILAVA = { {1,"TACKLE"}, {1,"LEER"}, {1,"SMOKESCREEN"}, {6,"SMOKESCREEN"}, {12,"EMBER"}, {21,"QUICK_ATTACK"}, {31,"FLAME_WHEEL"}, {42,"SWIFT"}, {54,"FLAMETHROWER"} },
    TYPHLOSION = { {1,"TACKLE"}, {1,"LEER"}, {1,"SMOKESCREEN"}, {1,"EMBER"}, {6,"SMOKESCREEN"}, {12,"EMBER"}, {21,"QUICK_ATTACK"}, {31,"FLAME_WHEEL"}, {45,"SWIFT"}, {60,"FLAMETHROWER"} },
    TOTODILE = { {1,"SCRATCH"}, {1,"LEER"}, {7,"RAGE"}, {13,"WATER_GUN"}, {20,"BITE"}, {27,"SCARY_FACE"}, {35,"SLASH"}, {43,"SCREECH"}, {52,"HYDRO_PUMP"} },
    CROCONAW = { {1,"SCRATCH"}, {1,"LEER"}, {1,"RAGE"}, {7,"RAGE"}, {13,"WATER_GUN"}, {21,"BITE"}, {28,"SCARY_FACE"}, {37,"SLASH"}, {45,"SCREECH"}, {55,"HYDRO_PUMP"} },
    FERALIGATR = { {1,"SCRATCH"}, {1,"LEER"}, {1,"RAGE"}, {1,"WATER_GUN"}, {7,"RAGE"}, {13,"WATER_GUN"}, {21,"BITE"}, {28,"SCARY_FACE"}, {38,"SLASH"}, {47,"SCREECH"}, {58,"HYDRO_PUMP"} },
    SENTRET = { {1,"TACKLE"}, {5,"DEFENSE_CURL"}, {11,"QUICK_ATTACK"}, {17,"FURY_SWIPES"}, {25,"SLAM"}, {33,"REST"}, {41,"AMNESIA"} },
    FURRET = { {1,"SCRATCH"}, {1,"DEFENSE_CURL"}, {1,"QUICK_ATTACK"}, {5,"DEFENSE_CURL"}, {11,"QUICK_ATTACK"}, {18,"FURY_SWIPES"}, {28,"SLAM"}, {38,"REST"}, {48,"AMNESIA"} },
    HOOTHOOT = { {1,"TACKLE"}, {1,"GROWL"}, {6,"FORESIGHT"}, {11,"PECK"}, {16,"HYPNOSIS"}, {22,"REFLECT"}, {28,"TAKE_DOWN"}, {34,"CONFUSION"}, {48,"DREAM_EATER"} },
    NOCTOWL = { {1,"TACKLE"}, {1,"GROWL"}, {1,"FORESIGHT"}, {1,"PECK"}, {6,"FORESIGHT"}, {11,"PECK"}, {16,"HYPNOSIS"}, {25,"REFLECT"}, {33,"TAKE_DOWN"}, {41,"CONFUSION"}, {57,"DREAM_EATER"} },
    LEDYBA = { {1,"TACKLE"}, {8,"SUPERSONIC"}, {15,"COMET_PUNCH"}, {22,"LIGHT_SCREEN"}, {22,"REFLECT"}, {22,"SAFEGUARD"}, {29,"BATON_PASS"}, {36,"SWIFT"}, {43,"AGILITY"}, {50,"DOUBLE_EDGE"} },
    LEDIAN = { {1,"TACKLE"}, {1,"SUPERSONIC"}, {8,"SUPERSONIC"}, {15,"COMET_PUNCH"}, {24,"LIGHT_SCREEN"}, {24,"REFLECT"}, {24,"SAFEGUARD"}, {33,"BATON_PASS"}, {42,"SWIFT"}, {51,"AGILITY"}, {60,"DOUBLE_EDGE"} },
    SPINARAK = { {1,"POISON_STING"}, {1,"STRING_SHOT"}, {6,"SCARY_FACE"}, {11,"CONSTRICT"}, {17,"NIGHT_SHADE"}, {23,"LEECH_LIFE"}, {30,"FURY_SWIPES"}, {37,"SPIDER_WEB"}, {45,"SCREECH"}, {53,"PSYCHIC_M"} },
    ARIADOS = { {1,"POISON_STING"}, {1,"STRING_SHOT"}, {1,"SCARY_FACE"}, {1,"CONSTRICT"}, {6,"SCARY_FACE"}, {11,"CONSTRICT"}, {17,"NIGHT_SHADE"}, {25,"LEECH_LIFE"}, {34,"FURY_SWIPES"}, {43,"SPIDER_WEB"}, {53,"SCREECH"}, {63,"PSYCHIC_M"} },
    CROBAT = { {1,"SCREECH"}, {1,"LEECH_LIFE"}, {1,"SUPERSONIC"}, {6,"SUPERSONIC"}, {12,"BITE"}, {19,"CONFUSE_RAY"}, {30,"WING_ATTACK"}, {42,"MEAN_LOOK"}, {55,"HAZE"} },
    CHINCHOU = { {1,"BUBBLE"}, {1,"THUNDER_WAVE"}, {5,"SUPERSONIC"}, {13,"FLAIL"}, {17,"WATER_GUN"}, {25,"SPARK"}, {29,"CONFUSE_RAY"}, {37,"TAKE_DOWN"}, {41,"HYDRO_PUMP"} },
    LANTURN = { {1,"BUBBLE"}, {1,"THUNDER_WAVE"}, {1,"SUPERSONIC"}, {5,"SUPERSONIC"}, {13,"FLAIL"}, {17,"WATER_GUN"}, {25,"SPARK"}, {33,"CONFUSE_RAY"}, {45,"TAKE_DOWN"}, {53,"HYDRO_PUMP"} },
    PICHU = { {1,"THUNDERSHOCK"}, {1,"CHARM"}, {6,"TAIL_WHIP"}, {8,"THUNDER_WAVE"}, {11,"SWEET_KISS"} },
    CLEFFA = { {1,"POUND"}, {1,"CHARM"}, {4,"ENCORE"}, {8,"SING"}, {13,"SWEET_KISS"} },
    IGGLYBUFF = { {1,"SING"}, {1,"CHARM"}, {4,"DEFENSE_CURL"}, {9,"POUND"}, {14,"SWEET_KISS"} },
    TOGEPI = { {1,"GROWL"}, {1,"CHARM"}, {7,"METRONOME"}, {18,"SWEET_KISS"}, {25,"ENCORE"}, {31,"SAFEGUARD"}, {38,"DOUBLE_EDGE"} },
    TOGETIC = { {1,"GROWL"}, {1,"CHARM"}, {7,"METRONOME"}, {18,"SWEET_KISS"}, {25,"ENCORE"}, {31,"SAFEGUARD"}, {38,"DOUBLE_EDGE"} },
    NATU = { {1,"PECK"}, {1,"LEER"}, {10,"NIGHT_SHADE"}, {20,"TELEPORT"}, {30,"FUTURE_SIGHT"}, {40,"CONFUSE_RAY"}, {50,"PSYCHIC_M"} },
    XATU = { {1,"PECK"}, {1,"LEER"}, {1,"NIGHT_SHADE"}, {10,"NIGHT_SHADE"}, {20,"TELEPORT"}, {35,"FUTURE_SIGHT"}, {50,"CONFUSE_RAY"}, {65,"PSYCHIC_M"} },
    MAREEP = { {1,"TACKLE"}, {1,"GROWL"}, {9,"THUNDERSHOCK"}, {16,"THUNDER_WAVE"}, {23,"COTTON_SPORE"}, {30,"LIGHT_SCREEN"}, {37,"THUNDER"} },
    FLAAFFY = { {1,"TACKLE"}, {1,"GROWL"}, {1,"THUNDERSHOCK"}, {9,"THUNDERSHOCK"}, {18,"THUNDER_WAVE"}, {27,"COTTON_SPORE"}, {36,"LIGHT_SCREEN"}, {45,"THUNDER"} },
    AMPHAROS = { {1,"TACKLE"}, {1,"GROWL"}, {1,"THUNDERSHOCK"}, {1,"THUNDER_WAVE"}, {9,"THUNDERSHOCK"}, {18,"THUNDER_WAVE"}, {27,"COTTON_SPORE"}, {30,"THUNDERPUNCH"}, {42,"LIGHT_SCREEN"}, {57,"THUNDER"} },
    BELLOSSOM = { {1,"ABSORB"}, {1,"SWEET_SCENT"}, {1,"STUN_SPORE"}, {1,"PETAL_DANCE"}, {55,"SOLARBEAM"} },
    MARILL = { {1,"TACKLE"}, {3,"DEFENSE_CURL"}, {6,"TAIL_WHIP"}, {10,"WATER_GUN"}, {15,"ROLLOUT"}, {21,"BUBBLEBEAM"}, {28,"DOUBLE_EDGE"}, {36,"RAIN_DANCE"} },
    AZUMARILL = { {1,"TACKLE"}, {1,"DEFENSE_CURL"}, {1,"TAIL_WHIP"}, {1,"WATER_GUN"}, {3,"DEFENSE_CURL"}, {6,"TAIL_WHIP"}, {10,"WATER_GUN"}, {15,"ROLLOUT"}, {25,"BUBBLEBEAM"}, {36,"DOUBLE_EDGE"}, {48,"RAIN_DANCE"} },
    SUDOWOODO = { {1,"ROCK_THROW"}, {1,"MIMIC"}, {10,"FLAIL"}, {19,"LOW_KICK"}, {28,"ROCK_SLIDE"}, {37,"FAINT_ATTACK"}, {46,"SLAM"} },
    POLITOED = { {1,"WATER_GUN"}, {1,"HYPNOSIS"}, {1,"DOUBLESLAP"}, {1,"PERISH_SONG"}, {35,"PERISH_SONG"}, {51,"SWAGGER"} },
    HOPPIP = { {1,"SPLASH"}, {1,"SYNTHESIS"}, {5,"TAIL_WHIP"}, {10,"TACKLE"}, {13,"POISONPOWDER"}, {15,"STUN_SPORE"}, {17,"SLEEP_POWDER"}, {20,"LEECH_SEED"}, {25,"COTTON_SPORE"}, {30,"MEGA_DRAIN"} },
    SKIPLOOM = { {1,"SPLASH"}, {1,"SYNTHESIS"}, {1,"TAIL_WHIP"}, {1,"TACKLE"}, {5,"TAIL_WHIP"}, {10,"TACKLE"}, {13,"POISONPOWDER"}, {15,"STUN_SPORE"}, {17,"SLEEP_POWDER"}, {22,"LEECH_SEED"}, {29,"COTTON_SPORE"}, {36,"MEGA_DRAIN"} },
    JUMPLUFF = { {1,"SPLASH"}, {1,"SYNTHESIS"}, {1,"TAIL_WHIP"}, {1,"TACKLE"}, {5,"TAIL_WHIP"}, {10,"TACKLE"}, {13,"POISONPOWDER"}, {15,"STUN_SPORE"}, {17,"SLEEP_POWDER"}, {22,"LEECH_SEED"}, {33,"COTTON_SPORE"}, {44,"MEGA_DRAIN"} },
    AIPOM = { {1,"SCRATCH"}, {1,"TAIL_WHIP"}, {6,"SAND_ATTACK"}, {12,"BATON_PASS"}, {19,"FURY_SWIPES"}, {27,"SWIFT"}, {36,"SCREECH"}, {46,"AGILITY"} },
    SUNKERN = { {1,"ABSORB"}, {4,"GROWTH"}, {10,"MEGA_DRAIN"}, {19,"SUNNY_DAY"}, {31,"SYNTHESIS"}, {46,"GIGA_DRAIN"} },
    SUNFLORA = { {1,"ABSORB"}, {1,"POUND"}, {4,"GROWTH"}, {10,"RAZOR_LEAF"}, {19,"SUNNY_DAY"}, {31,"PETAL_DANCE"}, {46,"SOLARBEAM"} },
    YANMA = { {1,"TACKLE"}, {1,"FORESIGHT"}, {7,"QUICK_ATTACK"}, {13,"DOUBLE_TEAM"}, {19,"SONICBOOM"}, {25,"DETECT"}, {31,"SUPERSONIC"}, {37,"SWIFT"}, {43,"SCREECH"} },
    WOOPER = { {1,"WATER_GUN"}, {1,"TAIL_WHIP"}, {11,"SLAM"}, {21,"AMNESIA"}, {31,"EARTHQUAKE"}, {41,"RAIN_DANCE"}, {51,"MIST"}, {51,"HAZE"} },
    QUAGSIRE = { {1,"WATER_GUN"}, {1,"TAIL_WHIP"}, {11,"SLAM"}, {23,"AMNESIA"}, {35,"EARTHQUAKE"}, {47,"RAIN_DANCE"}, {59,"MIST"}, {59,"HAZE"} },
    ESPEON = { {1,"TACKLE"}, {1,"TAIL_WHIP"}, {8,"SAND_ATTACK"}, {16,"CONFUSION"}, {23,"QUICK_ATTACK"}, {30,"SWIFT"}, {36,"PSYBEAM"}, {42,"PSYCH_UP"}, {47,"PSYCHIC_M"}, {52,"MORNING_SUN"} },
    UMBREON = { {1,"TACKLE"}, {1,"TAIL_WHIP"}, {8,"SAND_ATTACK"}, {16,"PURSUIT"}, {23,"QUICK_ATTACK"}, {30,"CONFUSE_RAY"}, {36,"FAINT_ATTACK"}, {42,"MEAN_LOOK"}, {47,"SCREECH"}, {52,"MOONLIGHT"} },
    MURKROW = { {1,"PECK"}, {11,"PURSUIT"}, {16,"HAZE"}, {26,"NIGHT_SHADE"}, {31,"FAINT_ATTACK"}, {41,"MEAN_LOOK"} },
    SLOWKING = { {1,"CURSE"}, {1,"TACKLE"}, {6,"GROWL"}, {15,"WATER_GUN"}, {20,"CONFUSION"}, {29,"DISABLE"}, {34,"HEADBUTT"}, {43,"SWAGGER"}, {48,"PSYCHIC_M"} },
    MISDREAVUS = { {1,"GROWL"}, {1,"PSYWAVE"}, {6,"SPITE"}, {12,"CONFUSE_RAY"}, {19,"MEAN_LOOK"}, {27,"PSYBEAM"}, {36,"PAIN_SPLIT"}, {46,"PERISH_SONG"} },
    UNOWN = { {1,"HIDDEN_POWER"} },
    WOBBUFFET = { {1,"COUNTER"}, {1,"MIRROR_COAT"}, {1,"SAFEGUARD"}, {1,"DESTINY_BOND"} },
    GIRAFARIG = { {1,"TACKLE"}, {1,"GROWL"}, {1,"CONFUSION"}, {1,"STOMP"}, {7,"CONFUSION"}, {13,"STOMP"}, {20,"AGILITY"}, {30,"BATON_PASS"}, {41,"PSYBEAM"}, {54,"CRUNCH"} },
    PINECO = { {1,"TACKLE"}, {1,"PROTECT"}, {8,"SELFDESTRUCT"}, {15,"TAKE_DOWN"}, {22,"RAPID_SPIN"}, {29,"BIDE"}, {36,"EXPLOSION"}, {43,"SPIKES"}, {50,"DOUBLE_EDGE"} },
    FORRETRESS = { {1,"TACKLE"}, {1,"PROTECT"}, {1,"SELFDESTRUCT"}, {8,"SELFDESTRUCT"}, {15,"TAKE_DOWN"}, {22,"RAPID_SPIN"}, {29,"BIDE"}, {39,"EXPLOSION"}, {49,"SPIKES"}, {59,"DOUBLE_EDGE"} },
    DUNSPARCE = { {1,"RAGE"}, {5,"DEFENSE_CURL"}, {13,"GLARE"}, {18,"SPITE"}, {26,"PURSUIT"}, {30,"SCREECH"}, {38,"TAKE_DOWN"} },
    GLIGAR = { {1,"POISON_STING"}, {6,"SAND_ATTACK"}, {13,"HARDEN"}, {20,"QUICK_ATTACK"}, {28,"FAINT_ATTACK"}, {36,"SLASH"}, {44,"SCREECH"}, {52,"GUILLOTINE"} },
    STEELIX = { {1,"TACKLE"}, {1,"SCREECH"}, {10,"BIND"}, {14,"ROCK_THROW"}, {23,"HARDEN"}, {27,"RAGE"}, {36,"SANDSTORM"}, {40,"SLAM"}, {49,"CRUNCH"} },
    SNUBBULL = { {1,"TACKLE"}, {1,"SCARY_FACE"}, {4,"TAIL_WHIP"}, {8,"CHARM"}, {13,"BITE"}, {19,"LICK"}, {26,"ROAR"}, {34,"RAGE"}, {43,"TAKE_DOWN"} },
    GRANBULL = { {1,"TACKLE"}, {1,"SCARY_FACE"}, {4,"TAIL_WHIP"}, {8,"CHARM"}, {13,"BITE"}, {19,"LICK"}, {28,"ROAR"}, {38,"RAGE"}, {51,"TAKE_DOWN"} },
    QWILFISH = { {1,"TACKLE"}, {1,"POISON_STING"}, {10,"HARDEN"}, {10,"MINIMIZE"}, {19,"WATER_GUN"}, {28,"PIN_MISSILE"}, {37,"TAKE_DOWN"}, {46,"HYDRO_PUMP"} },
    SCIZOR = { {1,"QUICK_ATTACK"}, {1,"LEER"}, {6,"FOCUS_ENERGY"}, {12,"PURSUIT"}, {18,"FALSE_SWIPE"}, {24,"AGILITY"}, {30,"METAL_CLAW"}, {36,"SLASH"}, {42,"SWORDS_DANCE"}, {48,"DOUBLE_TEAM"} },
    SHUCKLE = { {1,"CONSTRICT"}, {1,"WITHDRAW"}, {9,"WRAP"}, {14,"ENCORE"}, {23,"SAFEGUARD"}, {28,"BIDE"}, {37,"REST"} },
    HERACROSS = { {1,"TACKLE"}, {1,"LEER"}, {6,"HORN_ATTACK"}, {12,"ENDURE"}, {19,"FURY_ATTACK"}, {27,"COUNTER"}, {35,"TAKE_DOWN"}, {44,"REVERSAL"}, {54,"MEGAHORN"} },
    SNEASEL = { {1,"SCRATCH"}, {1,"LEER"}, {9,"QUICK_ATTACK"}, {17,"SCREECH"}, {25,"FAINT_ATTACK"}, {33,"FURY_SWIPES"}, {41,"AGILITY"}, {49,"SLASH"}, {57,"BEAT_UP"} },
    TEDDIURSA = { {1,"SCRATCH"}, {1,"LEER"}, {8,"LICK"}, {15,"FURY_SWIPES"}, {22,"FAINT_ATTACK"}, {29,"REST"}, {36,"SLASH"}, {43,"SNORE"}, {50,"THRASH"} },
    URSARING = { {1,"SCRATCH"}, {1,"LEER"}, {1,"LICK"}, {1,"FURY_SWIPES"}, {8,"LICK"}, {15,"FURY_SWIPES"}, {22,"FAINT_ATTACK"}, {29,"REST"}, {39,"SLASH"}, {49,"SNORE"}, {59,"THRASH"} },
    SLUGMA = { {1,"SMOG"}, {8,"EMBER"}, {15,"ROCK_THROW"}, {22,"HARDEN"}, {29,"AMNESIA"}, {36,"FLAMETHROWER"}, {43,"ROCK_SLIDE"}, {50,"BODY_SLAM"} },
    MAGCARGO = { {1,"SMOG"}, {1,"EMBER"}, {1,"ROCK_THROW"}, {8,"EMBER"}, {15,"ROCK_THROW"}, {22,"HARDEN"}, {29,"AMNESIA"}, {36,"FLAMETHROWER"}, {48,"ROCK_SLIDE"}, {60,"BODY_SLAM"} },
    SWINUB = { {1,"TACKLE"}, {10,"POWDER_SNOW"}, {19,"ENDURE"}, {28,"TAKE_DOWN"}, {37,"MIST"}, {46,"BLIZZARD"} },
    PILOSWINE = { {1,"HORN_ATTACK"}, {1,"POWDER_SNOW"}, {1,"ENDURE"}, {10,"POWDER_SNOW"}, {19,"ENDURE"}, {28,"TAKE_DOWN"}, {33,"FURY_ATTACK"}, {42,"MIST"}, {56,"BLIZZARD"} },
    CORSOLA = { {1,"TACKLE"}, {7,"HARDEN"}, {13,"BUBBLE"}, {19,"RECOVER"}, {25,"BUBBLEBEAM"}, {31,"SPIKE_CANNON"}, {37,"MIRROR_COAT"}, {43,"ANCIENTPOWER"} },
    REMORAID = { {1,"WATER_GUN"}, {11,"LOCK_ON"}, {22,"PSYBEAM"}, {22,"AURORA_BEAM"}, {22,"BUBBLEBEAM"}, {33,"FOCUS_ENERGY"}, {44,"ICE_BEAM"}, {55,"HYPER_BEAM"} },
    OCTILLERY = { {1,"WATER_GUN"}, {11,"CONSTRICT"}, {22,"PSYBEAM"}, {22,"AURORA_BEAM"}, {22,"BUBBLEBEAM"}, {25,"OCTAZOOKA"}, {38,"FOCUS_ENERGY"}, {54,"ICE_BEAM"}, {70,"HYPER_BEAM"} },
    DELIBIRD = { {1,"PRESENT"} },
    MANTINE = { {1,"TACKLE"}, {1,"BUBBLE"}, {10,"SUPERSONIC"}, {18,"BUBBLEBEAM"}, {25,"TAKE_DOWN"}, {32,"AGILITY"}, {40,"WING_ATTACK"}, {49,"CONFUSE_RAY"} },
    SKARMORY = { {1,"LEER"}, {1,"PECK"}, {13,"SAND_ATTACK"}, {19,"SWIFT"}, {25,"AGILITY"}, {37,"FURY_ATTACK"}, {49,"STEEL_WING"} },
    HOUNDOUR = { {1,"LEER"}, {1,"EMBER"}, {7,"ROAR"}, {13,"SMOG"}, {20,"BITE"}, {27,"FAINT_ATTACK"}, {35,"FLAMETHROWER"}, {43,"CRUNCH"} },
    HOUNDOOM = { {1,"LEER"}, {1,"EMBER"}, {7,"ROAR"}, {13,"SMOG"}, {20,"BITE"}, {30,"FAINT_ATTACK"}, {41,"FLAMETHROWER"}, {52,"CRUNCH"} },
    KINGDRA = { {1,"BUBBLE"}, {1,"SMOKESCREEN"}, {1,"LEER"}, {1,"WATER_GUN"}, {8,"SMOKESCREEN"}, {15,"LEER"}, {22,"WATER_GUN"}, {29,"TWISTER"}, {40,"AGILITY"}, {51,"HYDRO_PUMP"} },
    PHANPY = { {1,"TACKLE"}, {1,"GROWL"}, {9,"DEFENSE_CURL"}, {17,"FLAIL"}, {25,"TAKE_DOWN"}, {33,"ROLLOUT"}, {41,"ENDURE"}, {49,"DOUBLE_EDGE"} },
    DONPHAN = { {1,"HORN_ATTACK"}, {1,"GROWL"}, {9,"DEFENSE_CURL"}, {17,"FLAIL"}, {25,"FURY_ATTACK"}, {33,"ROLLOUT"}, {41,"RAPID_SPIN"}, {49,"EARTHQUAKE"} },
    PORYGON2 = { {1,"CONVERSION2"}, {1,"TACKLE"}, {1,"CONVERSION"}, {9,"AGILITY"}, {12,"PSYBEAM"}, {20,"RECOVER"}, {24,"DEFENSE_CURL"}, {32,"LOCK_ON"}, {36,"TRI_ATTACK"}, {44,"ZAP_CANNON"} },
    STANTLER = { {1,"TACKLE"}, {8,"LEER"}, {15,"HYPNOSIS"}, {23,"STOMP"}, {31,"SAND_ATTACK"}, {40,"TAKE_DOWN"}, {49,"CONFUSE_RAY"} },
    SMEARGLE = { {1,"SKETCH"}, {11,"SKETCH"}, {21,"SKETCH"}, {31,"SKETCH"}, {41,"SKETCH"}, {51,"SKETCH"}, {61,"SKETCH"}, {71,"SKETCH"}, {81,"SKETCH"}, {91,"SKETCH"} },
    TYROGUE = { {1,"TACKLE"} },
    HITMONTOP = { {1,"ROLLING_KICK"}, {7,"FOCUS_ENERGY"}, {13,"PURSUIT"}, {19,"QUICK_ATTACK"}, {25,"RAPID_SPIN"}, {31,"COUNTER"}, {37,"AGILITY"}, {43,"DETECT"}, {49,"TRIPLE_KICK"} },
    SMOOCHUM = { {1,"POUND"}, {1,"LICK"}, {9,"SWEET_KISS"}, {13,"POWDER_SNOW"}, {21,"CONFUSION"}, {25,"SING"}, {33,"MEAN_LOOK"}, {37,"PSYCHIC_M"}, {45,"PERISH_SONG"}, {49,"BLIZZARD"} },
    ELEKID = { {1,"QUICK_ATTACK"}, {1,"LEER"}, {9,"THUNDERPUNCH"}, {17,"LIGHT_SCREEN"}, {25,"SWIFT"}, {33,"SCREECH"}, {41,"THUNDERBOLT"}, {49,"THUNDER"} },
    MAGBY = { {1,"EMBER"}, {7,"LEER"}, {13,"SMOG"}, {19,"FIRE_PUNCH"}, {25,"SMOKESCREEN"}, {31,"SUNNY_DAY"}, {37,"FLAMETHROWER"}, {43,"CONFUSE_RAY"}, {49,"FIRE_BLAST"} },
    MILTANK = { {1,"TACKLE"}, {4,"GROWL"}, {8,"DEFENSE_CURL"}, {13,"STOMP"}, {19,"MILK_DRINK"}, {26,"BIDE"}, {34,"ROLLOUT"}, {43,"BODY_SLAM"}, {53,"HEAL_BELL"} },
    BLISSEY = { {1,"POUND"}, {4,"GROWL"}, {7,"TAIL_WHIP"}, {10,"SOFTBOILED"}, {13,"DOUBLESLAP"}, {18,"MINIMIZE"}, {23,"SING"}, {28,"EGG_BOMB"}, {33,"DEFENSE_CURL"}, {40,"LIGHT_SCREEN"}, {47,"DOUBLE_EDGE"} },
    RAIKOU = { {1,"BITE"}, {1,"LEER"}, {11,"THUNDERSHOCK"}, {21,"ROAR"}, {31,"QUICK_ATTACK"}, {41,"SPARK"}, {51,"REFLECT"}, {61,"CRUNCH"}, {71,"THUNDER"} },
    ENTEI = { {1,"BITE"}, {1,"LEER"}, {11,"EMBER"}, {21,"ROAR"}, {31,"FIRE_SPIN"}, {41,"STOMP"}, {51,"FLAMETHROWER"}, {61,"SWAGGER"}, {71,"FIRE_BLAST"} },
    SUICUNE = { {1,"BITE"}, {1,"LEER"}, {11,"WATER_GUN"}, {21,"ROAR"}, {31,"GUST"}, {41,"BUBBLEBEAM"}, {51,"MIST"}, {61,"MIRROR_COAT"}, {71,"HYDRO_PUMP"} },
    LARVITAR = { {1,"BITE"}, {1,"LEER"}, {8,"SANDSTORM"}, {15,"SCREECH"}, {22,"ROCK_SLIDE"}, {29,"THRASH"}, {36,"SCARY_FACE"}, {43,"CRUNCH"}, {50,"EARTHQUAKE"}, {57,"HYPER_BEAM"} },
    PUPITAR = { {1,"BITE"}, {1,"LEER"}, {1,"SANDSTORM"}, {1,"SCREECH"}, {8,"SANDSTORM"}, {15,"SCREECH"}, {22,"ROCK_SLIDE"}, {29,"THRASH"}, {38,"SCARY_FACE"}, {47,"CRUNCH"}, {56,"EARTHQUAKE"}, {65,"HYPER_BEAM"} },
    TYRANITAR = { {1,"BITE"}, {1,"LEER"}, {1,"SANDSTORM"}, {1,"SCREECH"}, {8,"SANDSTORM"}, {15,"SCREECH"}, {22,"ROCK_SLIDE"}, {29,"THRASH"}, {38,"SCARY_FACE"}, {47,"CRUNCH"}, {61,"EARTHQUAKE"}, {75,"HYPER_BEAM"} },
    LUGIA = { {1,"AEROBLAST"}, {11,"SAFEGUARD"}, {22,"GUST"}, {33,"RECOVER"}, {44,"HYDRO_PUMP"}, {55,"RAIN_DANCE"}, {66,"SWIFT"}, {77,"WHIRLWIND"}, {88,"ANCIENTPOWER"}, {99,"FUTURE_SIGHT"} },
    HO_OH = { {1,"SACRED_FIRE"}, {11,"SAFEGUARD"}, {22,"GUST"}, {33,"RECOVER"}, {44,"FIRE_BLAST"}, {55,"SUNNY_DAY"}, {66,"SWIFT"}, {77,"WHIRLWIND"}, {88,"ANCIENTPOWER"}, {99,"FUTURE_SIGHT"} },
    CELEBI = { {1,"LEECH_SEED"}, {1,"CONFUSION"}, {1,"RECOVER"}, {1,"HEAL_BELL"}, {10,"SAFEGUARD"}, {20,"ANCIENTPOWER"}, {30,"FUTURE_SIGHT"}, {40,"BATON_PASS"}, {50,"PERISH_SONG"} },
  }

  local randomSpeciesCache = nil
  local randomMovesCache = nil

  local function randomSpeciesIds()
    if randomSpeciesCache then return randomSpeciesCache end
    local ids = {}

    local game = liveGame
    local pokemonData = game and game.data and game.data.pokemon

    for _, sourceId in ipairs(GOLD_SPECIES_IDS) do
      local candidates = {
        sourceId,
        sourceId:lower(),
      }

      local found = nil
      if type(pokemonData) == "table" then
        for _, id in ipairs(candidates) do
          if type(pokemonData[id]) == "table" then
            found = id
            break
          end
        end
      end

      if found then
        ids[#ids + 1] = found
      end
    end

    -- If this cache keys species in an unexpected way, do not silently make
    -- RANDOM POKEMON a no-op: fall back to the canonical Gold ids themselves.
    if #ids == 0 then
      for _, id in ipairs(GOLD_SPECIES_IDS) do
        ids[#ids + 1] = id
      end
    end

    randomSpeciesCache = ids
    return ids
  end

  local function randomMoveIds()
    if randomMovesCache then return randomMovesCache end
    local ids = {}

    -- IMPORTANT: battle execution indexes moves through battle.data.moves,
    -- which is the live game.data.moves table.  mod.content.moves can expose
    -- registry ids/aliases that are valid to the mod API but are NOT valid
    -- BattleState move ids.  Passing one of those through slot.moves creates
    -- an enemy move with 0 PP / no battle definition and can crash when turn
    -- order or the move-effect pipeline tries to execute it.
    local game = liveGame
    local moveData = game and game.data and game.data.moves
    if type(moveData) == "table" then
      for id, def in pairs(moveData) do
        if type(id) == "string"
           and id ~= "STRUGGLE"
           and type(def) == "table"
           and tonumber(def.pp)
           and tonumber(def.pp) > 0 then
          ids[#ids + 1] = id
        end
      end
    end

    table.sort(ids)
    randomMovesCache = ids
    return ids
  end

  local function rngInt(a, b)
    -- Use the recomp/LÖVE RNG when available. Plain Lua math.random starts
    -- from a repeatable sequence unless explicitly seeded, which made wild
    -- encounters appear to cycle through Pokemon in a recognizable order.
    if love and love.math and type(love.math.random) == "function" then
      return love.math.random(a, b)
    end
    return math.random(a, b)
  end

  local function pickRandom(list)
    if type(list) ~= "table" or #list == 0 then return nil end
    return list[rngInt(1, #list)]
  end

  local function randomSpecies(fallback)
    local pool = randomSpeciesIds()
    if #pool == 0 then return fallback end
    if #pool == 1 then return pool[1] end

    local fallbackNorm = tostring(fallback or ""):upper()
    for _ = 1, 20 do
      local pick = pool[rngInt(1, #pool)]
      if tostring(pick):upper() ~= fallbackNorm then
        return pick
      end
    end

    -- Deterministic escape hatch if RNG happened to keep selecting the same id.
    for _, pick in ipairs(pool) do
      if tostring(pick):upper() ~= fallbackNorm then
        return pick
      end
    end

    return fallback
  end

  local function fourRandomMoves(fallbackMoves)
    local pool = randomMoveIds()
    if #pool == 0 then
      if type(fallbackMoves) == "table" then
        local copy = {}
        for _, id in ipairs(fallbackMoves) do copy[#copy + 1] = id end
        return copy
      end
      return nil
    end

    local chosen, used = {}, {}
    local attempts = 0
    while #chosen < 4 and attempts < 200 do
      attempts = attempts + 1
      local id = pickRandom(pool)
      if id and not used[id] then
        used[id] = true
        chosen[#chosen + 1] = id
      end
    end

    return #chosen > 0 and chosen or fallbackMoves
  end

  local function randomDVs()
    -- Legal Gen 2 DV range is 0-15. HP is derived by the engine from these
    -- four DVs just like a normal Gen 2 Pokémon.
    return {
      attack = rngInt(0, 15),
      defense = rngInt(0, 15),
      speed = rngInt(0, 15),
      special = rngInt(0, 15),
    }
  end

  local function buildTrainerParty(baseParty, step, randomPokemonEnabled, randomStatsMovesEnabled)
    local upgraded = {}

    for i, slot in ipairs(baseParty or {}) do
      local copy = copySlot(slot)
      local originalLevel = tonumber(slot.level) or 1
      local targetLevel = math.min(100, originalLevel + (tonumber(step) or 0))

      local finalSpecies
      if randomPokemonEnabled then
        -- Species rerolls every rematch, while this trainer slot's level still
        -- follows its ORIGINAL level + the persistent progression count.
        finalSpecies = randomSpecies(slot.species)
      else
        finalSpecies = evolvedSpeciesAtLevel(
          slot.species, originalLevel, targetLevel)
      end

      copy.level = targetLevel
      copy.species = finalSpecies

      -- Any species replacement/evolution must regenerate the displayed name.
      if tostring(finalSpecies) ~= tostring(slot.species) then
        copy.name = nil
        copy.nickname = nil
        copy.nick = nil
        copy.displayName = nil
        copy.speciesName = nil
      end

      -- Always rebuild level/species-derived battle state at construction time.
      copy.stats = nil
      copy.hp = nil
      copy.exp = nil
      copy.status = nil

      if randomStatsMovesEnabled then
        -- Random legal Gen 2 DVs produce randomized battle stats without
        -- injecting malformed final-stat tables into BattleState.
        copy.dvs = randomDVs()

        -- Any registered Gold move may be selected regardless of species.
        copy.moves = fourRandomMoves(slot.moves)
      else
        copy.dvs = nil

        -- Whether this is the trainer's original species or a randomized
        -- species, build its natural Gold moves the same proven way.  Using one
        -- path here prevents original rematch Pokemon from ending up with an
        -- empty/invalid move list while randomized Pokemon work correctly.
        copy.moves = nativeMovesAtLevel(
          finalSpecies,
          targetLevel,
          nil
        )
      end

      upgraded[i] = copy
    end

    return upgraded
  end

  local function buildProgressiveParty(baseParty, step)
    return buildTrainerParty(baseParty, step, settings.randomPokemon, settings.randomStatsMoves)
  end

  -- BattleState calls this hook before Pokemon.new constructs the enemy team.
  -- It is the safest place to scale a rematch because shared trainer data is
  -- never mutated.
  mod.hooks:wrap("trainer.party", function(next, oppClass, partyIndex, partyDef)
    -- Do not mutate shared trainer definitions. Build a temporary party for
    -- either a first encounter or an armed rematch.
    local baseParty = next(oppClass, partyIndex, partyDef) or partyDef

    if not rematchBattlePending then
      local firstRandomized = settings.randomFirstPokemon or settings.randomFirstStatsMoves
      if not firstRandomized then
        return baseParty
      end
      -- First encounters keep the trainer's vanilla levels. Species and/or
      -- stats+moves use the exact same proven construction path as rematches.
      return buildTrainerParty(
        baseParty,
        0,
        settings.randomFirstPokemon,
        settings.randomFirstStatsMoves
      )
    end

    local progressive = progressionEnabled()
    local randomized = settings.randomPokemon or settings.randomStatsMoves
    if not progressive and not randomized then
      return baseParty
    end

    local key = tostring(oppClass) .. "#" .. tostring(partyIndex or 1)
    local progress = getProgress()
    local step = tonumber(progress[key]) or 0

    if progressive then
      step = math.min(100, step + 1)
      progress[key] = step
      persistProgress(progress)
    else
      -- Progressive OFF means original levels, even if a randomizer is ON.
      step = 0
    end

    pendingProgressKey = key
    pendingProgressStep = progressive and step or nil

    local upgraded = buildProgressiveParty(baseParty, step)
    pendingProgressParty = upgraded
    return upgraded
  end)

  -- -----------------------------------------------------------------------
  -- Random Pokemon types + type-based TM/HM compatibility (Gen 2 Gold)
  -- -----------------------------------------------------------------------
  -- Gen 2 Mon.new copies `def.types` onto each newly-created Mon, while the
  -- Gold TM/HM menu checks `game.data.pokemon[mon.species].tmhm`.  Keep a
  -- stable per-species type map and project it into the live data while ON.
  local typeBaseline = setmetatable({}, { __mode = "k" })

  local function copyArray(src)
    local out = {}
    if type(src) == "table" then
      for i, v in ipairs(src) do out[i] = v end
    end
    return out
  end

  local function usableTypeIds(data)
    local out, seen = {}, {}
    if data and type(data.types) == "table" then
      for id, def in pairs(data.types) do
        local typeId = nil
        if type(id) == "string" then typeId = id
        elseif type(def) == "table" and type(def.id) == "string" then typeId = def.id end
        if typeId and typeId ~= "???" and typeId ~= "UNKNOWN" and not seen[typeId] then
          seen[typeId] = true
          out[#out + 1] = typeId
        end
      end
    end
    if #out == 0 then
      out = { "NORMAL", "FIGHTING", "FLYING", "POISON", "GROUND", "ROCK",
        "BUG", "GHOST", "STEEL", "FIRE", "WATER", "GRASS", "ELECTRIC",
        "PSYCHIC", "ICE", "DRAGON", "DARK" }
    end
    return out
  end

  local function uniqueTypeCount(types)
    if type(types) ~= "table" or types[1] == nil then return 1 end
    if types[2] ~= nil and types[2] ~= types[1] then return 2 end
    return 1
  end

  local function ensureRandomTypeMap(game)
    local data = game and game.data
    if not (data and type(data.pokemon) == "table") then return false end
    local pool = usableTypeIds(data)
    if #pool == 0 then return false end
    local changed = false
    for species, def in pairs(data.pokemon) do
      if type(species) == "string" and type(def) == "table" and type(def.types) == "table" then
        local mapped = settings.randomTypeMap[species]
        if type(mapped) ~= "table" or type(mapped[1]) ~= "string" then
          local count = uniqueTypeCount(def.types)
          local first = pool[rngInt(1, #pool)]
          local second = nil
          if count >= 2 and #pool > 1 then
            repeat second = pool[rngInt(1, #pool)] until second ~= first
          end
          settings.randomTypeMap[species] = { first, second }
          changed = true
        end
      end
    end
    return changed
  end

  local function tmMovesByType(data, wanted)
    local out, seen = {}, {}
    if not data then return out end
    local items, moves = data.items, data.moves
    if type(items) ~= "table" or type(moves) ~= "table" then return out end
    for _, item in pairs(items) do
      if type(item) == "table" and item.pocket == "TM_HM" and item.teaches then
        local moveId = item.teaches
        local moveDef = moves[moveId]
        local moveType = type(moveDef) == "table" and moveDef.type or nil
        if moveType and wanted[moveType] and not seen[moveId] then
          seen[moveId] = true
          out[#out + 1] = moveId
        end
      end
    end
    return out
  end

  local function syncMonTypes(mon)
    if not settings.randomTypes or type(mon) ~= "table" or not mon.species then return end
    local mapped = settings.randomTypeMap[tostring(mon.species)]
    if type(mapped) == "table" and mapped[1] then
      mon.types = { mapped[1] }
      if mapped[2] then mon.types[2] = mapped[2] end
    end
  end

  local function syncPartyTypes(game)
    local save = game and game.save
    if not save then return end
    local party = save.party
    if type(party) == "table" then
      for _, mon in ipairs(party) do syncMonTypes(mon) end
    end
  end

  syncRandomTypes = function(game, persistMap)
    game = game or liveGame
    local data = game and game.data
    if not (data and type(data.pokemon) == "table") then return false end

    local baseline = typeBaseline[data]
    if not baseline then
      baseline = {}
      typeBaseline[data] = baseline
      for species, def in pairs(data.pokemon) do
        if type(species) == "string" and type(def) == "table" and type(def.types) == "table" then
          baseline[species] = { types = copyArray(def.types), tmhm = copyArray(def.tmhm) }
        end
      end
    end

    if not settings.randomTypes then
      for species, original in pairs(baseline) do
        local def = data.pokemon[species]
        if type(def) == "table" then
          def.types = copyArray(original.types)
          def.tmhm = copyArray(original.tmhm)
        end
      end
      -- Existing party mons store a copy of their types, so restore those too.
      local save = game.save
      if save and type(save.party) == "table" then
        for _, mon in ipairs(save.party) do
          local original = mon and baseline[tostring(mon.species)]
          if original then mon.types = copyArray(original.types) end
        end
      end
      return true
    end

    local generated = ensureRandomTypeMap(game)
    for species, original in pairs(baseline) do
      local def = data.pokemon[species]
      local mapped = settings.randomTypeMap[species]
      if type(def) == "table" and type(mapped) == "table" and mapped[1] then
        def.types = { mapped[1] }
        if mapped[2] then def.types[2] = mapped[2] end

        -- Preserve vanilla compatibility, then add every TM/HM whose move type
        -- matches either randomized type.  This is intentionally additive so
        -- story-critical HMs and useful vanilla coverage are never lost.
        local compat, seen = {}, {}
        for _, id in ipairs(original.tmhm or {}) do
          if not seen[id] then seen[id] = true; compat[#compat + 1] = id end
        end
        local wanted = { [mapped[1]] = true }
        if mapped[2] then wanted[mapped[2]] = true end
        for _, id in ipairs(tmMovesByType(data, wanted)) do
          if not seen[id] then seen[id] = true; compat[#compat + 1] = id end
        end
        def.tmhm = compat
      end
    end
    syncPartyTypes(game)
    if generated and persistMap then writeSettings(game) end
    return true
  end


  -- -----------------------------------------------------------------------
  -- Random per-individual level-up learnsets -- v2.0.15
  -- -----------------------------------------------------------------------
  local LEARNSET_SCHEMA = 15
  local LF_SCHEDULE = "_g2rpLearnsetV15"
  local LF_SPECIES = "_g2rpLearnsetSpeciesV15"
  local LF_LAST_LEVEL = "_g2rpLearnsetLastLevelV15"
  local LF_PENDING = "_g2rpLearnsetPendingV15"
  local LF_PREVIOUS_MOVES = "_g2rpLearnsetPreviousMovesV15"

  local function learnsetRandom(a, b)
    if love and love.math and type(love.math.random) == "function" then
      return love.math.random(a, b)
    end
    return math.random(a, b)
  end

  local function learnsetMovePool(data)
    local pool = {}
    if type(data) ~= "table" or type(data.moves) ~= "table" then return pool end
    for id, def in pairs(data.moves) do
      if id ~= "STRUGGLE" and type(def) == "table" then
        local pp = tonumber(def.pp)
        if pp and pp > 0 then pool[#pool + 1] = id end
      end
    end
    return pool
  end

  local function moveIdSet(mon)
    local set = {}
    for _, mv in ipairs((mon and mon.moves) or {}) do
      local id = type(mv) == "table" and mv.id or mv
      if id then set[id] = true end
    end
    return set
  end

  local function nativeMove(data, id)
    local def = data and data.moves and data.moves[id]
    local pp = type(def) == "table" and tonumber(def.pp) or nil
    if not pp or pp <= 0 then return nil end
    return { id = id, pp = pp, maxPp = pp }
  end

  local function speciesLevelRows(data, species)
    local def = data and data.pokemon and data.pokemon[species]
    if type(def) ~= "table" or type(def.levelMoves) ~= "table" then return nil end
    return def.levelMoves
  end

  local function ensureIndividualLearnset(mon, data)
    if type(mon) ~= "table" or mon.isEgg or not mon.species then return nil end
    local vanilla = speciesLevelRows(data, mon.species)
    if not vanilla then return nil end

    local existing = mon[LF_SCHEDULE]
    if mon._g2rpLearnsetSchema == LEARNSET_SCHEMA
       and mon[LF_SPECIES] == mon.species
       and type(existing) == "table"
       and #existing == #vanilla then
      return existing
    end

    local pool = learnsetMovePool(data)
    if #pool == 0 then return nil end

    local used, schedule = {}, {}
    for i, row in ipairs(vanilla) do
      local chosen
      for _ = 1, math.max(100, #pool * 2) do
        local id = pool[learnsetRandom(1, #pool)]
        if id and id ~= row.move and not used[id] then
          chosen = id
          break
        end
      end
      chosen = chosen or pool[learnsetRandom(1, #pool)] or row.move
      used[chosen] = true
      schedule[i] = {
        level = tonumber(row.level) or 1,
        vanilla = row.move,
        random = chosen,
      }
    end

    mon._g2rpLearnsetSchema = LEARNSET_SCHEMA
    mon[LF_SCHEDULE] = schedule
    mon[LF_SPECIES] = mon.species
    mon[LF_LAST_LEVEL] = tonumber(mon.level) or 1
    mon[LF_PENDING] = {}
    mon[LF_PREVIOUS_MOVES] = moveIdSet(mon)
    return schedule
  end

  local function currentMovesFromLearnset(mon, data, schedule)
    local level = tonumber(mon.level) or 1
    local ids = {}
    for _, row in ipairs(schedule or {}) do
      if (tonumber(row.level) or 1) <= level then
        local duplicate = false
        for _, id in ipairs(ids) do
          if id == row.random then duplicate = true break end
        end
        if not duplicate then
          ids[#ids + 1] = row.random
          if #ids > 4 then table.remove(ids, 1) end
        end
      end
    end

    local moves = {}
    for _, id in ipairs(ids) do
      local mv = nativeMove(data, id)
      if mv then moves[#moves + 1] = mv end
    end
    return moves
  end

  local function enrollOwnedMon(mon, data, rebuildCurrent)
    local schedule = ensureIndividualLearnset(mon, data)
    if not schedule then return false end

    if rebuildCurrent then
      local moves = currentMovesFromLearnset(mon, data, schedule)
      if #moves > 0 then
        mon.moves = moves
      end
    end

    mon[LF_LAST_LEVEL] = tonumber(mon.level) or 1
    mon[LF_PREVIOUS_MOVES] = moveIdSet(mon)
    return true
  end

  local function eachOwnedPartyMon(game, fn)
    local party = game and game.save and game.save.party
    if type(party) ~= "table" then return end
    for _, mon in ipairs(party) do
      if type(mon) == "table" and not mon.isEgg then fn(mon) end
    end
  end

  syncOwnedRandomLearnsets = function(game, rebuildCurrent)
    if not settings.randomMoveLearnset or not (game and game.data) then return false end
    local changed = false
    eachOwnedPartyMon(game, function(mon)
      local fresh = not (
        mon._g2rpLearnsetSchema == LEARNSET_SCHEMA
        and mon[LF_SPECIES] == mon.species
        and type(mon[LF_SCHEDULE]) == "table"
      )
      if enrollOwnedMon(mon, game.data, rebuildCurrent and fresh) then
        changed = true
      end
    end)
    return changed
  end

  -- v2.0.25 combination helper:
  -- Unlike syncOwnedRandomLearnsets(), this intentionally rebuilds current
  -- moves even when the individual's schedule already exists from a prior
  -- test/build.  That is required when the user toggles Random Learnset ON.
  local function forceApplyCurrentRandomLearnsets(game)
    if not settings.randomMoveLearnset or not (game and game.data) then return false end
    local changed = false
    eachOwnedPartyMon(game, function(mon)
      local schedule = ensureIndividualLearnset(mon, game.data)
      if type(schedule) == "table" then
        local moves = currentMovesFromLearnset(mon, game.data, schedule)
        if type(moves) == "table" and #moves > 0 then
          -- Proven live-party mutation path from v2.0.14/v2.0.20.
          mon.moves = moves
          mon[LF_LAST_LEVEL] = tonumber(mon.level) or 1
          mon[LF_PREVIOUS_MOVES] = moveIdSet(mon)
          changed = true
        end
      end
    end)
    return changed
  end

  -- ---------------------------------------------------------------
  -- Native Gold level-up learnset injection -- v2.0.17
  -- ---------------------------------------------------------------
  -- Mon.gainExperience emits pokemon.level_up BEFORE its final scan of
  -- def.levelMoves.  Modify the exact live rows during that event, leave them
  -- changed through the final scan, then restore them at battle.exp_gained.
  --
  -- This avoids relying on exp.gain timing entirely.
  local activeLevelRowRestores = {}
  local pendingLevelReplacements = {}
  local learnsetDataByMon = setmetatable({}, { __mode = "k" })

  local originalEnrollOwnedMon = enrollOwnedMon
  enrollOwnedMon = function(mon, data, rebuildCurrent)
    local ok = originalEnrollOwnedMon(mon, data, rebuildCurrent)
    if ok and type(mon) == "table" and type(data) == "table" then
      learnsetDataByMon[mon] = data
    end
    return ok
  end

  local function rowsForExactLevel(mon, level)
    local out = {}
    for _, row in ipairs((mon and mon[LF_SCHEDULE]) or {}) do
      if tonumber(row.level) == tonumber(level) then
        out[#out + 1] = row
      end
    end
    return out
  end

  local function restoreLevelRows(mon)
    local restores = mon and activeLevelRowRestores[mon]
    if type(restores) ~= "table" then return end
    for _, r in ipairs(restores) do
      if r.entry then r.entry.move = r.original end
    end
    activeLevelRowRestores[mon] = nil
  end

  local function addPendingReplacement(mon, vanillaId, randomId, level)
    if not (mon and vanillaId and randomId) then return end
    local pending = pendingLevelReplacements[mon]
    if type(pending) ~= "table" then
      pending = {}
      pendingLevelReplacements[mon] = pending
    end
    pending[#pending + 1] = {
      vanilla = vanillaId,
      random = randomId,
      level = level,
      age = 0,
    }
  end

  mod.events:on("pokemon.level_up", function(ev)
    if not settings.randomMoveLearnset then return end
    local mon = ev and ev.mon
    local level = ev and tonumber(ev.level)
    if type(mon) ~= "table" or not level then return end
    local data = learnsetDataByMon[mon] or (liveGame and liveGame.data)
    if type(data) ~= "table" then return end
    local schedule = ensureIndividualLearnset(mon, data)
    if type(schedule) ~= "table" then return end
    learnsetDataByMon[mon] = data
    for _, row in ipairs(schedule) do
      if tonumber(row.level) == level and row.vanilla and row.random then
        addPendingReplacement(mon, row.vanilla, row.random, level)
      end
    end
  end)

  -- This fires after Mon.gainExperience has already performed its final
  -- def.levelMoves scan and copied the move ids into result.learned, but before
  -- Battle.lua teaches those copied ids.
  mod.events:on("battle.exp_gained", function(ev)
    if ev and ev.mon then restoreLevelRows(ev.mon) end
  end)

  local function replacementMoveObject(data, id)
    local def = data and data.moves and data.moves[id]
    local pp = type(def) == "table" and tonumber(def.pp) or nil
    if not pp or pp <= 0 then return nil end
    return { id = id, pp = pp, maxPp = pp }
  end

  local function replaceLearnedVanilla(mon, data, vanillaId, randomId)
    local replacement = replacementMoveObject(data, randomId)
    if not replacement then return false end
    for i, mv in ipairs(mon.moves or {}) do
      if type(mv) == "table" and mv.id == vanillaId then
        mon.moves[i] = replacement
        return true
      end
    end
    return false
  end

  -- Safety path. If the native pre-scan injection succeeded, moveId is already
  -- the random id and this simply clears its pending record. If some path still
  -- taught the vanilla id, correct the physical move slot immediately.
  mod.events:on("pokemon.move_learned", function(ev)
    if not settings.randomMoveLearnset then return end
    local mon = ev and ev.mon
    local learnedId = ev and ev.moveId
    if type(mon) ~= "table" or not learnedId then return end

    local data = learnsetDataByMon[mon] or (liveGame and liveGame.data)
    local pending = pendingLevelReplacements[mon]
    if type(data) ~= "table" or type(pending) ~= "table" then return end

    for i = #pending, 1, -1 do
      local row = pending[i]
      if learnedId == row.random then
        table.remove(pending, i)
        return
      elseif learnedId == row.vanilla then
        if replaceLearnedVanilla(mon, data, row.vanilla, row.random) then
          table.remove(pending, i)
          return
        end
      end
    end
  end)

  -- Lightweight fallback for the four-move forget path and any delayed UI
  -- resolution. It does not choose moves or alter levels; it only corrects a
  -- vanilla move if that exact pending level-up move eventually appears.
  local function reconcilePendingLevelReplacements(game)
    if not settings.randomMoveLearnset or not (game and game.data) then return end
    eachOwnedPartyMon(game, function(mon)
      local pending = pendingLevelReplacements[mon]
      if type(pending) ~= "table" then return end
      for i = #pending, 1, -1 do
        local row = pending[i]
        row.age = (tonumber(row.age) or 0) + 1

        local hasRandom, hasVanilla = false, false
        for _, mv in ipairs(mon.moves or {}) do
          local id = type(mv) == "table" and mv.id or mv
          if id == row.random then hasRandom = true end
          if id == row.vanilla then hasVanilla = true end
        end

        if hasRandom then
          table.remove(pending, i)
        elseif hasVanilla and replaceLearnedVanilla(
            mon, game.data, row.vanilla, row.random) then
          table.remove(pending, i)
        elseif row.age > 3600 then
          table.remove(pending, i)
        end
      end
    end)
  end

  local priorReconcileRandomLearnsets = reconcileRandomLearnsets
  reconcileRandomLearnsets = function(game)
    if priorReconcileRandomLearnsets then
      priorReconcileRandomLearnsets(game)
    end
    reconcilePendingLevelReplacements(game)
    return true
  end

  -- Safety restore if a battle is interrupted.
  mod.events:on("battle.ended", function()
    for mon in pairs(activeLevelRowRestores) do
      restoreLevelRows(mon)
    end
  end)

  -- -----------------------------------------------------------------------
  -- Random Learnset: active native registry projection -- v2.0.23
  -- -----------------------------------------------------------------------
  -- Gold's original LearnLevelMoves reads the species learnset first, then
  -- invokes LearnMove. The supplied randomizer also randomizes movesets by
  -- replacing learnset move IDs while preserving learn levels.
  --
  -- Mirror that design here: while the player's active Pokemon is in battle,
  -- project THAT INDIVIDUAL'S persistent random schedule into the exact live
  -- game.data.pokemon[species].levelMoves table before the engine step that can
  -- award EXP. Gold then consumes the random move natively from the beginning.
  local activeLearnsetProjection = nil

  local function restoreActiveLearnsetProjection()
    local p = activeLearnsetProjection
    if type(p) == "table" and type(p.def) == "table" then
      p.def.levelMoves = p.original
    end
    activeLearnsetProjection = nil
  end

  local function projectedLevelMoves(mon, data)
    local schedule = ensureIndividualLearnset(mon, data)
    if type(schedule) ~= "table" then return nil end
    local out = {}
    for _, row in ipairs(schedule) do
      if row.level and row.random and data.moves and data.moves[row.random] then
        out[#out + 1] = {
          level = tonumber(row.level) or 1,
          move = row.random,
        }
      end
    end
    return out
  end

  local function resolveActiveOwnedMon(game)
    local party = game and game.save and game.save.party
    if type(party) ~= "table" then return nil end

    local seen = {}
    local function walk(t, depth)
      if type(t) ~= "table" or depth > 5 or seen[t] then return nil end
      seen[t] = true

      -- First use identity: any battle/UI reference that is literally one of
      -- the save party mons is definitive.
      for _, v in pairs(t) do
        if type(v) == "table" then
          for _, mon in ipairs(party) do
            if v == mon then return mon end
          end
        end
      end

      -- Then try common 1-based party index fields.
      for _, key in ipairs({
        "playerIndex", "partyIndex", "activeIndex", "playerPartyIndex",
        "currentPartyIndex", "monIndex"
      }) do
        local n = tonumber(rawget(t, key))
        if n and party[n] then return party[n] end
      end

      for _, v in pairs(t) do
        if type(v) == "table" then
          local found = walk(v, depth + 1)
          if found then return found end
        end
      end
      return nil
    end

    local found = walk(game.stack, 0)
    if found then return found end

    -- The first-party fallback covers the controlled one-Pokemon/lead tests and
    -- is replaced as soon as the battle state exposes the active object/index.
    return party[1]
  end

  local function projectActiveRandomLearnset(game)
    if not settings.randomMoveLearnset then
      restoreActiveLearnsetProjection()
      return
    end
    if not (game and game.data and game.data.pokemon) then return end

    local mon = resolveActiveOwnedMon(game)
    if type(mon) ~= "table" or not mon.species then return end

    if activeLearnsetProjection
       and activeLearnsetProjection.mon == mon
       and activeLearnsetProjection.species == mon.species then
      return
    end

    restoreActiveLearnsetProjection()

    local def = game.data.pokemon[mon.species]
    if type(def) ~= "table" or type(def.levelMoves) ~= "table" then return end
    local rows = projectedLevelMoves(mon, game.data)
    if type(rows) ~= "table" or #rows == 0 then return end

    activeLearnsetProjection = {
      mon = mon,
      species = mon.species,
      def = def,
      original = def.levelMoves,
    }
    def.levelMoves = rows
  end

  mod.events:on("battle.ended", function()
    restoreActiveLearnsetProjection()
  end)

  -- -----------------------------------------------------------------------
  -- Random wild Pokemon / wild stats + moves (Gen1Recomp Gold runtime)
  -- -----------------------------------------------------------------------
  -- IMPORTANT: Gold does NOT use the Gen 1 Pokemon.lua learnset shape.
  -- src/battle/gen2/Mon.lua builds wild move objects from a species' `levelMoves`
  -- table, and src/world/gen2/World.lua creates the wild Mon before Battle.new.
  -- Rather than touching Gen 1 `level1Moves` / `learnset` fields, random wild
  -- moves are therefore applied to the already-created Gen 2 Mon at the public
  -- battle.started event.  Battle AI reads battle.enemy.moves directly.

  local function wildMovePoolFromData(data)
    local pool = {}
    if type(data) ~= "table" or type(data.moves) ~= "table" then return pool end
    for id, def in pairs(data.moves) do
      if id ~= "STRUGGLE" and type(def) == "table" then
        local pp = tonumber(def.pp)
        if pp and pp > 0 then
          pool[#pool + 1] = id
        end
      end
    end
    return pool
  end

  local function fourRandomWildMoveObjects(data)
    local pool = wildMovePoolFromData(data)
    local chosen, used = {}, {}
    local attempts = 0
    while #chosen < 4 and #pool > 0 and attempts < 1000 do
      attempts = attempts + 1
      local id = pool[rngInt(1, #pool)]
      if id ~= nil and not used[id] then
        local def = data.moves[id]
        local pp = type(def) == "table" and tonumber(def.pp) or 0
        if pp and pp > 0 then
          used[id] = true
          chosen[#chosen + 1] = { id = id, pp = pp, maxPp = pp }
        end
      end
    end
    return chosen
  end

  local function randomizeWildEncounter(encounter)
    if not settings.randomWildPokemon or type(encounter) ~= "table" then
      return encounter
    end
    local replacement = pickRandom(randomSpeciesIds())
    if not replacement then return encounter end
    local out = {}
    for key, value in pairs(encounter) do out[key] = value end
    out.species = replacement
    -- Deliberately preserve the exact level rolled by the map/rod/tree table.
    return out
  end

  mod.hooks:wrap("encounter.species", function(next, encounter, context)
    local resolved = next(encounter, context)
    return randomizeWildEncounter(resolved)
  end)

  mod.hooks:wrap("encounter.fishing", function(next, rod, mapId, candidates)
    local resolved = next(rod, mapId, candidates)
    return randomizeWildEncounter(resolved)
  end)

  local function applyRandomWildStatsAndMoves(battle)
    if not settings.randomWildStatsMoves then return false end
    if type(battle) ~= "table" or battle.wild ~= true then return false end
    local enemy = battle.enemy
    if type(enemy) ~= "table" then return false end

    -- Gen 2 Battle AI reads this table directly (battle.enemy.moves).  Move
    -- entries use id / pp / maxPp, matching Mon.movesAtLevel / Mon.learnMove.
    local randomMoves = fourRandomWildMoveObjects(battle.data)
    if #randomMoves > 0 then
      local moves = type(enemy.moves) == "table" and enemy.moves or {}
      enemy.moves = moves
      for i = #moves, 1, -1 do moves[i] = nil end
      for _, mv in ipairs(randomMoves) do
        moves[#moves + 1] = mv
      end
    end

    -- Randomize legal Gen 2 DVs as the stats half of this option.  Refresh
    -- through Gold's own Mon implementation so HP/stat formulas stay native.
    enemy.dvs = randomDVs()
    pcall(function()
      local Gen2Mon = require("src.battle.gen2.Mon")
      if Gen2Mon and type(Gen2Mon.refreshStats) == "function" then
        Gen2Mon.refreshStats(enemy, battle.data)
      end
    end)

    return #randomMoves > 0
  end

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
        randomMovesCache = nil
        randomSpeciesCache = nil
      end
      -- Load the persisted toggle BEFORE vanilla executes this frame.  Any
      -- encounter hook reached inside next(game, dt) therefore sees the exact
      -- menu state and the exact game.data object that newWild will consume.
      loadSettings(game)
      -- Capture vanilla TM/HM compatibility before any other option can project
      -- changes into game.data, then apply this playthrough's randomized TMs.
      ensureTMBaseline(game)
      if syncRandomTMs then syncRandomTMs(game, false) end
    end
    install()

    -- Randomize only the current map's extracted item-ball/hidden-item records
    -- before Gold can construct a pickup script on this engine step.
    if game and settings.randomWorldItems then
      patchMapWorldItems(game)
    end

    -- Safe deferred initialization after the settings menu has fully closed.
    -- Force current moves from the individual's persistent random schedule even
    -- if that schedule came from an earlier test build.
    local didForceLearnsetInit = false
    if game and pendingLearnsetSafeInit and settings.randomMoveLearnset then
      if restoreActiveLearnsetProjection then
        restoreActiveLearnsetProjection()
      end
      pendingLearnsetSafeInit = false
      forceApplyCurrentRandomLearnsets(game)
      didForceLearnsetInit = true
    end

    -- Reconcile the previous fixed step's level/move changes. This is the
    -- fallback that makes Random Learnset independent of battle UI timing.
    if game and settings.randomMoveLearnset and reconcileRandomLearnsets then
      reconcileRandomLearnsets(game)
    end

    -- Keep v2.0.23's confirmed-working native level-up projection.
    -- It starts on the frame AFTER current moves are force-applied.
    if game and not didForceLearnsetInit then
      projectActiveRandomLearnset(game)
    end

    local result = next(game, dt)

    if game and settings.randomMoveLearnset and reconcileRandomLearnsets then
      reconcileRandomLearnsets(game)
    end

    return result
  end, -1000)



  local function repairNaturalTrainerMoves(battle, randomStatsMovesEnabled)
    if randomStatsMovesEnabled then return end
    if type(battle) ~= "table" or type(battle.enemyParty) ~= "table" then return end

    for _, mon in ipairs(battle.enemyParty) do
      if type(mon) == "table" and mon.species then
        local ids = nativeMovesAtLevel(mon.species, mon.level, nil)
        if type(ids) == "table" and #ids > 0 then
          -- Mutate the existing table in place. makeBattler caches curMoves as
          -- this exact table reference, so replacing mon.moves alone is unsafe.
          local moves = mon.moves
          if type(moves) ~= "table" then
            moves = {}
            mon.moves = moves
          end
          for i = #moves, 1, -1 do moves[i] = nil end

          for _, id in ipairs(ids) do
            local liveId, mdef = resolveLiveMove(id)
            if liveId ~= nil and type(mdef) == "table" then
              local pp = tonumber(mdef.pp) or 0
              if pp > 0 then
                moves[#moves + 1] = { id = liveId, pp = pp }
              end
            end
          end
        end
      end
    end

    -- The currently active battler also keeps a cached curMoves pointer.
    if type(battle.enemy) == "table" and type(battle.enemy.mon) == "table" then
      battle.enemy.curMoves = battle.enemy.mon.moves
    end
  end


  local function repairRandomTrainerMoves(battle, randomStatsMovesEnabled)
    if not randomStatsMovesEnabled then return end
    if type(battle) ~= "table" or type(battle.enemyParty) ~= "table" then return end

    local moveData = battle.data and battle.data.moves
    if type(moveData) ~= "table" then return end
    local pool = randomMoveIds()

    for _, mon in ipairs(battle.enemyParty) do
      if type(mon) == "table" then
        local valid, used = {}, {}

        -- Keep the four random choices made during trainer.party, but only if
        -- they are genuine live BattleState move ids with positive native PP.
        for _, mv in ipairs(mon.moves or {}) do
          local id = type(mv) == "table" and mv.id or mv
          local def = id and moveData[id]
          if type(id) == "string" and id ~= "STRUGGLE"
             and type(def) == "table" and tonumber(def.pp)
             and tonumber(def.pp) > 0 and not used[id] then
            used[id] = true
            valid[#valid + 1] = { id = id, pp = tonumber(def.pp) }
            if #valid >= 4 then break end
          end
        end

        -- A malformed/aliased slot should never reach the battle engine.
        -- Refill any missing slots directly from the live move table.
        local attempts = 0
        while #valid < 4 and #pool > 0 and attempts < 300 do
          attempts = attempts + 1
          local id = pool[rngInt(1, #pool)]
          local def = moveData[id]
          if id and not used[id] and type(def) == "table"
             and tonumber(def.pp) and tonumber(def.pp) > 0 then
            used[id] = true
            valid[#valid + 1] = { id = id, pp = tonumber(def.pp) }
          end
        end

        -- Mutate in place because makeBattler caches mon.moves as curMoves.
        local moves = mon.moves
        if type(moves) ~= "table" then
          moves = {}
          mon.moves = moves
        end
        for i = #moves, 1, -1 do moves[i] = nil end
        for _, mv in ipairs(valid) do moves[#moves + 1] = mv end
      end
    end

    if type(battle.enemy) == "table" and type(battle.enemy.mon) == "table" then
      battle.enemy.curMoves = battle.enemy.mon.moves
    end
  end


  -- Wild random stats/moves are repaired on the actual Gen 2 battle Mon in
  -- battle.started below.  This is intentionally separate from trainer rematch
  -- repair because Gold's Battle object shape differs from Gen 1's battlers.

  -- Gold's battle engine emits the actual BattleState after the native
  -- `startbattle` command creates it.  The pending flag above identifies
  -- exactly the next trainer battle as our rematch; normal trainer and wild
  -- battles are untouched.
  mod.events:on("battle.started", function(ev)
    if not ev or not ev.battle then return end

    if settings.randomTypes then
      syncRandomTypes(liveGame, false)
      -- Gold battle objects keep the live Gen 2 Mon directly for wild enemies;
      -- trainer builds may expose party/battler variants, so cover both shapes.
      syncMonTypes(ev.battle.enemy)
      syncMonTypes(ev.battle.player)
      if type(ev.battle.enemyParty) == "table" then
        for _, mon in ipairs(ev.battle.enemyParty) do syncMonTypes(mon) end
      end
    end

    -- Gen1Recomp Gold emits kind="wild" and exposes the actual Gen 2 Mon as
    -- battle.enemy.  Process it before the trainer-rematch-only early return.
    if ev.kind == "wild" or ev.battle.wild == true then
      applyRandomWildStatsAndMoves(ev.battle)
      return
    end

    -- First-encounter trainer/Gym randomization uses the same final native
    -- move normalization that made randomized rematches stable. The earlier
    -- trainer.party hook intentionally works with ids; BattleState execution
    -- requires the fully constructed Gen 2 Mon move tables to contain native
    -- { id, pp } entries.
    if not rematchBattlePending and ev.kind == "trainer" then
      if settings.randomFirstPokemon or settings.randomFirstStatsMoves then
        if settings.randomFirstStatsMoves then
          repairRandomTrainerMoves(ev.battle, true)
        else
          repairNaturalTrainerMoves(ev.battle, false)
        end
      end
      return
    end

    if not rematchBattlePending or ev.kind ~= "trainer" then
      return
    end

    rematchBattlePending = false
    activeRematchBattle = ev.battle
    local battle = ev.battle
    battle._trainerRematch2 = true
    battle._trainerRematch2ProgressKey = pendingProgressKey
    battle._trainerRematch2ProgressStep = pendingProgressStep

    -- Final safety pass on the fully constructed BattleState. Natural and
    -- fully-random moves use separate validators, but both finish as native
    -- BattleState move objects with real live ids and PP.
    if settings.randomStatsMoves then
      repairRandomTrainerMoves(battle, true)
    else
      repairNaturalTrainerMoves(battle, false)
    end

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
    if syncRandomTMs then syncRandomTMs(game, false) end
    if syncRandomTypes then syncRandomTypes(game, true) end

    local outItems = next(game, items)
    if type(outItems) ~= "table" then return outItems end

    local clean = {}
    for _, item in ipairs(outItems) do
      local label = type(item) == "table" and item.label or nil
      if label ~= "REMATCH TRAINER" and label ~= "RANDOMIZER+ SETTINGS" then
        clean[#clean + 1] = item
      end
    end

    local settingsRow = {
      label = "RANDOMIZER+ SETTINGS",
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


  -- -----------------------------------------------------------------------
  -- Optional random starting moves for Elm's starter
  -- -----------------------------------------------------------------------
  local function randomizeStarterStartingMoves(mon, data)
    if not settings.randomStarterMoves or type(mon) ~= "table"
       or type(data) ~= "table" then return false end
    local pool = learnsetMovePool(data)
    if #pool == 0 then return false end

    local count = #(mon.moves or {})
    if count < 1 then count = 1 end
    if count > 4 then count = 4 end

    local used, moves = {}, {}
    for _ = 1, count do
      local chosen
      for _ = 1, math.max(80, #pool * 2) do
        local id = pool[rngInt(1, #pool)]
        if id and not used[id] then chosen = id break end
      end
      chosen = chosen or pool[rngInt(1, #pool)]
      if chosen then
        used[chosen] = true
        local obj = nativeMove(data, chosen)
        if obj then moves[#moves + 1] = obj end
      end
    end
    if #moves > 0 then
      mon.moves = moves
      mon[LF_PREVIOUS_MOVES] = moveIdSet(mon)
      return true
    end
    return false
  end

  -- -----------------------------------------------------------------------
  -- Random starters (Gen 2 Gold / Elm's Lab)
  -- -----------------------------------------------------------------------
  -- Adapted from the working Random Starters Gen 2 mod. Eligible starters are
  -- base-stage or true single-stage Pokemon only: any species that is the
  -- target of another species' evolution is excluded.
  local STARTER_SLOT = {
    CYNDAQUIL = "random_starter_cyndaquil",
    TOTODILE = "random_starter_totodile",
    CHIKORITA = "random_starter_chikorita",
  }
  local VANILLA_STARTER_INDEX = { [155]="CYNDAQUIL", [158]="TOTODILE", [152]="CHIKORITA" }
  local RIVAL_STARTER_SLOT = { CYNDAQUIL="TOTODILE", TOTODILE="CHIKORITA", CHIKORITA="CYNDAQUIL" }
  local JOHTO_STARTER_LINE = {
    CHIKORITA=true,BAYLEEF=true,MEGANIUM=true,
    CYNDAQUIL=true,QUILAVA=true,TYPHLOSION=true,
    TOTODILE=true,CROCONAW=true,FERALIGATR=true,
  }
  local activeStarterBall = setmetatable({}, { __mode = "k" })

  local function starterIsLab(ctx)
    local w = liveGame and liveGame.world
    local id = (w and w.map and w.map.id) or (ctx and ctx.mapId)
    return tostring(id or ""):upper() == "ELMS_LAB"
  end

  local function evolvedSpeciesSet(game)
    local evolved = {}
    for _, def in pairs((game and game.data and game.data.pokemon) or {}) do
      if type(def) == "table" then
        for _, evo in ipairs(def.evolutions or {}) do
          local into = evo.into or evo.species
          if type(into) == "string" then evolved[into] = true end
        end
      end
    end
    return evolved
  end

  local function eligibleStarterPool(game)
    local evolved = evolvedSpeciesSet(game)
    local pool = {}
    for name, def in pairs((game and game.data and game.data.pokemon) or {}) do
      if type(name) == "string" and type(def) == "table"
         and type(def.dex) == "number" and def.dex >= 1 and def.dex <= 251
         and not evolved[name] then
        pool[#pool + 1] = name
      end
    end
    table.sort(pool)
    return pool
  end

  local function saveStarterTrio(a,b,c)
    mod.save:set(STARTER_SLOT.CYNDAQUIL,a)
    mod.save:set(STARTER_SLOT.TOTODILE,b)
    mod.save:set(STARTER_SLOT.CHIKORITA,c)
  end

  local function starterAssigned(slot)
    return mod.save:get(STARTER_SLOT[slot])
  end

  local function ensureStarterTrio(game)
    local a,b,c = starterAssigned("CYNDAQUIL"), starterAssigned("TOTODILE"), starterAssigned("CHIKORITA")
    if a and b and c and game.data.pokemon[a] and game.data.pokemon[b] and game.data.pokemon[c] then
      return a,b,c
    end
    local pool = eligibleStarterPool(game)
    if #pool < 3 then return "CYNDAQUIL","TOTODILE","CHIKORITA" end
    local ia = rngInt(1,#pool)
    local ib
    repeat ib = rngInt(1,#pool) until ib ~= ia
    local ic
    repeat ic = rngInt(1,#pool) until ic ~= ia and ic ~= ib
    a,b,c = pool[ia],pool[ib],pool[ic]
    saveStarterTrio(a,b,c)
    return a,b,c
  end

  local function starterForSlot(game, slot)
    ensureStarterTrio(game)
    return starterAssigned(slot)
  end

  local function starterIndexFor(game, species)
    local d = game and game.data and game.data.pokemon and game.data.pokemon[species]
    return d and (tonumber(d.index) or tonumber(d.dex)) or nil
  end

  local function starterSlotFromVanilla(v)
    return VANILLA_STARTER_INDEX[tonumber(v)]
  end

  local function substituteStarterCommand(game, cmd, field, slot)
    local r = {}
    for k,v in pairs(cmd) do r[k]=v end
    r[field] = starterIndexFor(game, starterForSlot(game,slot)) or cmd[field]
    if type(r.args)=="table" and #r.args>0 then
      local a = {}
      for i,v in ipairs(r.args) do a[i]=v end
      a[1]=r[field]
      r.args=a
    end
    return r
  end

  mod.hooks:wrap("save.new_game", function(next, save)
    local out = next(save)
    worldItemAssignments = {}
    mod.save:set(WORLD_ITEM_SAVE_KEY, worldItemAssignments)
    restoreRandomWorldItems()
    randomTMAssignments = {}
    mod.save:set(RANDOM_TM_SAVE_KEY, randomTMAssignments)
    if liveGame then syncRandomTMs(liveGame, true) end
    for _,key in pairs(STARTER_SLOT) do mod.save:set(key,nil) end
    mod.save:set("random_starter_chosen_slot",nil)
    mod.save:set("random_starter_rival_species",nil)
    return out
  end)

  mod.hooks:wrap("script.command", function(next, ctx, name, args, cmd)
    local wantsStarterSpecies = settings.randomStarters == true
    local wantsStarterMoves = false
    local wantsRandomLearnset = settings.randomMoveLearnset == true
    if not (wantsStarterSpecies or wantsStarterMoves or wantsRandomLearnset)
       or not (liveGame and ctx and ctx.vm and cmd) then
      return next(ctx,name,args,cmd)
    end
    if not starterIsLab(ctx) then return next(ctx,name,args,cmd) end

    local vm = ctx.vm

    if wantsStarterSpecies and name=="pokepic" then
      local slot = starterSlotFromVanilla(cmd.species or (cmd.args and cmd.args[1]))
      if slot then
        activeStarterBall[vm]=slot
        return next(ctx,name,args,substituteStarterCommand(liveGame,cmd,"species",slot))
      end
    elseif wantsStarterSpecies and name=="cry" and activeStarterBall[vm] then
      local r = {}
      for k,v in pairs(cmd) do r[k]=v end
      r.id = starterIndexFor(liveGame,starterForSlot(liveGame,activeStarterBall[vm])) or cmd.id
      if type(r.args)=="table" and #r.args>0 then
        local a={}
        for i,v in ipairs(r.args) do a[i]=v end
        a[1]=r.id
        r.args=a
      end
      return next(ctx,name,args,r)
    elseif wantsStarterSpecies and name=="writetext"
       and activeStarterBall[vm] and vm.nextOp=="yesorno" then
      local sp=starterForSlot(liveGame,activeStarterBall[vm])
      local d=liveGame.data.pokemon[sp]
      vm:showRaw("Take "..((d and d.name) or sp).."?")
      return nil
    elseif wantsStarterSpecies and name=="getmonname" and activeStarterBall[vm] then
      return next(ctx,name,args,substituteStarterCommand(
        liveGame,cmd,"species",activeStarterBall[vm]))
    elseif name=="givepoke" then
      local vanillaSpecies = cmd.species or (cmd.args and cmd.args[1])
      local slot = starterSlotFromVanilla(vanillaSpecies) or activeStarterBall[vm]
      if slot then
        local beforeCount = #(liveGame.save and liveGame.save.party or {})
        local actualCmd = cmd

        if wantsStarterSpecies then
          mod.save:set("random_starter_chosen_slot",slot)
          local rivalSlot=RIVAL_STARTER_SLOT[slot]
          mod.save:set("random_starter_rival_species",
            rivalSlot and starterForSlot(liveGame,rivalSlot) or nil)
          actualCmd=substituteStarterCommand(liveGame,cmd,"species",slot)
        end

        activeStarterBall[vm]=nil
        local out = next(ctx,name,args,actualCmd)

        local party = liveGame.save and liveGame.save.party or {}
        local starter = (#party > beforeCount) and party[#party] or nil
        if starter then
          if settings.randomMoveLearnset then
            -- The starter now exists as the real owned Gen 2 Mon. Apply the
            -- same current-move Random Learnset path that is already confirmed
            -- working when the option is toggled after receiving a Pokemon.
            if restoreActiveLearnsetProjection then
              restoreActiveLearnsetProjection()
            end
            enrollOwnedMon(starter, liveGame.data, true)
          end
          if wantsStarterMoves then
            -- If both are enabled, STARTER MOVES deliberately wins for the
            -- moves the starter begins with. Its future V9 learnset remains.
            randomizeStarterStartingMoves(starter, liveGame.data)
          end
        end
        return out
      end
    end
    return next(ctx,name,args,cmd)
  end)

  mod.events:on("script.ended", function(ev)
    local ctx=ev and ev.ctx
    if ctx and ctx.vm then activeStarterBall[ctx.vm]=nil end
    if liveGame and settings.randomMoveLearnset and syncOwnedRandomLearnsets then
      syncOwnedRandomLearnsets(liveGame, true)
    end
  end)

  -- The rival keeps the starter corresponding to the unchosen Elm ball.
  mod.hooks:wrap("trainer.party", function(next, oppClass, partyIndex, partyDef)
    local out=next(oppClass,partyIndex,partyDef)
    if not settings.randomStarters or not liveGame or type(out)~="table" then return out end
    local cn=tostring(oppClass or "")
    if cn~="RIVAL1" and cn~="RIVAL2" then return out end
    local sp=mod.save:get("random_starter_rival_species")
    if not sp or not liveGame.data.pokemon[sp] then return out end
    local r={}
    for i,m in ipairs(out) do
      if m and JOHTO_STARTER_LINE[m.species] then
        r[i]=Gen2Mon.new(liveGame.data,sp,m.level,{
          dvs={attack=9,defense=8,speed=8,special=8},item=m.item
        }) or m
      else r[i]=m end
    end
    return r
  end, 1100)

  mod.events:on("game.ready", function(ev)
    liveGame=ev and ev.game or liveGame
    if liveGame and settings.randomStarters then ensureStarterTrio(liveGame) end
    if liveGame and settings.randomMoveLearnset and syncOwnedRandomLearnsets then
      syncOwnedRandomLearnsets(liveGame, true)
    end
  end)



  mod.exports.isInstalled = function()
    return installed
  end
end
