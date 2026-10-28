// Phase 16: a backend service (Payments or Shipping) on the API's App Service plan, so it adds no compute cost.
// Inbound: public, guarded by an Entra app role, until private endpoints are on; then ONLY via its private endpoint.
// Outbound: the same VNet integration subnet as the API (every app in a plan shares the plan's integration subnet).

param siteName string
param location string
param tags object
param planId string
param workspaceId string
param identityId string
param appSettings object
param alwaysOn bool = true

@description('Outbound VNet integration subnet (delegated to Microsoft.Web/serverFarms).')
param vnetSubnetId string = ''

@description('Set (with privateDnsZoneId) to give the app a private endpoint and shut its public entrance.')
param privateEndpointSubnetId string = ''
param privateDnsZoneId string = ''

var usePrivateEndpoint = !empty(privateEndpointSubnetId)

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
    serverFarmId: planId
    httpsOnly: true
    keyVaultReferenceIdentity: identityId
    virtualNetworkSubnetId: empty(vnetSubnetId) ? null : vnetSubnetId
    // Not 'Disabled': that would also close the deployment (SCM) site to the pipeline's Microsoft-hosted agents.
    // Instead the app's public entrance denies everything below; private endpoint traffic bypasses those rules.
    // (The fully private alternative: publicNetworkAccess 'Disabled' plus a self-hosted agent inside the VNet.)
    publicNetworkAccess: 'Enabled'
    siteConfig: {
      linuxFxVersion: 'DOTNETCORE|10.0'
      alwaysOn: alwaysOn
      http20Enabled: true
      minTlsVersion: '1.2'
      ftpsState: 'Disabled'
      healthCheckPath: '/health/live'
      vnetRouteAllEnabled: !empty(vnetSubnetId)
      appSettings: map(items(appSettings), s => { name: s.key, value: s.value })
      ipSecurityRestrictionsDefaultAction: usePrivateEndpoint ? 'Deny' : 'Allow'
      scmIpSecurityRestrictionsUseMain: false
      scmIpSecurityRestrictionsDefaultAction: 'Allow'
    }
  }
}

// Deploy with Entra ID (az webapp deploy / pipeline service connection), never with basic-auth publishing credentials.
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

// Inbound private endpoint: <app>.azurewebsites.net resolves to a private IP for anything using the VNet's DNS.
module privateEndpoint 'private-endpoint.bicep' = if (usePrivateEndpoint) {
  name: '${siteName}-pe'
  params: {
    name: 'pe-${siteName}'
    location: location
    tags: tags
    subnetId: privateEndpointSubnetId
    privateLinkServiceId: site.id
    groupId: 'sites'
    privateDnsZoneId: privateDnsZoneId
  }
}

output name string = site.name
output id string = site.id
output hostName string = site.properties.defaultHostName
