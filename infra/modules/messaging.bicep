// Phase 5: the three messaging services side by side.
//  - Service Bus topic  "orders"    : commands/business events that must not be lost (transactions, DLQ, filters)
//  - Event Hubs         "telemetry" : high-volume stream, replayable, partitioned, many independent readers
//  - Event Grid system topic        : reactive "something happened" notifications from Azure resources (BlobCreated)

import { roleAssignment } from 'types.bicep'

param serviceBusName string
param eventHubsName string
param eventGridTopicName string
param location string
param tags object
param workspaceId string
param storageAccountId string
param serviceBusRoleAssignments roleAssignment[] = []
param eventHubsRoleAssignments roleAssignment[] = []

@description('Phase 7: where the Service Bus alerts go. Empty = no alerts.')
param actionGroupId string = ''

@description('Set (with privateDnsZoneId) to put Event Hubs behind a private endpoint and turn its public access off.')
param privateEndpointSubnetId string = ''
param privateDnsZoneId string = ''

var usePrivateEndpoint = !empty(privateEndpointSubnetId)

// ---------------------------------------------------------------- Service Bus
resource serviceBus 'Microsoft.ServiceBus/namespaces@2024-01-01' = {
  name: serviceBusName
  location: location
  tags: tags
  // Standard is the cheapest tier with topics. Premium adds private endpoints, isolation, zones and geo-replication.
  // So Service Bus stays public even with enablePrivateEndpoints: Entra-only, TLS 1.2, reached from the VNet-integrated
  // apps over Microsoft's backbone. For "no public endpoints" in production, use Premium (≈ $680/month per messaging
  // unit): sku { name: 'Premium', tier: 'Premium', capacity: 1 }, publicNetworkAccess 'Disabled', and a private
  // endpoint like the Event Hubs one below (same groupId and DNS zone).
  sku: { name: 'Standard', tier: 'Standard' }
  properties: {
    disableLocalAuth: true // no SAS keys: Entra ID only
    minimumTlsVersion: '1.2'
  }
}

resource ordersTopic 'Microsoft.ServiceBus/namespaces/topics@2024-01-01' = {
  parent: serviceBus
  name: 'orders'
  properties: {
    requiresDuplicateDetection: true // same MessageId within 10 minutes = dropped
    duplicateDetectionHistoryTimeWindow: 'PT10M'
    defaultMessageTimeToLive: 'P1D'
  }
}

var subscriptions = [
  { name: 'fulfillment', maxDeliveryCount: 3 } // low on purpose: the poison-message demo dead-letters quickly
  { name: 'notifications', maxDeliveryCount: 5 }
  { name: 'high-value', maxDeliveryCount: 5 }
]

resource orderSubscriptions 'Microsoft.ServiceBus/namespaces/topics/subscriptions@2024-01-01' = [
  for s in subscriptions: {
    parent: ordersTopic
    name: s.name
    properties: {
      maxDeliveryCount: s.maxDeliveryCount
      lockDuration: 'PT1M'
      deadLetteringOnMessageExpiration: true
      defaultMessageTimeToLive: 'P1D'
    }
  }
]

// Every subscription starts with a match-all "$Default" rule. Replacing it is what makes this one selective.
resource highValueFilter 'Microsoft.ServiceBus/namespaces/topics/subscriptions/rules@2024-01-01' = {
  parent: orderSubscriptions[2]
  name: '$Default'
  properties: {
    filterType: 'SqlFilter'
    sqlFilter: { sqlExpression: 'total > 500' }
  }
}

resource serviceBusRoles 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for ra in serviceBusRoleAssignments: {
    name: guid(serviceBus.id, ra.principalId, ra.roleDefinitionId)
    scope: serviceBus
    properties: {
      principalId: ra.principalId
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', ra.roleDefinitionId)
      principalType: ra.?principalType ?? 'ServicePrincipal'
    }
  }
]

resource serviceBusDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'to-log-analytics'
  scope: serviceBus
  properties: {
    workspaceId: workspaceId
    logs: [{ categoryGroup: 'allLogs', enabled: true }]
    metrics: [{ category: 'AllMetrics', enabled: true }]
  }
}

// Dead-lettering only helps if somebody looks. One time series per topic ("EntityName"), ≈ $0.10/month each.
var serviceBusAlerts = [
  {
    name: 'dead-letters'
    description: 'A message was dead-lettered: find it in Service Bus Explorer, fix the cause, then resubmit or purge it.'
    metricName: 'DeadletteredMessages'
    timeAggregation: 'Maximum'
    threshold: 0
    windowSize: 'PT5M'
  }
  {
    name: 'backlog'
    description: 'Messages are piling up: the Functions app is down, failing or too slow to keep up.'
    metricName: 'ActiveMessages'
    timeAggregation: 'Average'
    threshold: 100
    windowSize: 'PT15M'
  }
]

resource serviceBusMetricAlerts 'Microsoft.Insights/metricAlerts@2018-03-01' = [
  for alert in serviceBusAlerts: if (!empty(actionGroupId)) {
    name: '${serviceBusName}-${alert.name}'
    location: 'global'
    tags: tags
    properties: {
      description: alert.description
      severity: 2
      enabled: true
      scopes: [serviceBus.id]
      evaluationFrequency: 'PT5M'
      windowSize: alert.windowSize
      criteria: {
        'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
        allOf: [
          {
            criterionType: 'StaticThresholdCriterion'
            name: alert.name
            metricName: alert.metricName
            metricNamespace: 'Microsoft.ServiceBus/namespaces'
            dimensions: [{ name: 'EntityName', operator: 'Include', values: ['*'] }]
            timeAggregation: alert.timeAggregation
            operator: 'GreaterThan'
            threshold: alert.threshold
          }
        ]
      }
      actions: [{ actionGroupId: actionGroupId }]
    }
  }
]

// ---------------------------------------------------------------- Event Hubs
resource eventHubs 'Microsoft.EventHub/namespaces@2024-01-01' = {
  name: eventHubsName
  location: location
  tags: tags
  // Basic has one consumer group and no Capture; Standard is the realistic minimum, and supports private endpoints.
  sku: { name: 'Standard', tier: 'Standard', capacity: 1 }
  properties: {
    disableLocalAuth: true
    minimumTlsVersion: '1.2'
    publicNetworkAccess: usePrivateEndpoint ? 'Disabled' : 'Enabled'
  }
}

resource telemetryHub 'Microsoft.EventHub/namespaces/eventhubs@2024-01-01' = {
  parent: eventHubs
  name: 'telemetry'
  properties: {
    partitionCount: 2 // fixed at creation on Standard: it caps the parallelism of each consumer group
    retentionDescription: { cleanupPolicy: 'Delete', retentionTimeInHours: 24 }
  }
}

resource functionsConsumerGroup 'Microsoft.EventHub/namespaces/eventhubs/consumergroups@2024-01-01' = {
  parent: telemetryHub
  name: 'functions'
}

resource eventHubsRoles 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for ra in eventHubsRoleAssignments: {
    name: guid(eventHubs.id, ra.principalId, ra.roleDefinitionId)
    scope: eventHubs
    properties: {
      principalId: ra.principalId
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', ra.roleDefinitionId)
      principalType: ra.?principalType ?? 'ServicePrincipal'
    }
  }
]

resource eventHubsDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'to-log-analytics'
  scope: eventHubs
  properties: {
    workspaceId: workspaceId
    logs: [{ categoryGroup: 'allLogs', enabled: true }]
    metrics: [{ category: 'AllMetrics', enabled: true }]
  }
}

// The API sends clicks and the Functions trigger reads them, both through VNet integration. Your laptop can't reach
// the namespace any more, just like Cosmos DB and SQL after the phase 4 hardening pass.
module eventHubsPrivateEndpoint 'private-endpoint.bicep' = if (usePrivateEndpoint) {
  name: '${eventHubsName}-pe'
  params: {
    name: 'pe-${eventHubsName}'
    location: location
    tags: tags
    subnetId: privateEndpointSubnetId
    privateLinkServiceId: eventHubs.id
    groupId: 'namespace'
    privateDnsZoneId: privateDnsZoneId
  }
}

// ---------------------------------------------------------------- Event Grid
// The system topic exists from the start; its subscription to the Function is eventgrid-subscription.bicep,
// deployed after the Functions code (Event Grid checks that the target function exists).
resource storageEvents 'Microsoft.EventGrid/systemTopics@2025-02-15' = {
  name: eventGridTopicName
  location: location
  tags: tags
  identity: { type: 'SystemAssigned' } // writes dead letters to Blob Storage without a key
  properties: {
    source: storageAccountId
    topicType: 'Microsoft.Storage.StorageAccounts'
  }
}

func hostOf(endpoint string) string => split(replace(endpoint, 'https://', ''), ':')[0]

output serviceBusFqdn string = hostOf(serviceBus.properties.serviceBusEndpoint)
output eventHubsFqdn string = hostOf(eventHubs.properties.serviceBusEndpoint)
output eventGridTopicName string = storageEvents.name
