--!strict
--[[
    TransportServer (Server)
    ========================
    Author: Clueless_Dev (1761758398)
    Updated: 15/06/26

    Pre-creates ReplicatedTable transport instances so client-side requires do
    not race the server's first API require.
]]

const RunService = game:GetService('RunService')

const TRANSPORT_FOLDER_NAME = '_ReplicatedTable'
const DELTA_EVENT_NAME = 'Delta'
const GET_FUNCTION_NAME = 'Get'

assert(RunService:IsServer(), '[ReplicatedTable] TransportServer must only run on the server')

const moduleScript = script.Parent
assert(moduleScript and moduleScript:IsA('ModuleScript'), '[ReplicatedTable] TransportServer must be parented to ReplicatedTable')

const existingTransportFolder = moduleScript:FindFirstChild(TRANSPORT_FOLDER_NAME)
if existingTransportFolder then
    assert(existingTransportFolder:IsA('Folder'), `[ReplicatedTable] {TRANSPORT_FOLDER_NAME} must be a Folder`)
else
    const createdTransportFolder = Instance.new('Folder')
    createdTransportFolder.Name = TRANSPORT_FOLDER_NAME
    createdTransportFolder.Parent = moduleScript
end

const transportFolder = moduleScript:FindFirstChild(TRANSPORT_FOLDER_NAME)
assert(transportFolder and transportFolder:IsA('Folder'), `[ReplicatedTable] {TRANSPORT_FOLDER_NAME} must be a Folder`)

const existingDeltaEvent = transportFolder:FindFirstChild(DELTA_EVENT_NAME)
if existingDeltaEvent then
    assert(existingDeltaEvent:IsA('RemoteEvent'), `[ReplicatedTable] {DELTA_EVENT_NAME} must be a RemoteEvent`)
else
    const deltaEvent = Instance.new('RemoteEvent')
    deltaEvent.Name = DELTA_EVENT_NAME
    deltaEvent.Parent = transportFolder
end

const existingGetFunction = transportFolder:FindFirstChild(GET_FUNCTION_NAME)
if existingGetFunction then
    assert(existingGetFunction:IsA('RemoteFunction'), `[ReplicatedTable] {GET_FUNCTION_NAME} must be a RemoteFunction`)
else
    const getFunction = Instance.new('RemoteFunction')
    getFunction.Name = GET_FUNCTION_NAME
    getFunction.Parent = transportFolder
end
