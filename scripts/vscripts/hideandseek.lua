print ('[hideandseek] hideandseek.lua' )

HNS_VERSION = "0.00.01"
USE_LOBBY = false
THINK_TIME = 0.1

STARTING_GOLD = 500--650
MAX_LEVEL = 50

bInPreRound = true
roundOne = true

ROUNDS_TO_WIN = 3
ROUND_TIME = 10 --240
PRE_GAME_TIME = 30 -- 30
PRE_ROUND_TIME = 30 --30
POST_ROUND_TIME = 5
POST_GAME_TIME = 30
-------------------------------------------------------------------------------------------
GameMode = nil

if HideAndSeekGameMode == nil then
  print ( '[hideandseek] creating hideandseek game mode' )
  HideAndSeekGameMode = {}
  HideAndSeekGameMode.szEntityClassName = "hideandseek"
  HideAndSeekGameMode.szNativeClassName = "dota_base_game_mode"
  HideAndSeekGameMode.__index = HideAndSeekGameMode
end

function HideAndSeekGameMode:new( o )
  print ( '[hideandseek] HideAndSeekGameMode:new' )
  o = o or {}
  setmetatable( o, HideAndSeekGameMode )
  return o
end

function HideAndSeekGameMode:InitGameMode()

  -- Setup rules
  GameRules:SetHeroRespawnEnabled( false )
  GameRules:SetUseUniversalShopMode( true )
  GameRules:SetSameHeroSelectionEnabled( false )
  GameRules:SetHeroSelectionTime( 30.0 )
  GameRules:SetPreGameTime( PRE_GAME_TIME)
  GameRules:SetPostGameTime( POST_GAME_TIME )
  GameRules:SetTreeRegrowTime( 60.0 )
  GameRules:SetUseCustomHeroXPValues ( true )
  GameRules:SetGoldPerTick(0)
  print('[hideandseek] Rules set')

  InitLogFile( "log/hideandseek.txt","")
  -- Hooks
  ListenToGameEvent('player_connect_full', Dynamic_Wrap(HideAndSeekGameMode, 'AutoAssignPlayer'), self)
  ListenToGameEvent('player_disconnect', Dynamic_Wrap(HideAndSeekGameMode, 'CleanupPlayer'), self)

  -- Fill server with fake clients
  Convars:RegisterCommand('fake', function()
    -- Check if the server ran it
    if not Convars:GetCommandClient() then
      -- Create fake Players
      SendToServerConsole('dota_create_fake_clients')
      
      local fakes = {
        "npc_dota_hero_ancient_apparition",
        "npc_dota_hero_antimage",
        "npc_dota_hero_bane",
        "npc_dota_hero_beastmaster",
        "npc_dota_hero_bloodseeker",
        "npc_dota_hero_chen",
        "npc_dota_hero_crystal_maiden",
        "npc_dota_hero_dark_seer",
        "npc_dota_hero_dazzle",
        "npc_dota_hero_dragon_knight",
        "npc_dota_hero_doom_bringer"
      }
        
      self:CreateTimer('assign_fakes', {
        endTime = Time(),
        callback = function(hideandseek, args)
          for i=0, 9 do
            -- Check if this player is a fake one
            if PlayerResource:IsFakeClient(i) then
              -- Grab player instance
              local ply = PlayerResource:GetPlayer(i)
              -- Make sure we actually found a player instance
              if ply then
                CreateHeroForPlayer(fakes[i], ply)
              end
            end
          end
          
          local ply = Convars:GetCommandClient()
          local plyID = ply:GetPlayerID()
          local hero = ply:GetAssignedHero()
          for k,v in pairs(HeroList:GetAllHeroes()) do
            if v ~= hero then
              v:SetControllableByPlayer(plyID, true)
            end
          end
        end})
    end
  end, 'Connects and assigns fake Players.', 0)

  -- Change random seed
  local timeTxt = string.gsub(string.gsub(GetSystemTime(), ':', ''), '0','')
  math.randomseed(tonumber(timeTxt))


  -- Round stuff
  self.nCurrentRound = 1
  self.nRadiantDead = 0
  self.nDireDead = 0
  self.nLastKilled = nil
  self.fRoundStartTime = 0

  self.Hunters = {}
  self.Props = {}

  self.PropsTeam = "Dire"
  self.HunterTeam = "Radiant"


  -- Timers
  self.timers = {}

  -- userID map
  self.vUserNames = {}
  self.vUserIds = {}
  self.vSteamIds = {}
  self.vBots = {}
  self.vBroadcasters = {}
  self.nConnected = 0

  self.vPlayers = {}
  self.vRadiant = {}
  self.vDire = {}

  -- Active Hero Map
  self.vPlayerHeroData = {}
  self.bPlayersInit = false
  print('[hideandseek] values set')

  print('[hideandseek] Precaching stuff...')
  PrecacheUnitByName('npc_precache_everything')
  print('[hideandseek] Done precaching!') 
  self.thinkState = Dynamic_Wrap( HideAndSeekGameMode, '_thinkState_Prep' )

  print('[hideandseek] Done loading hideandseek gamemode!\n\n')
end

function HideAndSeekGameMode:CaptureGameMode()
  if GameMode == nil then
    -- Set GameMode parameters
    GameMode = GameRules:GetGameModeEntity()		
    -- Disables recommended items...though I don't think it works
    GameMode:SetRecommendedItemsDisabled( true )
    -- Override the normal camera distance.  Usual is 1134
    GameMode:SetCameraDistanceOverride( 1504.0 )
    -- Set Buyback options
    GameMode:SetCustomBuybackCostEnabled( true )
    GameMode:SetCustomBuybackCooldownEnabled( true )
    GameMode:SetBuybackEnabled( false )
    -- Override the top bar values to show your own settings instead of total deaths
    GameMode:SetTopBarTeamValuesOverride ( true )
    -- Use custom hero level maximum and your own XP per level
    GameMode:SetUseCustomHeroLevels ( true )
    GameMode:SetCustomHeroMaxLevel ( MAX_LEVEL )
    GameMode:SetCustomXPRequiredToReachNextLevel( XP_PER_LEVEL_TABLE )
    -- Chage the minimap icon size
    GameRules:SetHeroMinimapIconSize( 300 )

    print( '[hideandseek] Beginning Think' ) 
    GameMode:SetContextThink("hideandseekThink", Dynamic_Wrap( HideAndSeekGameMode, 'Think' ), 0.1 )
  end 
end

function HideAndSeekGameMode:ShowCenterMessage(msg,dur)
  local msg = {
    message = msg,
    duration = dur
  }
  FireGameEvent("show_center_message",msg)
end

local propinit = false

function HideAndSeekGameMode:AutoAssignPlayer(keys)
    if propinit == false then
      for k,v in pairs(Entities:FindAllByClassname("prop_dynamic")) do 
        local u = CreateUnitByName( "npc_tree_dummy", Vector(0,0,0), false, nil, nil, DOTA_TEAM_NEUTRALS)
        u:SetOrigin(v:GetOrigin())
        u:RemoveModifierByName("modifier_invulnerable")
      end
    end
  print ('[hideandseek] AutoAssignPlayer')
  PrintTable(keys)
  HideAndSeekGameMode:CaptureGameMode()
  
  local entIndex = keys.index+1
  -- The Player entity of the joining user
  local ply = EntIndexToHScript(entIndex)
  
  -- The Player ID of the joining player
  local playerID = ply:GetPlayerID()
  
  -- Update the user ID table with this user
  self.vUserIds[keys.userid] = ply
  -- Update the Steam ID table
  self.vSteamIds[PlayerResource:GetSteamAccountID(playerID)] = ply
  
  -- If the player is a broadcaster flag it in the Broadcasters table
  if PlayerResource:IsBroadcaster(playerID) then
    self.vBroadcasters[keys.userid] = 1
    return
  end
  
  -- If this player is a bot (spectator) flag it and continue on
  if self.vBots[keys.userid] ~= nil then
    return
  end

  
  playerID = ply:GetPlayerID()
  -- Figure out if this player is just reconnecting after a disconnect
  if self.vPlayers[playerID] ~= nil then
    self.vUserIds[keys.userid] = ply
    return
  end

   self.vPlayers[playerID] = ply
  -- If we're not on D2MODD.in, assign players round robin to teams
  if not USE_LOBBY and playerID == -1 then
    if #self.vRadiant > #self.vDire then 
      ply:SetTeam(DOTA_TEAM_BADGUYS)
      ply:__KeyValueFromInt('teamnumber', DOTA_TEAM_BADGUYS)
      table.insert (self.vDire, ply)
      local hero = CreateHeroForPlayer("npc_dota_hero_ancient_apparition", ply)
      hero:SetAbilityPoints(0)
      local ab1 = hero:FindAbilityByName("disguise")
      ab1:SetLevel(4)
      local ab2 = hero:FindAbilityByName("solidify")
      ab2:SetLevel(4)
      local ab3 = hero:FindAbilityByName("dash")
      ab3:SetLevel(4)
      local ab4 = hero:FindAbilityByName("taunt")
      ab4:SetLevel(3)
    else
      ply:SetTeam(DOTA_TEAM_GOODGUYS)
      ply:__KeyValueFromInt('teamnumber', DOTA_TEAM_GOODGUYS)
      table.insert (self.vRadiant, ply)
      local hero = CreateHeroForPlayer("npc_dota_hero_templar_assassin", ply)
      local slingshot = CreateItem("item_slingshot", hero, hero)
      hero:AddItem(slingshot)    
    end
    playerID = ply:GetPlayerID()
    self.nConnected = self.nConnected + 1
  end
  self:InitializeRound()
end

function HideAndSeekGameMode:LoopOverPlayers(callback)
  for k, v in pairs(self.vPlayers) do
    -- Validate the player
    print ('looping')
    if IsValidEntity(v.hero) then
      print('is valid')
      print(v.hero)
      -- Run the callback
      if callback(v, v.hero:GetPlayerID()) then
        break
      end
    end
  end
end

function HideAndSeekGameMode:_thinkState_Prep( dt )
  --print ( '[HideAndSeek] _thinkState_Prep' )
  if GameRules:State_Get() ~= DOTA_GAMERULES_STATE_PRE_GAME then
    -- Waiting on the game to start..
    return
  end

  self.thinkState = Dynamic_Wrap( HideAndSeekGameMode, '_thinkState_None' )
  self:InitializeRound()
end

function HideAndSeekGameMode:_thinkState_None( dt )
  return
end

function HideAndSeekGameMode:Think()
  if GameRules:State_Get() == DOTA_GAMERULES_STATE_PRE_GAME then
  end
  -- If the game's over, it's over.
  if GameRules:State_Get() >= DOTA_GAMERULES_STATE_POST_GAME then
    return
  end

  -- Track game time, since the dt passed in to think is actually wall-clock time not simulation time.
  local now = GameRules:GetGameTime()
  --print("now: " .. now)
  if HideAndSeekGameMode.t0 == nil then
    HideAndSeekGameMode.t0 = now
  end
  local dt = now - HideAndSeekGameMode.t0
  HideAndSeekGameMode.t0 = now

  HideAndSeekGameMode:thinkState( dt )

  -- Process timers
  for k,v in pairs(HideAndSeekGameMode.timers) do
    local bUseGameTime = false
    if v.useGameTime and v.useGameTime == true then
      bUseGameTime = true;
    end
    -- Check if the timer has finished
    if (bUseGameTime and GameRules:GetGameTime() > v.endTime) or (not bUseGameTime and Time() > v.endTime) then
      -- Remove from timers list
      HideAndSeekGameMode.timers[k] = nil

      -- Run the callback
      local status, nextCall = pcall(v.callback, HideAndSeekGameMode, v)

      -- Make sure it worked
      if status then
        -- Check if it needs to loop
        if nextCall then
          -- Change it's end time
          v.endTime = nextCall
          HideAndSeekGameMode.timers[k] = v
        end
      end
    end
  end

  return THINK_TIME
end

function HideAndSeekGameMode:CreateTimer(name, args)
  --[[
  args: {
  endTime = Time you want this timer to end: Time() + 30 (for 30 seconds from now),
  useGameTime = use Game Time instead of Time()
  callback = function(frota, args) to run when this timer expires,
  text = text to display to clients,
  send = set this to true if you want clients to get this,
  persist = bool: Should we keep this timer even if the match ends?
  }

  If you want your timer to loop, simply return the time of the next callback inside of your callback, for example:

  callback = function()
  return Time() + 30 -- Will fire again in 30 seconds
  end
  ]]

  if not args.endTime or not args.callback then
    print("Invalid timer created: "..name)
    return
  end

  -- Store the timer
  self.timers[name] = args
end

function HideAndSeekGameMode:RemoveTimer(name)
  -- Remove this timer
  self.timers[name] = nil
end

function HideAndSeekGameMode:RemoveTimers(killAll)
  local timers = {}

  -- If we shouldn't kill all timers
  if not killAll then
    -- Loop over all timers
    for k,v in pairs(self.timers) do
      -- Check if it is persistant
      if v.persist then
        -- Add it to our new timer list
        timers[k] = v
      end
    end
  end

  -- Store the new batch of timers
  self.timers = timers
end

ROUNDS_PER_GAME = 10
round = 0
POST_ROUND_TIME = 15

function Disguise( keys )
  local caster = keys.caster
  local target = keys.target
  local modelunit = Entities:FindByClassnameNearest("prop_dynamic", target:GetOrigin(), 1.0)
  caster:SetModel(modelunit:GetModelName())
  print(modelunit:GetModelName())
end

function SolidifyOn( keys )
  local caster = keys.caster
  local unit = Entities:CreateByClassname( "prop_dynamic" )
  unit:SetOrigin(caster:GetOrigin())
  unit:SetModel(caster:GetModelName())  
  caster:SetOriginalModel("models/development/invisiblebox.mdl")
  unit:SetAngles(caster:GetAngles().x, caster:GetAngles().y, caster:GetAngles().z)
  caster:AddNewModifier(caster, nil, "modifier_rooted", {duration = -1})  
  caster:AddNewModifier(caster, nil, "modifier_persistent_invisibility", {duration = -1})
  local disguiseability = caster:FindAbilityByName("disguise")
  disguiseability:SetLevel(0)
end

function SolidifyOff( keys )
  local caster = keys.caster
  caster:RemoveModifierByName("modifier_rooted")
  caster:RemoveModifierByName("modifier_persistent_invisibility")
  local prop = Entities:FindByClassnameNearest("prop_dynamic", caster:GetOrigin(), 1.0)
  caster:SetModel(prop:GetModelName())
  caster:SetOriginalModel(prop:GetModelName())
  local disguiseability = caster:FindAbilityByName("disguise")
  disguiseability:SetLevel(1)
  prop:Remove()
end

function Taunt( keys )
  local timeTxt = string.gsub(string.gsub(GetSystemTime(), ':', ''), '0','')
  math.randomseed(tonumber(timeTxt))
  local caster = keys.caster
  -- Change random seed
  local timeTxt = string.gsub(string.gsub(GetSystemTime(), ':', ''), '0','')
  math.randomseed(tonumber(timeTxt))
  local tauntNumber = math.random(1,35)
  --caster:EmitSound("sound/Taunt_"..tostring(tauntNumber))
    EmitSoundOn("Taunt_"..tostring(tauntNumber), caster)
  print (tostring(tauntNumber))
end

local roundOne = true
function HideAndSeekGameMode:InitializeRound()
  print ( '[REFLEX] InitializeRound called' )
  bInPreRound = true
  GameRules:SetUseUniversalShopMode( true )

  --cancelTimer = false
  --Init Round (give level ups/points/gold back)
  self:RemoveTimer('playerInit')
  self:CreateTimer('playerInit', {
  endTime = Time(),
  callback = function(hideandseek, args)
    if not bInPreRound then
      return Time() + 0.5
    end
    self:LoopOverPlayers(function(player, plyID)
      if player.bRoundInit == false then
        print ( '[REFLEX] Initializing player ' .. plyID)
        player.bRoundInit = true
        player.hero:RespawnHero(false, false, false)

        if not player.hero:HasModifier("modifier_stunned") then
          player.hero:AddNewModifier( player.hero, nil , "modifier_stunned", {})
        end

        if not player.hero:HasModifier("modifier_invulnerable") then
          player.hero:AddNewModifier(player.hero, nil , "modifier_invulnerable", {})
        end
      end
    end)

    return Time() + 0.5
  end})

  local roundTime = PRE_ROUND_TIME + PRE_GAME_TIME
  PRE_GAME_TIME = 0
  
  self:ShowCenterMessage(string.format("Round %d starts in %d seconds!", self.nCurrentRound, roundTime), 10)
  
  if roundOne then
    self:CreateTimer('reflexDetail', {
      endTime = GameRules:GetGameTime() + 10,
      useGameTime = true,
      callback = function(hideandseek, args)
        GameRules:SendCustomMessage("Welcome to <font color='#70EA72'>Hide and Seek!</font>", 0, 0)
        GameRules:SendCustomMessage("Version: " .. HNS_VERSION, 0, 0)
        GameRules:SendCustomMessage("Created by <font color='#70EA72'>TechTeller</font>", 0, 0)
        GameRules:SendCustomMessage("Map by <font color='#70EA72'>Azarak</font>", 0, 0)
        GameRules:SendCustomMessage("Send feedback to <font color='#70EA72'>techteller96@gmail.com</font>", 0, 0)
      end
    })
    roundOne = false
  end
  
  local startCount = 7
  --Set Timers for round start announcements
  self:CreateTimer('round_start_timer', {
  endTime = GameRules:GetGameTime() + roundTime - 10,
  useGameTime = true,
  callback = function(hideandseek, args)
    startCount = startCount - 1
    if startCount == 0 then
      self.fRoundStartTime = GameRules:GetGameTime()
      self:LoopOverPlayers(function(player, plyID)

        --if has modifier remove it
        if player.hero:HasModifier("modifier_stunned") then
          player.hero:RemoveModifierByName("modifier_stunned")
        end
        
        if player.hero:HasModifier("modifier_invulnerable") then
          player.hero:RemoveModifierByName("modifier_invulnerable")
        end

        local timeoutCount = 14
        self:CreateTimer('round_time_out',{
        endTime = GameRules:GetGameTime() + ROUND_TIME - 120,
        useGameTime = true,
        callback = function(hideandseek, args)
          timeoutCount = timeoutCount - 1
          if timeoutCount == 0 then 
            -- TIME OUT
            self:LoopOverPlayers(function(player, plyID)
              player.hero:AddNewModifier( player.hero, nil , "modifier_stunned", {})
              player.hero:AddNewModifier( player.hero, nil , "modifier_invulnerable", {})
            end)
            self:CreateTimer('victory', {
              endTime = Time() + POST_ROUND_TIME,
              callback = function(hideandseek, args)
                HideAndSeekGameMode:RoundComplete(true)
              end})

            return
          elseif timeoutCount == 13 then
            self:ShowCenterMessage("2 minutes remaining!", 5)
            return GameRules:GetGameTime() + 60
          elseif timeoutCount == 12 then
            Say(nil, "1 minute remaining!", false)
            return GameRules:GetGameTime() + 30
          elseif timeoutCount == 11 then
            self:ShowCenterMessage("30 seconds remaining!", 5)
            return GameRules:GetGameTime() + 20
          else
            local msg = {
              message = tostring(timeoutCount),
              duration = 0.9
            }
            FireGameEvent("show_center_message",msg)
            return GameRules:GetGameTime() + 1
          end
        end})
      end)

      bInPreRound = false;
      local msg = {
        message = "GO!",
        duration = 0.9
      }
      FireGameEvent("show_center_message",msg)
      return
    elseif startCount == 6 then
      self:ShowCenterMessage("10 seconds remaining!", 5)
      return GameRules:GetGameTime() + 5
    else
      local msg = {
        message = tostring(startCount),
        duration = 0.9
      }
      FireGameEvent("show_center_message",msg)
      return GameRules:GetGameTime() + 1
    end
  end})
end

function HideAndSeekGameMode:RoundComplete(timedOut)
  print ('[REFLEX] Round Complete')
  
  self:RemoveTimer('round_start_timer')
  self:RemoveTimer('round_time_out')
  self:RemoveTimer('victory')

  local elapsedTime = GameRules:GetGameTime() - self.fRoundStartTime - POST_ROUND_TIME

  -- Determine Victor and boost Dire/Radiant score
  local victor = DOTA_TEAM_GOODGUYS
  local s = "Radiant"
  if timedOut then
    --If hunters dont kill anyone, boost props score
    if self.nLastKilled == nil then 
      if self.PropsTeam == "Dire" then
        victor = DOTA_TEAM_BADGUYS
        s = "Radiant"
      end
    end
  else
    -- Find someone alive and declare that team the winner (since all other team is dead)
    self:LoopOverPlayers(function(player, plyID)
      if player.bDead == false then
        victor = player.nTeam
        if victor == DOTA_TEAM_BADGUYS then
          s = "Dire"
        end
      end
    end)
  end

  if victor == DOTA_TEAM_GOODGUYS then
    self.nRadiantScore = self.nRadiantScore + 1
  else
    self.nDireScore = self.nDireScore + 1
  end

  GameMode:SetTopBarTeamValue ( DOTA_TEAM_BADGUYS, self.nDireScore )
  GameMode:SetTopBarTeamValue ( DOTA_TEAM_GOODGUYS, self.nRadiantScore )

  Say(nil, s .. " WINS the round!", false)

  -- Check if at max round
  -- Complete game entirely and declare an overall victor
  if self.nRadiantScore == ROUNDS_TO_WIN then
    Say(nil, "RADIANT WINS!!  Well Played!", false)
    GameRules:SetSafeToLeave( true )
    GameRules:SetGameWinner( DOTA_TEAM_GOODGUYS )
    self:CreateTimer('endGame', {
    endTime = Time() + POST_GAME_TIME,
    callback = function(hideandseek, args)
      --HideAndSeekGameMode:CloseServer()
    end})
    return
  elseif self.nDireScore == ROUNDS_TO_WIN then
    Say(nil, "DIRE WINS!!  Well Played!", false)
    GameRules:SetSafeToLeave( true )
    GameRules:SetGameWinner( DOTA_TEAM_BADGUYS )
    self:CreateTimer('endGame', {
    endTime = Time() + POST_GAME_TIME,
    callback = function(hideandseek, args)
      --HideAndSeekGameMode:CloseServer()
    end})
    return
  end

  self:LoopOverPlayers(function(player, plyID)
    player.bRoundInit = false
  end)


  self.nCurrentRound = self.nCurrentRound + 1
  self.nRadiantDead = 0
  self.nDireDead = 0

  self:InitializeRound()
end