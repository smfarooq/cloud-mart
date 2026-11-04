// Phase 14: a data lake, and a Data Factory pipeline that copies the orders database into it as Parquet.
// The lake is its own storage account with a hierarchical namespace (Data Lake Storage Gen2): real directories, POSIX
// ACLs and the abfss:// endpoint that Spark, Fabric and Synapse expect. Event Hubs Capture can land the click stream
// here too (messaging.bicep). No keys anywhere: Data Factory reads SQL and writes the lake as its own managed identity.

import { roles } from 'types.bicep'

param lakeName string
param factoryName string
param location string
param tags object
param workspaceId string

@description('Phase 7: where the failed-run alert goes. Empty = no alert.')
param actionGroupId string = ''

@description('What Data Factory connects to: the failover group listener when there is one (phase 11), the server otherwise.')
param sqlFqdn string
param sqlDatabaseName string
@description('The SQL server. With private endpoints, Data Factory reaches it through a managed private endpoint.')
param sqlServerId string

@description('Read the orders and clickstream containers (the API, for the Platform page).')
param readerPrincipalIds string[] = []
@description('You: browse the lake in the portal and open the Parquet files in Power BI Desktop.')
param deployerPrincipalId string
@description('Public IPs the lake still accepts once it is private (yours, for the portal and Power BI Desktop).')
param allowedIpAddresses string[] = []

@description('Phase 2: with a subnet, the lake refuses the internet and Data Factory runs in a managed virtual network.')
param privateEndpointSubnetId string = ''
param blobDnsZoneId string = ''

var usePrivateEndpoint = !empty(privateEndpointSubnetId)
var managedRuntimeName = 'managed-vnet-runtime'
var ordersContainerName = 'orders'
var clickstreamContainerName = 'clickstream'

// ---------------------------------------------------------------- the lake
resource lake 'Microsoft.Storage/storageAccounts@2024-01-01' = {
  name: lakeName
  location: location
  tags: tags
  kind: 'StorageV2'
  // LRS: the order snapshots can be rebuilt from SQL. Captured clicks can't (Event Hubs keeps them for a day), so if
  // that history matters, move up the phase 11 ladder: ZRS or GZRS.
  sku: { name: 'Standard_LRS' }
  properties: {
    isHnsEnabled: true // the "Gen2" part. It can't be switched on later without a migration.
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    defaultToOAuthAuthentication: true
    accessTier: 'Hot'
    // Private: only private endpoints, trusted Azure services that sign in with a managed identity (Event Hubs Capture),
    // and your IPs. Unlike the images account, nothing here needs a browser to reach it directly.
    publicNetworkAccess: 'Enabled'
    networkAcls: usePrivateEndpoint
      ? {
          defaultAction: 'Deny'
          bypass: 'AzureServices'
          ipRules: map(allowedIpAddresses, ip => { value: ip, action: 'Allow' })
        }
      : { defaultAction: 'Allow', bypass: 'AzureServices' }
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2024-01-01' = {
  parent: lake
  name: 'default'
  properties: {
    deleteRetentionPolicy: { enabled: true, days: 7 }
    containerDeleteRetentionPolicy: { enabled: true, days: 7 }
  }
}

// A container is a "file system" in Data Lake terms: the abfss://orders@<account>.dfs.core.windows.net/ root.
resource ordersContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2024-01-01' = {
  parent: blobService
  name: ordersContainerName
  properties: { publicAccess: 'None' }
}

resource clickstreamContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2024-01-01' = {
  parent: blobService
  name: clickstreamContainerName
  properties: { publicAccess: 'None' }
}

// Each night writes a full snapshot, so old ones are only history. The click stream is append-only: cool it, then age
// it out.
resource lifecycle 'Microsoft.Storage/storageAccounts/managementPolicies@2024-01-01' = {
  parent: lake
  name: 'default'
  properties: {
    policy: {
      rules: [
        {
          name: 'expire-order-snapshots'
          enabled: true
          type: 'Lifecycle'
          definition: {
            filters: { blobTypes: ['blockBlob'], prefixMatch: ['${ordersContainerName}/'] }
            actions: { baseBlob: { delete: { daysAfterModificationGreaterThan: 90 } } }
          }
        }
        {
          name: 'cool-then-expire-clicks'
          enabled: true
          type: 'Lifecycle'
          definition: {
            filters: { blobTypes: ['blockBlob'], prefixMatch: ['${clickstreamContainerName}/'] }
            actions: {
              baseBlob: {
                tierToCool: { daysAfterModificationGreaterThan: 30 }
                delete: { daysAfterModificationGreaterThan: 365 }
              }
            }
          }
        }
      ]
    }
  }
}

resource lakeDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'to-log-analytics'
  scope: blobService
  properties: {
    workspaceId: workspaceId
    logs: [{ categoryGroup: 'allLogs', enabled: true }]
    metrics: [{ category: 'Transaction', enabled: true }]
  }
}

// The API reads the lake for the Platform page, through the VNet like every other data store.
module lakeBlobEndpoint 'private-endpoint.bicep' = if (usePrivateEndpoint) {
  name: '${lakeName}-pe-blob'
  params: {
    name: 'pe-${lakeName}-blob'
    location: location
    tags: tags
    subnetId: privateEndpointSubnetId
    privateLinkServiceId: lake.id
    groupId: 'blob'
    privateDnsZoneId: blobDnsZoneId
  }
}

// ---------------------------------------------------------------- who can read and write it
// Scoped to containers, not the account: Data Factory can write orders but can't touch the click stream.
resource factoryWritesOrders 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  // Named from the factory's id: its principal id only exists once the deployment has created it.
  name: guid(ordersContainer.id, factory.id, roles.storageBlobDataContributor)
  scope: ordersContainer
  properties: {
    principalId: factory.identity.principalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.storageBlobDataContributor)
    principalType: 'ServicePrincipal'
  }
}

resource readersOfOrders 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for principalId in readerPrincipalIds: {
    name: guid(ordersContainer.id, principalId, roles.storageBlobDataReader)
    scope: ordersContainer
    properties: {
      principalId: principalId
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.storageBlobDataReader)
      principalType: 'ServicePrincipal'
    }
  }
]

resource readersOfClicks 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for principalId in readerPrincipalIds: {
    name: guid(clickstreamContainer.id, principalId, roles.storageBlobDataReader)
    scope: clickstreamContainer
    properties: {
      principalId: principalId
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.storageBlobDataReader)
      principalType: 'ServicePrincipal'
    }
  }
]

resource deployerContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(lake.id, deployerPrincipalId, roles.storageBlobDataContributor)
  scope: lake
  properties: {
    principalId: deployerPrincipalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.storageBlobDataContributor)
    principalType: 'User'
  }
}

// ---------------------------------------------------------------- Data Factory
// Pay per use: about $1 per 1,000 activity runs plus $0.25 per DIU-hour of copying. A nightly copy costs cents a month.
resource factory 'Microsoft.DataFactory/factories@2018-06-01' = {
  name: factoryName
  location: location
  tags: tags
  // The identity is the factory's name in Entra ID: that is the database user in grant-managed-identities.sql.
  identity: { type: 'SystemAssigned' }
  properties: {}
}

// Resource-specific tables (ADFPipelineRun, ADFActivityRun) instead of the catch-all AzureDiagnostics table.
resource factoryDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'to-log-analytics'
  scope: factory
  properties: {
    workspaceId: workspaceId
    logAnalyticsDestinationType: 'Dedicated'
    logs: [{ categoryGroup: 'allLogs', enabled: true }]
    metrics: [{ category: 'AllMetrics', enabled: true }]
  }
}

resource failedRunsAlert 'Microsoft.Insights/metricAlerts@2018-03-01' = if (!empty(actionGroupId)) {
  name: '${factoryName}-failed-runs'
  location: 'global'
  tags: tags
  properties: {
    description: 'A Data Factory pipeline run failed: the lake is missing a night of orders. ADFActivityRun in Log Analytics says why.'
    severity: 2
    enabled: true
    scopes: [factory.id]
    evaluationFrequency: 'PT1H'
    windowSize: 'PT1H'
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          criterionType: 'StaticThresholdCriterion'
          name: 'failed-runs'
          metricName: 'PipelineFailedRuns'
          metricNamespace: 'Microsoft.DataFactory/factories'
          timeAggregation: 'Total'
          operator: 'GreaterThan'
          threshold: 0
        }
      ]
    }
    actions: [{ actionGroupId: actionGroupId }]
  }
}

// With private endpoints the SQL server refuses public traffic, and the default Azure integration runtime is public.
// A managed virtual network gives Data Factory its own Microsoft-run VNet, and managed private endpoints connect it to
// the server and the lake. The owner of each target must approve them (the phase 14 lab does it with the CLI).
resource managedVnet 'Microsoft.DataFactory/factories/managedVirtualNetworks@2018-06-01' = if (usePrivateEndpoint) {
  parent: factory
  name: 'default'
  properties: {}
}

resource managedRuntime 'Microsoft.DataFactory/factories/integrationRuntimes@2018-06-01' = if (usePrivateEndpoint) {
  parent: factory
  name: managedRuntimeName
  properties: {
    type: 'Managed'
    description: 'Azure integration runtime inside the managed VNet: the only way it reaches the private SQL server.'
    managedVirtualNetwork: { referenceName: managedVnet.name, type: 'ManagedVirtualNetworkReference' }
    typeProperties: { computeProperties: { location: 'AutoResolve' } }
  }
}

resource sqlManagedEndpoint 'Microsoft.DataFactory/factories/managedVirtualNetworks/managedPrivateEndpoints@2018-06-01' = if (usePrivateEndpoint) {
  parent: managedVnet
  name: 'orders-sql'
  properties: {
    privateLinkResourceId: sqlServerId
    groupId: 'sqlServer'
  }
}

resource lakeManagedEndpoint 'Microsoft.DataFactory/factories/managedVirtualNetworks/managedPrivateEndpoints@2018-06-01' = if (usePrivateEndpoint) {
  parent: managedVnet
  name: 'data-lake'
  properties: {
    privateLinkResourceId: lake.id
    groupId: 'dfs'
  }
}

// AutoResolveIntegrationRuntime is the default, public Azure integration runtime every factory has.
var connectVia = {
  referenceName: usePrivateEndpoint ? managedRuntimeName : 'AutoResolveIntegrationRuntime'
  type: 'IntegrationRuntimeReference'
}

// No credentials in either linked service: authenticationType (SQL) or their absence (the lake) means "sign in as
// the factory's managed identity".
resource sqlLinkedService 'Microsoft.DataFactory/factories/linkedservices@2018-06-01' = {
  parent: factory
  name: 'OrdersDatabase'
  dependsOn: [managedRuntime]
  properties: {
    type: 'AzureSqlDatabase'
    connectVia: connectVia
    typeProperties: {
      server: sqlFqdn
      database: sqlDatabaseName
      encrypt: 'mandatory'
      authenticationType: 'SystemAssignedManagedIdentity'
    }
  }
}

resource lakeLinkedService 'Microsoft.DataFactory/factories/linkedservices@2018-06-01' = {
  parent: factory
  name: 'DataLake'
  dependsOn: [managedRuntime]
  properties: {
    type: 'AzureBlobFS'
    connectVia: connectVia
    typeProperties: { url: lake.properties.primaryEndpoints.dfs }
  }
}

resource orderLinesSource 'Microsoft.DataFactory/factories/datasets@2018-06-01' = {
  parent: factory
  name: 'OrderLinesSql'
  properties: {
    type: 'AzureSqlTable'
    linkedServiceName: { referenceName: sqlLinkedService.name, type: 'LinkedServiceReference' }
    typeProperties: { schema: 'dbo', table: 'OrderLines' }
  }
}

// One folder per snapshot, named key=value, so Spark, Fabric and serverless SQL read snapshot_date as a column and
// skip the folders a query doesn't need (partition pruning).
resource orderLinesParquet 'Microsoft.DataFactory/factories/datasets@2018-06-01' = {
  parent: factory
  name: 'OrderLinesParquet'
  properties: {
    type: 'Parquet'
    linkedServiceName: { referenceName: lakeLinkedService.name, type: 'LinkedServiceReference' }
    parameters: { snapshotDate: { type: 'String' } }
    typeProperties: {
      location: {
        type: 'AzureBlobFSLocation'
        fileSystem: ordersContainer.name
        folderPath: { value: '@concat(\'snapshot_date=\', dataset().snapshotDate)', type: 'Expression' }
        fileName: 'order_lines.parquet'
      }
      compressionCodec: 'snappy'
    }
  }
}

// One row per order line, with its order's columns: the flat shape analytics tools like. CustomerName stays behind:
// the lake gets the pseudonymous customer id and no personal data it doesn't need.
var orderLinesQuery = '''
SELECT o.Id AS OrderId, o.CustomerId, o.Status, o.Total AS OrderTotal,
       CAST(o.CreatedUtc AS datetime2) AS CreatedUtc, CAST(o.UpdatedUtc AS datetime2) AS UpdatedUtc,
       l.ProductId, l.ProductName, l.Quantity, l.UnitPrice, l.Quantity * l.UnitPrice AS LineTotal
FROM dbo.Orders AS o
JOIN dbo.OrderLines AS l ON l.OrderId = o.Id
'''

// No trigger here: ARM can't update a started trigger, so a trigger in this template would make every later
// deployment fail. The lab creates and starts it from deploy/analytics/nightly-export-trigger.json.
resource exportPipeline 'Microsoft.DataFactory/factories/pipelines@2018-06-01' = {
  parent: factory
  name: 'export-orders'
  properties: {
    description: 'Copies every order line to the data lake as one Parquet snapshot per day (orders/snapshot_date=yyyy-MM-dd/).'
    activities: [
      {
        name: 'CopyOrderLinesToLake'
        type: 'Copy'
        // The serverless database is usually paused at night. The first attempt wakes it and can fail while it
        // resumes (about a minute); the retry then finds it online.
        policy: { timeout: '0.00:30:00', retry: 2, retryIntervalInSeconds: 120 }
        inputs: [{ referenceName: orderLinesSource.name, type: 'DatasetReference' }]
        outputs: [
          {
            referenceName: orderLinesParquet.name
            type: 'DatasetReference'
            parameters: {
              snapshotDate: { value: '@formatDateTime(pipeline().TriggerTime, \'yyyy-MM-dd\')', type: 'Expression' }
            }
          }
        ]
        typeProperties: {
          source: { type: 'AzureSqlSource', sqlReaderQuery: orderLinesQuery }
          sink: { type: 'ParquetSink', storeSettings: { type: 'AzureBlobFSWriteSettings' } }
        }
      }
    ]
  }
}

output lakeName string = lake.name
output lakeId string = lake.id
output blobEndpoint string = lake.properties.primaryEndpoints.blob
output dfsEndpoint string = lake.properties.primaryEndpoints.dfs
output ordersContainerName string = ordersContainer.name
output clickstreamContainerName string = clickstreamContainer.name
output factoryName string = factory.name
