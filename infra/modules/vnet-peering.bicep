// Phase 13: peering is two resources, one on each VNet, and traffic flows only once both say Connected. In a landing
// zone the hub belongs to the platform team (often in another subscription), so each side is deployed by its owner.
// Here both VNets live in one resource group. Peering isn't transitive: a second spoke reaches this one only through
// the firewall, with a route for its prefix.

param hubVnetName string
param spokeVnetName string

resource hub 'Microsoft.Network/virtualNetworks@2024-05-01' existing = {
  name: hubVnetName
}

resource spoke 'Microsoft.Network/virtualNetworks@2024-05-01' existing = {
  name: spokeVnetName
}

resource hubToSpoke 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2024-05-01' = {
  parent: hub
  name: 'peer-to-${spokeVnetName}'
  properties: {
    remoteVirtualNetwork: { id: spoke.id }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
    allowGatewayTransit: false // true once the hub has a VPN or ExpressRoute gateway to share
    useRemoteGateways: false
  }
}

resource spokeToHub 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2024-05-01' = {
  parent: spoke
  name: 'peer-to-${hubVnetName}'
  properties: {
    remoteVirtualNetwork: { id: hub.id }
    allowVirtualNetworkAccess: true
    // Replies from the internet come back through the firewall with an internet source address: traffic that didn't
    // start in the hub. Without this the spoke drops them.
    allowForwardedTraffic: true
    useRemoteGateways: false // true (with allowGatewayTransit on the hub side) to reach on-premises via the hub
  }
}
