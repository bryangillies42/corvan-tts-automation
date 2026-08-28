-- Host físico opt-in para adaptadores de personagem do Tabletop Simulator.
-- Não contém regras de personagem: apenas ciclo de vida, identidade e física.
TtsRuntimeHost = TtsRuntimeHost or {}

local DIE_TYPES = {
    [4] = "Die_4", [6] = "Die_6", [8] = "Die_8",
    [10] = "Die_10", [12] = "Die_12", [20] = "Die_20"
}

local function finiteNumber(value, fallback)
    value = tonumber(value)
    if value == nil or value ~= value or value == math.huge or value == -math.huge then
        return fallback
    end
    return value
end

local function integer(value, fallback, minimum, maximum)
    value = math.floor(finiteNumber(value, fallback))
    if minimum ~= nil and value < minimum then value = minimum end
    if maximum ~= nil and value > maximum then value = maximum end
    return value
end

local function copy(value, seen)
    if type(value) ~= "table" then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local result = {}
    seen[value] = result
    for key, item in pairs(value) do result[copy(key, seen)] = copy(item, seen) end
    return result
end

local function invoke(callback, ...)
    if type(callback) ~= "function" then return false end
    return pcall(callback, ...)
end

local function objectGuid(object)
    if not object or type(object.getGUID) ~= "function" then return nil end
    local ok, guid = pcall(function() return object.getGUID() end)
    if ok and type(guid) == "string" and guid ~= "" then return guid end
    return nil
end

local function randomRange(minimum, maximum)
    return minimum + math.random() * (maximum - minimum)
end

function TtsRuntimeHost.create(rawConfig, rawEnvironment)
    local config = type(rawConfig) == "table" and rawConfig or {}
    local environment = type(rawEnvironment) == "table" and rawEnvironment or {}
    local characterId = tostring(config.characterId or "")
    if characterId == "" or not characterId:match("^[a-z0-9%-]+$")
        or characterId:sub(1, 1) == "-" or characterId:sub(-1) == "-"
        or characterId:find("--", 1, true) then
        error("TtsRuntimeHost requer characterId válido.")
    end

    local characterName = tostring(config.characterName or characterId)
    local project = tostring(config.project or "corvan-tts-automation")
    local spawnTimeout = finiteNumber(config.spawnTimeoutSeconds, 5)
    local rollTimeout = finiteNumber(config.rollTimeoutSeconds, 12)
    local launchDelayFrames = integer(config.launchDelayFrames, 2, 1, 30)
    local stableFramesRequired = integer(config.stableFrames, 3, 1, 30)
    local maxDice = integer(config.maxDice, 64, 1, 128)
    local verticalMinimum = finiteNumber(config.verticalSpeedMin, 7.5)
    local verticalMaximum = finiteNumber(config.verticalSpeedMax, 11.5)
    if verticalMaximum < verticalMinimum then
        verticalMinimum, verticalMaximum = verticalMaximum, verticalMinimum
    end

    local active = nil
    local sequence = 0
    local ownedGuids = {}
    local lastTransactionId = nil
    local lastResult = nil
    local host = {}

    local function ownerGuid()
        if type(environment.getOwnerPanelGuid) == "function" then
            local ok, value = pcall(environment.getOwnerPanelGuid)
            if ok and type(value) == "string" and value ~= "" then return value end
        end
        if type(config.ownerPanelGuid) == "function" then
            local ok, value = pcall(config.ownerPanelGuid)
            if ok and type(value) == "string" and value ~= "" then return value end
        elseif type(config.ownerPanelGuid) == "string" and config.ownerPanelGuid ~= "" then
            return config.ownerPanelGuid
        end
        return nil
    end

    local function parentObject()
        if type(environment.getParent) == "function" then
            local ok, value = pcall(environment.getParent)
            if ok then return value end
        end
        return environment.parent
    end

    local function offset()
        local value = config.diceOffset
        if type(environment.getDiceOffset) == "function" then
            local ok, current = pcall(environment.getDiceOffset)
            if ok and type(current) == "table" then value = current end
        end
        value = type(value) == "table" and value or {}
        return {
            x = finiteNumber(value.x, 0),
            y = finiteNumber(value.y, 3.5),
            z = finiteNumber(value.z, -7)
        }
    end

    local function metadata(transactionId, groupId, dieIndex)
        return {
            project = project,
            characterId = characterId,
            kind = "owned-die",
            ownerPanelGuid = ownerGuid(),
            transactionId = transactionId,
            groupId = groupId,
            dieIndex = dieIndex
        }
    end

    local function readMetadata(object)
        if not object or type(JSON) ~= "table" or type(JSON.decode) ~= "function" then return nil end
        local notesOk, notes = pcall(function() return object.getGMNotes() end)
        if not notesOk or type(notes) ~= "string" or notes == "" then return nil end
        local decodedOk, result = pcall(function() return JSON.decode(notes) end)
        if not decodedOk or type(result) ~= "table" then return nil end
        return result
    end

    local function belongsToHost(object)
        local notes = readMetadata(object)
        return type(notes) == "table"
            and notes.project == project
            and notes.characterId == characterId
            and notes.kind == "owned-die"
            and notes.ownerPanelGuid == ownerGuid()
    end

    local function mark(object, transactionId, groupId, dieIndex)
        if type(JSON) ~= "table" or type(JSON.encode) ~= "function" then return false end
        local encodedOk, notes = pcall(function()
            return JSON.encode(metadata(transactionId, groupId, dieIndex))
        end)
        if not encodedOk or type(notes) ~= "string" then return false end
        return pcall(function() object.setGMNotes(notes) end)
    end

    local function destroy(object)
        if object and type(destroyObject) == "function" then
            return pcall(function() destroyObject(object) end)
        end
        return false
    end

    function host.clear(requestedGuids)
        local requested = {}
        if type(requestedGuids) == "table" then
            for _, guid in ipairs(requestedGuids) do
                if type(guid) == "string" then requested[guid] = true end
            end
        end
        local filter = next(requested) ~= nil
        local candidates = {}
        local seen = {}
        for _, guid in ipairs(ownedGuids) do
            if not seen[guid] then table.insert(candidates, guid); seen[guid] = true end
        end
        -- Depois de save/load ou Refresh, o host recomeça sem memória local,
        -- mas o envelope persiste os GUIDs. Eles só são destruídos depois da
        -- mesma validação forte de metadata usada para dados recém-criados.
        for guid, _ in pairs(requested) do
            if not seen[guid] then table.insert(candidates, guid); seen[guid] = true end
        end
        local retained = {}
        local removed = 0
        for _, guid in ipairs(candidates) do
            if filter and not requested[guid] then
                table.insert(retained, guid)
            else
                local object = nil
                if type(getObjectFromGUID) == "function" then
                    local ok, found = pcall(function() return getObjectFromGUID(guid) end)
                    if ok then object = found end
                end
                if object and belongsToHost(object) and destroy(object) then removed = removed + 1 end
            end
        end
        ownedGuids = retained
        return removed
    end

    local function render()
        invoke(environment.render)
    end

    local function notifyFailure(transaction, reason)
        local handled = false
        if type(transaction.callbacks.onRollback) == "function" then
            invoke(transaction.callbacks.onRollback, copy(transaction.rollback), reason)
            handled = true
        end
        if type(transaction.callbacks.onFailure) == "function" then
            invoke(transaction.callbacks.onFailure, reason, transaction.id)
            handled = true
        end
        if not handled and type(environment.privateError) == "function" then
            invoke(environment.privateError, reason, transaction.playerColor)
        end
    end

    local function fail(token, reason)
        if not active or active.token ~= token then return end
        local transaction = active
        active = nil
        host.clear()
        notifyFailure(transaction, reason or "a rolagem falhou.")
        render()
    end

    local function positionFor(index, count)
        local localPosition = offset()
        localPosition.x = localPosition.x + (index - ((count + 1) / 2)) * 1.25
        local parent = parentObject()
        if parent and type(parent.positionToWorld) == "function" then
            local ok, world = pcall(function() return parent.positionToWorld(localPosition) end)
            if ok and world then return world end
        end
        return localPosition
    end

    local function directionToWorld(localDirection)
        local parent = parentObject()
        if parent and type(parent.positionToWorld) == "function" then
            local ok, origin, target = pcall(function()
                return parent.positionToWorld({x = 0, y = 0, z = 0}),
                    parent.positionToWorld(localDirection)
            end)
            if ok and origin and target then
                local direction = {
                    x = finiteNumber(target.x, 0) - finiteNumber(origin.x, 0),
                    y = finiteNumber(target.y, 0) - finiteNumber(origin.y, 0),
                    z = finiteNumber(target.z, 0) - finiteNumber(origin.z, 0)
                }
                local length = math.sqrt(direction.x * direction.x + direction.y * direction.y + direction.z * direction.z)
                if length > 0.001 then
                    return {x = direction.x / length, y = direction.y / length, z = direction.z / length}
                end
            end
        end
        return localDirection
    end

    local function resultFor(transaction)
        local result = {transactionId = transaction.id, groups = {}, ownedGuids = copy(ownedGuids)}
        for groupIndex, group in ipairs(transaction.groups) do
            local values = {}
            local total = finiteNumber(group.bonus, 0)
            if group.maximized then
                for _ = 1, group.count do
                    table.insert(values, group.sides)
                    total = total + group.sides
                end
            else
                for _, entry in ipairs(transaction.entries) do
                    if entry.groupIndex == groupIndex then
                        local ok, value = pcall(function() return entry.object.getRotationValue() end)
                        value = ok and tonumber(value) or nil
                        if not value then return nil, "um dado foi removido antes do resultado." end
                        table.insert(values, value)
                        total = total + value
                    end
                end
            end
            table.insert(result.groups, {
                id = group.id, count = group.count, sides = group.sides,
                bonus = finiteNumber(group.bonus, 0), values = values,
                total = total, maximized = group.maximized
            })
        end
        return result, nil
    end

    local function complete(token)
        if not active or active.token ~= token then return end
        local transaction = active
        local result, failure = resultFor(transaction)
        if not result then fail(token, failure) return end
        active = nil
        local completed = invoke(transaction.callbacks.onComplete, copy(result))
        if not completed then
            host.clear()
            notifyFailure(transaction, "o adaptador não concluiu a rolagem; estado restaurado.")
            render()
            return
        end
        lastTransactionId = transaction.id
        lastResult = copy(result)
        render()
    end

    local function settled(token)
        if not active or active.token ~= token then return true end
        local allSettled = true
        for _, entry in ipairs(active.entries) do
            local object = entry.object
            if not object or not objectGuid(object) then active.missing = true return true end
            local ok, resting = pcall(function() return object.resting end)
            if not ok then active.missing = true return true end
            if not resting then
                entry.motionObserved = true
                entry.stableFrames = 0
                entry.lastValue = nil
                allSettled = false
            else
                local valueOk, value = pcall(function() return object.getRotationValue() end)
                value = valueOk and tonumber(value) or nil
                if not value then
                    entry.stableFrames = 0
                    entry.lastValue = nil
                    allSettled = false
                else
                    if entry.lastValue == value then
                        entry.stableFrames = entry.stableFrames + 1
                    else
                        entry.lastValue = value
                        entry.stableFrames = 1
                    end
                    if entry.stableFrames < stableFramesRequired then allSettled = false end
                end
            end
        end
        return allSettled
    end

    local function waitForDice(token)
        local ok = pcall(function()
            Wait.condition(function()
                if active and active.token == token and active.missing then
                    fail(token, "um dado foi removido durante a rolagem.")
                else complete(token) end
            end, function() return settled(token) end, rollTimeout,
            function() fail(token, "os dados não pararam a tempo.") end)
        end)
        if not ok then fail(token, "não foi possível acompanhar os dados.") end
    end

    local function launch(token, entry)
        if not active or active.token ~= token or not entry.object then return end
        local up = directionToWorld({x = 0, y = 1, z = 0})
        local right = directionToWorld({x = 1, y = 0, z = 0})
        local forward = directionToWorld({x = 0, y = 0, z = 1})
        local vertical = randomRange(verticalMinimum, verticalMaximum)
        local lateral = (math.random() * 2 - 1) * 1.4
        local depth = (math.random() * 2 - 1) * 1.4
        local velocity = {
            x = up.x * vertical + right.x * lateral + forward.x * depth,
            y = up.y * vertical + right.y * lateral + forward.y * depth,
            z = up.z * vertical + right.z * lateral + forward.z * depth
        }
        local launched = pcall(function() entry.object.setVelocity(velocity) end)
        if not launched then launched = pcall(function() entry.object.addForce(velocity, 4) end) end
        local angular = {x = randomRange(-24, 24), y = randomRange(-24, 24), z = randomRange(-24, 24)}
        local spun = pcall(function() entry.object.setAngularVelocity(angular) end)
        if not spun then pcall(function() entry.object.addTorque(angular, 4) end) end
        if not launched then launched = pcall(function() entry.object.roll() end) end
        if not launched then fail(token, "não foi possível lançar o dado.") return end
        -- O monitor coletivo começa apenas depois do último lançamento. Um
        -- dado anterior pode já ter parado; o lançamento bem-sucedido prova
        -- movimento, e os frames de face estável evitam leitura prematura.
        entry.motionObserved = true
        active.pendingLaunches = active.pendingLaunches - 1
        if active.pendingSpawns == 0 and active.pendingLaunches == 0 then waitForDice(token) end
    end

    local function spawned(token, entry, object)
        if not active or active.token ~= token then destroy(object) return end
        if not object then fail(token, "não foi possível criar um dado.") return end
        entry.object = object
        active.pendingSpawns = active.pendingSpawns - 1
        local guid = objectGuid(object)
        if not guid or not mark(object, active.id, entry.groupId, entry.dieIndex) then
            destroy(object)
            fail(token, "não foi possível identificar um dado com segurança.")
            return
        end
        table.insert(ownedGuids, guid)
        pcall(function() object.setName(characterName .. " • dado da ferramenta") end)
        local scheduled = pcall(function()
            Wait.frames(function() launch(token, entry) end, launchDelayFrames)
        end)
        if not scheduled then fail(token, "não foi possível agendar o lançamento do dado.") end
    end

    local function normalizeGroups(groups)
        if type(groups) ~= "table" or #groups == 0 then return nil, "informe ao menos um grupo de dados." end
        local result, ids, physicalCount = {}, {}, 0
        for index, source in ipairs(groups) do
            if type(source) ~= "table" then return nil, "grupo de dados inválido." end
            local id = tostring(source.id or ("group-" .. tostring(index)))
            if id == "" or ids[id] then return nil, "IDs de grupos de dados devem ser únicos." end
            ids[id] = true
            local rawCount = tonumber(source.count)
            local rawSides = tonumber(source.sides)
            if rawCount == nil or rawCount ~= math.floor(rawCount) or rawCount < 0 or rawCount > maxDice
                or rawSides == nil or rawSides ~= math.floor(rawSides) or not DIE_TYPES[rawSides] then
                return nil, "tipo ou quantidade de dados não suportado."
            end
            local count = rawCount
            local sides = rawSides
            local maximized = source.maximized == true
            if not maximized then physicalCount = physicalCount + count end
            if physicalCount > maxDice then return nil, "a rolagem excede o limite de dados físicos." end
            table.insert(result, {id = id, count = count, sides = sides, bonus = finiteNumber(source.bonus, 0), maximized = maximized})
        end
        return result, physicalCount
    end

    function host.roll(specification, callbacks)
        specification = type(specification) == "table" and specification or {}
        callbacks = type(callbacks) == "table" and callbacks or {}
        local transactionId = tostring(specification.transactionId or "")
        if transactionId == "" then invoke(callbacks.onFailure, "transactionId é obrigatório.") return false end
        if active then invoke(callbacks.onFailure, "já existe uma rolagem em andamento.", transactionId) return false end
        if lastTransactionId == transactionId and lastResult then
            invoke(callbacks.onComplete, copy(lastResult))
            return true
        end
        local groups, physicalCountOrFailure = normalizeGroups(specification.groups)
        if not groups then invoke(callbacks.onFailure, physicalCountOrFailure, transactionId) return false end
        if physicalCountOrFailure > 0 then
            if not ownerGuid() then invoke(callbacks.onFailure, "o painel proprietário não está disponível.", transactionId) return false end
            if spawnObject == nil then invoke(callbacks.onFailure, "não foi possível criar dados físicos.", transactionId) return false end
            -- APIs estáticas do TTS podem ser expostas pelo MoonSharp como
            -- userdata/proxy em vez de uma table Lua comum. Validamos as
            -- operações usadas, não a representação interna do host.
            if Wait == nil or type(Wait.time) ~= "function"
                or type(Wait.frames) ~= "function" or type(Wait.condition) ~= "function"
            then
                invoke(callbacks.onFailure, "o agendador do TTS não está disponível.", transactionId)
                return false
            end
        end

        host.clear()
        sequence = sequence + 1
        active = {
            token = sequence, id = transactionId, groups = groups, entries = {},
            callbacks = callbacks, rollback = copy(specification.rollback),
            playerColor = specification.playerColor,
            pendingSpawns = physicalCountOrFailure, pendingLaunches = physicalCountOrFailure,
            missing = false
        }
        render()
        if physicalCountOrFailure == 0 then complete(sequence) return true end

        local physicalIndex = 0
        for groupIndex, group in ipairs(groups) do
            if not group.maximized then
                for dieIndex = 1, group.count do
                    if not active or active.token ~= sequence then
                        -- A transação já foi concluída ou falhou via callback.
                        -- Ela foi aceita pelo host, portanto não peça ao
                        -- adaptador para executar um segundo rollback.
                        return true
                    end
                    physicalIndex = physicalIndex + 1
                    local entry = {groupIndex = groupIndex, groupId = group.id, dieIndex = dieIndex, stableFrames = 0, motionObserved = false}
                    table.insert(active.entries, entry)
                    local ok = pcall(function()
                        spawnObject({
                            type = DIE_TYPES[group.sides],
                            position = positionFor(physicalIndex, physicalCountOrFailure),
                            rotation = {x = math.random(0, 359), y = math.random(0, 359), z = math.random(0, 359)},
                            sound = true,
                            callback_function = function(object) spawned(sequence, entry, object) end
                        })
                    end)
                    if not ok then fail(sequence, "não foi possível criar os dados.") return true end
                    if not active or active.token ~= sequence then
                        return true
                    end
                end
            end
        end
        local timeoutOk = pcall(function()
            Wait.time(function()
                if active and active.token == sequence and active.pendingSpawns > 0 then
                    fail(sequence, "a criação dos dados expirou.")
                end
            end, spawnTimeout)
            Wait.time(function()
                if active and active.token == sequence then
                    fail(sequence, "a rolagem excedeu o tempo máximo; estado restaurado.")
                end
            end, spawnTimeout + rollTimeout + 2)
        end)
        if not timeoutOk then fail(sequence, "não foi possível iniciar o temporizador dos dados.") return true end
        return true
    end

    function host.cancel(reason)
        if not active then return false end
        fail(active.token, reason or "rolagem cancelada.")
        return true
    end

    function host.isRolling() return active ~= nil end
    function host.getOwnedGuids() return copy(ownedGuids) end
    function host.getActiveTransactionId() return active and active.id or nil end

    return host
end
