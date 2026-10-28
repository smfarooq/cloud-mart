// Phase 2: a single spoke VNet with purpose-built subnets, NSGs and private DNS zones.
// Phase 13 (optional) adds the hub: firewall-hub.bicep, peered to this VNet, with the app subnets' egress routed to it.

param location string
param tags object
param vnetName string
param addressPrefix string = '10.20.0.0/16'

@description('Phase 13: the hub firewall\'s private IP. Set = the app subnets send their internet-bound traffic to it.')
param egressFirewallIp string = ''

// Exported so the hub's firewall rules can name these subnets as sources.
@export()
var subnetPrefixes = {
  appService: '10.20.1.0/24' // App Service VNet integration (outbound)
  functions: '10.20.2.0/24' // Flex Consumption VNet integration (outbound)
  containerApps: '10.20.4.0/23' // Container Apps environment (workload profiles)
  privateEndpoints: '10.20.6.0/24' // inbound private IPs of PaaS services
  vm: '10.20.7.0/24' // jumpbox
  aks: '10.20.8.0/22' // AKS nodes (pods use an overlay CIDR, not this range)
  appGateway: '10.20.12.0/24' // Application Gateway v2 needs a dedicated subnet
  bastion: '10.20.13.0/26' // name must be AzureBastionSubnet, minimum /26
}

// A private endpoint is only useful if the name resolves to its private IP: one zone per service type,
// linked to the VNet. This is the step people forget, and the first thing to check when "it times out".
var privateDnsZoneNames = {
  keyVault: 'privatelink.vaultcore.azure.net'
  blob: 'privatelink.blob.${environment().suffixes.storage}'
  queue: 'privatelink.queue.${environment().suffixes.storage}'
  table: 'privatelink.table.${environment().suffixes.storage}'
  cosmos: 'privatelink.documents.azure.com'
  sql: 'privatelink${environment().suffixes.sqlServerHostname}'
  postgres: 'privatelink.postgres.database.azure.com'
  webApps: 'privatelink.azurewebsites.net' // phase 16: the Payments and Shipping APIs' inbound private endpoints
  // Event Hubs (any tier from Standard) and Service Bus Premium share this zone. A Service Bus Standard namespace has
  // no private endpoint, so its name never points into the zone and keeps resolving to its public address.
  serviceBus: 'privatelink.servicebus.windows.net'
}

resource nsgPrivateEndpoints 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: '${vnetName}-pe-nsg'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'AllowVnetToPaaS'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          // HTTPS, SQL, PostgreSQL, and AMQP over TLS: the Event Hubs SDK and trigger use 5671, not 443.
          destinationPortRanges: ['443', '1433', '5432', '5671-5672']
        }
      }
      {
        name: 'DenyEverythingElse'
        properties: {
          priority: 4000
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
    ]
  }
}

resource nsgVm 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: '${vnetName}-vm-nsg'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'AllowSshFromVnet' // Bastion connects from inside the VNet; nothing is exposed to the internet
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '22'
        }
      }
    ]
  }
}

resource nsgAppGateway 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: '${vnetName}-agw-nsg'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'AllowGatewayManager' // required for Application Gateway v2 health/management
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'GatewayManager'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '65200-65535'
        }
      }
      {
        name: 'AllowHttpFromInternet'
        properties: {
          priority: 110
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'Internet'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRanges: ['80', '443']
        }
      }
      {
        name: 'AllowAzureLoadBalancer'
        properties: {
          priority: 120
          direction: 'Inbound'
          access: 'Allow'
          protocol: '*'
          sourceAddressPrefix: 'AzureLoadBalancer'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
    ]
  }
}

// Integration subnets get an NSG with only the default rules, so you can practise adding outbound rules.
resource nsgApps 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: '${vnetName}-apps-nsg'
  location: location
  tags: tags
}

// Phase 13: a user-defined route sends the app subnets' default route (0.0.0.0/0) to the hub firewall. App Service
// (vnetRouteAllEnabled) and Flex Consumption already put all their outbound traffic into these subnets.
//
// The private endpoints' /32 system routes are more specific than 0.0.0.0/0, so traffic to the data stores still goes
// straight to them and never reaches the firewall. To inspect it as well, add a route for 10.20.6.0/24 to the firewall
// here: snet-private-endpoints already has privateEndpointNetworkPolicies 'Enabled', which lets a route that covers
// the /32s override them. Allow that traffic with application rules, which SNAT it, so the replies come back through
// the firewall too.
var useEgressFirewall = !empty(egressFirewallIp)

resource egressRoutes 'Microsoft.Network/routeTables@2024-05-01' = if (useEgressFirewall) {
  name: '${vnetName}-egress-rt'
  location: location
  tags: tags
  properties: {
    disableBgpRoutePropagation: true // a gateway in the hub must not advertise a way around the firewall
    routes: [
      {
        name: 'internet-via-firewall'
        properties: {
          addressPrefix: '0.0.0.0/0'
          nextHopType: 'VirtualAppliance'
          nextHopIpAddress: egressFirewallIp
        }
      }
    ]
  }
}

var appRouteTable = useEgressFirewall ? { id: egressRoutes.id } : null

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: vnetName
  location: location
  tags: tags
  properties: {
    addressSpace: { addressPrefixes: [addressPrefix] }
    subnets: [
      {
        name: 'snet-appservice'
        properties: {
          addressPrefix: subnetPrefixes.appService
          networkSecurityGroup: { id: nsgApps.id }
          routeTable: appRouteTable
          delegations: [{ name: 'web', properties: { serviceName: 'Microsoft.Web/serverFarms' } }]
        }
      }
      {
        name: 'snet-functions'
        properties: {
          addressPrefix: subnetPrefixes.functions
          networkSecurityGroup: { id: nsgApps.id }
          routeTable: appRouteTable
          delegations: [{ name: 'flex', properties: { serviceName: 'Microsoft.App/environments' } }]
        }
      }
      {
        name: 'snet-containerapps'
        properties: {
          addressPrefix: subnetPrefixes.containerApps
          networkSecurityGroup: { id: nsgApps.id }
          routeTable: appRouteTable
          delegations: [{ name: 'aca', properties: { serviceName: 'Microsoft.App/environments' } }]
        }
      }
      {
        name: 'snet-private-endpoints'
        properties: {
          addressPrefix: subnetPrefixes.privateEndpoints
          networkSecurityGroup: { id: nsgPrivateEndpoints.id }
          privateEndpointNetworkPolicies: 'Enabled' // makes the NSG apply to private endpoints
        }
      }
      {
        name: 'snet-vm'
        properties: {
          addressPrefix: subnetPrefixes.vm
          networkSecurityGroup: { id: nsgVm.id }
        }
      }
      {
        name: 'snet-aks'
        properties: { addressPrefix: subnetPrefixes.aks }
      }
      {
        name: 'snet-appgateway'
        properties: {
          addressPrefix: subnetPrefixes.appGateway
          networkSecurityGroup: { id: nsgAppGateway.id }
        }
      }
      {
        name: 'AzureBastionSubnet'
        properties: { addressPrefix: subnetPrefixes.bastion }
      }
    ]
  }
}

resource zones 'Microsoft.Network/privateDnsZones@2024-06-01' = [
  for zone in items(privateDnsZoneNames): {
    name: zone.value
    location: 'global'
    tags: tags
  }
]

resource zoneLinks 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = [
  for (zone, i) in items(privateDnsZoneNames): {
    parent: zones[i]
    name: '${vnetName}-link'
    location: 'global'
    tags: tags
    properties: {
      virtualNetwork: { id: vnet.id }
      registrationEnabled: false
    }
  }
]

func subnetId(vnetName string, subnetName string) string =>
  resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, subnetName)

output vnetId string = vnet.id
output vnetName string = vnet.name
output appServiceSubnetId string = subnetId(vnet.name, 'snet-appservice')
output functionsSubnetId string = subnetId(vnet.name, 'snet-functions')
output containerAppsSubnetId string = subnetId(vnet.name, 'snet-containerapps')
output privateEndpointSubnetId string = subnetId(vnet.name, 'snet-private-endpoints')
output vmSubnetId string = subnetId(vnet.name, 'snet-vm')
output aksSubnetId string = subnetId(vnet.name, 'snet-aks')
output appGatewaySubnetId string = subnetId(vnet.name, 'snet-appgateway')
output bastionSubnetId string = subnetId(vnet.name, 'AzureBastionSubnet')
output dnsZoneIds object = toObject(
  items(privateDnsZoneNames),
  zone => zone.key,
  zone => resourceId('Microsoft.Network/privateDnsZones', zone.value)
)
