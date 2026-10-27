// Phase 3/5: Azure Functions on the Flex Consumption plan (the recommended serverless plan: scale to zero,
// VNet integration, per-function scaling, identity-based deployment storage).

param planName string
param appName string
param location string
param tags object
param workspaceId string
param identityId string
param deploymentContainerUrl string
param appSettings object

@description('Outbound VNet integration subnet (delegated to Microsoft.App/environments).')
param vnetSubnetId string = ''

param maximumInstanceCount int = 40
@allowed([512, 2048, 4096])
param instanceMemoryMB int = 2048
param dotnetVersion string = '10.0'

resource plan 'Microsoft.Web/serverfarms@2024-04-01' = {
  name: planName
  location: location
  tags: tags
  kind: 'functionapp'
  sku: { tier: 'FlexConsumption', name: 'FC1' }
  properties: { reserved: true }
}

resource site 'Microsoft.Web/sites@2024-04-01' = {
  name: appName
  location: location
  tags: tags
  kind: 'functionapp,linux'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${identityId}': {} }
  }
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    keyVaultReferenceIdentity: identityId
    virtualNetworkSubnetId: empty(vnetSubnetId) ? null : vnetSubnetId
    functionAppConfig: {
      deployment: {
        storage: {
          type: 'blobContainer'
          value: deploymentContainerUrl
          authentication: { type: 'UserAssignedIdentity', userAssignedIdentityResourceId: identityId }
        }
      }
      scaleAndConcurrency: {
        maximumInstanceCount: maximumInstanceCount
        instanceMemoryMB: instanceMemoryMB
      }
      runtime: { name: 'dotnet-isolated', version: dotnetVersion }
    }
    siteConfig: {
      minTlsVersion: '1.2'
      // Flex Consumption rejects FUNCTIONS_WORKER_RUNTIME / FUNCTIONS_EXTENSION_VERSION here: runtime is set above.
      appSettings: map(items(appSettings), s => { name: s.key, value: s.value })
    }
  }
}

resource scmCredentials 'Microsoft.Web/sites/basicPublishingCredentialsPolicies@2024-04-01' = {
  parent: site
  name: 'scm'
  properties: { allow: false }
}

resource diagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'to-log-analytics'
  scope: site
  properties: {
    workspaceId: workspaceId
    logs: [{ categoryGroup: 'allLogs', enabled: true }]
    metrics: [{ category: 'AllMetrics', enabled: true }]
  }
}

output name string = site.name
output id string = site.id
