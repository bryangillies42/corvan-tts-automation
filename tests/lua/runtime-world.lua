-- Execute the real bootstrap and runtime in separate Lua environments, with a
-- queued clock: immediate Wait mocks cannot detect duplicate work in one frame.
local function copy(value)
    if type(value) ~= 'table' then return value end
    local result = {}
    for key, item in pairs(value) do result[key] = copy(item) end
    return result
end

RuntimeTestWorld = {}
function RuntimeTestWorld.create(options)
    local config = options.config
    local characterId = config.id
    local helperFirst = options.helperFirst
    local automaticSpending = options.automaticSpending ~= false
    local w = {
        tick = 0, queue = {}, json = {}, requests = {}, conditions = {},
        xmlSets = 0, attributeSets = 0, renderPasses = 0, registrations = 0,
        reloads = 0, fallbackButtons = 0, failAttribute = false,
        attributes = {}, installedXml = '',
        uiCalls = 0, attributeAttempts = 0, loadingReads = 0, copyTables = 0, previewPlans = 0,
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
            return copy(config)
        end,
    }
    local function environment(source, label, object)
        local env = {}
        env._G = env
        setmetatable(env, {__index = _G})
        env.JSON = json
        env.BENCH_COUNTERS = w
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
        if options.instrument then
            source = source:gsub('local copy = {}%s+seen%[value%] = copy',
                'local copy = {}\n    BENCH_COUNTERS.copyTables = BENCH_COUNTERS.copyTables + 1\n    seen[value] = copy')
        end
        local chunk, message = load(source, label, 't', env)
        assert(chunk, message)
        chunk()
        return env
    end
    local loading = false
    w.panel = {
        getGUID = function() return 'panel' end,
        createButton = function() w.fallbackButtons = w.fallbackButtons + 1 end,
        clearButtons = function() w.fallbackButtons = 0 end,
        UI = {
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
                assert(not loading, 'attribute sent before UI readiness')
                assert(string.find(w.installedXml, 'id="' .. id .. '"', 1, true), 'missing UI ID')
                if w.failAttribute then error('transient attribute failure') end
                w.attributeSets = w.attributeSets + 1
                w.attributes[id .. ':' .. attribute] = value
            end,
        },
    }
    setmetatable(w.panel.UI, {
        __index = function(_, key)
            if key == 'loading' then w.loadingReads = w.loadingReads + 1; return loading end
        end,
        __newindex = function(target, key, value)
            if key == 'loading' then loading = value else rawset(target, key, value) end
        end,
    })
    w.helper = {
        getGUID = function() return 'helper' end,
        getGMNotes = function() return json.encode({characterId = characterId, parentGuid = 'panel'}) end,
        setGMNotes = function() end, setName = function() end,
        setDescription = function() end, setLock = function() end,
        setInvisibleTo = function() end, setLuaScript = function() end,
        reload = function() w.reloads = w.reloads + 1; return w.helper end,
    }
    w.bootstrap = environment(options.bootstrapSource, 'startup-bootstrap', w.panel)
    w.runtime = environment(options.runtimeSource, 'startup-runtime', w.helper)
    if options.instrument and w.runtime.SpentarRules then
        local originalPlan = w.runtime.SpentarRules.damagePlan
        w.runtime.SpentarRules.damagePlan = function(...)
            w.previewPlans = w.previewPlans + 1
            return originalPlan(...)
        end
    end
    w.panel.call = function(name, payload)
        if name == 'setRuntimeUiAttribute' or name == 'setRuntimeUiAttributes' then
            w.uiCalls = w.uiCalls + 1
            local attributes = name == 'setRuntimeUiAttributes' and payload.attributes
                or {[payload.id] = {[payload.attribute] = payload.value}}
            for id, values in pairs(attributes) do
                for _ in pairs(values) do w.attributeAttempts = w.attributeAttempts + 1 end
                if id == 'pvCurrent' or id == 'resource_hp' then w.renderPasses = w.renderPasses + 1 end
            end
        end
        return w.bootstrap[name](payload)
    end
    w.helper.call = function(name, payload)
        if name == 'registerParent' then w.registrations = w.registrations + 1 end
        return w.runtime[name](payload)
    end
    local savedRuntime = {
        characterId = characterId, runtimeVersion = config.version,
        schemaVersion = 1, parentGuid = 'panel',
        character = {hp = 47, mp = 12, effects = {duel = 2}, automaticResourceSpending = automaticSpending},
        core = {settingsOpen = true, diceOffset = {x = 2, y = 4, z = 1}},
    }
    if characterId ~= 'corvan' then
        savedRuntime = w.runtime.exportState()
        savedRuntime.parentGuid = 'panel'
    end
    local xml = options.ui:gsub('id="automatic_resource_spending" isOn="[^"]*"',
        'id="automatic_resource_spending" isOn="' .. tostring(automaticSpending) .. '"')
    local savedPanel = json.encode({
        characterId = characterId, helperGuid = 'helper', runtimeVersion = config.version,
        runtimeSource = options.runtimeSource, runtimeState = savedRuntime, uiXml = xml,
    })
    if helperFirst then w.runtime.onLoad(json.encode(savedRuntime)) end
    w.bootstrap.onLoad(savedPanel)
    if not helperFirst then w.runtime.onLoad(json.encode(savedRuntime)) end
    w.flush()
    w.config = config
    function w.event(id, value)
        if id == 'pv_adjust' or (id:match('^prepare_') and value ~= nil) then
            w.attributes[id .. ':text'] = tostring(value or '')
        end
        if id == 'automatic_resource_spending' then w.attributes[id .. ':isOn'] = tostring(value) end
        w.bootstrap.dispatch('White', value, id)
    end
    return w
end
