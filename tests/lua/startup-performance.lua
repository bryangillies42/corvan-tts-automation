-- Execute the real bootstrap and runtime in separate Lua environments, with a
-- queued clock: immediate Wait mocks cannot detect duplicate work in one frame.
local function copy(value)
    if type(value) ~= 'table' then return value end
    local result = {}
    for key, item in pairs(value) do result[key] = copy(item) end
    return result
end

local function world(helperFirst, automaticSpending, bootstrapSource)
    local w = {
        tick = 0, queue = {}, json = {}, requests = {}, conditions = {},
        xmlSets = 0, attributeSets = 0, renderPasses = 0, registrations = 0,
        reloads = 0, fallbackButtons = 0, failAttribute = false,
        attributes = {}, installedXml = '',
    }
    local function enqueue(callback, frames)
        table.insert(w.queue, {callback = callback, tick = w.tick + frames})
    end
    function w.flush()
        local iterations = 0
        while #w.queue > 0 do
            iterations = iterations + 1
            assert(iterations < 1000, 'startup event loop did not converge')
            local index = 1
            for i, pending in ipairs(w.queue) do
                if pending.tick < w.queue[index].tick then index = i end
            end
            local pending = table.remove(w.queue, index)
            w.tick = pending.tick
            pending.callback()
        end
    end
    local json = {
        encode = function(value)
            local token = 'JSON:' .. tostring(#w.json + 1)
            w.json[#w.json + 1] = copy(value)
            return token
        end,
        decode = function(text)
            local index = tonumber(string.match(text, '^JSON:(%d+)$'))
            if index then return copy(w.json[index]) end
            return copy(CHARACTER_CONFIG)
        end,
    }
    local function environment(source, label, object)
        local env = {}
        env._G = env
        setmetatable(env, {__index = _G})
        env.JSON = json
        env.self = object
        env.Wait = {
            frames = function(callback, frames) enqueue(callback, frames) end,
            time = function(callback, seconds) enqueue(callback, math.ceil(seconds * 60)) end,
            condition = function(callback, condition, _, timeout)
                table.insert(w.conditions, timeout)
                enqueue(function()
                    assert(condition(), 'UI never became ready')
                    callback()
                end, 1)
            end,
        }
        env.WebRequest = {get = function(_, callback) table.insert(w.requests, callback) end}
        env.getObjectFromGUID = function(guid)
            if guid == 'panel' then return w.panel end
            if guid == 'helper' then return w.helper end
        end
        env.getAllObjects = function() return {w.panel, w.helper} end
        env.printToColor = function() end
        env.log = function() end
        env.Player = {getPlayers = function() return {} end}
        env.spawnObject = function() error('healthy saved helper was not reused') end
        local chunk, message = load(source, label, 't', env)
        assert(chunk, message)
        chunk()
        return env
    end
    w.panel = {
        getGUID = function() return 'panel' end,
        createButton = function() w.fallbackButtons = w.fallbackButtons + 1 end,
        clearButtons = function() w.fallbackButtons = 0 end,
        UI = {
            loading = false,
            getXml = function() return w.installedXml end,
            setXml = function(xml)
                w.xmlSets = w.xmlSets + 1
                w.panel.UI.loading = true
                enqueue(function()
                    w.installedXml = xml
                    w.attributes = {}
                    w.panel.UI.loading = false
                end, 1)
            end,
            setAttribute = function(id, attribute, value)
                assert(not w.panel.UI.loading, 'attribute sent before UI readiness')
                assert(string.find(w.installedXml, 'id="' .. id .. '"', 1, true), 'missing UI ID')
                if w.failAttribute then error('transient attribute failure') end
                w.attributeSets = w.attributeSets + 1
                w.attributes[id .. ':' .. attribute] = value
            end,
        },
    }
    w.helper = {
        getGUID = function() return 'helper' end,
        getGMNotes = function() return json.encode({characterId = 'corvan', parentGuid = 'panel'}) end,
        setGMNotes = function() end, setName = function() end,
        setDescription = function() end, setLock = function() end,
        setInvisibleTo = function() end, setLuaScript = function() end,
        reload = function() w.reloads = w.reloads + 1; return w.helper end,
    }
    w.bootstrap = environment(bootstrapSource or BOOTSTRAP_SOURCE, 'startup-bootstrap', w.panel)
    w.runtime = environment(RUNTIME_SOURCE, 'startup-runtime', w.helper)
    w.panel.call = function(name, payload)
        if name == 'setRuntimeUiAttribute' and payload.id == 'pvCurrent' then
            w.renderPasses = w.renderPasses + 1
        end
        return w.bootstrap[name](payload)
    end
    w.helper.call = function(name, payload)
        if name == 'registerParent' then w.registrations = w.registrations + 1 end
        return w.runtime[name](payload)
    end
    local savedRuntime = {
        characterId = 'corvan', runtimeVersion = CHARACTER_CONFIG.version,
        schemaVersion = 1, parentGuid = 'panel',
        character = {hp = 47, mp = 12, effects = {duel = 2}, automaticResourceSpending = automaticSpending},
        core = {settingsOpen = true, diceOffset = {x = 2, y = 4, z = 1}},
    }
    local xml = SEED_UI_SOURCE:gsub('id="automatic_resource_spending" isOn="[^"]*"',
        'id="automatic_resource_spending" isOn="' .. tostring(automaticSpending) .. '"')
    local savedPanel = json.encode({
        characterId = 'corvan', helperGuid = 'helper', runtimeVersion = CHARACTER_CONFIG.version,
        runtimeSource = RUNTIME_SOURCE, runtimeState = savedRuntime, uiXml = xml,
    })
    if helperFirst then w.runtime.onLoad(json.encode(savedRuntime)) end
    w.bootstrap.onLoad(savedPanel)
    if not helperFirst then w.runtime.onLoad(json.encode(savedRuntime)) end
    w.flush()
    return w
end

for _, helperFirst in ipairs({false, true}) do
    for _, automaticSpending in ipairs({false, true}) do
        local w = world(helperFirst, automaticSpending)
        assert(w.xmlSets == 1, 'healthy startup rebuilt identical XML')
        assert(#w.requests == 1, 'healthy startup duplicated the image request')
        assert(w.registrations == 1 and w.reloads == 0, 'healthy helper registered twice or reloaded')
        assert(w.renderPasses == 2, 'startup renders were not coalesced per frame')
        local state = w.runtime.exportState()
        assert(state.character.hp == 47 and state.character.mp == 12, 'spent resources changed')
        assert(state.character.effects.duel == 2 and state.core.settingsOpen, 'effects/settings changed')
        assert(state.core.diceOffset.x == 2, 'dice calibration changed')
        assert(w.attributes['automatic_resource_spending:isOn'] == tostring(automaticSpending))

        -- Repeated registrations while HTTP is pending must reuse both XML and request.
        for _ = 1, 5 do
            assert(w.runtime.registerParent({characterId = 'corvan', parentGuid = 'panel'}))
        end
        local beforeRender, beforeAttributes = w.renderPasses, w.attributeSets
        w.flush()
        assert(w.renderPasses == beforeRender + 1 and w.attributeSets == beforeAttributes)
        assert(w.xmlSets == 1 and #w.requests == 1)
        w.requests[1]({is_error = false, response_code = 200})
        assert(w.attributes['panelBoardArt:active'] == 'true')
        w.runtime.registerParent({characterId = 'corvan', parentGuid = 'panel'})
        w.flush()
        assert(#w.requests == 1 and w.xmlSets == 1, 'successful image/XML cache was discarded')

        -- Mutations and saves remain synchronous; only rendering waits one frame.
        local function event(id, value)
            if id == 'pv_adjust' then w.attributes['pv_adjust:text'] = value end
            if id == 'automatic_resource_spending' then
                w.attributes['automatic_resource_spending:isOn'] = tostring(value)
            end
            w.bootstrap.dispatch('White', value, id)
        end
        beforeRender = w.renderPasses
        event('pv_adjust', '3')
        event('pv_subtract')
        assert(w.runtime.exportState().character.hp == 44)
        assert(w.runtime.onSave() ~= '')
        w.flush()
        assert(w.renderPasses == beforeRender + 1)
        assert(w.attributes['pv_adjust:text'] == '', 'native input was not cleared after applying')
        beforeRender = w.renderPasses
        event('automatic_resource_spending', not automaticSpending)
        w.flush()
        assert(w.renderPasses == beforeRender + 1)
        assert(w.attributes['pvCurrent:text'] == '44')
        assert(w.attributes['automatic_resource_spending:isOn'] == tostring(not automaticSpending))
        assert(w.xmlSets == 2 and #w.requests == 1)

        -- Explicit recovery forces a rebuild and replays even unchanged values.
        beforeAttributes = w.attributeSets
        w.bootstrap.recoverUi(nil, 'White')
        w.flush()
        assert(w.xmlSets == 3 and w.attributeSets > beforeAttributes)
        assert(w.attributes['pvCurrent:text'] == '44' and w.attributes['panelBoardArt:active'] == 'true')
        -- A timeout belonging to a replaced tree cannot invalidate the current UI.
        w.conditions[1]()
        assert(w.fallbackButtons == 0)

        local payload = {characterId = 'corvan', id = 'pvCurrent', attribute = 'text', value = '43'}
        w.failAttribute = true
        assert(not w.bootstrap.setRuntimeUiAttribute(payload))
        w.failAttribute = false
        assert(w.bootstrap.setRuntimeUiAttribute(payload))
        assert(w.attributes['pvCurrent:text'] == '43', 'failed attribute was incorrectly cached')
    end
end

-- An unavailable image stays hidden, and a later registration can retry it.
local offline = world(false, true)
offline.requests[1]({is_error = true, response_code = 0})
offline.runtime.registerParent({characterId = 'corvan', parentGuid = 'panel'})
assert(#offline.requests == 2)
assert(offline.attributes['panelBoardArt:active'] == 'false')
offline.requests[2]({is_error = false, response_code = 200})
offline.flush()
assert(offline.attributes['panelBoardArt:active'] == 'true')

-- Refresh on existing objects keeps bootstrap 1.0.2: runtime-only optimizations
-- must still preserve state and avoid duplicate requests/XML submissions.
local legacy = world(false, false, LEGACY_BOOTSTRAP_SOURCE)
assert(#legacy.requests == 1 and legacy.xmlSets == 2)
assert(legacy.runtime.exportState().character.hp == 47)
assert(legacy.runtime.exportState().character.automaticResourceSpending == false)
return 'startup: 1 XML, 1 HTTP, 1 registration, 2 renders; recovery, offline and legacy OK'
