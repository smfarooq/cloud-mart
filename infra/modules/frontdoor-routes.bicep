// Phase 10, part 2: one Front Door host name for both the SPA and the API (so no CORS), edge caching for
// product images, and active/passive failover to a second region's API when you deploy one.

param profileName string
param endpointName string
param apiHostName string

@description('Phase 10 DR: a second region\'s API host name. Priority 2 = only used when the primary is unhealthy.')
param secondaryApiHostName string = ''
param spaHostName string = ''

resource profile 'Microsoft.Cdn/profiles@2024-09-01' existing = {
  name: profileName
}

resource endpoint 'Microsoft.Cdn/profiles/afdEndpoints@2024-09-01' existing = {
  parent: profile
  name: endpointName
}

resource apiGroup 'Microsoft.Cdn/profiles/originGroups@2024-09-01' = {
  parent: profile
  name: 'api'
  properties: {
    loadBalancingSettings: { sampleSize: 4, successfulSamplesRequired: 3, additionalLatencyInMilliseconds: 50 }
    healthProbeSettings: { probePath: '/health/live', probeRequestType: 'GET', probeProtocol: 'Https', probeIntervalInSeconds: 30 }
    sessionAffinityState: 'Disabled'
  }
}

var apiOrigins = concat(
  [{ name: 'primary', hostName: apiHostName, priority: 1 }],
  empty(secondaryApiHostName) ? [] : [{ name: 'secondary', hostName: secondaryApiHostName, priority: 2 }]
)

@batchSize(1)
resource apiOriginResources 'Microsoft.Cdn/profiles/originGroups/origins@2024-09-01' = [
  for origin in apiOrigins: {
    parent: apiGroup
    name: origin.name
    properties: {
      hostName: origin.hostName
      originHostHeader: origin.hostName
      httpPort: 80
      httpsPort: 443
      priority: origin.priority
      weight: 1000
      enabledState: 'Enabled'
      enforceCertificateNameCheck: true
    }
  }
]

resource spaGroup 'Microsoft.Cdn/profiles/originGroups@2024-09-01' = if (!empty(spaHostName)) {
  parent: profile
  name: 'spa'
  properties: {
    loadBalancingSettings: { sampleSize: 4, successfulSamplesRequired: 3, additionalLatencyInMilliseconds: 50 }
    healthProbeSettings: { probePath: '/', probeRequestType: 'HEAD', probeProtocol: 'Https', probeIntervalInSeconds: 100 }
  }
}

resource spaOrigin 'Microsoft.Cdn/profiles/originGroups/origins@2024-09-01' = if (!empty(spaHostName)) {
  parent: spaGroup
  name: 'static-web-app'
  properties: {
    hostName: spaHostName
    originHostHeader: spaHostName
    httpPort: 80
    httpsPort: 443
    priority: 1
    weight: 1000
    enabledState: 'Enabled'
  }
}

resource apiRoute 'Microsoft.Cdn/profiles/afdEndpoints/routes@2024-09-01' = {
  parent: endpoint
  name: 'api'
  properties: {
    originGroup: { id: apiGroup.id }
    patternsToMatch: ['/api/*', '/health/*', '/openapi/*']
    supportedProtocols: ['Https']
    httpsRedirect: 'Enabled'
    forwardingProtocol: 'HttpsOnly'
    linkToDefaultDomain: 'Enabled'
  }
  dependsOn: [apiOriginResources]
}

// More specific pattern wins: images are cached at the edge, honouring the API's Cache-Control header.
resource imageRoute 'Microsoft.Cdn/profiles/afdEndpoints/routes@2024-09-01' = {
  parent: endpoint
  name: 'images'
  properties: {
    originGroup: { id: apiGroup.id }
    patternsToMatch: ['/api/images/*']
    supportedProtocols: ['Https']
    httpsRedirect: 'Enabled'
    forwardingProtocol: 'HttpsOnly'
    linkToDefaultDomain: 'Enabled'
    cacheConfiguration: { queryStringCachingBehavior: 'IgnoreQueryString' }
  }
  dependsOn: [apiRoute]
}

resource spaRoute 'Microsoft.Cdn/profiles/afdEndpoints/routes@2024-09-01' = if (!empty(spaHostName)) {
  parent: endpoint
  name: 'spa'
  properties: {
    originGroup: { id: spaGroup.id }
    patternsToMatch: ['/*']
    supportedProtocols: ['Http', 'Https']
    httpsRedirect: 'Enabled'
    forwardingProtocol: 'HttpsOnly'
    linkToDefaultDomain: 'Enabled'
    cacheConfiguration: {
      queryStringCachingBehavior: 'IgnoreQueryString'
      compressionSettings: {
        isCompressionEnabled: true
        contentTypesToCompress: ['text/html', 'text/css', 'application/javascript', 'application/json', 'image/svg+xml']
      }
    }
  }
  dependsOn: [spaOrigin, imageRoute]
}
