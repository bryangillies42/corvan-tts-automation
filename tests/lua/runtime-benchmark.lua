-- Operation counts, not FPS. Both versions execute the same events and their
-- state plus every visible dynamic attribute are compared after every step.
local metrics = {'uiCalls', 'attributeAttempts', 'attributeSets', 'loadingReads',
    'xmlSets', 'renderPasses', 'copyTables', 'previewPlans'}
local function equal(left, right, path)
    assert(type(left) == type(right), path .. ': type mismatch')
    if type(left) ~= 'table' then
        assert(left == right, path .. ': ' .. tostring(left) .. ' ~= ' .. tostring(right))
        return
    end
    for key, value in pairs(left) do equal(value, right[key], path .. '.' .. tostring(key)) end
    for key in pairs(right) do assert(left[key] ~= nil, path .. ': extra field ' .. tostring(key)) end
end

local scenarios
if BEFORE_CONFIG.id == 'corvan' then
    scenarios = {
        {name = 'pv-adjust', events = {{'pv_adjust', '1'}, {'pv_subtract'}, {'pv_adjust', '1'}, {'pv_add'}}},
        {name = 'settings', events = {{'toggle_settings'}, {'toggle_settings'}}},
        {name = 'auto-spend', events = {{'automatic_resource_spending', false}, {'automatic_resource_spending', true}}},
        {name = 'burst-input', burst = true, events = {{'pv_adjust', '1'}, {'pv_adjust', '2'}, {'pv_adjust', '3'}}},
        {name = 'export', exportOnly = true, events = {}},
    }
else
    scenarios = {
        {name = 'resources', events = {{'resource_hp_sub'}, {'resource_hp_add'}}},
        {name = 'pages', events = {{'nav_casting'}, {'nav_necromancy'}, {'nav_settings'}, {'nav_sheet'}, {'nav_combat'}}},
        {name = 'preparation', setup = {{'nav_casting'}}, events = {{'prepare_dice_count', '4'}, {'prepare_dice_count', '3'}}},
        {name = 'souls', events = {{'souls_add'}, {'souls_sub'}}},
        {name = 'burst-resources', burst = true, events = {{'resource_hp_sub'}, {'resource_hp_sub'}, {'resource_hp_add'}, {'resource_hp_add'}}},
        {name = 'export', exportOnly = true, events = {}},
    }
end

local output = {'scenario\tmetric\tbefore\tafter'}
for _, scenario in ipairs(scenarios) do
    local before = RuntimeTestWorld.create({config = BEFORE_CONFIG, runtimeSource = BEFORE_RUNTIME,
        bootstrapSource = BEFORE_BOOTSTRAP, ui = BEFORE_UI, instrument = true})
    local after = RuntimeTestWorld.create({config = AFTER_CONFIG, runtimeSource = AFTER_RUNTIME,
        bootstrapSource = AFTER_BOOTSTRAP, ui = AFTER_UI, instrument = true})
    for _, w in ipairs({before, after}) do
        for _, request in ipairs(w.requests) do request({is_error = false, response_code = 200}) end
        w.flush()
    end
    local function assertSame()
        local oldCopies, newCopies = before.copyTables, after.copyTables
        local oldState, newState = before.runtime.exportState(), after.runtime.exportState()
        before.copyTables, after.copyTables = oldCopies, newCopies
        equal(oldState, newState, scenario.name .. '.state')
        local page = oldState.core.page
        for key, value in pairs(before.attributes) do
            local id = key:match('^([^:]+):')
            local owner = UI_PAGES[id]
            if owner == nil or owner == page then
                equal(value, after.attributes[key], scenario.name .. '.UI.' .. key)
            end
        end
    end
    local function events(items, burst)
        for _, event in ipairs(items) do
            before.event(event[1], event[2])
            after.event(event[1], event[2])
            if not burst then before.flush(); after.flush(); assertSame() end
        end
        if burst then before.flush(); after.flush(); assertSame() end
    end
    events(scenario.setup or {}, false)
    -- Warm caches and undo history equally before counting repeated workloads.
    for _ = 1, 25 do events(scenario.events, scenario.burst) end
    assertSame()
    for _, w in ipairs({before, after}) do for _, metric in ipairs(metrics) do w[metric] = 0 end end
    for _ = 1, ITERATIONS do
        if scenario.exportOnly then
            equal(before.runtime.exportState(), after.runtime.exportState(), 'export')
        else
            events(scenario.events, scenario.burst)
        end
    end
    for _, metric in ipairs(metrics) do
        table.insert(output, scenario.name .. '\t' .. metric .. '\t' .. before[metric] .. '\t' .. after[metric])
    end
end
return table.concat(output, '\n')
