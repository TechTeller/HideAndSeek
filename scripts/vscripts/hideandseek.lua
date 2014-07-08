print ('[hideandseek] hideandseek.lua' )

USE_LOBBY = false
THINK_TIME = 0.1

STARTING_GOLD = 500--650
MAX_LEVEL = 50

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
  GameRules:SetPreGameTime( 30.0)
  GameRules:SetPostGameTime( 60.0 )
  GameRules:SetTreeRegrowTime( 60.0 )
  GameRules:SetUseCustomHeroXPValues ( true )
  GameRules:SetGoldPerTick(0)
  print('[hideandseek] Rules set')

  InitLogFile( "log/hideandseek.txt","")
  -- Hooks
  ListenToGameEvent('player_connect_full', Dynamic_Wrap(HideAndSeekGameMode, 'AutoAssignPlayer'), self)
  ListenToGameEvent('player_disconnect', Dynamic_Wrap(HideAndSeekGameMode, 'CleanupPlayer'), self)

  -- Change random seed
  local timeTxt = string.gsub(string.gsub(GetSystemTime(), ':', ''), '0','')
  math.randomseed(tonumber(timeTxt))

  -- Timers
  self.timers = {}

  -- userID map
  self.vUserNames = {}
  self.vUserIds = {}
  self.vSteamIds = {}
  self.vBots = {}
  self.vBroadcasters = {}

  self.vPlayers = {}
  self.vRadiant = {}
  self.vDire = {}
  self.Seeker = nil

  -- Active Hero Map
  self.vPlayerHeroData = {}
  print('[hideandseek] values set')

  print('[hideandseek] Precaching stuff...')
  PrecacheUnitByName('npc_precache_everything')
  print('[hideandseek] Done precaching!') 

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

local propinit = false

function HideAndSeekGameMode:AutoAssignPlayer(keys)
    if propinit == false then
      for k,v in pairs(Entities:FindAllByClassname("prop_dynamic")) do 
        local u = CreateUnitByName( "npc_tree_dummy", Vector(0,0,0), false, nil, nil, DOTA_TEAM_BADGUYS)
        u:SetOrigin(v:GetOrigin())
        u:RemoveModifierByName("modifier_invulnerable")
        u:AddNewModifier(u, nil, "modifier_phased", {duration = -1})
        propinit = true
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
  
  -- If we're not on D2MODD.in, assign players round robin to teams
  if not USE_LOBBY and playerID == -1 then
    if #self.vDire > #self.vRadiant and #self.vDire == 1 then
      ply:SetTeam(DOTA_TEAM_GOODGUYS)
      ply:__KeyValueFromInt('teamnumber', DOTA_TEAM_GOODGUYS)
      table.insert (self.vRadiant, ply)
    else
      ply:SetTeam(DOTA_TEAM_BADGUYS)
      ply:__KeyValueFromInt('teamnumber', DOTA_TEAM_BADGUYS)
      table.insert (self.vDire, ply)
      self.Seeker = ply
      local hero = CreateHeroForPlayer("npc_dota_hero_ancient_apparition", ply)
      hero:SetAbilityPoints(3)
    end
    playerID = ply:GetPlayerID()
  end
end

function HideAndSeekGameMode:LoopOverPlayers(callback)
  for k, v in pairs(self.vPlayers) do
    -- Validate the player
    if IsValidEntity(v.hero) then
      -- Run the callback
      if callback(v, v.hero:GetPlayerID()) then
        break
      end
    end
  end
end

function HideAndSeekGameMode:Think()
  if GameRules:State_Get() == DOTA_GAMERULES_STATE_PRE_GAME then
    HideAndSeekGameMode:InitRounds()
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

  --HideAndSeekGameMode:thinkState( dt )

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

      else
        -- Nope, handle the error
        HideAndSeekGameMode:HandleEventError('Timer', k, nextCall)
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

function HideAndSeekGameMode:InitRounds()
  if round == 0 then
    useGameTime = true
    local msg = {
                    message = "Game is starting! Hiders, hide!",
                    duration = 29.8
                }
      FireGameEvent("show_center_message",msg)
      HideAndSeekGameMode:RoundLogic()
    end
end

function HideAndSeekGameMode:RoundLogic()
    round = 1
    self:CreateTimer('round'..round, {
    endTime = Time() + 90,
    callback = function(hideandseek, args)
      
    end})
end

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
  unit:SetAngles(caster:GetAngles().x, caster:GetAngles().y, caster:GetAngles().z)
  caster:AddNewModifier(caster, nil, "modifier_rooted", {duration = -1})
  caster:SetModel("models/development/invisiblebox.mdl")
  local disguiseability = caster:FindAbilityByName("disguise")
  disguiseability:SetLevel(0)
end

function SolidifyOff( keys )
  local caster = keys.caster
  caster:RemoveModifierByName("modifier_rooted")
  local prop = Entities:FindByClassnameNearest("prop_dynamic", caster:GetOrigin(), 1.0)
  caster:SetModel(prop:GetModelName())
  local disguiseability = caster:FindAbilityByName("disguise")
  disguiseability:SetLevel(1)
  prop:Remove()
end