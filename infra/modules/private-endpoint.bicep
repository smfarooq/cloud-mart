// A private endpoint = a NIC with a private IP in your subnet that maps to one sub-resource (groupId) of a PaaS
// service, plus a DNS zone group that writes the A record into the matching privatelink zone.

param name string
param location string
param tags object
param subnetId string
param privateLinkServiceId string

@description('blob, queue, table, vault, Sql, sqlServer, postgresqlServer, namespace (Event Hubs, Service Bus), ...')
param groupId string
param privateDnsZoneId string

@description('Application security groups for the endpoint\'s NIC, so NSG rules can target it by name.')
param applicationSecurityGroupIds string[] = []

resource endpoint 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    subnet: { id: subnetId }
    applicationSecurityGroups: [for id in applicationSecurityGroupIds: { id: id }]
    privateLinkServiceConnections: [
      {
        name: name
        properties: {
          privateLinkServiceId: privateLinkServiceId
          groupIds: [groupId]
        }
      }
    ]
  }
}

resource dnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = {
  parent: endpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      { name: groupId, properties: { privateDnsZoneId: privateDnsZoneId } }
    ]
  }
}
