// Phase 13: the hub of a hub-and-spoke network. Azure Firewall Basic in its own VNet, with an allow-list policy and its
// logs in the resource-specific AZFW* tables. The CloudMart VNet is the spoke: network.bicep points its app subnets'
// default route at this firewall, and vnet-peering.bicep connects the two VNets.
//
// The hub deploys BEFORE the spoke. The spoke's route needs the firewall's private IP, which Azure assigns (and can
// change if the firewall is stopped and started), so main.bicep reads it from this module instead of guessing .4.

param location string
param tags object
param vnetName string
param firewallName string
param policyName string
param workspaceId string

@description('Must not overlap the spoke (10.20.0.0/16) or any network you connect later (on-premises, other spokes).')
param addressPrefix string = '10.0.0.0/16'

@description('The spoke subnets the rules apply to: the three app integration subnets.')
param appSubnetPrefixes string[]

@description('The Container Apps subnet: the only one allowed to pull container images.')
param containerAppsSubnetPrefix string

@description('Service Bus namespace host name. Empty = no Service Bus rule.')
param serviceBusHostName string = ''

@description('App Configuration store host name (phase 12). Empty = no rule.')
param appConfigHostName string = ''

@description('Container Apps is on: allow its platform images and binaries.')
param allowContainerApps bool = false

@description('Container Apps runs your image from Azure Container Registry.')
param allowContainerRegistry bool = false

// Both subnet names are fixed and both need at least a /26. Basic always has a management NIC: Microsoft's management
// traffic uses that subnet and its own public IP, so your rules can never cut the firewall off from its control plane.
// The rest of the /16 is room for what a real hub also holds: GatewaySubnet (VPN/ExpressRoute), AzureBastionSubnet,
// and the inbound and outbound subnets of a DNS Private Resolver.
var subnetPrefixes = {
  firewall: cidrSubnet(addressPrefix, 26, 0) // 10.0.0.0/26
  firewallManagement: cidrSubnet(addressPrefix, 26, 1) // 10.0.0.64/26
}

// No NSGs: Azure Firewall doesn't support one on either subnet.
resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: vnetName
  location: location
  tags: tags
  properties: {
    addressSpace: { addressPrefixes: [addressPrefix] }
    subnets: [
      { name: 'AzureFirewallSubnet', properties: { addressPrefix: subnetPrefixes.firewall } }
      { name: 'AzureFirewallManagementSubnet', properties: { addressPrefix: subnetPrefixes.firewallManagement } }
    ]
  }
}

// Every app's outbound connection now leaves Azure from this one address: the IP a partner would allow-list.
resource publicIp 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: 'pip-${firewallName}'
  location: location
  tags: tags
  sku: { name: 'Standard' }
  properties: { publicIPAllocationMethod: 'Static' }
}

resource managementPublicIp 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: 'pip-${firewallName}-mgmt'
  location: location
  tags: tags
  sku: { name: 'Standard' }
  properties: { publicIPAllocationMethod: 'Static' }
}

// The rules live in a firewall policy, not on the firewall: Firewall Manager can then share one policy (or a parent
// policy with per-spoke children) across many firewalls and regions.
resource policy 'Microsoft.Network/firewallPolicies@2024-05-01' = {
  name: policyName
  location: location
  tags: tags
  properties: {
    sku: { tier: 'Basic' }
    threatIntelMode: 'Alert' // Basic can only alert on known-malicious IPs and domains; Standard can also deny
  }
}

// Allow only what the apps need. Network rules are evaluated before application rules, and anything that matches
// neither is denied and logged ("No rule matched. Proceeding with default action"): there is no "deny all" to write.
//
// Not listed, because it never reaches the firewall: everything behind a private endpoint (Cosmos DB, SQL, PostgreSQL,
// Key Vault, Event Hubs, the Payments and Shipping APIs, and Storage, which also holds the Functions host's state and
// the Durable Functions task hub). Each endpoint's /32 route is more specific than the spoke's 0.0.0.0/0. Also not
// listed: Azure DNS (168.63.129.16) and the managed identity endpoints, which the platform answers without routing.
//
// Basic matches names only in application rules: HTTP(S) and SQL, by Host header or TLS SNI. Names in network rules
// (any port) need DNS proxy, which starts at Standard. That is why Service Bus is an application rule on 443 and the
// apps switch to AMQP over WebSockets: a network rule for AMQP on 5671 could only use the ServiceBus tag, which also
// lets data out to every other customer's namespace.
var networkRules = concat(
  [
    {
      ruleType: 'NetworkRule'
      name: 'entra-id'
      description: 'Signing keys for validating Entra tokens (API, Payments, Shipping) and managed identity in Container Apps.'
      ipProtocols: ['TCP']
      sourceAddresses: appSubnetPrefixes
      destinationAddresses: ['AzureActiveDirectory']
      destinationPorts: ['443']
    }
    {
      ruleType: 'NetworkRule'
      name: 'azure-monitor'
      description: 'Application Insights ingestion and live metrics from every app and the Functions host.'
      ipProtocols: ['TCP']
      sourceAddresses: appSubnetPrefixes
      destinationAddresses: ['AzureMonitor']
      destinationPorts: ['443']
    }
  ],
  allowContainerRegistry
    ? [
        {
          ruleType: 'NetworkRule'
          name: 'container-registry'
          description: 'Your API image from Azure Container Registry.'
          ipProtocols: ['TCP']
          sourceAddresses: [containerAppsSubnetPrefix]
          destinationAddresses: ['AzureContainerRegistry']
          destinationPorts: ['443']
        }
      ]
    : []
)

var applicationRules = concat(
  empty(serviceBusHostName)
    ? []
    : [
        {
          ruleType: 'ApplicationRule'
          name: 'service-bus'
          description: 'Order events: the API sends, the Functions app receives. Only this namespace.'
          protocols: [{ protocolType: 'Https', port: 443 }]
          sourceAddresses: appSubnetPrefixes
          targetFqdns: [serviceBusHostName]
        }
      ],
  empty(appConfigHostName)
    ? []
    : [
        {
          ruleType: 'ApplicationRule'
          name: 'app-configuration'
          description: 'Settings and feature flags (phase 12). The API reads them at startup.'
          protocols: [{ protocolType: 'Https', port: 443 }]
          sourceAddresses: appSubnetPrefixes
          targetFqdns: [appConfigHostName]
        }
      ],
  allowContainerApps
    ? [
        {
          ruleType: 'ApplicationRule'
          name: 'container-apps-platform'
          description: 'Microsoft Artifact Registry (system and sample images) and the Kubernetes binaries under the environment.'
          protocols: [{ protocolType: 'Https', port: 443 }]
          sourceAddresses: [containerAppsSubnetPrefix]
          targetFqdns: ['mcr.microsoft.com', '*.data.mcr.microsoft.com', 'packages.aks.azure.com', 'acs-mirror.azureedge.net']
        }
      ]
    : []
)

resource rules 'Microsoft.Network/firewallPolicies/ruleCollectionGroups@2024-05-01' = {
  parent: policy
  name: 'cloudmart-egress'
  properties: {
    priority: 200
    ruleCollections: concat(
      [
        {
          ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
          name: 'azure-platform'
          priority: 100
          action: { type: 'Allow' }
          rules: networkRules
        }
      ],
      empty(applicationRules)
        ? []
        : [
            {
              ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
              name: 'app-dependencies'
              priority: 200
              action: { type: 'Allow' }
              rules: applicationRules
            }
          ]
    )
  }
}

resource firewall 'Microsoft.Network/azureFirewalls@2024-05-01' = {
  name: firewallName
  location: location
  tags: tags
  // The firewall and a rule collection group can't both update the policy at once: let the rules finish first.
  dependsOn: [rules]
  properties: {
    sku: { name: 'AZFW_VNet', tier: 'Basic' }
    firewallPolicy: { id: policy.id }
    ipConfigurations: [
      {
        name: 'data'
        properties: {
          subnet: { id: subnetId(vnet.name, 'AzureFirewallSubnet') }
          publicIPAddress: { id: publicIp.id }
        }
      }
    ]
    managementIpConfiguration: {
      name: 'management'
      properties: {
        subnet: { id: subnetId(vnet.name, 'AzureFirewallManagementSubnet') }
        publicIPAddress: { id: managementPublicIp.id }
      }
    }
  }
}

resource diagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'to-log-analytics'
  scope: firewall
  properties: {
    workspaceId: workspaceId
    // 'Dedicated' = resource-specific tables (AZFWApplicationRule, AZFWNetworkRule...) with a column per field, instead
    // of one shared AzureDiagnostics table. The legacy AzureFirewall* categories stay off: they'd log everything twice.
    logAnalyticsDestinationType: 'Dedicated'
    logs: [
      for category in ['AZFWApplicationRule', 'AZFWNetworkRule', 'AZFWNatRule', 'AZFWThreatIntel']: {
        category: category
        enabled: true
      }
    ]
    metrics: [{ category: 'AllMetrics', enabled: true }]
  }
}

func subnetId(vnetName string, subnetName string) string =>
  resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, subnetName)

output vnetName string = vnet.name
output privateIp string = firewall.properties.ipConfigurations[0].properties.privateIPAddress
output publicIp string = publicIp.properties.ipAddress
