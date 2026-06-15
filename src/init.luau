--!strict
--[[
    ReplicatedTable (Shared)
    ========================
    Author: Clueless_Dev (1761758398)
    Updated: 15/06/26

    Small delta-compressed table replication helper. Services keep owning their
    data; this module only mirrors plain table snapshots to clients.
]]

--[=[
    @class ReplicatedTable

    ReplicatedTable is a small server-to-client table replication helper for Roblox.
    It creates named streams, tracks authoritative server tables by stable keys, sends
    delta-compressed snapshots to approved clients, and exposes
    accessor-based reads and change signals on both sides.

    It is intentionally not a data store, validation layer, or global player-data
    facade. Services still own their data shapes and lifecycle. ReplicatedTable only
    mirrors those plain tables over one shared `RemoteEvent` and one shared
    `RemoteFunction`, routing every message by stream id.

    See `README.md` for the guide, API reference, examples, and publishing notes.
]=]

const RunService = game:GetService('RunService')

const DeltaCompress = require(script.DeltaCompress)
const NamedSignal   = require(script.NamedSignal)

type ChangedSignal = NamedSignal.Signal<(newData: any, oldData: any?) -> ()>
export type OwnerOrUid = Instance | string
type RecipientResolver = (ownerOrUid: OwnerOrUid) -> { Player }
type AccessorKey = string | number
type AccessorUpdater = (currentValue: any) -> any

--[=[
    @type Stream
    @within ReplicatedTable

    A named stream returned by `ReplicatedTable.new(streamId)`.

    The handle is a plain table of functions. It does not use metatables or `self`.
    Call methods with dot syntax:

    ```lua
    const PlayerDataStream = ReplicatedTable.new<PlayerData>('PlayerData')
    PlayerDataStream.register(player, data)
    PlayerDataStream.update(player, 'chests.ownedChests', function(ownedChests)
        table.insert(ownedChests, chest)
    end)
    ```
]=]
export type Stream<T> = {
    setRecipients: (resolver: RecipientResolver) -> (),
    register: (ownerOrUid: OwnerOrUid, data: T) -> T,
    modify: (ownerOrUid: OwnerOrUid, data: T) -> T,
    set: (ownerOrUid: OwnerOrUid, accessor: string, value: any) -> T,
    update: (ownerOrUid: OwnerOrUid, accessor: string?, updater: AccessorUpdater) -> T,
    unregister: (ownerOrUid: OwnerOrUid) -> (),
    get: (ownerOrUid: OwnerOrUid, accessor: string?) -> any?,
    changed: (ownerOrUid: OwnerOrUid, accessor: string?) -> ChangedSignal,
}

type StreamState = {
    id: string,
    resolveRecipients: RecipientResolver,
    authoritativeByOwner: { [any]: any },
    sentSnapshotsByOwner: { [any]: { [Player]: any } },
    signalSnapshotsByOwner: { [any]: any },
    replicatedDataByOwner: { [any]: any },
    signalsByOwner: { [any]: { [string]: ChangedSignal } },
}

const TRANSPORT_FOLDER_NAME = '_ReplicatedTable'
const DELTA_EVENT_NAME = 'Delta'
const GET_FUNCTION_NAME = 'Get'
const ROOT_PATH = ''
const TRANSPORT_WAIT_SECONDS = 30

const streamsById: { [string]: StreamState } = {}
const pendingDeltasByStreamId: { [string]: { { ownerOrUid: OwnerOrUid, diff: buffer } } } = {}

local transportFolder: Folder
local deltaEvent: RemoteEvent
local getFunction: RemoteFunction

const function waitForTransportChild(parent: Instance, childName: string, className: string): Instance
    const child = parent:WaitForChild(childName, TRANSPORT_WAIT_SECONDS)
    assert(child, `[ReplicatedTable] timed out waiting for {childName} under {parent:GetFullName()}`)
    assert(child:IsA(className), `[ReplicatedTable] {childName} under {parent:GetFullName()} must be a {className}`)

    return child
end

if RunService:IsServer() then
    const existingFolder = script:FindFirstChild(TRANSPORT_FOLDER_NAME)
    if existingFolder then
        assert(existingFolder:IsA('Folder'), `[ReplicatedTable] {TRANSPORT_FOLDER_NAME} must be a Folder`)
        transportFolder = existingFolder
    else
        transportFolder = Instance.new('Folder')
        transportFolder.Name = TRANSPORT_FOLDER_NAME
        transportFolder.Parent = script
    end

    const existingDeltaEvent = transportFolder:FindFirstChild(DELTA_EVENT_NAME)
    if existingDeltaEvent then
        assert(existingDeltaEvent:IsA('RemoteEvent'), `[ReplicatedTable] {DELTA_EVENT_NAME} must be a RemoteEvent`)
        deltaEvent = existingDeltaEvent
    else
        deltaEvent = Instance.new('RemoteEvent')
        deltaEvent.Name = DELTA_EVENT_NAME
        deltaEvent.Parent = transportFolder
    end

    const existingGetFunction = transportFolder:FindFirstChild(GET_FUNCTION_NAME)
    if existingGetFunction then
        assert(existingGetFunction:IsA('RemoteFunction'), `[ReplicatedTable] {GET_FUNCTION_NAME} must be a RemoteFunction`)
        getFunction = existingGetFunction
    else
        getFunction = Instance.new('RemoteFunction')
        getFunction.Name = GET_FUNCTION_NAME
        getFunction.Parent = transportFolder
    end
else
    transportFolder = waitForTransportChild(script, TRANSPORT_FOLDER_NAME, 'Folder') :: Folder
    deltaEvent = waitForTransportChild(transportFolder, DELTA_EVENT_NAME, 'RemoteEvent') :: RemoteEvent
    getFunction = waitForTransportChild(transportFolder, GET_FUNCTION_NAME, 'RemoteFunction') :: RemoteFunction
end

const function defaultRecipients(ownerOrUid: OwnerOrUid): { Player }
    if typeof(ownerOrUid) == 'Instance' and ownerOrUid:IsA('Player') then
        return { ownerOrUid :: Player }
    end

    const nobody: { Player } = {}
    return nobody
end

const function describeOwnerOrUid(ownerOrUid: OwnerOrUid): string
    if typeof(ownerOrUid) == 'Instance' then
        return ownerOrUid:GetFullName()
    end

    return ownerOrUid
end

const function copyDeep(value: any): any
    if typeof(value) ~= 'table' then return value end

    const result = {}
    for key, childValue in value do
        result[copyDeep(key)] = copyDeep(childValue)
    end

    return result
end

const function normalizeAccessor(accessor: string?): string
    return accessor or ROOT_PATH
end

const function splitAccessor(accessor: string?): { AccessorKey }
    const normalizedAccessor = normalizeAccessor(accessor)
    const path: { AccessorKey } = {}
    if normalizedAccessor == ROOT_PATH then return path end

    for _, rawKey in string.split(normalizedAccessor, '.') do
        assert(rawKey ~= '', `[ReplicatedTable] invalid empty accessor segment in {normalizedAccessor}`)

        table.insert(path, tonumber(rawKey) or rawKey)
    end

    return path
end

const function readAccessor(data: any, accessor: string?): any
    const path = splitAccessor(accessor)
    if #path == 0 then
        return data
    end

    local current: any
    current = data
    for _, key in path do
        if typeof(current) ~= 'table' then return nil end

        current = current[key]
    end

    return current
end

const function resolveAccessorParent(data: any, accessor: string): ({ [any]: any }, AccessorKey)
    const path = splitAccessor(accessor)
    assert(#path > 0, '[ReplicatedTable] root data replacement should use modify')

    local current: any
    current = data
    for index = 1, #path - 1 do
        const key = path[index]
        assert(typeof(current) == 'table', `[ReplicatedTable] {accessor} hit a non-table before {tostring(key)}`)

        current = current[key]
        assert(typeof(current) == 'table', `[ReplicatedTable] missing table segment {tostring(key)} while resolving {accessor}`)
    end

    assert(typeof(current) == 'table', `[ReplicatedTable] accessor parent must be a table for {accessor}`)

    return current, path[#path]
end

const function getRegisteredData(stream: StreamState, ownerOrUid: OwnerOrUid): any
    const data = stream.authoritativeByOwner[ownerOrUid]
    assert(data ~= nil, `[ReplicatedTable] {describeOwnerOrUid(ownerOrUid)} is not registered in stream {stream.id}`)

    return data
end

const function setAccessorValue(data: any, accessor: string, value: any): any
    const parent, key = resolveAccessorParent(data, accessor)
    parent[key] = value

    return data
end

const function updateAccessorValue(data: any, accessor: string?, updater: AccessorUpdater): any
    const normalizedAccessor = normalizeAccessor(accessor)
    if normalizedAccessor == ROOT_PATH then
        const replacement = updater(data)
        if replacement ~= nil then return replacement end

        return data
    end

    const currentValue = readAccessor(data, normalizedAccessor)
    const replacement = updater(currentValue)
    if replacement ~= nil then
        setAccessorValue(data, normalizedAccessor, replacement)
    end

    return data
end

const function isSame(left: any, right: any): boolean
    if typeof(left) ~= 'table' or typeof(right) ~= 'table' then
        return left == right
    end

    for key, leftValue in left do
        if not isSame(leftValue, right[key]) then
            return false
        end
    end

    for key, rightValue in right do
        if left[key] == nil and rightValue ~= nil then
            return false
        end
    end

    return true
end

const function getOwnerSignals(stream: StreamState, ownerOrUid: OwnerOrUid): { [string]: ChangedSignal }
    local ownerSignals: { [string]: ChangedSignal }?
    ownerSignals = stream.signalsByOwner[ownerOrUid]
    if ownerSignals then return ownerSignals end

    ownerSignals = {}
    stream.signalsByOwner[ownerOrUid] = ownerSignals

    return ownerSignals
end

const function fireChanged(stream: StreamState, ownerOrUid: OwnerOrUid, oldData: any, newData: any)
    const ownerSignals = stream.signalsByOwner[ownerOrUid]
    if not ownerSignals then return end

    for accessorKey, signal in ownerSignals do
        const accessor = if accessorKey == ROOT_PATH then nil else accessorKey
        const oldValue = readAccessor(oldData, accessor)
        const newValue = readAccessor(newData, accessor)
        if isSame(oldValue, newValue) then continue end

        signal:Fire(newValue, oldValue)
    end
end

const function canReceive(stream: StreamState, player: Player, ownerOrUid: OwnerOrUid): boolean
    for _, recipient in stream.resolveRecipients(ownerOrUid) do
        if recipient == player then
            return true
        end
    end

    return false
end

const function applyDelta(stream: StreamState, ownerOrUid: OwnerOrUid, diff: buffer)
    const oldData = stream.replicatedDataByOwner[ownerOrUid]
    const newData = DeltaCompress.applyImmutable(oldData, diff)

    stream.replicatedDataByOwner[ownerOrUid] = newData
    fireChanged(stream, ownerOrUid, oldData, newData)
end

const function flushPendingDeltas(stream: StreamState)
    const pendingDeltas = pendingDeltasByStreamId[stream.id]
    if not pendingDeltas then return end

    pendingDeltasByStreamId[stream.id] = nil
    for _, pendingDelta in pendingDeltas do
        applyDelta(stream, pendingDelta.ownerOrUid, pendingDelta.diff)
    end
end

const function fire(stream: StreamState, ownerOrUid: OwnerOrUid, newData: any)
    assert(RunService:IsServer(), '[ReplicatedTable] fire can only run on the server')

    const oldSignalData = stream.signalSnapshotsByOwner[ownerOrUid]
    const oldSignalDataCopy = copyDeep(oldSignalData)
    const signalDiff, updatedSignalData = DeltaCompress.diffMutable(oldSignalData, newData)
    if signalDiff then
        stream.signalSnapshotsByOwner[ownerOrUid] = updatedSignalData
        fireChanged(stream, ownerOrUid, oldSignalDataCopy, newData)
    end

    local sentSnapshots: { [Player]: any }?
    sentSnapshots = stream.sentSnapshotsByOwner[ownerOrUid]
    if not sentSnapshots then
        sentSnapshots = {}
        stream.sentSnapshotsByOwner[ownerOrUid] = sentSnapshots
    end

    const currentRecipients: { [Player]: boolean } = {}
    for _, player in stream.resolveRecipients(ownerOrUid) do
        currentRecipients[player] = true

        const oldRecipientData = sentSnapshots[player]
        const diff, updatedRecipientData = DeltaCompress.diffMutable(oldRecipientData, newData)
        if not diff then continue end

        sentSnapshots[player] = updatedRecipientData
        deltaEvent:FireClient(player, stream.id, ownerOrUid, diff)
    end

    for player in sentSnapshots do
        if currentRecipients[player] then continue end

        sentSnapshots[player] = nil
    end
end

if RunService:IsServer() then
    getFunction.OnServerInvoke = function(player: Player, streamId: string, ownerOrUid: OwnerOrUid): buffer?
        const stream = streamsById[streamId]
        if not stream then return nil end
        if not canReceive(stream, player, ownerOrUid) then return nil end

        const data = stream.authoritativeByOwner[ownerOrUid]
        if data == nil then return nil end

        local sentSnapshots: { [Player]: any }?
        sentSnapshots = stream.sentSnapshotsByOwner[ownerOrUid]
        if not sentSnapshots then
            sentSnapshots = {}
            stream.sentSnapshotsByOwner[ownerOrUid] = sentSnapshots
        end

        const diff, updatedRecipientData = DeltaCompress.diffMutable(nil, data)
        sentSnapshots[player] = updatedRecipientData

        return diff
    end
else
    deltaEvent.OnClientEvent:Connect(function(streamId: string, ownerOrUid: OwnerOrUid, diff: buffer)
        const stream = streamsById[streamId]
        if not stream then
            local pendingDeltas: { { ownerOrUid: OwnerOrUid, diff: buffer } }?
            pendingDeltas = pendingDeltasByStreamId[streamId]
            if not pendingDeltas then
                pendingDeltas = {}
                pendingDeltasByStreamId[streamId] = pendingDeltas
            end

            table.insert(pendingDeltas, {
                ownerOrUid = ownerOrUid,
                diff = diff,
            })
            return
        end

        applyDelta(stream, ownerOrUid, diff)
    end)
end

const ReplicatedTable = {}

--[=[
    Creates or returns a named stream.

    A stream id identifies one mirrored table shape, for example `"PlayerData"`
    or `"Chests"`. All streams share the same internal transport instances; the
    id is included in each transport payload so the
    receiver can route the diff.

    On the server, the returned handle owns authoritative data and recipient
    snapshots for that id. On the client, it owns cached mirrored data and local
    change signals for that id.

    @within ReplicatedTable
    @param streamId string -- Stable id used to route this replicated data shape.
    @return Stream
]=]
function ReplicatedTable.new<T>(streamId: string): Stream<T>
    assert(streamId ~= '', '[ReplicatedTable] stream id cannot be empty')

    local streamState: StreamState?
    streamState = streamsById[streamId]
    if not streamState then
        streamState = {
            id = streamId,
            resolveRecipients = defaultRecipients,
            authoritativeByOwner = {},
            sentSnapshotsByOwner = {},
            signalSnapshotsByOwner = {},
            replicatedDataByOwner = {},
            signalsByOwner = {},
        }
        streamsById[streamId] = streamState

        if RunService:IsClient() then
            flushPendingDeltas(streamState :: StreamState)
        end
    end

    const streamApi = {}

    --[=[
        Sets the server-side recipient resolver for this stream.

        The resolver receives an ownerOrUid and returns the players allowed to receive
        data for that key. It is checked before sending deltas and before serving
        an initial snapshot through client `get`.

        The default resolver only returns `{ ownerOrUid }` when the key is a `Player`.

        @within Stream
        @param resolver (ownerOrUid: OwnerOrUid) -> { Player } -- Server-side visibility rule.
        @return ()
    ]=]
    function streamApi.setRecipients(resolver: RecipientResolver)
        assert(RunService:IsServer(), '[ReplicatedTable] setRecipients can only run on the server')

        streamState.resolveRecipients = resolver
    end

    --[=[
        Registers authoritative data for a stable key.

        Use this for first setup, such as player data, shared world data, or entity spawn.
        Registering clears old per-recipient snapshots for that key, stores the
        provided table as authoritative data, and sends a baseline diff to current
        recipients.

        Calling `register` again for the same key replaces the previous baseline
        and should be treated as a full lifecycle reset.

        @within Stream
        @param ownerOrUid OwnerOrUid -- Stable key for this table, usually a `Player` or string UID.
        @param data T -- Authoritative table to mirror.
        @return T -- The registered table.
    ]=]
    function streamApi.register(ownerOrUid: OwnerOrUid, data: T): T
        assert(RunService:IsServer(), '[ReplicatedTable] register can only run on the server')

        streamState.authoritativeByOwner[ownerOrUid] = data
        streamState.sentSnapshotsByOwner[ownerOrUid] = nil
        streamState.signalSnapshotsByOwner[ownerOrUid] = nil
        fire(streamState, ownerOrUid, data)

        return data
    end

    --[=[
        Replaces the whole authoritative table for a registered key.

        This is the broad write API. It asserts if the key was not registered,
        stores the new root table, and sends one delta to current recipients.

        Use `set` or `update` when only a small accessor path changed.

        @within Stream
        @param ownerOrUid OwnerOrUid -- Registered key whose data should be replaced.
        @param data T -- New authoritative root table.
        @return T -- The new authoritative table.
    ]=]
    function streamApi.modify(ownerOrUid: OwnerOrUid, data: T): T
        assert(RunService:IsServer(), '[ReplicatedTable] modify can only run on the server')
        getRegisteredData(streamState, ownerOrUid)

        streamState.authoritativeByOwner[ownerOrUid] = data
        fire(streamState, ownerOrUid, data)

        return data
    end

    --[=[
        Replaces one accessor path inside a registered table.

        Accessors are dot paths such as `"stats.coins"` or
        `"chests.ownedChests.1"`. Numeric segments are converted to numbers.
        Intermediate tables must already exist; ReplicatedTable does not create
        missing table paths.

        Use `modify` to replace the root table. Use `set(ownerOrUid, path, nil)` when
        intentionally clearing a value.

        @within Stream
        @param ownerOrUid OwnerOrUid -- Registered key whose data should be changed.
        @param accessor string -- Dot path to replace.
        @param value any -- Value to store at the accessor.
        @return T -- The updated root table.
    ]=]
    function streamApi.set(ownerOrUid: OwnerOrUid, accessor: string, value: any): T
        assert(RunService:IsServer(), '[ReplicatedTable] set can only run on the server')

        const data = getRegisteredData(streamState, ownerOrUid)
        const updatedData = setAccessorValue(data, accessor, value)
        fire(streamState, ownerOrUid, updatedData)

        return updatedData
    end

    --[=[
        Updates one accessor path inside a registered table.

        The current accessor value is passed to `updater`. If `updater` returns a
        non-nil value, that value replaces the accessor target. If it returns
        `nil`, ReplicatedTable assumes the callback mutated the current value in
        place and keeps it.

        Passing `nil` or omitting the accessor updates the root table. In that
        root-table case, a non-nil updater return replaces the root table.

        @within Stream
        @param ownerOrUid OwnerOrUid -- Registered key whose data should be changed.
        @param accessor string? -- Dot path to update; nil means the root table.
        @param updater (currentValue: any) -> any -- Mutation/replacement callback.
        @return T -- The updated root table.
    ]=]
    function streamApi.update(ownerOrUid: OwnerOrUid, accessor: string?, updater: AccessorUpdater): T
        assert(RunService:IsServer(), '[ReplicatedTable] update can only run on the server')

        const data = getRegisteredData(streamState, ownerOrUid)
        const updatedData = updateAccessorValue(data, accessor, updater)
        streamState.authoritativeByOwner[ownerOrUid] = updatedData
        fire(streamState, ownerOrUid, updatedData)

        return updatedData
    end

    --[=[
        Removes a key from this stream.

        Unregistering clears authoritative data, recipient snapshots, and local
        server-side changed signals for the key. Current recipients receive a
        final nil delta so their mirrored root value becomes nil.

        Use this during player removal or entity despawn.

        @within Stream
        @param ownerOrUid OwnerOrUid -- Key to remove.
        @return ()
    ]=]
    function streamApi.unregister(ownerOrUid: OwnerOrUid)
        assert(RunService:IsServer(), '[ReplicatedTable] unregister can only run on the server')

        streamState.authoritativeByOwner[ownerOrUid] = nil
        fire(streamState, ownerOrUid, nil)
        streamState.sentSnapshotsByOwner[ownerOrUid] = nil
        streamState.signalSnapshotsByOwner[ownerOrUid] = nil
        streamState.signalsByOwner[ownerOrUid] = nil
    end

    --[=[
        Reads replicated data for a key.

        On the server, this reads the authoritative table. On the client, this
        reads the local cache. If no client cache exists yet, `get` invokes the
        shared `Get` `RemoteFunction` once and yields until the server responds.

        This returns nil if the key is not registered, if the local player is
        not a recipient, or if the accessor cannot be resolved.

        @within Stream
        @param ownerOrUid OwnerOrUid -- Key whose data should be read.
        @param accessor string? -- Dot path to read; nil returns the root table.
        @return any? -- The root table or accessor value, if available.
    ]=]
    function streamApi.get(ownerOrUid: OwnerOrUid, accessor: string?): any?
        local data: any
        if RunService:IsServer() then
            data = streamState.authoritativeByOwner[ownerOrUid]
        else
            const cachedData = streamState.replicatedDataByOwner[ownerOrUid]
            if cachedData ~= nil then
                return readAccessor(cachedData, accessor)
            end

            const diff = getFunction:InvokeServer(streamState.id, ownerOrUid) :: buffer?
            if not diff then return nil end

            applyDelta(streamState, ownerOrUid, diff)
            data = streamState.replicatedDataByOwner[ownerOrUid]
        end

        return readAccessor(data, accessor)
    end

    --[=[
        Returns a local change signal for a key and optional accessor.

        Signals are local to the current VM. They are not separate Roblox remotes.
        A listener receives `(newValue, oldValue)` whenever the root table or
        requested accessor changes as a result of `register`, `modify`, `set`,
        `update`, `unregister`, or an incoming client delta.

        Passing nil for `accessor` listens to the whole root table.

        @within Stream
        @param ownerOrUid OwnerOrUid -- Key whose mirrored data should be observed.
        @param accessor string? -- Dot path to observe; nil observes the root table.
        @return NamedSignal -- Signal that fires with `(newValue, oldValue)`.
    ]=]
    function streamApi.changed(ownerOrUid: OwnerOrUid, accessor: string?): ChangedSignal
        const accessorKey = normalizeAccessor(accessor)
        const ownerSignals = getOwnerSignals(streamState, ownerOrUid)
        local signal: ChangedSignal?
        signal = ownerSignals[accessorKey]
        if signal then return signal end

        signal = NamedSignal.new()
        ownerSignals[accessorKey] = signal

        return signal
    end

    return streamApi :: Stream<T>
end

return ReplicatedTable
