-- ===========================================================================
-- Haikesi_CrashHeli_Bridge.lua
-- 铝翼坠毁：Gameplay 经 ExposedMembers 回调播爆炸 VFX（跨 VM 的 LuaEvents 不可靠）
-- ===========================================================================

-- 优先用风暴灾难核熔毁特效；失败再试原版可见特效名
local EXPLOSION_VFX_CANDIDATES = {
    'DISASTER_NUCLEAR_MELTDOWN',
    'WONDER_CREATED',
    'DISTRICT_CREATED',
}

local function PlayBoomAt(x, y, damage)
    x = tonumber(x)
    y = tonumber(y)
    damage = tonumber(damage) or 50
    if x == nil or y == nil then
        print('[Haikesi CrashHeli UI] PlayBoom skip — bad xy')
        return
    end

    local played = false
    if WorldView ~= nil and WorldView.PlayEffectAtXY ~= nil then
        for _, vfx in ipairs(EXPLOSION_VFX_CANDIDATES) do
            local ok = pcall(function()
                WorldView.PlayEffectAtXY(vfx, x, y, true)
            end)
            if ok then
                played = true
                print(string.format('[Haikesi CrashHeli UI] PlayEffectAtXY %s at (%d,%d)', vfx, x, y))
                break
            end
        end
    else
        print('[Haikesi CrashHeli UI] WorldView.PlayEffectAtXY unavailable')
    end

    if UI ~= nil and UI.AddWorldViewText ~= nil and EventSubTypes ~= nil then
        pcall(function()
            UI.AddWorldViewText(EventSubTypes.DAMAGE, tostring(damage), x, y, 0)
        end)
    end

    print(string.format(
        '[Haikesi CrashHeli UI] explode boom at (%d,%d) dmg=%d played=%s',
        x, y, damage, tostring(played)))
end

local function Initialize()
    if ExposedMembers ~= nil then
        ExposedMembers.Haikesi_CrashHeliPlayBoom = PlayBoomAt
    end
    -- 仍挂 LuaEvents 作备用（若某端共享事件表）
    if LuaEvents ~= nil then
        LuaEvents.Haikesi_CrashHeliExplode.Add(PlayBoomAt)
    end
    print('[Haikesi CrashHeli UI] bridge ready (ExposedMembers.Haikesi_CrashHeliPlayBoom)')
end

Events.LoadScreenClose.Add(Initialize)
