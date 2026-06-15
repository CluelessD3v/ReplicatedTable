--!strict
--[[
    TransportClient (Client)
    ========================
    Author: Clueless_Dev (1761758398)
    Updated: 15/06/26

    Warms ReplicatedTable after transport replication so gameplay requires do
    not become the first place that waits for the transport tree.
]]

const RunService = game:GetService('RunService')

const TRANSPORT_FOLDER_NAME = '_ReplicatedTable'
const DELTA_EVENT_NAME = 'Delta'
const GET_FUNCTION_NAME = 'Get'
const TRANSPORT_WAIT_SECONDS = 30

assert(RunService:IsClient(), '[ReplicatedTable] TransportClient must only run on the client')

const moduleScript = script.Parent
assert(moduleScript and moduleScript:IsA('ModuleScript'), '[ReplicatedTable] TransportClient must be parented to ReplicatedTable')

const transportFolder = moduleScript:WaitForChild(TRANSPORT_FOLDER_NAME, TRANSPORT_WAIT_SECONDS)
assert(transportFolder and transportFolder:IsA('Folder'), `[ReplicatedTable] timed out waiting for {TRANSPORT_FOLDER_NAME}`)

const deltaEvent = transportFolder:WaitForChild(DELTA_EVENT_NAME, TRANSPORT_WAIT_SECONDS)
assert(deltaEvent and deltaEvent:IsA('RemoteEvent'), `[ReplicatedTable] timed out waiting for {DELTA_EVENT_NAME}`)

const getFunction = transportFolder:WaitForChild(GET_FUNCTION_NAME, TRANSPORT_WAIT_SECONDS)
assert(getFunction and getFunction:IsA('RemoteFunction'), `[ReplicatedTable] timed out waiting for {GET_FUNCTION_NAME}`)

require(moduleScript)
