-- ===========================================================================
-- Haikesi_Bean_Bridge.lua
-- 憨豆特工：实例改名（间谍公民名池 →「憨豆」）
-- SetName 在 GameplayScripts 不存在（function expected instead of nil）；
-- 原版改名走 UnitCommandTypes.NAME_UNIT（需约第 2 级；憨豆 InitialLevel=2）。
-- ===========================================================================

local BEAN_UNIT_TYPE = 'UNIT_NW_BEAN'
-- 实例名「憨豆」；单位类型名 LOC_UNIT_NW_BEAN_NAME =「特工」
local BEAN_NAME_LOC = 'LOC_UNIT_NW_BEAN_INSTANCE_NAME'
local MAX_RETRY_FRAMES = 30

local g_BeanUnitIndex = nil
-- { [unitID] = framesLeft } 仅本地玩家
local g_PendingRename = {}

local function GetBeanUnitIndex()
    if g_BeanUnitIndex ~= nil then
        return g_BeanUnitIndex
    end
    local row = GameInfo.Units[BEAN_UNIT_TYPE]
    if row == nil then
        return nil
    end
    g_BeanUnitIndex = row.Index
    return g_BeanUnitIndex
end

local function ResolveBeanDisplayName()
    local name = Locale.Lookup(BEAN_NAME_LOC)
    if name == nil or name == '' or name == BEAN_NAME_LOC then
        return '憨豆'
    end
    return name
end

local function IsAlreadyBeanName(pUnit)
    if pUnit == nil then
        return false
    end
    local raw = pUnit:GetName()
    if raw == nil then
        return false
    end
    if raw == BEAN_NAME_LOC then
        return true
    end
    return Locale.Lookup(raw) == ResolveBeanDisplayName()
end

local function TryRenameBeanUnit(pUnit)
    if pUnit == nil or IsAlreadyBeanName(pUnit) then
        return true
    end
    local localPlayer = Game.GetLocalPlayer()
    if localPlayer == nil or localPlayer < 0 or pUnit:GetOwner() ~= localPlayer then
        return true -- 非本地：不排队
    end
    if UnitCommandTypes == nil or UnitCommandTypes.NAME_UNIT == nil
        or UnitManager.RequestCommand == nil then
        print('[Haikesi Bean UI] NAME_UNIT / RequestCommand unavailable')
        return true
    end

    -- 间谍通常 CanStartCommand(NAME_UNIT)=false（老兵改名门槛）；勿空转 RequestCommand
    if UnitManager.CanStartCommand ~= nil
        and UnitManager.CanStartCommand(pUnit, UnitCommandTypes.NAME_UNIT, true) ~= true then
        print(string.format(
            '[Haikesi Bean UI] unit#%d NAME_UNIT locked; rely on UnitPanel instance-name fallback',
            pUnit:GetID()))
        return true
    end

    local tParameters = {}
    tParameters[UnitCommandTypes.PARAM_NAME] = BEAN_NAME_LOC
    UnitManager.RequestCommand(pUnit, UnitCommandTypes.NAME_UNIT, tParameters)

    local ok = IsAlreadyBeanName(pUnit)
    print(string.format(
        '[Haikesi Bean UI] NAME_UNIT unit#%d applied=%s',
        pUnit:GetID(), tostring(ok)))
    return ok
end

local function QueueRename(pUnit)
    if pUnit == nil then
        return
    end
    if TryRenameBeanUnit(pUnit) then
        g_PendingRename[pUnit:GetID()] = nil
        return
    end
    g_PendingRename[pUnit:GetID()] = MAX_RETRY_FRAMES
end

local function RenameAllBeanUnitsForPlayer(iPlayer)
    local beanIndex = GetBeanUnitIndex()
    if beanIndex == nil then
        return
    end
    local pPlayer = Players[iPlayer]
    if pPlayer == nil then
        return
    end
    local units = pPlayer:GetUnits()
    if units == nil then
        return
    end
    for _, unit in units:Members() do
        if unit and unit:GetType() == beanIndex then
            QueueRename(unit)
        end
    end
end

local function OnUnitAddedToMap(iPlayer, iUnit)
    local beanIndex = GetBeanUnitIndex()
    if beanIndex == nil then
        return
    end
    local pUnit = UnitManager.GetUnit(iPlayer, iUnit)
    if pUnit == nil or pUnit:GetType() ~= beanIndex then
        return
    end
    QueueRename(pUnit)
end

local function OnLocalPlayerTurnBegin()
    local localPlayer = Game.GetLocalPlayer()
    if localPlayer == nil or localPlayer < 0 then
        return
    end
    RenameAllBeanUnitsForPlayer(localPlayer)
end

local function ProcessPendingRenames()
    local localPlayer = Game.GetLocalPlayer()
    if localPlayer == nil or localPlayer < 0 then
        return
    end
    local beanIndex = GetBeanUnitIndex()
    if beanIndex == nil then
        return
    end

    local done = {}
    for unitID, framesLeft in pairs(g_PendingRename) do
        local pUnit = UnitManager.GetUnit(localPlayer, unitID)
        if pUnit == nil or pUnit:GetType() ~= beanIndex then
            table.insert(done, unitID)
        elseif TryRenameBeanUnit(pUnit) then
            table.insert(done, unitID)
        else
            framesLeft = framesLeft - 1
            if framesLeft <= 0 then
                print(string.format(
                    '[Haikesi Bean UI] rename give up unit#%d (NAME_UNIT not accepted; panel fallback still shows 憨豆)',
                    unitID))
                table.insert(done, unitID)
            else
                g_PendingRename[unitID] = framesLeft
            end
        end
    end
    for _, unitID in ipairs(done) do
        g_PendingRename[unitID] = nil
    end
end

local function Initialize()
    Events.UnitAddedToMap.Add(OnUnitAddedToMap)
    Events.LocalPlayerTurnBegin.Add(OnLocalPlayerTurnBegin)
    Events.GameCoreEventPublishComplete.Add(ProcessPendingRenames)
    local localPlayer = Game.GetLocalPlayer()
    if localPlayer ~= nil and localPlayer >= 0 then
        RenameAllBeanUnitsForPlayer(localPlayer)
    end
    print('[Haikesi Bean UI] rename bridge ready (NAME_UNIT)')
end

Events.LoadScreenClose.Add(Initialize)
