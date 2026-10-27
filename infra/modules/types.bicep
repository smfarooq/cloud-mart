// Shared types and built-in role ids. Role definition ids are the same in every tenant:
//   az role definition list --name "Storage Blob Data Owner" --query "[].name" -o tsv

@export()
type roleAssignment = {
  principalId: string
  roleDefinitionId: string
  principalType: ('ServicePrincipal' | 'User' | 'Group')?
}

@export()
var roles = {
  acrPull: '7f951dda-4ed3-4680-a7ca-43fe172d538d'
  aksRbacClusterAdmin: 'b1ff04bb-8a4e-4dc4-8eb5-8693973ce19b'
  appConfigDataOwner: '5ae67dd6-50cb-40e7-96ff-dc2bfa4b606b'
  appConfigDataReader: '516239f1-63e1-4d78-a4de-a74fb236a071'
  eventHubsDataOwner: 'f526a384-b230-433a-b45c-95f59c4a2dec'
  eventHubsDataReceiver: 'a638d3c7-ab3a-418d-83e6-5f17a39d4fde'
  eventHubsDataSender: '2b629674-e913-4c01-ae53-ef4638d8f975'
  grafanaAdmin: '22926164-76b3-42b3-bc55-97df8dab3e41'
  keyVaultSecretsOfficer: 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7'
  keyVaultSecretsUser: '4633458b-17de-408a-b874-0445c86b69e6'
  monitoringReader: '43d0d8ad-25c7-4714-9337-8ba259a9fe05'
  serviceBusDataOwner: '090c5cfd-751d-490a-894a-3ce6f1109419'
  serviceBusDataReceiver: '4f6d3b9b-027b-4f4c-9142-0e5a2a2247e0'
  serviceBusDataSender: '69a216fc-b8fb-44d8-bc22-1f3c2cd27a39'
  storageBlobDataContributor: 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
  storageBlobDataOwner: 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b'
  storageBlobDelegator: 'db58b8e5-c6ad-4a2a-8342-4190687cbf4a'
  storageQueueDataContributor: '974c5e8b-45b9-4653-ba55-5f855dd0fb88'
  storageTableDataContributor: '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3'
  tagContributor: '4a9ae827-6dc8-4573-8ac7-8239d42aa03f'
  vmAdminLogin: '1c0163c0-47e6-4577-8991-ea5c82e286e4'
}
