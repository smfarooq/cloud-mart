// Your environment. Flip switches as you work through docs/learning-path.md, then redeploy:
//   az deployment sub what-if -l eastus2 -f infra/main.bicep -p infra/main.bicepparam
//   az deployment sub create  -l eastus2 -f infra/main.bicep -p infra/main.bicepparam
using 'main.bicep'

param appName = 'cloudmart'
param environmentName = 'dev' // 'dr' in the second-region copy's parameter file (phases 10 and 11)
param location = 'eastus2'
param staticWebAppLocation = 'eastus2'

// az ad signed-in-user show --query "{id:id, upn:userPrincipalName}" -o json
param deployerPrincipalId = '<your-entra-object-id>'
param deployerPrincipalName = '<you@yourtenant.onmicrosoft.com>'
param ownerEmail = '<you@example.com>'
param monthlyBudget = 50

// Phase 2 · Networking
param deployNetwork = false
param enablePrivateEndpoints = false
param deployJumpbox = false
param jumpboxSshPublicKey = ''

// Phase 3 · Compute (App Service + Functions + Static Web App are on from day one)
param deployAppService = true
param deployFunctions = true
param deployStaticWebApp = true
param deployContainerApps = false
param containerImage = ''
param deployAks = false

// Phase 4 · Data
param deployCosmos = false
param cosmosFreeTier = true
param deploySql = false
param deployPostgres = false
param storageSku = 'Standard_LRS'

// Phase 5 · Messaging
param deployMessaging = false
param deployEventGridSubscription = false

// Phase 6 · Security
param enableEntraAuth = false
param entraApiClientId = ''
param entraSpaClientId = ''

// Phase 7 · Observability
param logAnalyticsDailyCapGb = 1
param deployGrafana = false

// Phase 8 · DevOps
param deployAcr = false

// Phase 9 · Governance
param deployGovernance = true

// Phase 10 · Architecture
param deployFrontDoor = false
param frontDoorSku = 'Standard_AzureFrontDoor'
param secondaryApiHostName = ''
param cosmosSecondaryLocation = ''
param deployAppGateway = false
// Needs deployFrontDoor. Static Web Apps Standard (about $9/month): the SPA's own host then refuses direct requests.
param lockStaticWebAppToFrontDoor = false

// Phase 11 · Business continuity (docs/continuity.svg). Geo-redundant SQL backups are on from day one.
param sqlBackupRedundancy = 'Geo'
// COST: about $750/month while it exists. Geo-replicated serverless databases never auto-pause. Drill, then remove it.
param sqlSecondaryLocation = ''
// Only in the phase 10 second copy's parameter file: the first environment's sqlListenerFqdn output (with deploySql = false).
param sharedSqlListenerFqdn = ''
param eventHubsSecondaryLocation = ''
// Set before the first deployment. COST: the App Service plan becomes P1v3 x 2 (about $250/month).
param zoneRedundant = false

// Gap topics (AZ-305 "application architecture")
param deployAppConfig = false
param deployRedis = false
param deployApim = false

// Phase 13 · Hub-and-spoke: a hub VNet with Azure Firewall Basic, and the app subnets' egress routed through it.
// Needs deployNetwork and enablePrivateEndpoints (and deployMessaging for the lab's "break it").
// COST: about $290/month plus per-GB processing, billed every hour it exists. Deploy, do the lab, delete it the same
// day (setting it back to false does not delete the firewall: use a deployment stack or delete it).
param deployFirewall = false
// With the firewall, Service Bus accepts only its egress IP and these: add yours (curl ifconfig.me) for the portal's
// Service Bus Explorer and local runs.
param adminIpAddresses = []

// Phase 14 · Data integration and analytics: a Data Lake Gen2 account and a Data Factory export of the orders.
// Needs deploySql. Data Factory bills per run (cents a month for one nightly copy).
param deployAnalytics = false
// Needs deployAnalytics and deployMessaging. COST: Event Hubs Capture is about $73/month while it is on. Unlike most
// switches, setting it back to false and redeploying does turn it off.
param enableClickstreamCapture = false

// Phase 15 · Migration: a simulated on-premises server in its own resource group (rg-cloudmart-dev-legacy) with the
// old shop's PostgreSQL database and product photos, an Azure Migrate project, and access for the server's identity
// to Blob Storage and (with deployPostgres) PostgreSQL. Needs jumpboxSshPublicKey (any SSH public key).
// COST: about $10/month while the server exists (it shuts down at 19:00 UTC); Azure Migrate is free. Setting it back
// to false deletes nothing: the lab ends by deleting the legacy resource group.
param deployMigrationLab = false
param migrateProjectLocation = 'centralus' // Azure Migrate metadata: centralus or westus2 in the United States

// Phase 16 · Microservices (Payments + Shipping APIs, Durable Functions saga)
param deployPayments = false
param deployShipping = false
// From deploy/entra/setup-service-auth.sh. Empty = the services accept any caller (lab only, like phase 1's API).
param entraPaymentsClientId = ''
param entraShippingClientId = ''
