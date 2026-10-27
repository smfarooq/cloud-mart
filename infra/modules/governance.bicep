// Phase 9: guard rails on the resource group. Policy (deny + modify with remediation identity) and a budget.
// Management-group hierarchy, initiatives and Defender for Cloud are subscription/tenant-level labs (see docs).

import { roles } from 'types.bicep'

param location string
param allowedLocations array
param budgetAmount int
param budgetContactEmails array

@description('First day of a month, yyyy-MM-01. Pin it in main.bicepparam if Azure refuses to change it later.')
param budgetStartDate string

// Built-in definition ids (identical in every tenant):
//   az policy definition list --query "[?displayName=='Allowed locations'].name" -o tsv
var allowedLocationsPolicy = 'e56962a6-4747-49cd-b67b-bf8b01975c4c'
var inheritTagIfMissingPolicy = 'ea3f2387-9b95-492a-a190-fcdc54f7b070'

// Deny: anything created outside these regions fails at deployment time.
resource allowedLocationsAssignment 'Microsoft.Authorization/policyAssignments@2024-04-01' = {
  name: 'cloudmart-allowed-locations'
  properties: {
    displayName: 'CloudMart: allowed locations'
    policyDefinitionId: tenantResourceId('Microsoft.Authorization/policyDefinitions', allowedLocationsPolicy)
    parameters: { listOfAllowedLocations: { value: allowedLocations } }
  }
}

// Modify: copies the resource group's "environment" tag onto resources that lack it. Modify/DeployIfNotExists
// policies need a managed identity with rights to make the change, plus a remediation task for existing resources.
resource inheritTagAssignment 'Microsoft.Authorization/policyAssignments@2024-04-01' = {
  name: 'cloudmart-inherit-env-tag'
  location: location
  identity: { type: 'SystemAssigned' }
  properties: {
    displayName: 'CloudMart: inherit the environment tag from the resource group'
    policyDefinitionId: tenantResourceId('Microsoft.Authorization/policyDefinitions', inheritTagIfMissingPolicy)
    parameters: { tagName: { value: 'environment' } }
  }
}

resource remediationRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, inheritTagAssignment.id, roles.tagContributor)
  properties: {
    principalId: inheritTagAssignment.identity.principalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.tagContributor)
    principalType: 'ServicePrincipal'
  }
}

resource budget 'Microsoft.Consumption/budgets@2023-11-01' = {
  name: 'cloudmart-monthly'
  properties: {
    category: 'Cost'
    amount: budgetAmount
    timeGrain: 'Monthly'
    timePeriod: { startDate: budgetStartDate }
    notifications: {
      actual50: { enabled: true, operator: 'GreaterThanOrEqualTo', threshold: 50, thresholdType: 'Actual', contactEmails: budgetContactEmails }
      actual80: { enabled: true, operator: 'GreaterThanOrEqualTo', threshold: 80, thresholdType: 'Actual', contactEmails: budgetContactEmails }
      forecast100: { enabled: true, operator: 'GreaterThanOrEqualTo', threshold: 100, thresholdType: 'Forecasted', contactEmails: budgetContactEmails }
    }
  }
}
