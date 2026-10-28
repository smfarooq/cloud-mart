// Phase 4: Azure SQL Database, serverless General Purpose (auto-pauses when idle), Entra-only authentication.
// The app identities still need database users: run deploy/sql/grant-managed-identities.sql once (Bicep can't run T-SQL).

param serverName string
param databaseName string = 'cloudmart'

@description('Phase 16: a second database for the Payments API (database per service). Empty = not created.')
param paymentsDatabaseName string = ''
param location string
param tags object
param workspaceId string

@description('Entra admin of the server: you. Use a group in real life.')
param adminLogin string
param adminObjectId string
@allowed(['User', 'Group', 'Application'])
param adminPrincipalType string = 'User'

@description('Adds the 0.0.0.0 "Allow Azure services" rule. It admits traffic from ANY Azure tenant, not just yours: fine for a lab, replace with private endpoints.')
param allowAzureServices bool = true

@allowed(['Local', 'Zone', 'Geo', 'GeoZone'])
param backupStorageRedundancy string = 'Local'

param privateEndpointSubnetId string = ''
param privateDnsZoneId string = ''

var usePrivateEndpoint = !empty(privateEndpointSubnetId)

resource server 'Microsoft.Sql/servers@2023-08-01' = {
  name: serverName
  location: location
  tags: tags
  properties: {
    minimalTlsVersion: '1.2'
    publicNetworkAccess: usePrivateEndpoint ? 'Disabled' : 'Enabled'
    administrators: {
      administratorType: 'ActiveDirectory'
      azureADOnlyAuthentication: true
      login: adminLogin
      sid: adminObjectId
      tenantId: tenant().tenantId
      principalType: adminPrincipalType
    }
  }
}

resource database 'Microsoft.Sql/servers/databases@2023-08-01' = {
  parent: server
  name: databaseName
  location: location
  tags: tags
  sku: { name: 'GP_S_Gen5', tier: 'GeneralPurpose', family: 'Gen5', capacity: 1 }
  properties: {
    autoPauseDelay: 60
    minCapacity: json('0.5')
    requestedBackupStorageRedundancy: backupStorageRedundancy
    zoneRedundant: false
  }
}

// Point-in-time restore window. Long-term retention (weekly/monthly/yearly) is a separate policy.
resource shortTermRetention 'Microsoft.Sql/servers/databases/backupShortTermRetentionPolicies@2023-08-01' = {
  parent: database
  name: 'default'
  properties: { retentionDays: 7 }
}

// Same server, separate database: its own users, backups, scale and blast radius. The Payments identity is a user
// here and nowhere else, so even a compromised Payments API can't read orders (and the API can't read payments).
resource paymentsDatabase 'Microsoft.Sql/servers/databases@2023-08-01' = if (!empty(paymentsDatabaseName)) {
  parent: server
  name: empty(paymentsDatabaseName) ? 'unused' : paymentsDatabaseName
  location: location
  tags: tags
  sku: { name: 'GP_S_Gen5', tier: 'GeneralPurpose', family: 'Gen5', capacity: 1 }
  properties: {
    autoPauseDelay: 60
    minCapacity: json('0.5')
    requestedBackupStorageRedundancy: backupStorageRedundancy
    zoneRedundant: false
  }
}

resource paymentsDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = if (!empty(paymentsDatabaseName)) {
  name: 'to-log-analytics'
  scope: paymentsDatabase
  properties: {
    workspaceId: workspaceId
    logs: [{ categoryGroup: 'allLogs', enabled: true }]
    metrics: [{ category: 'Basic', enabled: true }]
  }
}

resource allowAzure 'Microsoft.Sql/servers/firewallRules@2023-08-01' = if (allowAzureServices && !usePrivateEndpoint) {
  parent: server
  name: 'AllowAllWindowsAzureIps'
  properties: { startIpAddress: '0.0.0.0', endIpAddress: '0.0.0.0' }
}

resource diagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'to-log-analytics'
  scope: database
  properties: {
    workspaceId: workspaceId
    logs: [{ categoryGroup: 'allLogs', enabled: true }]
    metrics: [{ category: 'Basic', enabled: true }]
  }
}

module privateEndpoint 'private-endpoint.bicep' = if (usePrivateEndpoint) {
  name: '${serverName}-pe'
  params: {
    name: 'pe-${serverName}'
    location: location
    tags: tags
    subnetId: privateEndpointSubnetId
    privateLinkServiceId: server.id
    groupId: 'sqlServer'
    privateDnsZoneId: privateDnsZoneId
  }
}

output serverName string = server.name
output fqdn string = server.properties.fullyQualifiedDomainName
output databaseName string = database.name
output paymentsDatabaseName string = paymentsDatabaseName
