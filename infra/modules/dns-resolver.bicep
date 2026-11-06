// Phase 13 (hybrid): Azure DNS Private Resolver in the hub. Its inbound endpoint is an IP address that answers DNS the
// way Azure DNS answers inside the hub: from the private DNS zones linked to the hub VNet (network.bicep links them when
// this switch is on). An on-premises DNS server conditionally forwards Azure's zones to this address, over the VPN.
//
// Only an inbound endpoint. The other direction, Azure resolving on-premises names, needs an outbound endpoint (its own
// delegated subnet) and a forwarding ruleset ("corp.contoso.com -> 192.168.1.10"): another $180/month for the endpoint.

param location string
param tags object
param name string
param vnetId string
param inboundSubnetId string

@description('A fixed address in the inbound subnet, so on-premises forwarders never need changing.')
param inboundIp string

resource resolver 'Microsoft.Network/dnsResolvers@2022-07-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    virtualNetwork: { id: vnetId }
  }
}

resource inbound 'Microsoft.Network/dnsResolvers/inboundEndpoints@2022-07-01' = {
  parent: resolver
  name: 'inbound'
  location: location
  tags: tags
  properties: {
    ipConfigurations: [
      {
        subnet: { id: inboundSubnetId }
        privateIpAllocationMethod: 'Static'
        privateIpAddress: inboundIp
      }
    ]
  }
}

output inboundIp string = inbound.properties.ipConfigurations[0].privateIpAddress!
