// Phase 4: Blob Storage for product images, plus the Functions host's own storage.
// Shared-key access is OFF: every caller (apps, pipeline, you in the portal) authenticates with Entra ID.

import { roleAssignment } from 'types.bicep'

param name string
param location string
param tags object
param workspaceId string
param roleAssignments roleAssignment[] = []

@description('LRS -> ZRS -> GRS/GZRS -> RA-GZRS: the durability/availability ladder (phase 10).')
@allowed(['Standard_LRS', 'Standard_ZRS', 'Standard_GRS', 'Standard_GZRS', 'Standard_RAGZRS'])
param skuName string = 'Standard_LRS'

@description('Origins allowed to PUT directly to Blob Storage (the SPA, for SAS uploads).')
param corsOrigins array = []

param privateEndpointSubnetId string = ''
param blobDnsZoneId string = ''
param queueDnsZoneId string = ''
param tableDnsZoneId string = ''

var usePrivateEndpoint = !empty(privateEndpointSubnetId)
var containerNames = ['product-uploads', 'product-images', 'function-deployments']

resource account 'Microsoft.Storage/storageAccounts@2024-01-01' = {
  name: name
  location: location
  tags: tags
  kind: 'StorageV2'
  sku: { name: skuName }
  properties: {
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    defaultToOAuthAuthentication: true
    accessTier: 'Hot'
    // Stays reachable from the internet because the browser uploads straight to it with a SAS (valet key).
    // App traffic still goes through the private endpoints when they exist. That trade-off is a phase 4 discussion.
    publicNetworkAccess: 'Enabled'
    networkAcls: { defaultAction: 'Allow', bypass: 'AzureServices' }
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2024-01-01' = {
  parent: account
  name: 'default'
  properties: {
    cors: {
      corsRules: empty(corsOrigins)
        ? []
        : [
            {
              allowedOrigins: corsOrigins
              allowedMethods: ['PUT', 'OPTIONS']
              allowedHeaders: ['*']
              exposedHeaders: ['*']
              maxAgeInSeconds: 3600
            }
          ]
    }
    // Data protection for unstructured data: soft delete + versioning (+ point-in-time restore if you want it).
    deleteRetentionPolicy: { enabled: true, days: 7 }
    containerDeleteRetentionPolicy: { enabled: true, days: 7 }
    isVersioningEnabled: true
  }
}

resource containers 'Microsoft.Storage/storageAccounts/blobServices/containers@2024-01-01' = [
  for containerName in containerNames: {
    parent: blobService
    name: containerName
    properties: { publicAccess: 'None' }
  }
]

// Lifecycle management: the cost lever for unstructured data.
resource lifecycle 'Microsoft.Storage/storageAccounts/managementPolicies@2024-01-01' = {
  parent: account
  name: 'default'
  properties: {
    policy: {
      rules: [
        {
          name: 'delete-abandoned-uploads'
          enabled: true
          type: 'Lifecycle'
          definition: {
            filters: { blobTypes: ['blockBlob'], prefixMatch: ['product-uploads/'] }
            actions: { baseBlob: { delete: { daysAfterModificationGreaterThan: 1 } } }
          }
        }
        {
          name: 'cool-old-images'
          enabled: true
          type: 'Lifecycle'
          definition: {
            filters: { blobTypes: ['blockBlob'], prefixMatch: ['product-images/'] }
            actions: {
              baseBlob: { tierToCool: { daysAfterModificationGreaterThan: 90 } }
              version: { delete: { daysAfterCreationGreaterThan: 30 } }
            }
          }
        }
      ]
    }
  }
}

resource assignments 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for ra in roleAssignments: {
    name: guid(account.id, ra.principalId, ra.roleDefinitionId)
    scope: account
    properties: {
      principalId: ra.principalId
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', ra.roleDefinitionId)
      principalType: ra.?principalType ?? 'ServicePrincipal'
    }
  }
]

resource blobDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'to-log-analytics'
  scope: blobService
  properties: {
    workspaceId: workspaceId
    logs: [{ categoryGroup: 'allLogs', enabled: true }]
    metrics: [{ category: 'Transaction', enabled: true }]
  }
}

var privateEndpoints = [
  { groupId: 'blob', zoneId: blobDnsZoneId }
  { groupId: 'queue', zoneId: queueDnsZoneId }
  { groupId: 'table', zoneId: tableDnsZoneId }
]

module endpoints 'private-endpoint.bicep' = [
  for pe in privateEndpoints: if (usePrivateEndpoint) {
    name: '${name}-pe-${pe.groupId}'
    params: {
      name: 'pe-${name}-${pe.groupId}'
      location: location
      tags: tags
      subnetId: privateEndpointSubnetId
      privateLinkServiceId: account.id
      groupId: pe.groupId
      privateDnsZoneId: pe.zoneId
    }
  }
]

output name string = account.name
output id string = account.id
output blobEndpoint string = account.properties.primaryEndpoints.blob
output deploymentContainerUrl string = '${account.properties.primaryEndpoints.blob}function-deployments'
