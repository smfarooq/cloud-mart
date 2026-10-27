// Phase 8: a private registry. Admin user off; pulls use managed identity (AcrPull), pushes use the pipeline identity.

import { roleAssignment } from 'types.bicep'

param name string
param location string
param tags object
param workspaceId string
param roleAssignments roleAssignment[] = []

@description('Basic is enough to learn. Premium adds private endpoints, geo-replication and zone redundancy.')
@allowed(['Basic', 'Standard', 'Premium'])
param sku string = 'Basic'

resource registry 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: name
  location: location
  tags: tags
  sku: { name: sku }
  properties: {
    adminUserEnabled: false
  }
}

resource assignments 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for ra in roleAssignments: {
    name: guid(registry.id, ra.principalId, ra.roleDefinitionId)
    scope: registry
    properties: {
      principalId: ra.principalId
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', ra.roleDefinitionId)
      principalType: ra.?principalType ?? 'ServicePrincipal'
    }
  }
]

resource diagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'to-log-analytics'
  scope: registry
  properties: {
    workspaceId: workspaceId
    logs: [{ categoryGroup: 'allLogs', enabled: true }]
    metrics: [{ category: 'AllMetrics', enabled: true }]
  }
}

output name string = registry.name
output loginServer string = registry.properties.loginServer
