// Phase 4: Azure SQL Database, serverless General Purpose (auto-pauses when idle), Entra-only authentication.
// The app identities still need database users: run deploy/sql/grant-managed-identities.sql once (Bicep can't run T-SQL).
// Phase 11 adds geo-redundant backups (default), zone redundancy and an optional auto-failover group.

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

@description('Where backups are copied. Local backups die with the region; Geo (RA-GRS) lets you geo-restore anywhere.')
@allowed(['Local', 'Zone', 'Geo', 'GeoZone'])
param backupStorageRedundancy string = 'Geo'

@description('Phase 11: spread each database\'s replicas across availability zones (survives a datacentre failure).')
param zoneRedundant bool = false

@description('Phase 11: a region for the secondary server of an auto-failover group. Empty = no failover group.')
param secondaryLocation string = ''

param privateEndpointSubnetId string = ''
param privateDnsZoneId string = ''

var usePrivateEndpoint = !empty(privateEndpointSubnetId)
var useFailoverGroup = !empty(secondaryLocation)
var secondaryServerName = '${serverName}-dr'
var failoverGroupName = '${serverName}-fog'

// Geo-replicated serverless databases can't auto-pause (-1 = never): a failover group bills compute around the clock.
var autoPauseDelay = useFailoverGroup ? -1 : 60

var entraOnlyAdmin = {
  administratorType: 'ActiveDirectory'
  azureADOnlyAuthentication: true
  login: adminLogin
  sid: adminObjectId
  tenantId: tenant().tenantId
  principalType: adminPrincipalType
}

resource server 'Microsoft.Sql/servers@2023-08-01' = {
  name: serverName
  location: location
  tags: tags
  properties: {
    minimalTlsVersion: '1.2'
    publicNetworkAccess: usePrivateEndpoint ? 'Disabled' : 'Enabled'
    administrators: entraOnlyAdmin
  }
}

resource database 'Microsoft.Sql/servers/databases@2023-08-01' = {
  parent: server
  name: databaseName
  location: location
  tags: tags
  sku: { name: 'GP_S_Gen5', tier: 'GeneralPurpose', family: 'Gen5', capacity: 1 }
  properties: {
    autoPauseDelay: autoPauseDelay
    minCapacity: json('0.5')
    requestedBackupStorageRedundancy: backupStorageRedundancy
    zoneRedundant: zoneRedundant
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
    autoPauseDelay: autoPauseDelay
    minCapacity: json('0.5')
    requestedBackupStorageRedundancy: backupStorageRedundancy
    zoneRedundant: zoneRedundant
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

// Through a private endpoint, Proxy keeps every connection on 1433, so pe-nsg can stay narrow. Redirect is faster
// (after the login, the client talks to the database node directly) but needs 1433-65535 open to the endpoint.
resource connectionPolicy 'Microsoft.Sql/servers/connectionPolicies@2023-08-01' = if (usePrivateEndpoint) {
  parent: server
  name: 'default'
  properties: { connectionType: 'Proxy' }
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

// ---------------------------------------------------------------- Phase 11: auto-failover group
// The secondary server holds asynchronous geo-replicas of both databases. The listener name
// <server>-fog.database.windows.net always points at whichever server is primary, so the apps never change config.
// Database users created FROM EXTERNAL PROVIDER live inside each database, so they replicate too.
resource secondaryServer 'Microsoft.Sql/servers@2023-08-01' = if (useFailoverGroup) {
  name: secondaryServerName
  location: useFailoverGroup ? secondaryLocation : location
  tags: tags
  properties: {
    minimalTlsVersion: '1.2'
    publicNetworkAccess: usePrivateEndpoint ? 'Disabled' : 'Enabled'
    administrators: entraOnlyAdmin
  }
}

resource secondaryConnectionPolicy 'Microsoft.Sql/servers/connectionPolicies@2023-08-01' = if (useFailoverGroup && usePrivateEndpoint) {
  parent: secondaryServer
  name: 'default'
  properties: { connectionType: 'Proxy' }
}

resource secondaryAllowAzure 'Microsoft.Sql/servers/firewallRules@2023-08-01' = if (useFailoverGroup && allowAzureServices && !usePrivateEndpoint) {
  parent: secondaryServer
  name: 'AllowAllWindowsAzureIps'
  properties: { startIpAddress: '0.0.0.0', endIpAddress: '0.0.0.0' }
}

// A private endpoint lives in the VNet's region, but its target can be anywhere: the secondary server gets one in
// this VNet, so the apps still reach the database privately after a failover. Both records go in the same DNS zone.
module secondaryPrivateEndpoint 'private-endpoint.bicep' = if (useFailoverGroup && usePrivateEndpoint) {
  name: '${secondaryServerName}-pe'
  params: {
    name: 'pe-${secondaryServerName}'
    location: location
    tags: tags
    subnetId: privateEndpointSubnetId
    privateLinkServiceId: secondaryServer.id
    groupId: 'sqlServer'
    privateDnsZoneId: privateDnsZoneId
  }
}

resource failoverGroup 'Microsoft.Sql/servers/failoverGroups@2023-08-01' = if (useFailoverGroup) {
  parent: server
  name: failoverGroupName
  properties: {
    partnerServers: [{ id: secondaryServer.id }]
    // Customer-managed ("Manual") is Microsoft's recommendation: you decide when to fail over. With Automatic,
    // Microsoft fails over only for a region-wide outage, after the grace period, which can be later than your RTO.
    readWriteEndpoint: { failoverPolicy: 'Manual' }
    readOnlyEndpoint: { failoverPolicy: 'Disabled' }
    databases: concat([database.id], empty(paymentsDatabaseName) ? [] : [paymentsDatabase.id])
  }
}

output serverName string = server.name
output fqdn string = server.properties.fullyQualifiedDomainName
output databaseName string = database.name
output paymentsDatabaseName string = paymentsDatabaseName
output listenerFqdn string = useFailoverGroup ? '${failoverGroupName}${environment().suffixes.sqlServerHostname}' : ''
@description('What the apps connect to: the failover group listener when there is one, the server otherwise.')
output connectionFqdn string = useFailoverGroup
  ? '${failoverGroupName}${environment().suffixes.sqlServerHostname}'
  : server.properties.fullyQualifiedDomainName
output secondaryServerName string = useFailoverGroup ? secondaryServerName : ''
