// Phase 3: AKS with the current best-practice defaults: Entra ID + Azure RBAC for Kubernetes, local accounts off,
// Azure CNI Overlay, OIDC issuer + workload identity (pods get the API's managed identity, no secrets).
// Deploy the app with deploy/k8s. Turn on Container Insights with: az aks enable-addons -a monitoring ...

import { roles } from 'types.bicep'

param name string
param location string
param tags object

@description('System pools need >= 2 vCPU / 4 GiB. Stop the cluster when not in use: az aks stop.')
param nodeVmSize string = 'Standard_D2s_v5'
param nodeSubnetId string = ''

@description('The API identity that pods will run as, via a federated credential.')
param apiIdentityName string
param acrName string = ''

@description('Gets "Azure Kubernetes Service RBAC Cluster Admin" so you can kubectl after az aks get-credentials.')
param adminPrincipalId string

resource cluster 'Microsoft.ContainerService/managedClusters@2024-09-01' = {
  name: name
  location: location
  tags: tags
  sku: { name: 'Base', tier: 'Free' }
  identity: { type: 'SystemAssigned' }
  properties: {
    dnsPrefix: name
    enableRBAC: true
    disableLocalAccounts: true
    aadProfile: { managed: true, enableAzureRBAC: true, tenantID: tenant().tenantId }
    oidcIssuerProfile: { enabled: true }
    securityProfile: { workloadIdentity: { enabled: true } }
    networkProfile: {
      networkPlugin: 'azure'
      networkPluginMode: 'overlay'
      podCidr: '192.168.0.0/16'
      serviceCidr: '172.16.0.0/16'
      dnsServiceIP: '172.16.0.10'
      loadBalancerSku: 'standard'
    }
    agentPoolProfiles: [
      {
        name: 'system'
        mode: 'System'
        osType: 'Linux'
        osSKU: 'AzureLinux'
        vmSize: nodeVmSize
        count: 1
        enableAutoScaling: true
        minCount: 1
        maxCount: 3
        type: 'VirtualMachineScaleSets'
        vnetSubnetID: empty(nodeSubnetId) ? null : nodeSubnetId
      }
    ]
    autoUpgradeProfile: { upgradeChannel: 'patch', nodeOSUpgradeChannel: 'NodeImage' }
  }
}

// Workload identity: the API identity trusts tokens issued to service account cloudmart/cloudmart-api.
resource apiIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = {
  name: apiIdentityName
}

resource federation 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2023-01-31' = {
  parent: apiIdentity
  name: 'aks-cloudmart-api'
  properties: {
    issuer: cluster.properties.oidcIssuerProfile.issuerURL
    subject: 'system:serviceaccount:cloudmart:cloudmart-api'
    audiences: ['api://AzureADTokenExchange']
  }
}

resource registry 'Microsoft.ContainerRegistry/registries@2023-07-01' existing = if (!empty(acrName)) {
  name: acrName
}

// Nodes pull images as the kubelet identity (what `az aks update --attach-acr` does).
resource kubeletAcrPull 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(acrName)) {
  name: guid(resourceGroup().id, cluster.id, 'kubelet-acrpull')
  scope: registry
  properties: {
    principalId: cluster.properties.identityProfile.kubeletidentity.objectId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.acrPull)
    principalType: 'ServicePrincipal'
  }
}

resource clusterAdmin 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(cluster.id, adminPrincipalId, roles.aksRbacClusterAdmin)
  scope: cluster
  properties: {
    principalId: adminPrincipalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.aksRbacClusterAdmin)
    principalType: 'User'
  }
}

output name string = cluster.name
output oidcIssuerUrl string = cluster.properties.oidcIssuerProfile.issuerURL
