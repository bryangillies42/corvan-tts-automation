-- Count real Lua startup work with a restored host UI and a saved helper.
-- Host XML parsing, Unity rendering, asset decoding and disk I/O are not simulated.
local metrics = {'xmlSets', 'renderPasses', 'registrations', 'imports', 'exports',
    'cacheCalls', 'helperConfigurations', 'tableScans', 'noteReads', 'noteDecodes',
    'copyTables', 'uiCalls', 'attributeSets', 'reloads', 'hashBlocks', 'luaHarnessMs'}
local function equal(a, b, path)
    assert(type(a) == type(b), path .. ': type mismatch')
    if type(a) ~= 'table' then assert(a == b, path .. ': value mismatch'); return end
    for k, v in pairs(a) do equal(v, b[k], path .. '.' .. tostring(k)) end
    for k in pairs(b) do assert(a[k] ~= nil, path .. ': extra key ' .. tostring(k) .. '=' .. tostring(b[k])) end
end
local scenarios = {
    {name='saved-panel-first', restoredUi=true},
    {name='saved-helper-first', restoredUi=true, helperFirst=true},
    {name='saved-dynamic-ui', restoredUi=true, dynamicUi=true},
    {name='missing-ui', restoredUi=false},
    {name='stale-guid-1000-objects', restoredUi=true, staleGuid=true, unrelatedObjects=1000},
    {name='fallback-scan-1000-objects', restoredUi=true, staleGuid=true, unrelatedObjects=1000, noAnnouncement=true},
}
local output = {'scenario\tmetric\tbefore\tafter'}
for _, scenario in ipairs(scenarios) do
    local totals = {before={}, after={}}
    local durations = {before={}, after={}}
    for _, counters in pairs(totals) do for _, metric in ipairs(metrics) do counters[metric] = 0 end end
    for iteration = -1, ITERATIONS do
        local worlds = {}
        local order = iteration % 2 == 0 and {'before', 'after'} or {'after', 'before'}
        for _, variant in ipairs(order) do
            local old = variant == 'before'
            local options = {config=old and BEFORE_CONFIG or AFTER_CONFIG,
                runtimeSource=old and BEFORE_RUNTIME or AFTER_RUNTIME,
                bootstrapSource=old and BEFORE_BOOTSTRAP or AFTER_BOOTSTRAP,
                ui=old and BEFORE_UI or AFTER_UI, instrument=true}
            for key, value in pairs(scenario) do options[key] = value end
            local started = BENCH_CLOCK_MS()
            local w = RuntimeTestWorld.create(options)
            w.luaHarnessMs = BENCH_CLOCK_MS() - started
            worlds[variant] = w
            if iteration > 0 then
                table.insert(durations[variant], w.luaHarnessMs)
                for _, metric in ipairs(metrics) do totals[variant][metric] = totals[variant][metric] + w[metric] end
            end
            assert(w.reloads == 0 and w.hashBlocks == 0, 'unexpected startup reload/hash')
        end
        equal(worlds.before.runtime.exportState(), worlds.after.runtime.exportState(), scenario.name .. '.state')
        for key, value in pairs(worlds.before.attributes) do
            equal(value, worlds.after.attributes[key], scenario.name .. '.UI.' .. key)
        end
    end
    for _, metric in ipairs(metrics) do
        table.insert(output, scenario.name .. '\t' .. metric .. '\t'
            .. tostring(totals.before[metric]):gsub(',', '.') .. '\t' .. tostring(totals.after[metric]):gsub(',', '.'))
    end
    for _, values in pairs(durations) do table.sort(values) end
    for metric, percentile in pairs({luaHarnessMedianMs=0.5, luaHarnessP95Ms=0.95}) do
        local index = math.ceil(ITERATIONS * percentile)
        table.insert(output, scenario.name .. '\t' .. metric .. '\t'
            .. tostring(durations.before[index]):gsub(',', '.') .. '\t' .. tostring(durations.after[index]):gsub(',', '.'))
    end
end
return table.concat(output, '\n')
