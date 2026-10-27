// Phase 7: one workspace-based Application Insights + Log Analytics workspace for everything.
// Every other module sends its platform logs here through diagnostic settings ("routing logs" on the exam).

param location string
param tags object
param workspaceName string
param appInsightsName string
param actionGroupName string
param alertEmail string

@description('Ingestion stops for the day at this cap. A cheap guard rail for a learning subscription.')
param dailyCapGb int = 1

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: workspaceName
  location: location
  tags: tags
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: 30
    workspaceCapping: { dailyQuotaGb: dailyCapGb }
  }
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: appInsightsName
  location: location
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: workspace.id
    IngestionMode: 'LogAnalytics'
  }
}

resource actionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: actionGroupName
  location: 'global'
  tags: tags
  properties: {
    groupShortName: 'cloudmart'
    enabled: true
    emailReceivers: [
      { name: 'owner', emailAddress: alertEmail, useCommonAlertSchema: true }
    ]
  }
}

// A log search alert: more than 5 server exceptions in 5 minutes. Trigger it with the Admin > Chaos buttons.
resource exceptionAlert 'Microsoft.Insights/scheduledQueryRules@2023-12-01' = {
  name: '${appInsightsName}-exceptions'
  location: location
  tags: tags
  properties: {
    displayName: 'CloudMart: exception spike'
    severity: 2
    enabled: true
    scopes: [appInsights.id]
    evaluationFrequency: 'PT5M'
    windowSize: 'PT5M'
    criteria: {
      allOf: [
        {
          query: 'exceptions | where client_Type != "Browser"'
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 5
          failingPeriods: { numberOfEvaluationPeriods: 1, minFailingPeriodsToAlert: 1 }
        }
      ]
    }
    actions: { actionGroups: [actionGroup.id] }
  }
}

output workspaceId string = workspace.id
output appInsightsId string = appInsights.id
output appInsightsConnectionString string = appInsights.properties.ConnectionString
