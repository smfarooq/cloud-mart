// Phase 3: the same API container on Azure Container Apps (serverless Kubernetes: KEDA scaling, revisions,
// scale to zero, no cluster to run). Compare with App Service and AKS.

param environmentName string
param appName string
param location string
param tags object
param workspaceId string
param identityId string
param appSettings object

@description('Leave empty for a public sample image (first deployment, before anything is pushed to ACR).')
param image string = ''
param registryServer string = ''

@description('Container Apps environment subnet (delegated to Microsoft.App/environments, /27 or larger).')
param infrastructureSubnetId string = ''

var useSampleImage = empty(image)
var port = useSampleImage ? 80 : 8080

resource environment 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: environmentName
  location: location
  tags: tags
  properties: {
    // Logs go out through the diagnostic setting below, so no workspace shared key is needed.
    appLogsConfiguration: { destination: 'azure-monitor' }
    workloadProfiles: [{ name: 'Consumption', workloadProfileType: 'Consumption' }]
    vnetConfiguration: empty(infrastructureSubnetId) ? null : { infrastructureSubnetId: infrastructureSubnetId, internal: false }
    zoneRedundant: false
  }
}

resource environmentDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'to-log-analytics'
  scope: environment
  properties: {
    workspaceId: workspaceId
    logs: [{ categoryGroup: 'allLogs', enabled: true }]
    metrics: [{ category: 'AllMetrics', enabled: true }]
  }
}

resource app 'Microsoft.App/containerApps@2024-03-01' = {
  name: appName
  location: location
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${identityId}': {} }
  }
  properties: {
    environmentId: environment.id
    workloadProfileName: 'Consumption'
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: {
        external: true
        targetPort: port
        transport: 'auto'
        allowInsecure: false
      }
      registries: useSampleImage ? [] : [{ server: registryServer, identity: identityId }]
    }
    template: {
      containers: [
        {
          name: 'api'
          image: useSampleImage ? 'mcr.microsoft.com/k8se/quickstart:latest' : image
          resources: { cpu: json('0.5'), memory: '1Gi' }
          env: useSampleImage ? [] : map(items(appSettings), s => { name: s.key, value: s.value })
          probes: [
            { type: 'Liveness', httpGet: { path: useSampleImage ? '/' : '/health/live', port: port }, periodSeconds: 30 }
            { type: 'Readiness', httpGet: { path: useSampleImage ? '/' : '/health/live', port: port }, periodSeconds: 10 }
          ]
        }
      ]
      scale: {
        minReplicas: 0
        maxReplicas: 5
        rules: [{ name: 'http', http: { metadata: { concurrentRequests: '50' } } }]
      }
    }
  }
}

output fqdn string = app.properties.configuration.ingress.fqdn
