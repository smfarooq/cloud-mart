// Phase 13 (hybrid): a site-to-site VPN between the hub and the simulated on-premises site (onprem-sim.bicep).
//
// Each side has three pieces:
//   - a virtual network gateway in its GatewaySubnet, with a public IP: the tunnel's endpoint;
//   - a local network gateway that describes the OTHER side: its public IP and the address ranges behind it;
//   - a connection that joins the two with a pre-shared key. Both connections must use the same key.
// On a real site, the on-premises half is your VPN device's configuration. Here a Basic gateway plays the device.
//
// Why an IPsec (site-to-site) connection instead of the simpler 'Vnet2Vnet' type: it uses the same objects as a real
// on-premises device, and the local network gateways make you list each side's ranges yourself. That list is static
// (Basic can't run BGP), so every spoke you add must be added to it too.
//
// Both gateways take 30-45 minutes to create, and bill by the hour until they're deleted.

param location string
param tags object
param workspaceId string
param hubGatewayName string
param onPremGatewayName string
param hubGatewaySubnetId string
param onPremGatewaySubnetId string

@description('The ranges on-premises sends into the tunnel: the hub and every spoke that uses its gateway.')
param azureAddressPrefixes string[]

@description('The ranges the hub sends into the tunnel: the on-premises site.')
param onPremAddressPrefixes string[]

@secure()
@description('The pre-shared key both connections use.')
param sharedKey string

// VpnGw1AZ because gateway transit (the spoke using the hub's gateway) works with every SKU except Basic, and since
// November 2025 new gateways must use an AZ SKU. In a region without zones it is still allowed, as a regional gateway.
// The simulated site needs no transit, so it gets Basic: about a sixth of the price, fine for a lab "device".
var gateways = [
  { name: hubGatewayName, subnetId: hubGatewaySubnetId, sku: 'VpnGw1AZ' }
  { name: onPremGatewayName, subnetId: onPremGatewaySubnetId, sku: 'Basic' }
]

// Standard, static. No zones listed: since 2025 a Standard IP without zones is zone-redundant in regions that have
// them, which is what the AZ gateway needs, and the same template still deploys in regions that don't.
resource publicIps 'Microsoft.Network/publicIPAddresses@2024-05-01' = [
  for gw in gateways: {
    name: 'pip-${gw.name}'
    location: location
    tags: tags
    sku: { name: 'Standard' }
    properties: { publicIPAllocationMethod: 'Static' }
  }
]

resource vpnGateways 'Microsoft.Network/virtualNetworkGateways@2024-05-01' = [
  for (gw, i) in gateways: {
    name: gw.name
    location: location
    tags: tags
    properties: {
      gatewayType: 'Vpn'
      vpnType: 'RouteBased' // policy-based gateways allow one tunnel and no gateway transit
      vpnGatewayGeneration: 'Generation1'
      sku: { name: gw.sku, tier: gw.sku }
      enableBgp: false
      activeActive: false
      ipConfigurations: [
        {
          name: 'default'
          properties: {
            subnet: { id: gw.subnetId }
            publicIPAddress: { id: publicIps[i].id }
            privateIPAllocationMethod: 'Dynamic'
          }
        }
      ]
    }
  }
]

// Seen from the hub: on-premises is the simulated site's public IP, with its range behind it.
resource onPremSite 'Microsoft.Network/localNetworkGateways@2024-05-01' = {
  name: 'lgw-${replace(onPremGatewayName, 'vgw-', '')}'
  location: location
  tags: tags
  properties: {
    gatewayIpAddress: publicIps[1].properties.ipAddress
    localNetworkAddressSpace: { addressPrefixes: onPremAddressPrefixes }
  }
}

// Seen from the simulated site: Azure is the hub gateway's public IP, with the hub and the spoke behind it.
resource azureSite 'Microsoft.Network/localNetworkGateways@2024-05-01' = {
  name: 'lgw-${replace(hubGatewayName, 'vgw-', '')}'
  location: location
  tags: tags
  properties: {
    gatewayIpAddress: publicIps[0].properties.ipAddress
    localNetworkAddressSpace: { addressPrefixes: azureAddressPrefixes }
  }
}

var connections = [
  { name: 'con-${replace(hubGatewayName, 'vgw-', '')}-to-onprem', gateway: vpnGateways[0].id, peer: onPremSite.id }
  { name: 'con-${replace(onPremGatewayName, 'vgw-', '')}-to-hub', gateway: vpnGateways[1].id, peer: azureSite.id }
]

resource vpnConnections 'Microsoft.Network/connections@2024-05-01' = [
  for c in connections: {
    name: c.name
    location: location
    tags: tags
    properties: {
      connectionType: 'IPsec'
      connectionProtocol: 'IKEv2'
      virtualNetworkGateway1: { id: c.gateway, properties: {} }
      localNetworkGateway2: { id: c.peer, properties: {} }
      sharedKey: sharedKey
      enableBgp: false
    }
  }
]

// Tunnel up and down events, IKE negotiation (a wrong key shows up here) and the routes each gateway learned.
// VPN gateways write to the shared AzureDiagnostics table.
resource diagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = [
  for (gw, i) in gateways: {
    name: 'to-log-analytics'
    scope: vpnGateways[i]
    properties: {
      workspaceId: workspaceId
      logs: [
        for category in ['GatewayDiagnosticLog', 'TunnelDiagnosticLog', 'RouteDiagnosticLog', 'IKEDiagnosticLog']: {
          category: category
          enabled: true
        }
      ]
      metrics: [{ category: 'AllMetrics', enabled: true }]
    }
  }
]

output hubGatewayName string = vpnGateways[0].name
output hubGatewayPublicIp string = publicIps[0].properties.ipAddress
output onPremGatewayPublicIp string = publicIps[1].properties.ipAddress
