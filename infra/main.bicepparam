// Your environment. Flip switches as you work through docs/learning-path.md, then redeploy:
//   az deployment sub what-if -l eastus2 -f infra/main.bicep -p infra/main.bicepparam
//   az deployment sub create  -l eastus2 -f infra/main.bicep -p infra/main.bicepparam
using 'main.bicep'

param appName = 'cloudmart'
param environmentName = 'dev'
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

// Gap topics (AZ-305 "application architecture")
param deployAppConfig = false
param deployRedis = false
param deployApim = false

// Phase 13 · Hub-and-spoke: a hub VNet with Azure Firewall Basic, and the app subnets' egress routed through it.
// Needs deployNetwork and enablePrivateEndpoints (and deployMessaging for the lab's "break it").
// COST: about $290/month plus per-GB processing, billed every hour it exists. Deploy, do the lab, delete it the same
// day (setting it back to false does not delete the firewall: use a deployment stack or delete it).
param deployFirewall = false

// Phase 16 · Microservices (Payments + Shipping APIs, Durable Functions saga)
param deployPayments = false
param deployShipping = false
// From deploy/entra/setup-service-auth.sh. Empty = the services accept any caller (lab only, like phase 1's API).
param entraPaymentsClientId = ''
param entraShippingClientId = ''
