// CloudMart platform. Subscription-scoped so it also creates the resource group.
//
//   az deployment sub what-if  -l <region> -f infra/main.bicep -p infra/main.bicepparam
//   az deployment sub create   -l <region> -f infra/main.bicep -p infra/main.bicepparam
//
// Each learning phase is a switch below. Flip it in main.bicepparam and redeploy: Bicep is declarative and
// idempotent, so only the difference is applied. Set a switch back to false to stop paying for that piece
// (resources are NOT deleted automatically; delete them or use a deployment stack, see the learning path).

targetScope = 'subscription'

import { roles } from 'modules/types.bicep'

@minLength(3)
@maxLength(10)
@description('Short lowercase name used in every resource name.')
param appName string = 'cloudmart'

@allowed(['dev', 'test', 'prod'])
param environmentName string = 'dev'

param location string = 'eastus2'

@allowed(['westus2', 'centralus', 'eastus2', 'westeurope', 'eastasia'])
param staticWebAppLocation string = 'eastus2'

@description('Your Entra object id: az ad signed-in-user show --query id -o tsv')
param deployerPrincipalId string

@description('Your UPN (you@contoso.com). Becomes the SQL / PostgreSQL Entra admin login.')
param deployerPrincipalName string

@description('Receives budget and alert emails.')
param ownerEmail string

param monthlyBudget int = 50

@description('First day of the current month. Pin it after the first deployment if Azure refuses to change it.')
param budgetStartDate string = utcNow('yyyy-MM-01')

@secure()
@description('A fake third-party API key, stored in Key Vault to show secret handling end to end.')
param paymentGatewayApiKey string = newGuid()

// ------------------------------------------------------------------ Phase 2 · Networking
param deployNetwork bool = false
@description('Requires deployNetwork. Moves Key Vault, Storage, Cosmos DB, SQL and PostgreSQL behind private endpoints.')
param enablePrivateEndpoints bool = false
param deployJumpbox bool = false
param jumpboxSshPublicKey string = ''
@allowed(['Developer', 'Basic'])
param bastionSku string = 'Developer'

// ------------------------------------------------------------------ Phase 3 · Compute
param deployAppService bool = true
param appServiceSku string = 'B1'
param deployFunctions bool = true
param deployStaticWebApp bool = true
param deployContainerApps bool = false
@description('e.g. crcloudmartxxxx.azurecr.io/cloudmart-api:1. Empty = public sample image.')
param containerImage string = ''
param deployAks bool = false

// ------------------------------------------------------------------ Phase 4 · Data
param deployCosmos bool = false
param cosmosFreeTier bool = true
param deploySql bool = false
param deployPostgres bool = false
@allowed(['SqlServer', 'PostgreSql'])
param ordersProvider string = 'SqlServer'
@allowed(['Standard_LRS', 'Standard_ZRS', 'Standard_GRS', 'Standard_GZRS', 'Standard_RAGZRS'])
param storageSku string = 'Standard_LRS'

// ------------------------------------------------------------------ Phase 5 · Messaging
param deployMessaging bool = false
@description('Turn on after the Functions code has been deployed once: Event Grid validates the function exists.')
param deployEventGridSubscription bool = false

// ------------------------------------------------------------------ Phase 6 · Security
param enableEntraAuth bool = false
@description('Application (client) id of the "CloudMart API" app registration.')
param entraApiClientId string = ''
@description('Application (client) id of the "CloudMart SPA" app registration.')
param entraSpaClientId string = ''

// ------------------------------------------------------------------ Phase 7 · Observability
param logAnalyticsDailyCapGb int = 1
param deployGrafana bool = false

// ------------------------------------------------------------------ Phase 8 · DevOps
param deployAcr bool = false

// ------------------------------------------------------------------ Phase 9 · Governance
param deployGovernance bool = true

// ------------------------------------------------------------------ Phase 10 · Architecture
param deployFrontDoor bool = false
@allowed(['Standard_AzureFrontDoor', 'Premium_AzureFrontDoor'])
param frontDoorSku string = 'Standard_AzureFrontDoor'
@description('Host name of a second region\'s API (deploy this template again with another environmentName/location).')
param secondaryApiHostName string = ''
param cosmosSecondaryLocation string = ''
param deployAppGateway bool = false

// ------------------------------------------------------------------ Gap topics
param deployAppConfig bool = false
param deployRedis bool = false
param deployApim bool = false

// ------------------------------------------------------------------ Phase 16 · Microservices
@description('Payments API on the App Service plan. Its ledger database needs deploySql; without it, payments are in memory.')
param deployPayments bool = false
@description('Shipping API on the App Service plan, storing shipments in Table Storage.')
param deployShipping bool = false
@description('Application (client) id of the "CloudMart Payments" app registration (deploy/entra/setup-service-auth.sh).')
param entraPaymentsClientId string = ''
@description('Application (client) id of the "CloudMart Shipping" app registration (deploy/entra/setup-service-auth.sh).')
param entraShippingClientId string = ''

// ==================================================================================================== names
var suffix = uniqueString(subscription().id, appName, environmentName)
var short = take(suffix, 6)
var prefix = '${appName}-${environmentName}'
var compact = toLower(replace(appName, '-', ''))
var tags = {
  application: appName
  environment: environmentName
  'managed-by': 'bicep'
}

var names = {
  resourceGroup: 'rg-${prefix}'
  workspace: 'log-${prefix}'
  appInsights: 'appi-${prefix}'
  actionGroup: 'ag-${prefix}'
  apiIdentity: 'id-${prefix}-api'
  functionsIdentity: 'id-${prefix}-func'
  paymentsIdentity: 'id-${prefix}-pay'
  shippingIdentity: 'id-${prefix}-ship'
  vnet: 'vnet-${prefix}'
  keyVault: 'kv-${compact}-${take(suffix, 8)}'
  storage: take('st${compact}${suffix}', 24)
  cosmos: 'cosmos-${prefix}-${short}'
  sql: 'sql-${prefix}-${short}'
  postgres: 'psql-${prefix}-${short}'
  serviceBus: 'sbns-${prefix}-${short}'
  eventHubs: 'evhns-${prefix}-${short}'
  eventGrid: 'evgt-${prefix}-storage'
  appServicePlan: 'asp-${prefix}'
  apiApp: 'app-${prefix}-api-${short}'
  paymentsApp: 'app-${prefix}-pay-${short}'
  shippingApp: 'app-${prefix}-ship-${short}'
  functionsPlan: 'asp-${prefix}-func'
  functionApp: 'func-${prefix}-${short}'
  staticWebApp: 'stapp-${prefix}'
  acr: take('cr${compact}${suffix}', 50)
  containerAppsEnv: 'cae-${prefix}'
  containerApp: 'ca-${prefix}-api'
  aks: 'aks-${prefix}'
  jumpbox: 'vm-${take(compact, 6)}-jump'
  appConfig: 'appcs-${prefix}-${short}'
  redis: 'redis-${prefix}-${short}'
  apim: 'apim-${prefix}-${short}'
  grafana: take('amg-${prefix}', 23)
  frontDoor: 'afd-${prefix}'
  frontDoorEndpoint: 'fde-${prefix}-${short}'
  frontDoorWaf: 'waf${compact}${environmentName}'
  appGateway: 'agw-${prefix}'
}

var usePrivateEndpoints = deployNetwork && enablePrivateEndpoints
var needAcr = deployAcr || deployAks || (deployContainerApps && !empty(containerImage))

// Phase 16: both services run on the API's App Service plan. Each gets Entra protection once its app registration
// exists; until then it runs in the same lab-only "anonymous" mode as the API before phase 6.
var usePayments = deployPayments && deployAppService
var useShipping = deployShipping && deployAppService
var paymentsEntra = enableEntraAuth && !empty(entraPaymentsClientId)
var shippingEntra = enableEntraAuth && !empty(entraShippingClientId)

// ==================================================================================================== foundation
resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: names.resourceGroup
  location: location
  tags: tags
}

module governance 'modules/governance.bicep' = if (deployGovernance) {
  scope: rg
  name: 'governance'
  params: {
    location: location
    allowedLocations: union([location, staticWebAppLocation], empty(cosmosSecondaryLocation) ? [] : [cosmosSecondaryLocation])
    budgetAmount: monthlyBudget
    budgetContactEmails: [ownerEmail]
    budgetStartDate: budgetStartDate
  }
}

module monitoring 'modules/monitoring.bicep' = {
  scope: rg
  name: 'monitoring'
  params: {
    location: location
    tags: tags
    workspaceName: names.workspace
    appInsightsName: names.appInsights
    actionGroupName: names.actionGroup
    alertEmail: ownerEmail
    dailyCapGb: logAnalyticsDailyCapGb
  }
}

module identity 'modules/identity.bicep' = {
  scope: rg
  name: 'identity'
  params: {
    location: location
    tags: tags
    apiIdentityName: names.apiIdentity
    functionsIdentityName: names.functionsIdentity
    paymentsIdentityName: names.paymentsIdentity
    shippingIdentityName: names.shippingIdentity
  }
}

module network 'modules/network.bicep' = if (deployNetwork) {
  scope: rg
  name: 'network'
  params: {
    location: location
    tags: tags
    vnetName: names.vnet
  }
}

var peSubnetId = usePrivateEndpoints ? network!.outputs.privateEndpointSubnetId : ''
var dnsZones = usePrivateEndpoints ? network!.outputs.dnsZoneIds : {}

// ==================================================================================================== edge (early: other modules need its ids)
module staticWebApp 'modules/staticwebapp.bicep' = if (deployStaticWebApp) {
  scope: rg
  name: 'static-web-app'
  params: {
    name: names.staticWebApp
    location: staticWebAppLocation
    tags: tags
  }
}

module frontDoor 'modules/frontdoor.bicep' = if (deployFrontDoor) {
  scope: rg
  name: 'front-door'
  params: {
    profileName: names.frontDoor
    endpointName: names.frontDoorEndpoint
    wafPolicyName: names.frontDoorWaf
    sku: frontDoorSku
    tags: tags
  }
}

var spaOrigins = concat(
  ['http://localhost:5173'],
  deployStaticWebApp ? ['https://${staticWebApp!.outputs.hostName}'] : [],
  deployFrontDoor ? ['https://${frontDoor!.outputs.endpointHostName}'] : []
)

// ==================================================================================================== security + data
module keyVault 'modules/keyvault.bicep' = {
  scope: rg
  name: 'key-vault'
  params: {
    name: names.keyVault
    location: location
    tags: tags
    workspaceId: monitoring.outputs.workspaceId
    paymentGatewayApiKey: paymentGatewayApiKey
    privateEndpointSubnetId: peSubnetId
    privateDnsZoneId: dnsZones.?keyVault ?? ''
    // Least privilege: whoever takes payments reads the gateway key. Before phase 16 that is the API and Functions
    // (payments run in-process); after it, only the Payments API, and the other two lose access.
    roleAssignments: concat(
      usePayments
        ? [{ principalId: identity.outputs.paymentsPrincipalId, roleDefinitionId: roles.keyVaultSecretsUser }]
        : [
            { principalId: identity.outputs.apiPrincipalId, roleDefinitionId: roles.keyVaultSecretsUser }
            { principalId: identity.outputs.functionsPrincipalId, roleDefinitionId: roles.keyVaultSecretsUser }
          ],
      [{ principalId: deployerPrincipalId, roleDefinitionId: roles.keyVaultSecretsOfficer, principalType: 'User' }]
    )
  }
}

module storage 'modules/storage.bicep' = {
  scope: rg
  name: 'storage'
  params: {
    name: names.storage
    location: location
    tags: tags
    skuName: storageSku
    workspaceId: monitoring.outputs.workspaceId
    corsOrigins: spaOrigins
    privateEndpointSubnetId: peSubnetId
    blobDnsZoneId: dnsZones.?blob ?? ''
    queueDnsZoneId: dnsZones.?queue ?? ''
    tableDnsZoneId: dnsZones.?table ?? ''
    roleAssignments: concat(
      [
        // API: signs user-delegation SAS for uploads, serves images.
        { principalId: identity.outputs.apiPrincipalId, roleDefinitionId: roles.storageBlobDataContributor }
        { principalId: identity.outputs.apiPrincipalId, roleDefinitionId: roles.storageBlobDelegator }
        // Functions: host storage (blobs, queues, tables: also the Durable Functions task hub) + image processing
        // + deployment package.
        { principalId: identity.outputs.functionsPrincipalId, roleDefinitionId: roles.storageBlobDataOwner }
        { principalId: identity.outputs.functionsPrincipalId, roleDefinitionId: roles.storageQueueDataContributor }
        { principalId: identity.outputs.functionsPrincipalId, roleDefinitionId: roles.storageTableDataContributor }
        // You: so the app can run on your laptop against this account, and the portal's storage browser works.
        { principalId: deployerPrincipalId, roleDefinitionId: roles.storageBlobDataContributor, principalType: 'User' }
        { principalId: deployerPrincipalId, roleDefinitionId: roles.storageBlobDelegator, principalType: 'User' }
      ],
      // Shipping: tables only. (Account-wide here; a role assignment scoped to the one table is tighter still.)
      useShipping ? [{ principalId: identity.outputs.shippingPrincipalId, roleDefinitionId: roles.storageTableDataContributor }] : []
    )
  }
}

module cosmos 'modules/cosmos.bicep' = if (deployCosmos) {
  scope: rg
  name: 'cosmos'
  params: {
    name: names.cosmos
    location: location
    tags: tags
    workspaceId: monitoring.outputs.workspaceId
    freeTier: cosmosFreeTier
    secondaryLocation: cosmosSecondaryLocation
    privateEndpointSubnetId: peSubnetId
    privateDnsZoneId: dnsZones.?cosmos ?? ''
    dataContributorPrincipalIds: [identity.outputs.apiPrincipalId, identity.outputs.functionsPrincipalId, deployerPrincipalId]
  }
}

module sql 'modules/sql.bicep' = if (deploySql) {
  scope: rg
  name: 'sql'
  params: {
    serverName: names.sql
    location: location
    tags: tags
    workspaceId: monitoring.outputs.workspaceId
    adminLogin: deployerPrincipalName
    adminObjectId: deployerPrincipalId
    privateEndpointSubnetId: peSubnetId
    privateDnsZoneId: dnsZones.?sql ?? ''
    paymentsDatabaseName: usePayments ? 'payments' : ''
  }
}

module postgres 'modules/postgres.bicep' = if (deployPostgres) {
  scope: rg
  name: 'postgres'
  params: {
    name: names.postgres
    location: location
    tags: tags
    workspaceId: monitoring.outputs.workspaceId
    adminLogin: deployerPrincipalName
    adminObjectId: deployerPrincipalId
    privateEndpointSubnetId: peSubnetId
    privateDnsZoneId: dnsZones.?postgres ?? ''
  }
}

module messaging 'modules/messaging.bicep' = if (deployMessaging) {
  scope: rg
  name: 'messaging'
  params: {
    serviceBusName: names.serviceBus
    eventHubsName: names.eventHubs
    eventGridTopicName: names.eventGrid
    location: location
    tags: tags
    workspaceId: monitoring.outputs.workspaceId
    storageAccountId: storage.outputs.id
    privateEndpointSubnetId: peSubnetId
    privateDnsZoneId: dnsZones.?serviceBus ?? ''
    // Least privilege: the API only sends, the Functions app only receives.
    serviceBusRoleAssignments: [
      { principalId: identity.outputs.apiPrincipalId, roleDefinitionId: roles.serviceBusDataSender }
      { principalId: identity.outputs.functionsPrincipalId, roleDefinitionId: roles.serviceBusDataReceiver }
      { principalId: deployerPrincipalId, roleDefinitionId: roles.serviceBusDataOwner, principalType: 'User' }
    ]
    eventHubsRoleAssignments: [
      { principalId: identity.outputs.apiPrincipalId, roleDefinitionId: roles.eventHubsDataSender }
      { principalId: identity.outputs.functionsPrincipalId, roleDefinitionId: roles.eventHubsDataReceiver }
      { principalId: deployerPrincipalId, roleDefinitionId: roles.eventHubsDataOwner, principalType: 'User' }
    ]
  }
}

module appIntegration 'modules/app-integration.bicep' = if (deployAppConfig || deployRedis || deployApim) {
  scope: rg
  name: 'app-integration'
  params: {
    location: location
    tags: tags
    appInsightsId: monitoring.outputs.appInsightsId
    appInsightsConnectionString: monitoring.outputs.appInsightsConnectionString
    deployAppConfig: deployAppConfig
    appConfigName: names.appConfig
    appConfigRoleAssignments: [
      { principalId: identity.outputs.apiPrincipalId, roleDefinitionId: roles.appConfigDataReader }
      { principalId: deployerPrincipalId, roleDefinitionId: roles.appConfigDataOwner, principalType: 'User' }
    ]
    deployRedis: deployRedis
    redisName: names.redis
    redisPrincipalIds: [identity.outputs.apiPrincipalId, deployerPrincipalId]
    deployApim: deployApim
    apimName: names.apim
    apimPublisherEmail: ownerEmail
  }
}

module registry 'modules/acr.bicep' = if (needAcr) {
  scope: rg
  name: 'container-registry'
  params: {
    name: names.acr
    location: location
    tags: tags
    workspaceId: monitoring.outputs.workspaceId
    roleAssignments: [
      { principalId: identity.outputs.apiPrincipalId, roleDefinitionId: roles.acrPull }
    ]
  }
}

// ==================================================================================================== app settings
// The configuration contract lives in src/CloudMart.Core/CloudMartSettings.cs. Each service that is switched on
// adds its setting, and the app swaps the in-memory implementation for the Azure one.

func sqlConnectionString(serverFqdn string, database string, identityClientId string) string =>
  'Server=tcp:${serverFqdn},1433;Database=${database};Authentication=Active Directory Managed Identity;User Id=${identityClientId};Encrypt=True;Connect Timeout=30;'

func postgresConnectionString(serverFqdn string, database string, identityName string) string =>
  'Host=${serverFqdn};Database=${database};Username=${identityName};SslMode=Require'

var sharedSettings = union(
  {
    APPLICATIONINSIGHTS_CONNECTION_STRING: monitoring.outputs.appInsightsConnectionString
    CLOUDMART_REGION: location
    Storage__BlobEndpoint: storage.outputs.blobEndpoint
  },
  deployCosmos ? { Cosmos__Endpoint: cosmos!.outputs.endpoint } : {},
  deploySql && deployPostgres ? { Orders__Provider: ordersProvider } : {},
  // Phase 16: where the order saga finds the two services, and which token audience to ask Entra for. The host
  // names are built from the site names: reading them from the modules would make the API depend on itself
  // (API settings -> Payments app -> the API's App Service plan -> API).
  usePayments ? { Payments__BaseUrl: 'https://${names.paymentsApp}.azurewebsites.net' } : {},
  usePayments && paymentsEntra ? { Payments__Scope: 'api://${entraPaymentsClientId}/.default' } : {},
  useShipping ? { Shipping__BaseUrl: 'https://${names.shippingApp}.azurewebsites.net' } : {},
  useShipping && shippingEntra ? { Shipping__Scope: 'api://${entraShippingClientId}/.default' } : {}
)

var keyVaultReference = '@Microsoft.KeyVault(VaultName=${keyVault.outputs.name};SecretName=PaymentGateway--ApiKey)'

var apiSettings = union(
  sharedSettings,
  {
    AZURE_CLIENT_ID: identity.outputs.apiClientId
    Cors__AllowedOrigins: join(spaOrigins, ',')
    Auth__AllowAnonymousDevMode: string(!enableEntraAuth)
  },
  // The Key Vault configuration provider fails at startup without read access, which the API loses in phase 16.
  usePayments ? {} : { KeyVault__Uri: keyVault.outputs.uri },
  enableEntraAuth
    ? {
        AzureAd__TenantId: tenant().tenantId
        AzureAd__ClientId: entraApiClientId
        AzureAd__Audience: 'api://${entraApiClientId}'
      }
    : {},
  deploySql ? { ConnectionStrings__OrdersSql: sqlConnectionString(sql!.outputs.fqdn, sql!.outputs.databaseName, identity.outputs.apiClientId) } : {},
  deployPostgres ? { ConnectionStrings__OrdersPostgres: postgresConnectionString(postgres!.outputs.fqdn, postgres!.outputs.databaseName, identity.outputs.apiName) } : {},
  deployMessaging
    ? {
        ServiceBus__FullyQualifiedNamespace: messaging!.outputs.serviceBusFqdn
        EventHubs__FullyQualifiedNamespace: messaging!.outputs.eventHubsFqdn
      }
    : {},
  deployAppConfig ? { AppConfig__Endpoint: appIntegration!.outputs.appConfigEndpoint } : {},
  deployRedis ? { Redis__Endpoint: appIntegration!.outputs.redisEndpoint } : {},
  deployFrontDoor ? { FrontDoor__Id: frontDoor!.outputs.frontDoorId } : {}
)

var functionsSettings = union(
  sharedSettings,
  {
    AZURE_CLIENT_ID: identity.outputs.functionsClientId
    // Identity-based host storage: no AzureWebJobsStorage connection string.
    AzureWebJobsStorage__accountName: storage.outputs.name
    AzureWebJobsStorage__credential: 'managedidentity'
    AzureWebJobsStorage__clientId: identity.outputs.functionsClientId
  },
  // Key Vault reference: the platform resolves the secret; the code just reads an app setting.
  usePayments ? {} : { PaymentGateway__ApiKey: keyVaultReference },
  deploySql ? { ConnectionStrings__OrdersSql: sqlConnectionString(sql!.outputs.fqdn, sql!.outputs.databaseName, identity.outputs.functionsClientId) } : {},
  deployPostgres ? { ConnectionStrings__OrdersPostgres: postgresConnectionString(postgres!.outputs.fqdn, postgres!.outputs.databaseName, identity.outputs.functionsName) } : {},
  deployMessaging
    ? {
        // Identity-based trigger connections: "<Connection>__fullyQualifiedNamespace" + credential + clientId.
        ServiceBus__fullyQualifiedNamespace: messaging!.outputs.serviceBusFqdn
        ServiceBus__credential: 'managedidentity'
        ServiceBus__clientId: identity.outputs.functionsClientId
        EventHubs__fullyQualifiedNamespace: messaging!.outputs.eventHubsFqdn
        EventHubs__credential: 'managedidentity'
        EventHubs__clientId: identity.outputs.functionsClientId
      }
    : {
        // Nothing to listen to yet: disable these triggers instead of letting them fail at startup.
        'AzureWebJobs.FulfillOrder.Disabled': 'true'
        'AzureWebJobs.FlagHighValueOrder.Disabled': 'true'
        'AzureWebJobs.NotifyCustomer.Disabled': 'true'
        'AzureWebJobs.AggregateProductViews.Disabled': 'true'
      },
  deploySql || deployPostgres ? {} : { 'AzureWebJobs.DailyOrderReport.Disabled': 'true' }
)

var serviceBaseSettings = {
  APPLICATIONINSIGHTS_CONNECTION_STRING: monitoring.outputs.appInsightsConnectionString
  CLOUDMART_REGION: location
}

var paymentsSettings = union(
  serviceBaseSettings,
  {
    AZURE_CLIENT_ID: identity.outputs.paymentsClientId
    Auth__AllowAnonymousDevMode: string(!paymentsEntra)
    PaymentGateway__ApiKey: keyVaultReference
  },
  paymentsEntra
    ? {
        AzureAd__TenantId: tenant().tenantId
        AzureAd__ClientId: entraPaymentsClientId
        AzureAd__Audience: 'api://${entraPaymentsClientId}'
      }
    : {},
  deploySql && usePayments
    ? { ConnectionStrings__PaymentsSql: sqlConnectionString(sql!.outputs.fqdn, sql!.outputs.paymentsDatabaseName, identity.outputs.paymentsClientId) }
    : {}
)

var shippingSettings = union(
  serviceBaseSettings,
  {
    AZURE_CLIENT_ID: identity.outputs.shippingClientId
    Auth__AllowAnonymousDevMode: string(!shippingEntra)
    Shipping__TableEndpoint: storage.outputs.tableEndpoint
  },
  shippingEntra
    ? {
        AzureAd__TenantId: tenant().tenantId
        AzureAd__ClientId: entraShippingClientId
        AzureAd__Audience: 'api://${entraShippingClientId}'
      }
    : {}
)

// ==================================================================================================== compute
module apiApp 'modules/appservice.bicep' = if (deployAppService) {
  scope: rg
  name: 'api-app-service'
  params: {
    planName: names.appServicePlan
    siteName: names.apiApp
    location: location
    tags: tags
    skuName: appServiceSku
    workspaceId: monitoring.outputs.workspaceId
    identityId: identity.outputs.apiId
    appSettings: apiSettings
    vnetSubnetId: deployNetwork ? network!.outputs.appServiceSubnetId : ''
    frontDoorId: deployFrontDoor ? frontDoor!.outputs.frontDoorId : ''
  }
}

module functionApp 'modules/functionapp.bicep' = if (deployFunctions) {
  scope: rg
  name: 'function-app'
  params: {
    planName: names.functionsPlan
    appName: names.functionApp
    location: location
    tags: tags
    workspaceId: monitoring.outputs.workspaceId
    identityId: identity.outputs.functionsId
    deploymentContainerUrl: storage.outputs.deploymentContainerUrl
    appSettings: functionsSettings
    vnetSubnetId: deployNetwork ? network!.outputs.functionsSubnetId : ''
  }
}

module paymentsApp 'modules/microservice.bicep' = if (usePayments) {
  scope: rg
  name: 'payments-app'
  params: {
    siteName: names.paymentsApp
    location: location
    tags: tags
    planId: apiApp!.outputs.planId
    alwaysOn: appServiceSku != 'F1'
    workspaceId: monitoring.outputs.workspaceId
    identityId: identity.outputs.paymentsId
    appSettings: paymentsSettings
    vnetSubnetId: deployNetwork ? network!.outputs.appServiceSubnetId : ''
    privateEndpointSubnetId: peSubnetId
    privateDnsZoneId: dnsZones.?webApps ?? ''
  }
}

module shippingApp 'modules/microservice.bicep' = if (useShipping) {
  scope: rg
  name: 'shipping-app'
  params: {
    siteName: names.shippingApp
    location: location
    tags: tags
    planId: apiApp!.outputs.planId
    alwaysOn: appServiceSku != 'F1'
    workspaceId: monitoring.outputs.workspaceId
    identityId: identity.outputs.shippingId
    appSettings: shippingSettings
    vnetSubnetId: deployNetwork ? network!.outputs.appServiceSubnetId : ''
    privateEndpointSubnetId: peSubnetId
    privateDnsZoneId: dnsZones.?webApps ?? ''
  }
}

module containerApp 'modules/containerapps.bicep' = if (deployContainerApps) {
  scope: rg
  name: 'container-app'
  params: {
    environmentName: names.containerAppsEnv
    appName: names.containerApp
    location: location
    tags: tags
    workspaceId: monitoring.outputs.workspaceId
    identityId: identity.outputs.apiId
    appSettings: apiSettings
    image: containerImage
    registryServer: needAcr ? registry!.outputs.loginServer : ''
    infrastructureSubnetId: deployNetwork ? network!.outputs.containerAppsSubnetId : ''
  }
}

module aks 'modules/aks.bicep' = if (deployAks) {
  scope: rg
  name: 'aks'
  params: {
    name: names.aks
    location: location
    tags: tags
    nodeSubnetId: deployNetwork ? network!.outputs.aksSubnetId : ''
    apiIdentityName: names.apiIdentity
    acrName: names.acr
    adminPrincipalId: deployerPrincipalId
  }
  dependsOn: [identity, registry]
}

module jumpbox 'modules/jumpbox.bicep' = if (deployNetwork && deployJumpbox) {
  scope: rg
  name: 'jumpbox'
  params: {
    name: names.jumpbox
    location: location
    tags: tags
    subnetId: network!.outputs.vmSubnetId
    vnetId: network!.outputs.vnetId
    bastionSubnetId: network!.outputs.bastionSubnetId
    sshPublicKey: jumpboxSshPublicKey
    loginPrincipalId: deployerPrincipalId
    bastionSku: bastionSku
  }
}

module eventGridSubscription 'modules/eventgrid-subscription.bicep' = if (deployMessaging && deployFunctions && deployEventGridSubscription) {
  scope: rg
  name: 'event-grid-subscription'
  params: {
    systemTopicName: messaging!.outputs.eventGridTopicName
    functionAppId: functionApp!.outputs.id
  }
}

// ==================================================================================================== edge (late: needs the apps)
module frontDoorRoutes 'modules/frontdoor-routes.bicep' = if (deployFrontDoor && deployAppService) {
  scope: rg
  name: 'front-door-routes'
  params: {
    profileName: frontDoor!.outputs.profileName
    endpointName: frontDoor!.outputs.endpointName
    apiHostName: apiApp!.outputs.hostName
    secondaryApiHostName: secondaryApiHostName
    spaHostName: deployStaticWebApp ? staticWebApp!.outputs.hostName : ''
  }
}

module appGateway 'modules/appgateway.bicep' = if (deployAppGateway && deployNetwork && deployAppService) {
  scope: rg
  name: 'app-gateway'
  params: {
    name: names.appGateway
    location: location
    tags: tags
    workspaceId: monitoring.outputs.workspaceId
    subnetId: network!.outputs.appGatewaySubnetId
    backendHostName: apiApp!.outputs.hostName
  }
}

module grafana 'modules/grafana.bicep' = if (deployGrafana) {
  scope: rg
  name: 'grafana'
  params: {
    name: names.grafana
    location: location
    tags: tags
    adminPrincipalId: deployerPrincipalId
  }
}

// ==================================================================================================== outputs
var apiUrl = deployAppService
  ? 'https://${apiApp!.outputs.hostName}'
  : (deployContainerApps ? 'https://${containerApp!.outputs.fqdn}' : '')

output resourceGroupName string = rg.name
output apiUrl string = apiUrl
output apiAppName string = deployAppService ? apiApp!.outputs.name : ''
output functionAppName string = deployFunctions ? functionApp!.outputs.name : ''
output staticWebAppName string = deployStaticWebApp ? staticWebApp!.outputs.name : ''
output spaUrl string = deployFrontDoor
  ? 'https://${frontDoor!.outputs.endpointHostName}'
  : (deployStaticWebApp ? 'https://${staticWebApp!.outputs.hostName}' : '')
output containerAppUrl string = deployContainerApps ? 'https://${containerApp!.outputs.fqdn}' : ''
output acrLoginServer string = needAcr ? registry!.outputs.loginServer : ''
output aksName string = deployAks ? aks!.outputs.name : ''
output keyVaultName string = keyVault.outputs.name
output storageAccountName string = storage.outputs.name
output sqlServerName string = deploySql ? sql!.outputs.serverName : ''
output apiIdentityName string = identity.outputs.apiName
output apiIdentityClientId string = identity.outputs.apiClientId
output functionsIdentityName string = identity.outputs.functionsName
output paymentsAppName string = usePayments ? paymentsApp!.outputs.name : ''
output shippingAppName string = useShipping ? shippingApp!.outputs.name : ''
output paymentsIdentityName string = identity.outputs.paymentsName
output shippingIdentityName string = identity.outputs.shippingName
output appGatewayUrl string = (deployAppGateway && deployNetwork && deployAppService) ? 'http://${appGateway!.outputs.publicHostName}' : ''
output grafanaUrl string = deployGrafana ? grafana!.outputs.url : ''

@description('Written to the SPA\'s config.json by the pipeline (build once, deploy anywhere).')
output spaConfig object = {
  // Behind Front Door the SPA and API share one host name, so the API is same-origin.
  apiBaseUrl: deployFrontDoor ? '' : apiUrl
  entra: {
    clientId: enableEntraAuth ? entraSpaClientId : ''
    tenantId: tenant().tenantId
    apiScope: enableEntraAuth ? 'api://${entraApiClientId}/access_as_user' : ''
  }
  appInsightsConnectionString: monitoring.outputs.appInsightsConnectionString
}

@description('Paste into src/CloudMart.Api/appsettings.Development.json (or user-secrets) to run locally against Azure.')
output localDevelopmentSettings object = {
  Cosmos: { Endpoint: deployCosmos ? cosmos!.outputs.endpoint : '' }
  ConnectionStrings: {
    OrdersSql: deploySql ? 'Server=tcp:${sql!.outputs.fqdn},1433;Database=${sql!.outputs.databaseName};Authentication=Active Directory Default;Encrypt=True;' : ''
  }
  Storage: { BlobEndpoint: storage.outputs.blobEndpoint }
  ServiceBus: { FullyQualifiedNamespace: deployMessaging ? messaging!.outputs.serviceBusFqdn : '' }
  EventHubs: { FullyQualifiedNamespace: deployMessaging ? messaging!.outputs.eventHubsFqdn : '' }
  KeyVault: { Uri: keyVault.outputs.uri }
}
