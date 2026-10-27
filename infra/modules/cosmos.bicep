// Phase 4: Cosmos DB for NoSQL. Keys are disabled; apps use Entra ID + Cosmos data-plane RBAC.
// Note: data-plane RBAC cannot create databases/containers. That is a control-plane (ARM) job, so it lives here.

param name string
param location string
param tags object
param workspaceId string

@description('Free tier: 1000 RU/s + 25 GB free, one account per subscription. If you already used it, set false (serverless).')
param freeTier bool = true

@description('Phase 10: a second read region with automatic failover. Requires provisioned throughput (freeTier = true); serverless is single-region.')
param secondaryLocation string = ''

@description('Principals that get the built-in "Cosmos DB Built-in Data Contributor" data-plane role.')
param dataContributorPrincipalIds array = []

param privateEndpointSubnetId string = ''
param privateDnsZoneId string = ''

var usePrivateEndpoint = !empty(privateEndpointSubnetId)
var multiRegion = freeTier && !empty(secondaryLocation)

resource account 'Microsoft.DocumentDB/databaseAccounts@2024-11-15' = {
  name: name
  location: location
  tags: tags
  kind: 'GlobalDocumentDB'
  properties: {
    databaseAccountOfferType: 'Standard'
    enableFreeTier: freeTier
    capabilities: freeTier ? [] : [{ name: 'EnableServerless' }]
    consistencyPolicy: { defaultConsistencyLevel: 'Session' }
    locations: concat(
      [{ locationName: location, failoverPriority: 0, isZoneRedundant: false }],
      multiRegion ? [{ locationName: secondaryLocation, failoverPriority: 1, isZoneRedundant: false }] : []
    )
    enableAutomaticFailover: multiRegion
    disableLocalAuth: true
    minimalTlsVersion: 'Tls12'
    publicNetworkAccess: usePrivateEndpoint ? 'Disabled' : 'Enabled'
    // Continuous backup = point-in-time restore. The 7-day tier is free.
    backupPolicy: { type: 'Continuous', continuousModeProperties: { tier: 'Continuous7Days' } }
  }
}

resource database 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases@2024-11-15' = {
  parent: account
  name: 'cloudmart'
  properties: {
    resource: { id: 'cloudmart' }
    // Shared database throughput, sized to exactly the free-tier allowance.
    options: freeTier ? { throughput: 1000 } : {}
  }
}

var containerDefinitions = [
  { name: 'products', partitionKey: '/category' }
  { name: 'product-stats', partitionKey: '/id' }
]

resource containers 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers@2024-11-15' = [
  for c in containerDefinitions: {
    parent: database
    name: c.name
    properties: {
      resource: {
        id: c.name
        partitionKey: { paths: [c.partitionKey], kind: 'Hash', version: 2 }
      }
    }
  }
]

resource dataContributors 'Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments@2024-11-15' = [
  for principalId in dataContributorPrincipalIds: {
    parent: account
    name: guid(account.id, principalId, 'data-contributor')
    properties: {
      roleDefinitionId: '${account.id}/sqlRoleDefinitions/00000000-0000-0000-0000-000000000002'
      principalId: principalId
      scope: account.id
    }
  }
]

resource diagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'to-log-analytics'
  scope: account
  properties: {
    workspaceId: workspaceId
    logAnalyticsDestinationType: 'Dedicated'
    logs: [{ categoryGroup: 'allLogs', enabled: true }]
    metrics: [{ category: 'Requests', enabled: true }]
  }
}

module privateEndpoint 'private-endpoint.bicep' = if (usePrivateEndpoint) {
  name: '${name}-pe'
  params: {
    name: 'pe-${name}'
    location: location
    tags: tags
    subnetId: privateEndpointSubnetId
    privateLinkServiceId: account.id
    groupId: 'Sql'
    privateDnsZoneId: privateDnsZoneId
  }
}

output name string = account.name
output endpoint string = account.properties.documentEndpoint
