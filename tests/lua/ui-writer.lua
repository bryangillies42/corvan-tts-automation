local parentGuid = 'panel-one'
local advertisedCharacter = 'corvan'
local advertisedProtocol = 1
local rejectBatch = false
local calls = {}
local writer = CharacterRuntimeCore.createUiWriter('corvan', function(name, payload)
    table.insert(calls, {name = name, payload = payload})
    if name == 'getBootstrapInfo' then
        return true, {characterId = advertisedCharacter, uiProtocolVersion = advertisedProtocol}
    end
    if name == 'setRuntimeUiAttributes' and rejectBatch then return false, nil end
    return true, true
end, function() return parentGuid end)

writer.begin()
writer.set('hp', 'text', 40)
writer.set('hp', 'text', 41)
writer.set('toggle', 'isOn', false)
assert(#calls == 0)
assert(writer.flush())
assert(#calls == 2 and calls[1].name == 'getBootstrapInfo')
assert(calls[2].payload.characterId == 'corvan' and calls[2].payload.parentGuid == 'panel-one')
assert(calls[2].payload.attributes.hp.text == '41')
assert(calls[2].payload.attributes.toggle.isOn == 'false')
writer.begin(); writer.set('hp', 'text', 42); writer.flush()
assert(#calls == 3, 'capability handshake was repeated')

rejectBatch = true
writer.begin(); writer.set('hp', 'text', 43); writer.flush()
assert(#calls == 5 and calls[5].name == 'setRuntimeUiAttribute', 'batch failure lost fallback')
assert(calls[5].payload.value == '43')
writer.begin(); writer.set('hp', 'text', 44); writer.flush()
assert(#calls == 6 and calls[6].name == 'setRuntimeUiAttribute')

-- Changing parent must invalidate capabilities; a foreign identity cannot opt in.
parentGuid = 'panel-two'
advertisedCharacter = 'spentar'
rejectBatch = false
writer.begin(); writer.set('hp', 'text', 45); writer.flush()
assert(calls[7].name == 'getBootstrapInfo' and calls[8].name == 'setRuntimeUiAttribute')
parentGuid = 'panel-three'
advertisedCharacter = 'corvan'
advertisedProtocol = nil
assert(not writer.supportsBatch(), 'legacy bootstrap incorrectly opted in')
writer.begin(); writer.set('hp', 'text', 46); writer.flush()
assert(calls[#calls].name == 'setRuntimeUiAttribute')

local original = {effects = {duel = 2}, undo = {hp = 10}}
local envelope = CharacterRuntimeCore.envelopeState({characterId = 'corvan', runtimeVersion = '0.2.5'}, original, {})
envelope.character.effects.duel = 3
envelope.character.undo.hp = 0
assert(original.effects.duel == 2 and original.undo.hp == 10, 'state alias escaped envelope')
return 'UI writer: batch, identity, parent change, fallback and state isolation OK'
