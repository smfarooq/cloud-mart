// Gap topics from the AZ-305 outline ("Design an application architecture"):
//  - App Configuration: central settings + feature flags, refreshed without redeploying
//  - Azure Managed Redis: shared cache (the successor to Azure Cache for Redis), Entra auth, no access keys
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
resource redis 'Microsoft.Cache/redisEnterprise@2025-04-01' = if (deployRedis) {
  name: redisName
  location: location
  tags: tags
  sku: { name: 'Balanced_B0' }
  properties: { minimumTlsVersion: '1.2' }
}

resource redisDatabase 'Microsoft.Cache/redisEnterprise/databases@2025-04-01' = if (deployRedis) {
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

resource redisAccess 'Microsoft.Cache/redisEnterprise/databases/accessPolicyAssignments@2025-04-01' = [
  for (principalId, i) in redisPrincipalIds: if (deployRedis) {
    parent: redisDatabase
    name: 'principal${i}'
    properties: {
      accessPolicyName: 'default'
      user: { objectId: principalId }
    }
  }
]

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
