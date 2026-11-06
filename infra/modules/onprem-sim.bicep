// Phase 13 (hybrid): a stand-in for an on-premises site. A VNet with its own address space that is deliberately NOT
// peered to anything: the only private path between it and Azure is the VPN (vpn.bicep), as it would be from a real
// datacenter. A small Linux VM plays a server there. It uses the jumpbox module: same tools (nslookup, dig, psql, az),
// Entra ID sign-in through a free Bastion Developer, and the same 19:00 UTC auto-shutdown.
//
// What the simulation can't show: a real site's DNS servers, firewalls and VPN device. Here Azure-provided DNS plays an
// on-premises DNS server that knows nothing about Azure's private zones, and a Basic VPN gateway plays the device.

param location string
param tags object
param vnetName string
param vmName string

@description('ssh-keygen -t ed25519, then the .pub contents. Required even with Entra ID sign-in.')
param sshPublicKey string

@description('Gets "Virtual Machine Administrator Login" on the VM.')
param loginPrincipalId string

@export()
@description('The simulated site\'s range. It must not overlap the hub (10.0.0.0/16) or the spoke (10.20.0.0/16): a VPN can\'t route between overlapping ranges, which is why real networks plan addresses before they connect.')
var addressSpace = '192.168.0.0/16'

var subnetPrefixes = {
  servers: '192.168.1.0/24'
  gateway: '192.168.255.0/27' // GatewaySubnet: the simulated site's VPN "device"
}

// Bastion Developer connects from the platform's own address (168.63.129.16), which the VirtualNetwork tag includes.
resource nsgServers 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: '${vnetName}-servers-nsg'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'AllowSshFromVnet'
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

// API 2024-05-01 keeps default outbound access, so the VM reaches the internet (apt, the Azure CLI, Key Vault's public
// endpoint) the way an on-premises server reaches it through its own ISP. Newer API versions make subnets private.
resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: vnetName
  location: location
  tags: tags
  properties: {
    addressSpace: { addressPrefixes: [addressSpace] }
    subnets: [
      {
        name: 'snet-servers'
        properties: {
          addressPrefix: subnetPrefixes.servers
          networkSecurityGroup: { id: nsgServers.id }
        }
      }
      { name: 'GatewaySubnet', properties: { addressPrefix: subnetPrefixes.gateway } }
    ]
  }
}

module server 'jumpbox.bicep' = {
  name: 'onprem-server'
  params: {
    name: vmName
    location: location
    tags: tags
    subnetId: resourceId('Microsoft.Network/virtualNetworks/subnets', vnet.name, 'snet-servers')
    vnetId: vnet.id
    bastionSubnetId: '' // Developer needs no AzureBastionSubnet
    bastionSku: 'Developer'
    sshPublicKey: sshPublicKey
    loginPrincipalId: loginPrincipalId
  }
}

output vnetName string = vnet.name
output gatewaySubnetId string = resourceId('Microsoft.Network/virtualNetworks/subnets', vnet.name, 'GatewaySubnet')
output vmName string = server.outputs.vmName
