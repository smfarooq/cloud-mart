// Phase 5: route BlobCreated events from the uploads container to the ProcessProductImage function.
// Deploy only after the Functions code is published: Event Grid validates that the function exists.

param systemTopicName string
param functionAppId string
param storageAccountName string

@description('Phase 7: where the dead-letter alert goes. Empty = no alert.')
param actionGroupId string = ''

var storageBlobDataContributor = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'

resource storageEvents 'Microsoft.EventGrid/systemTopics@2025-02-15' existing = {
  name: systemTopicName
}

resource storage 'Microsoft.Storage/storageAccounts@2024-01-01' existing = {
  name: storageAccountName

  resource blobService 'blobServices' existing = {
    name: 'default'

    resource deadLetters 'containers' existing = {
      name: 'eventgrid-deadletter'
    }
  }
}

// The system topic writes dead letters with its own managed identity (the account has shared keys disabled),
// and only into this one container.
resource deadLetterWriter 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storage::blobService::deadLetters.id, storageEvents.id, storageBlobDataContributor)
  scope: storage::blobService::deadLetters
  properties: {
    principalId: storageEvents.identity.principalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataContributor)
    principalType: 'ServicePrincipal'
  }
}

resource imageUploads 'Microsoft.EventGrid/systemTopics/eventSubscriptions@2025-02-15' = {
  parent: storageEvents
  name: 'product-image-uploads'
  dependsOn: [deadLetterWriter]
  properties: {
    destination: {
      endpointType: 'AzureFunction'
      properties: {
        resourceId: '${functionAppId}/functions/ProcessProductImage'
        maxEventsPerBatch: 1
      }
    }
    filter: {
      includedEventTypes: ['Microsoft.Storage.BlobCreated']
      subjectBeginsWith: '/blobServices/default/containers/product-uploads/'
    }
    eventDeliverySchema: 'EventGridSchema'
    retryPolicy: { maxDeliveryAttempts: 10, eventTimeToLiveInMinutes: 60 }
    // Without this, an event that runs out of retries (or the 60-minute TTL) is silently dropped. With it, the event
    // lands in eventgrid-deadletter as JSON, with the reason and the last delivery error, ready to be replayed.
    deadLetterWithResourceIdentity: {
      identity: { type: 'SystemAssigned' }
      deadLetterDestination: {
        endpointType: 'StorageBlob'
        properties: {
          resourceId: storage.id
          blobContainerName: storage::blobService::deadLetters.name
        }
      }
    }
  }
}

resource deadLetterAlert 'Microsoft.Insights/metricAlerts@2018-03-01' = if (!empty(actionGroupId)) {
  name: '${systemTopicName}-dead-letters'
  location: 'global'
  properties: {
    description: 'An upload event was dead-lettered: read the JSON in the eventgrid-deadletter container, fix the cause, then replay it.'
    severity: 2
    enabled: true
    scopes: [storageEvents.id]
    evaluationFrequency: 'PT5M'
    windowSize: 'PT5M'
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          criterionType: 'StaticThresholdCriterion'
          name: 'dead-lettered'
          metricName: 'DeadLetteredCount'
          metricNamespace: 'Microsoft.EventGrid/systemTopics'
          timeAggregation: 'Total'
          operator: 'GreaterThan'
          threshold: 0
        }
      ]
    }
    actions: [{ actionGroupId: actionGroupId }]
  }
}
