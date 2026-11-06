// Gap topics from the AZ-305 outline ("Design an application architecture"):
//  - App Configuration: central settings + feature flags, refreshed without redeploying
//  - Azure Managed Redis: shared cache (the successor to Azure Cache for Redis), Entra auth, no access keys, and a
//    private endpoint once the data stores have them
//  - API Management: a gateway in front of the API (import the OpenAPI document after the API is deployed)

import { roleAssignment } from 'types.bicep'

param location string
param tags object
param appInsightsId string
param appInsightsConnectionString string

param deployAppConfig bool
param appConfigName string
param appConfigRoleAssignments roleAssignment[] = []

param deployRedis bool
param redisName string
@description('Object ids that get a data access policy on the Redis database.')
param redisPrincipalIds array = []

@description('Set (with redisPrivateDnsZoneId) to put Redis behind a private endpoint and turn its public access off.')
param privateEndpointSubnetId string = ''
param redisPrivateDnsZoneId string = ''
@description('The VNet\'s Redis application security group: pe-nsg opens the Redis ports to it alone.')
param redisAsgId string = ''

var redisPrivate = deployRedis && !empty(privateEndpointSubnetId)

param deployApim bool
param apimName string
param apimPublisherEmail string
@description('Consumption: pay per call, no VNet. Developer: full features, no SLA. BasicV2/StandardV2: production v2 tiers.')
@allowed(['Consumption', 'Developer', 'BasicV2', 'StandardV2'])
param apimSku string = 'Consumption'

// ---------------------------------------------------------------- App Configuration
resource appConfig 'Microsoft.AppConfiguration/configurationStores@2024-05-01' = if (deployAppConfig) {
  name: appConfigName
  location: location
  tags: tags
  sku: { name: 'free' } // one free store per subscription; Standard adds private endpoints, replicas, SLA
  properties: {
    disableLocalAuth: true
    publicNetworkAccess: 'Enabled'
  }
}

resource appConfigRoles 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for ra in appConfigRoleAssignments: if (deployAppConfig) {
    name: guid(resourceGroup().id, appConfigName, ra.principalId, ra.roleDefinitionId)
    scope: appConfig
    properties: {
      principalId: ra.principalId
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', ra.roleDefinitionId)
      principalType: ra.?principalType ?? 'ServicePrincipal'
    }
  }
]

// ---------------------------------------------------------------- Azure Managed Redis
// 2025-07-01 is the first API version with publicNetworkAccess. Before it, a private endpoint switched public access
// off by itself; now the two are independent, so it is set explicitly.
resource redis 'Microsoft.Cache/redisEnterprise@2025-07-01' = if (deployRedis) {
  name: redisName
  location: location
  tags: tags
  sku: { name: 'Balanced_B0' }
  properties: {
    minimumTlsVersion: '1.2'
    publicNetworkAccess: redisPrivate ? 'Disabled' : 'Enabled'
  }
}

resource redisDatabase 'Microsoft.Cache/redisEnterprise/databases@2025-07-01' = if (deployRedis) {
  parent: redis
  name: 'default'
  properties: {
    clientProtocol: 'Encrypted'
    port: 10000
    clusteringPolicy: 'OSSCluster'
    evictionPolicy: 'VolatileLRU'
    accessKeysAuthentication: 'Disabled'
  }
}

resource redisAccess 'Microsoft.Cache/redisEnterprise/databases/accessPolicyAssignments@2025-07-01' = [
  for (principalId, i) in redisPrincipalIds: if (deployRedis) {
    parent: redisDatabase
    name: 'principal${i}'
    properties: {
      accessPolicyName: 'default'
      user: { objectId: principalId }
    }
  }
]

// Inbound private endpoint. The API keeps connecting to <name>.<region>.redis.azure.net:10000: inside the VNet that name
// resolves through privatelink.redis.azure.net to the endpoint's 10.20.6.x address. Never put the privatelink name in
// the connection string. With the OSS clustering policy the client then follows the cluster map to the shards on
// 85XX ports at the same address, which is why pe-nsg opens both. Traffic to the endpoint also never reaches the
// phase 13 firewall, which could not have allowed Redis by name anyway: port 10000 is TLS, but not HTTPS.
module redisPrivateEndpoint 'private-endpoint.bicep' = if (redisPrivate) {
  name: '${redisName}-pe'
  params: {
    name: 'pe-${redisName}'
    location: location
    tags: tags
    subnetId: privateEndpointSubnetId
    privateLinkServiceId: redis.id
    groupId: 'redisEnterprise'
    privateDnsZoneId: redisPrivateDnsZoneId
    applicationSecurityGroupIds: empty(redisAsgId) ? [] : [redisAsgId]
  }
}

// ---------------------------------------------------------------- API Management
resource apim 'Microsoft.ApiManagement/service@2024-05-01' = if (deployApim) {
  name: apimName
  location: location
  tags: tags
  sku: { name: apimSku, capacity: apimSku == 'Consumption' ? 0 : 1 }
  identity: { type: 'SystemAssigned' }
  properties: {
    publisherEmail: apimPublisherEmail
    publisherName: 'CloudMart'
  }
}

resource apimLogger 'Microsoft.ApiManagement/service/loggers@2024-05-01' = if (deployApim) {
  parent: apim
  name: 'appinsights'
  properties: {
    loggerType: 'applicationInsights'
    resourceId: appInsightsId
    credentials: { connectionString: appInsightsConnectionString }
  }
}

output appConfigEndpoint string = deployAppConfig ? appConfig!.properties.endpoint : ''
output redisEndpoint string = deployRedis ? '${redis!.properties.hostName}:10000' : ''
output apimGatewayUrl string = deployApim ? apim!.properties.gatewayUrl : ''
