// Phase 3: the API on App Service (Linux, .NET 10), running as a user-assigned managed identity.

param planName string
param siteName string
param location string
param tags object
param workspaceId string
param identityId string
param appSettings object

@description('B1 is the cheapest with Always On. Deployment slots and autoscale need S1/P0v3 or higher; zone redundancy needs Premium v3.')
param skuName string = 'B1'

@description('Outbound VNet integration subnet (delegated to Microsoft.Web/serverFarms).')
param vnetSubnetId string = ''

@description('Front Door profile id (its frontDoorId GUID). When set, only that Front Door can reach the app.')
param frontDoorId string = ''

@description('Phase 11: instances spread across availability zones. Needs Premium v2 or later and at least 2 instances; an existing plan may have to be recreated.')
param zoneRedundant bool = false

resource plan 'Microsoft.Web/serverfarms@2024-04-01' = {
  name: planName
  location: location
  tags: tags
  kind: 'linux'
  sku: zoneRedundant ? { name: skuName, capacity: 2 } : { name: skuName }
  properties: { reserved: true, zoneRedundant: zoneRedundant }
}

resource site 'Microsoft.Web/sites@2024-04-01' = {
  name: siteName
  location: location
  tags: tags
  kind: 'app,linux'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${identityId}': {} }
  }
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    keyVaultReferenceIdentity: identityId
    virtualNetworkSubnetId: empty(vnetSubnetId) ? null : vnetSubnetId
    siteConfig: {
      linuxFxVersion: 'DOTNETCORE|10.0'
      alwaysOn: skuName != 'F1'
      http20Enabled: true
      minTlsVersion: '1.2'
      ftpsState: 'Disabled'
      healthCheckPath: '/health/live'
      vnetRouteAllEnabled: !empty(vnetSubnetId)
      appSettings: map(items(appSettings), s => { name: s.key, value: s.value })
      // Phase 10: lock the origin so traffic can't bypass Front Door's WAF. Service tag + the X-Azure-FDID header
      // (the tag alone would admit every Front Door customer's traffic).
      ipSecurityRestrictionsDefaultAction: empty(frontDoorId) ? 'Allow' : 'Deny'
      ipSecurityRestrictions: empty(frontDoorId)
        ? []
        : [
            {
              name: 'AllowOurFrontDoor'
              action: 'Allow'
              priority: 100
              tag: 'ServiceTag'
              ipAddress: 'AzureFrontDoor.Backend'
              headers: { 'x-azure-fdid': [frontDoorId] }
            }
          ]
      scmIpSecurityRestrictionsUseMain: false
    }
  }
}

// Publish with Entra ID (az webapp deploy / pipeline service connection), never with basic-auth publishing credentials.
resource ftpCredentials 'Microsoft.Web/sites/basicPublishingCredentialsPolicies@2024-04-01' = {
  parent: site
  name: 'ftp'
  properties: { allow: false }
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
output hostName string = site.properties.defaultHostName
output planId string = plan.id
