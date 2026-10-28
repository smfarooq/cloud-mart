// Phase 6: Key Vault in RBAC mode (not access policies). The API reads it through the configuration provider;
// the Functions app reads the same secret through an App Service Key Vault reference. Compare the two.

import { roleAssignment } from 'types.bicep'

param name string
param location string
param tags object
param workspaceId string
param roleAssignments roleAssignment[] = []

@secure()
param paymentGatewayApiKey string

@description('Days until the payment-gateway secret expires. Key Vault raises a SecretNearExpiry event 30 days before.')
param secretValidityDays int = 90

@description('Deployment time: the secret\'s expiry counts from here. Leave the default.')
param now string = utcNow()

@description('Set (with privateDnsZoneId) to put the vault behind a private endpoint and turn public access off.')
param privateEndpointSubnetId string = ''
param privateDnsZoneId string = ''

var usePrivateEndpoint = !empty(privateEndpointSubnetId)

resource vault 'Microsoft.KeyVault/vaults@2024-11-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    tenantId: tenant().tenantId
    sku: { family: 'A', name: 'standard' }
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
    // enablePurgeProtection: true  // production: yes. In a lab it stops you re-using the name for 7 days.
    publicNetworkAccess: usePrivateEndpoint ? 'Disabled' : 'Enabled'
    networkAcls: {
      defaultAction: usePrivateEndpoint ? 'Deny' : 'Allow'
      bypass: 'AzureServices'
    }
  }
}

// Secret names can't contain ':' so "--" stands in for it; the .NET provider maps it back.
resource paymentKey 'Microsoft.KeyVault/vaults/secrets@2024-11-01' = {
  parent: vault
  name: 'PaymentGateway--ApiKey'
  properties: {
    value: paymentGatewayApiKey
    contentType: 'text/plain'
    // Expiry is a promise to rotate, not a kill switch: an expired secret can still be read, but the SecretNearExpiry
    // event, the portal and Azure Policy ("secrets should have an expiration date") all key off it.
    attributes: { exp: dateTimeToEpoch(dateTimeAdd(now, 'P${secretValidityDays}D')) }
  }
}

resource assignments 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for ra in roleAssignments: {
    name: guid(vault.id, ra.principalId, ra.roleDefinitionId)
    scope: vault
    properties: {
      principalId: ra.principalId
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', ra.roleDefinitionId)
      principalType: ra.?principalType ?? 'ServicePrincipal'
    }
  }
]

resource diagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'to-log-analytics'
  scope: vault
  properties: {
    workspaceId: workspaceId
    logs: [{ categoryGroup: 'audit', enabled: true }]
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
    privateLinkServiceId: vault.id
    groupId: 'vault'
    privateDnsZoneId: privateDnsZoneId
  }
}

output name string = vault.name
output uri string = vault.properties.vaultUri
