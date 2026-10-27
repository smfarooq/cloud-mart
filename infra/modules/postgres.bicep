// Phase 4 (alternative engine): Azure Database for PostgreSQL Flexible Server, Burstable B1ms, Entra-only auth.
// The app identities need roles: run deploy/postgres/grant-managed-identities.sql as the Entra admin.

param name string
param databaseName string = 'cloudmart'
param location string
param tags object
param workspaceId string
param adminLogin string
param adminObjectId string
@allowed(['User', 'Group', 'ServicePrincipal'])
param adminPrincipalType string = 'User'
param allowAzureServices bool = true
param privateEndpointSubnetId string = ''
param privateDnsZoneId string = ''

var usePrivateEndpoint = !empty(privateEndpointSubnetId)

resource server 'Microsoft.DBforPostgreSQL/flexibleServers@2024-08-01' = {
  name: name
  location: location
  tags: tags
  sku: { name: 'Standard_B1ms', tier: 'Burstable' }
  properties: {
    version: '16'
    storage: { storageSizeGB: 32, autoGrow: 'Disabled' }
    backup: { backupRetentionDays: 7, geoRedundantBackup: 'Disabled' }
    highAvailability: { mode: 'Disabled' }
    authConfig: {
      activeDirectoryAuth: 'Enabled'
      passwordAuth: 'Disabled'
      tenantId: tenant().tenantId
    }
    network: { publicNetworkAccess: usePrivateEndpoint ? 'Disabled' : 'Enabled' }
  }
}

// The flexible server accepts one operation at a time, hence the explicit chain below.
resource admin 'Microsoft.DBforPostgreSQL/flexibleServers/administrators@2024-08-01' = {
  parent: server
  name: adminObjectId
  properties: {
    principalType: adminPrincipalType
    principalName: adminLogin
    tenantId: tenant().tenantId
  }
}

resource database 'Microsoft.DBforPostgreSQL/flexibleServers/databases@2024-08-01' = {
  parent: server
  name: databaseName
  properties: { charset: 'UTF8', collation: 'en_US.utf8' }
  dependsOn: [admin]
}

resource allowAzure 'Microsoft.DBforPostgreSQL/flexibleServers/firewallRules@2024-08-01' = if (allowAzureServices && !usePrivateEndpoint) {
  parent: server
  name: 'AllowAllAzureServicesAndResourcesWithinAzureIps'
  properties: { startIpAddress: '0.0.0.0', endIpAddress: '0.0.0.0' }
  dependsOn: [database]
}

resource diagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'to-log-analytics'
  scope: server
  properties: {
    workspaceId: workspaceId
    logs: [{ categoryGroup: 'allLogs', enabled: true }]
    metrics: [{ category: 'AllMetrics', enabled: true }]
  }
}

module privateEndpoint 'private-endpoint.bicep' = if (usePrivateEndpoint) {
  name: '${name}-pe'
  params: {
    name: 'pe-${name}'
    location: location
    tags: tags
    subnetId: privateEndpointSubnetId
    privateLinkServiceId: server.id
    groupId: 'postgresqlServer'
    privateDnsZoneId: privateDnsZoneId
  }
}

output fqdn string = server.properties.fullyQualifiedDomainName
output databaseName string = database.name
