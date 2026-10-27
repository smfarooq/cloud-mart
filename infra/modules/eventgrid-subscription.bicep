// Phase 5: route BlobCreated events from the uploads container to the ProcessProductImage function.
// Deploy only after the Functions code is published: Event Grid validates that the function exists.

param systemTopicName string
param functionAppId string

resource storageEvents 'Microsoft.EventGrid/systemTopics@2025-02-15' existing = {
  name: systemTopicName
}

resource imageUploads 'Microsoft.EventGrid/systemTopics/eventSubscriptions@2025-02-15' = {
  parent: storageEvents
  name: 'product-image-uploads'
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
  }
}
