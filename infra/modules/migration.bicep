// Phase 15: the Azure side of the migration. An Azure Migrate project for the assessment, and just enough access for
// the legacy server's identity to copy into CloudMart's targets. The server itself is in legacy-datacentre.bicep, in
// its own resource group.

import { roles } from 'types.bicep'

@description('Azure Migrate project name: letters, digits and hyphens.')
@minLength(3)
@maxLength(13)
param projectName string

@description('Azure Migrate keeps project metadata in a few regions per geography (United States: centralus or westus2).')
param projectLocation string

@description('The legacy server\'s system-assigned identity: its object id, and its name in Entra ID (the VM\'s name).')
param legacyPrincipalId string
param legacyServerName string

@description('CloudMart\'s storage account. The server may write to its product-uploads container and nothing else.')
param storageAccountName string

@description('Phase 4 PostgreSQL server, or empty. The migration identity becomes one of its Entra administrators.')
param postgresServerName string = ''

// ---------------------------------------------------------------- Azure Migrate
// Free: the project, imported inventories, assessments and business cases cost nothing. These are the resources the
// portal creates (and the azure-quickstart-templates "migrate-project-create" sample): the project and its tools.
// The appliance-based discovery tool stays inactive: this lab imports a CSV instead of running an appliance.
// No tags: this API version's resource type doesn't define them.
resource project 'Microsoft.Migrate/migrateProjects@2023-01-01' = {
  name: projectName
  location: projectLocation
  properties: {}
}

var tools = [
  { name: 'Servers-Assessment-ServerAssessment', tool: 'ServerAssessment', purpose: 'Assessment', status: 'Active' }
  { name: 'Servers-Discovery-ServerDiscovery', tool: 'ServerDiscovery', purpose: 'Discovery', status: 'Inactive' }
  { name: 'Servers-Migration-ServerMigration', tool: 'ServerMigration', purpose: 'Migration', status: 'Active' }
]

@batchSize(1) // the project takes one change at a time
resource projectTools 'Microsoft.Migrate/migrateProjects/solutions@2023-01-01' = [
  for t in tools: {
    parent: project
    // These are the names the portal gives its tools. The API's published name pattern for this type is malformed
    // ("$^[a-zA-Z0-9-]{3,24}$" matches no string at all), so Bicep's check is a false alarm.
    #disable-next-line BCP416
    name: t.name
    properties: { tool: t.tool, purpose: t.purpose, goal: 'Servers', status: t.status }
  }
]

// ---------------------------------------------------------------- wave 1: product photos
resource storage 'Microsoft.Storage/storageAccounts@2024-01-01' existing = {
  name: storageAccountName

  resource blobService 'blobServices' existing = {
    name: 'default'

    resource uploads 'containers' existing = {
      name: 'product-uploads'
    }
  }
}

// Scoped to the one container the photos go to. The server can't overwrite a published image in product-images:
// everything it sends passes the same checks as a photo uploaded in Admin.
resource legacyWritesUploads 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storage::blobService::uploads.id, legacyPrincipalId, roles.storageBlobDataContributor)
  scope: storage::blobService::uploads
  properties: {
    principalId: legacyPrincipalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.storageBlobDataContributor)
    principalType: 'ServicePrincipal'
  }
}

// ---------------------------------------------------------------- wave 2: the database
resource postgres 'Microsoft.DBforPostgreSQL/flexibleServers@2024-08-01' existing = if (!empty(postgresServerName)) {
  name: postgresServerName
}

// pg_restore must create the database, and in Azure Database for PostgreSQL only administrators can (there is no
// superuser). A migration identity often holds this much for the migration window, and only then: the lab's cutover
// step removes it. Its role on the server is named after the VM, which is the identity's name in Entra ID.
resource legacyPostgresAdmin 'Microsoft.DBforPostgreSQL/flexibleServers/administrators@2024-08-01' = if (!empty(postgresServerName)) {
  parent: postgres
  name: legacyPrincipalId
  properties: {
    principalType: 'ServicePrincipal'
    principalName: legacyServerName
    tenantId: tenant().tenantId
  }
}

output projectName string = project.name
