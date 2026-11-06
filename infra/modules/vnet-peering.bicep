// Phase 13: peering is two resources, one on each VNet, and traffic flows only once both say Connected. In a landing
// zone the hub belongs to the platform team (often in another subscription), so each side is deployed by its owner.
// Here both VNets live in one resource group. Peering isn't transitive: a second spoke reaches this one only through
// the firewall, with a route for its prefix.

param hubVnetName string
param spokeVnetName string

@description('Phase 13 hybrid: the spoke uses the hub\'s VPN gateway, so on-premises can reach it. The gateway must exist first.')
param useGatewayTransit bool = false

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
    // Gateway transit: the hub's VPN gateway also serves the spoke. It learns the spoke's prefix and carries
    // on-premises traffic across this peering. One gateway per hub instead of one per spoke.
    allowGatewayTransit: useGatewayTransit
    useRemoteGateways: false
  }
}

resource spokeToHub 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2024-05-01' = {
  parent: spoke
  name: 'peer-to-${hubVnetName}'
  // Azure refuses useRemoteGateways until the other side allows gateway transit.
  dependsOn: [hubToSpoke]
  properties: {
    remoteVirtualNetwork: { id: hub.id }
    allowVirtualNetworkAccess: true
    // Replies from the internet come back through the firewall with an internet source address: traffic that didn't
    // start in the hub. Without this the spoke drops them.
    allowForwardedTraffic: true
    // The spoke's subnets get the on-premises routes (next hop: the hub's gateway). Turn it off and the spoke has no
    // way back to 192.168.0.0/16: the private endpoints' replies are lost (the lab's first "break it").
    useRemoteGateways: useGatewayTransit
  }
}
