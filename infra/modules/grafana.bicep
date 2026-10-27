// Phase 7: Azure Managed Grafana reading Azure Monitor with its own managed identity.

import { roles } from 'types.bicep'

param name string
param location string
param tags object
param adminPrincipalId string

resource grafana 'Microsoft.Dashboard/grafana@2024-10-01' = {
  name: name
  location: location
  tags: tags
  sku: { name: 'Standard' }
  identity: { type: 'SystemAssigned' }
  properties: {
    publicNetworkAccess: 'Enabled'
    zoneRedundancy: 'Disabled'
    apiKey: 'Disabled'
  }
}

// Read every metric and log in this resource group (Monitoring Reader covers Log Analytics queries too).
resource monitoringReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, grafana.id, roles.monitoringReader)
  properties: {
    principalId: grafana.identity.principalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.monitoringReader)
    principalType: 'ServicePrincipal'
  }
}

resource admin 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(grafana.id, adminPrincipalId, roles.grafanaAdmin)
  scope: grafana
  properties: {
    principalId: adminPrincipalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.grafanaAdmin)
    principalType: 'User'
  }
}

output url string = grafana.properties.endpoint
