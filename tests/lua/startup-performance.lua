local function world(helperFirst, automaticSpending, bootstrapSource)
    return RuntimeTestWorld.create({config = CHARACTER_CONFIG, helperFirst = helperFirst,
        automaticSpending = automaticSpending, bootstrapSource = bootstrapSource or BOOTSTRAP_SOURCE,
        runtimeSource = RUNTIME_SOURCE, ui = SEED_UI_SOURCE})
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
        state.character.effects.duel = 99
        state.core.diceOffset.x = 99
        assert(w.runtime.exportState().character.effects.duel == 2)
        assert(w.runtime.exportState().core.diceOffset.x == 2)

        local writes = w.attributeSets
        assert(not w.bootstrap.setRuntimeUiAttributes({characterId = 'spentar', parentGuid = 'panel', attributes = {}}))
        assert(not w.bootstrap.setRuntimeUiAttributes({characterId = 'corvan', parentGuid = 'foreign', attributes = {}}))
        assert(not w.bootstrap.setRuntimeUiAttributes({characterId = 'corvan', parentGuid = 'panel',
            attributes = {pvCurrent = {text = '99'}, bad = {unknownAttribute = 'invalid'}}}))
        assert(w.attributeSets == writes, 'invalid batch partially changed the UI')

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
        assert(w.xmlSets == 1 and #w.requests == 1)

        -- Explicit recovery forces a rebuild and replays even unchanged values.
        beforeAttributes = w.attributeSets
        w.bootstrap.recoverUi(nil, 'White')
        w.flush()
        assert(w.xmlSets == 2 and w.attributeSets > beforeAttributes)
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
