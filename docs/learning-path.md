# CloudMart learning path: hands-on prep for AZ-305

Fifteen phases: your ten, plus five the exam needs (see [az305-gap-analysis.md](az305-gap-analysis.md)).
Each phase follows the same loop:

1. **Switch it on.** Flip the phase's switch in [`infra/main.bicepparam`](../infra/main.bicepparam) and redeploy.
2. **Click, script, codify.** Do the key task once in the portal (to see the options), once with the CLI (to learn the
   model), then read the Bicep that does it (to know what is really configured).
3. **See it in CloudMart.** The **Platform** page shows which implementation each boundary uses, the hosting model,
   the region and readiness. Every phase changes something you can see.
4. **Break it, then fix it.** Diagnosing is how this sticks, and it is where the "why" questions on the exam come from.
5. **Answer the architect's questions.** AZ-305 is a design exam: "given X, recommend Y". Each phase ends with the
   decisions it tests.

> **Cost discipline.** Prices below are approximate pay-as-you-go list prices. Check the
> [pricing calculator](https://azure.microsoft.com/pricing/calculator/) for your region. Keep the budget alert (on by
> default), and when you finish a session either flip expensive switches back to `false` and use a
> **deployment stack** (phase 8) so the resources are actually deleted, or delete the whole resource group.

---

## Phase 0 · Setup (1 hour)

**Tools:** an Azure subscription you own (trial, Visual Studio credits or pay-as-you-go), the
[Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli), .NET 10 SDK, Node.js 24, Git, VS Code with the
Bicep and C# Dev Kit extensions. Later: a free Azure DevOps organisation.

**Run CloudMart locally with zero Azure resources:**

```bash
dotnet run --project src/CloudMart.Api          # http://localhost:5080
```

```bash
cd src/cloudmart-web && npm install && npm run dev   # http://localhost:5173
```

Browse the shop, place an order (it goes Pending → Confirmed after ~1.5 s in an in-process worker), click **Details**
on a few products (the "Trending" bar fills), and open **Platform**: every boundary says *In-memory* or
*In-process*. That baseline is what each phase replaces.

**Find your ids** (you will need them in `main.bicepparam`):

```bash
az login
az ad signed-in-user show --query "{id:id, upn:userPrincipalName}" -o json
```

---

## Phase 1 · Foundations

**Exam objectives:** management groups / subscriptions / resource groups structure and tagging strategy;
authorising access to Azure resources (RBAC).

### Lab

1. **CLI orientation.**

   ```bash
   az account show -o table
   az account list-locations --query "[?metadata.regionType=='Physical'].{name:name, pair:metadata.pairedRegion[0].name}" -o table
   az group create -n rg-sandbox -l eastus2 --tags environment=dev owner=you
   az provider list --query "[?registrationState=='Registered'].namespace" -o tsv | sort
   ```

   Resource providers must be registered before you can create their resources. ARM registers most of them on first
   use, but register these up front to avoid surprises:
   `az provider register -n Microsoft.App` (repeat for `Microsoft.ContainerService`, `Microsoft.Cdn`,
   `Microsoft.Dashboard`, `Microsoft.ApiManagement`, `Microsoft.Cache`, `Microsoft.AppConfiguration`).

2. **ARM, the control plane.** Create a storage account in `rg-sandbox` in the portal, then *Export template*. Decompile
   it: `az bicep decompile --file template.json`. Every portal click, CLI command and Bicep file becomes the same
   ARM REST call. Delete `rg-sandbox` when done.

3. **First CloudMart deployment.** Fill in the three placeholders in `infra/main.bicepparam`, then:

   ```bash
   az deployment sub what-if -l eastus2 -f infra/main.bicep -p infra/main.bicepparam
   az deployment sub create  -l eastus2 -f infra/main.bicep -p infra/main.bicepparam
   ```

   You get: a resource group, Log Analytics + Application Insights + an alert, two managed identities, Key Vault,
   Storage, App Service (API), Functions (Flex Consumption), Static Web Apps (SPA), two policy assignments and a budget.
   Read `what-if` output carefully every time: it is the plan-before-apply habit.

4. **Deploy the code by hand once** (phase 8 automates it):

   ```bash
   dotnet publish src/CloudMart.Api -c Release -o out/api
   cd out/api && zip -r ../api.zip . && cd ../..
   az webapp deploy -g rg-cloudmart-dev -n <apiAppName output> --src-path out/api.zip --type zip

   cd src/cloudmart-web && npm run build
   az deployment sub show -n main --query properties.outputs.spaConfig.value > dist/config.json
   npx @azure/static-web-apps-cli deploy dist --env production \
     --deployment-token $(az staticwebapp secrets list -n stapp-cloudmart-dev --query properties.apiKey -o tsv)
   ```

   (On Windows, use `Compress-Archive out/api/* out/api.zip` instead of `zip`.) Open the SPA URL. The Platform page now
   says **App Service** with your region and instance id.

5. **RBAC.** Make a custom role that can only restart web apps, and assign it at resource group scope:

   ```json
   {
     "Name": "CloudMart App Restarter",
     "Description": "Restart web apps, nothing else.",
     "Actions": ["Microsoft.Web/sites/read", "Microsoft.Web/sites/restart/action"],
     "AssignableScopes": ["/subscriptions/<subscription-id>"]
   }
   ```

   ```bash
   az role definition create --role-definition @restarter.json
   az role assignment create --assignee <a colleague or test user> --role "CloudMart App Restarter" -g rg-cloudmart-dev
   ```

   Then look at the **data-plane** roles Bicep gave your managed identities (`Storage Blob Data Contributor`,
   `Key Vault Secrets User`...). Owner/Contributor do **not** include data access to blobs, secrets or queues. That
   split comes up on the exam constantly.

6. **Locks.** `az lock create -g rg-cloudmart-dev -n no-delete --lock-type CanNotDelete`, try to delete the storage
   account, then remove the lock. Try a `ReadOnly` lock on the storage account and watch what breaks (anything that
   needs a POST, such as listing keys or creating a user delegation key).

### Break it

Remove your own `Key Vault Secrets Officer` assignment, then try `az keyvault secret show`. You are subscription Owner
and still get 403. Put it back (redeploy).

### Architect's questions

| Requirement | Recommendation |
|---|---|
| Hard isolation, separate billing and quotas per environment or business unit | Separate **subscriptions** |
| Apply the same policy and RBAC across many subscriptions | **Management groups** (up to six levels below the root) |
| Group resources that share a lifecycle | **Resource groups**: deployed, secured and deleted together |
| Prevent accidental deletion of production | **CanNotDelete** lock (and know `ReadOnly`'s side effects) |
| Give an app access to blobs | A **data** role (Storage Blob Data *), never Contributor plus keys |
| Least privilege for a narrow task | **Custom role** at the narrowest scope |

Learn the vocabulary of the **Well-Architected Framework** (reliability, security, cost optimisation, operational
excellence, performance efficiency) and the **Cloud Adoption Framework** (strategy, plan, ready, adopt, govern,
secure, manage). Many exam answers are justified in those terms.

---

## Phase 2 · Networking

**Switches:** `deployNetwork = true`, `deployJumpbox = true` (+ `jumpboxSshPublicKey`).
Leave `enablePrivateEndpoints` off until phase 4: build first, then lock down.

**Cost:** the VNet, NSGs and DNS zones are free or close to it. The jumpbox (B2ats_v2) is a few dollars a month
with auto-shutdown. Bastion **Developer** is free but portal-only and limited to some regions; if your region
rejects it, set `bastionSku = 'Basic'` (≈ $140/month, so delete it after the lab).

### Lab

1. **Read the design** in [`network.bicep`](../infra/modules/network.bicep): one subnet per purpose, and *why* the
   delegations differ (App Service integration → `Microsoft.Web/serverFarms`; Flex Consumption and Container Apps →
   `Microsoft.App/environments`). App Service and Functions are now VNet-integrated (outbound only).
2. **Connect** to the jumpbox through Bastion in the portal using *Microsoft Entra ID* authentication (no password).
   Run `curl -s -H Metadata:true "http://169.254.169.254/metadata/instance?api-version=2021-02-01" | jq .compute`:
   the Instance Metadata Service is also where managed identity tokens come from. If `jq` or `az` is missing,
   cloud-init could not reach the internet: the VM has no public IP and the subnet no NAT gateway. Default outbound
   access is being retired, so explicit outbound (NAT Gateway, Load Balancer outbound rules, Azure Firewall) is a
   design decision you now have to make.
3. **DNS before and after.** On the jumpbox: `nslookup <keyvault-name>.vault.azure.net`. Note the public IP. You will
   repeat this in phase 4 after private endpoints.
4. **NSGs.** `az network nic list-effective-nsg -g rg-cloudmart-dev -n vm-cloudm-jump-nic` shows the default rules
   plus yours. Use *Network Watcher → IP flow verify* to ask "would port 3389 from the internet reach this VM?"
5. **Load Balancer lab.** Run [`deploy/labs/phase2-load-balancer.sh`](../deploy/labs/phase2-load-balancer.sh): two
   small VMs running nginx behind a Standard public Load Balancer with a health probe. Curl it in a loop, stop one VM,
   watch the probe take it out of rotation. Delete with the command at the end of the script.
6. **Peering.** Create `vnet-onprem-sim` (10.30.0.0/16) and peer it with the CloudMart VNet in both directions. Add a
   third VNet peered only to the second, and prove peering is **not transitive**. Hub-and-spoke solves this with a hub
   firewall or a gateway: see phase 13.

### Break it

Add an outbound **Deny** rule for service tag `Storage` (priority 100) to the `vnet-cloudmart-dev-apps-nsg`. The API
keeps running, but `/health/ready` reports `blob-storage` failing and image uploads stop being processed. Read the
error, remove the rule.

### Architect's questions

| Question | Answer |
|---|---|
| Service endpoint or private endpoint? | **Service endpoint**: free, the service keeps its public IP, traffic stays on the backbone, only from that VNet. **Private endpoint**: a private IP in your VNet, reachable from peered VNets and on-premises, blocks data exfiltration to other accounts; costs per endpoint and needs private DNS. |
| NSG or Azure Firewall? | **NSG**: L3/L4 allow/deny on subnets or NICs, free. **Azure Firewall**: central, stateful, FQDN/application rules, threat intelligence, TLS inspection (Premium), shared by many spokes. |
| Rules by role, not IP | **Application security groups** |
| Predictable outbound IPs, no SNAT exhaustion | **NAT Gateway** |
| Admin access without public IPs on VMs | **Azure Bastion** (or Just-in-time VM access in Defender for Cloud) |
| Distribute TCP/UDP within a region | **Azure Load Balancer** (Standard; Basic is retired). Internal or public. |

---

## Phase 3 · Compute

**Already deployed:** App Service (API), Functions (Flex Consumption), Static Web Apps (SPA).
**Switches for this phase:** `deployContainerApps = true`, then optionally `deployAks = true` (+ `deployAcr`).

**Cost:** Container Apps scales to zero (near-free while idle). AKS with one D2s_v5 node is roughly $70/month:
run `az aks stop` whenever you are not using it.

### Lab

1. **App Service scale-out.** Scale the plan to 2–3 instances (`az appservice plan update --number-of-workers 3`).
   On the Platform page, click **Call the API 20 times** and watch requests spread across instance ids.
   Then upgrade to `S1` (`appServiceSku = 'S1'`), add a `staging` deployment slot, deploy to it, and **swap**.
   Add an autoscale rule on CPU (autoscale and slots need Standard or higher).
2. **Functions.** In the portal look at the Flex Consumption plan: instance memory, max instances, the
   `AzureWebJobs.<name>.Disabled` settings that keep the messaging triggers off until phase 5, and the identity-based
   `AzureWebJobsStorage__*` settings (no connection string).
3. **Container Apps.** First deploy with the sample image. Then `deployAcr = true`, build the API image in Azure
   (no local Docker needed):

   ```bash
   az acr build -r <acr-name> -t cloudmart-api:1 -f src/CloudMart.Api/Dockerfile .
   ```

   Set `containerImage = '<acrLoginServer>/cloudmart-api:1'`, redeploy, and `curl https://<containerAppUrl>/api/platform/info`.
   It reports **Container Apps**, a revision and a replica. Watch it scale to zero after a few idle minutes, then
   cold-start on the next request.
4. **AKS.** `deployAks = true`, then follow the header of [`deploy/k8s/cloudmart-api.yaml`](../deploy/k8s/cloudmart-api.yaml).
   Things to notice: you sign in with Entra ID (`kubelogin`), local accounts are disabled, the pod has no secret yet
   reads Cosmos DB and Key Vault via **workload identity**, and the `LoadBalancer` service created a public IP on an
   Azure Load Balancer in the `MC_` resource group. Enable Container Insights with
   `az aks enable-addons -a monitoring -g rg-cloudmart-dev -n aks-cloudmart-dev --workspace-resource-id <workspace id>`.
   Then `az aks stop`.
5. **The one-off job.** `az container create -g rg-cloudmart-dev -n hello --image mcr.microsoft.com/azuredocs/aci-helloworld --restart-policy Never --os-type Linux --cpu 1 --memory 1`, read its logs, delete it.
   That is Azure Container Instances: per-second billing for a single container with no orchestrator.

### Architect's questions

| Requirement | Recommendation |
|---|---|
| Lift-and-shift, full OS control, legacy software | **Virtual machines**; **VM Scale Sets** for elastic fleets |
| Web app or API with minimal ops, slots, easy TLS | **App Service** |
| Event-driven, spiky, pay per execution | **Functions** (Flex Consumption; Premium for always-warm plus VNet; Dedicated on an App Service plan) |
| Microservices in containers, scale to zero, no cluster to run | **Container Apps** |
| Full Kubernetes API, operators, service mesh, platform team | **AKS** |
| One short-lived container, simplest possible | **Container Instances** |
| Large parallel compute or HPC batch jobs | **Azure Batch** (or Container Apps jobs for container batch) |
| Virtual desktops | **Azure Virtual Desktop** |
| Interruptible work at a deep discount | **Spot VMs** / spot node pools |

---

## Phase 4 · Data

**Switches:** `deployCosmos = true`, `deploySql = true`. Optional: `deployPostgres = true`.
Then the hardening pass: `deployNetwork = true` + `enablePrivateEndpoints = true`.

**Cost:** Cosmos DB free tier (1000 RU/s and 25 GB free; one account per subscription. If you have used it, set
`cosmosFreeTier = false` for serverless). SQL serverless auto-pauses after an hour idle, so you pay mostly for storage.
PostgreSQL B1ms is ≈ $15/month. Private endpoints are ≈ $7/month each (this phase creates seven).

### Lab

1. **Deploy and read the readiness probe.** After `az deployment sub create`, Platform shows **Cosmos DB** and
   **Azure SQL Database**. Readiness shows SQL failing with *Login failed for user '<token-identified principal>'*.
   That is correct: Entra authentication worked, but the identity has no database user yet. (If the catalog is
   empty, the Cosmos role assignment hadn't propagated when the API seeded it: restart the API in a few minutes.)
2. **Grant the identities.** Run [`deploy/sql/grant-managed-identities.sql`](../deploy/sql/grant-managed-identities.sql)
   in the portal's query editor (signed in as yourself, the Entra admin). Restart the API
   (`az webapp restart`) so it creates the schema. Readiness goes green. Place orders and query `SELECT * FROM Orders`.
3. **Cosmos DB modelling.** In Data Explorer run `SELECT * FROM c WHERE c.category = 'audio'` and then
   `SELECT * FROM c WHERE c.id = 'fabrikam-studio-mic'`, and compare the **request charge** (RU) of the
   single-partition query with the cross-partition one. In Admin, try to move a product to another category: the API
   refuses, because the partition key is immutable.
4. **Blob Storage.** Upload a product image in Admin. It lands in `product-uploads` through a SAS URL the API signed
   with a *user delegation key*, since the account has shared keys disabled. Nothing attaches it to the product yet:
   that is phase 5's Event Grid. Delete a blob and undelete it (soft delete); open *Versions*; read the lifecycle rules.
5. **PostgreSQL (optional).** `deployPostgres = true` (and `ordersProvider = 'PostgreSql'` if SQL is also on), then
   run [`deploy/postgres/grant-managed-identities.sql`](../deploy/postgres/grant-managed-identities.sql). One EF Core
   model, two engines.
6. **Hardening pass.** `deployNetwork = true`, `enablePrivateEndpoints = true`, redeploy. Now:
   - From the jumpbox, `nslookup <cosmos-account>.documents.azure.com` returns a **10.20.6.x** address.
   - From your laptop, Cosmos Data Explorer and the SQL query editor are blocked (public access is off). Use the jumpbox.
   - The app keeps working, through VNet integration → private endpoint → private DNS.
   - Storage keeps public access **on**, because the browser uploads to it directly. Discuss: is a short-lived,
     write-only, single-blob SAS acceptable, or should uploads go through the API (or Front Door Premium + Private Link)?

### Break it

Delete the `privatelink.documents.azure.com` zone's VNet link. The API now resolves Cosmos to its public IP, which is
blocked, and readiness fails. Fix it by redeploying: Bicep puts back what drifted.

### Architect's questions

| Requirement | Recommendation |
|---|---|
| New cloud app, relational, minimal admin | **Azure SQL Database** |
| Near-100% SQL Server compatibility (SQL Agent, cross-database queries, CLR) | **Azure SQL Managed Instance** |
| OS access or an unsupported feature | **SQL Server on Azure VMs** |
| Many small databases with unpredictable, non-overlapping peaks | **Elastic pool** |
| Intermittent use, tolerate a cold-start delay | **Serverless** compute tier |
| Very large database (100 TB+), fast scaling, read replicas | **Hyperscale** |
| Lowest latency, in-memory OLTP, a free readable secondary | **Business Critical** |
| Open-source engine | **Azure Database for PostgreSQL / MySQL** flexible server |
| Global distribution, single-digit ms, flexible schema | **Cosmos DB**: pick the partition key for even distribution *and* your main query |
| Consistency vs latency | Strong → bounded staleness → **session** (the default) → consistent prefix → eventual |
| Files rarely read after 30 / 90 / 180 days | **Cool / Cold / Archive** tiers + lifecycle rules (Archive needs hours to rehydrate) |
| Analytics over files with folders and ACLs | **Data Lake Storage Gen2** (hierarchical namespace) |
| SMB/NFS shares | **Azure Files** (Azure File Sync for hybrid) |
| Encryption beyond the TDE default | Customer-managed keys in Key Vault; **Always Encrypted** for columns even DBAs can't read |

---

## Phase 5 · Messaging

**Switches:** `deployMessaging = true`. Deploy the Functions code (pipeline or
`az functionapp deployment source config-zip`). **Then** `deployEventGridSubscription = true` and redeploy:
Event Grid checks that the target function exists.

**Cost:** Service Bus Standard ≈ $10/month base; Event Hubs Standard (1 throughput unit) ≈ $22/month;
Event Grid is effectively free at this volume.

### Lab

1. **Asynchronous orders.** Place an order: HTTP 202, *Pending*, then *Confirmed* about 2 seconds later. Platform
   shows **Service Bus**. In Application Insights → Transaction search, open the request: one end-to-end trace spans
   SPA → API → Service Bus → `FulfillOrder`.
2. **Topic filters.** Buy a 4K monitor ($549): the order gets a *High value · review* badge. Only the `high-value`
   subscription received it; open its `$Default` rule (`total > 500`) in the portal.
3. **Poison message.** Tick *Simulate a processing failure* at checkout. The order stays Pending. In *Service Bus
   Explorer* → `orders` → `fulfillment` → **Dead-letter**, find the message with `DeliveryCount = 3` and reason
   `MaxDeliveryCountExceeded`. Re-submitting it fails again (the flag is in the body). What would an operator do?
4. **Duplicate detection.** In Service Bus Explorer, send two messages with the same `MessageId`. Only one arrives.
5. **Event Hubs.** Click *Details* on products. Views flow browser → API → **Event Hubs** → `AggregateProductViews`
   (batched) → Cosmos `product-stats`, and the Trending bar updates. Look at the `functions` consumer group, the two
   partitions, and the checkpoint blobs the Functions host keeps in storage.
6. **Event Grid.** Upload an image in Admin. A few seconds later it appears on the product:
   `BlobCreated` → Event Grid system topic → `ProcessProductImage` → validate → copy to `product-images` → update
   Cosmos. Try a file over 5 MB: the function deletes it. Check the event subscription's delivery metrics.
7. **Design exercise: transactional outbox.** `OrderService` saves the order and *then* publishes. If the publish
   fails, the order is stuck Pending. Design the fix: write an `Outbox` row in the same SQL transaction as the
   order, and let a relay (a timer Function, or change data capture) publish and mark it sent. Stretch goal:
   implement it.

### Architect's questions

| Requirement | Recommendation |
|---|---|
| Business commands that must not be lost: ordering, transactions, DLQ, duplicate detection | **Service Bus** (queues; topics for pub/sub) |
| Simple, huge, cheap queue; no ordering or DLQ guarantees | **Storage queues** |
| React to state changes ("a blob was created"), push delivery, fan-out | **Event Grid** |
| Telemetry or click-streams, millions of events/s, replay, many readers | **Event Hubs** (Kafka-compatible) |
| Ordered processing per customer in Service Bus | **Sessions** |
| Private endpoints, isolation, zones, geo-replication for Service Bus | **Premium** tier |
| Archive the raw stream to a data lake | **Event Hubs Capture** |
| IoT / MQTT clients | **Event Grid namespaces** (MQTT broker) or IoT Hub |

---

## Phase 6 · Security

**Switches:** `enableEntraAuth = true`, `entraApiClientId`, `entraSpaClientId` (after step 1).

### Lab

1. **App registrations** (portal: *Microsoft Entra ID → App registrations*):
   - **CloudMart API**: *Expose an API*, set the Application ID URI to `api://<client-id>`, add scope
     `access_as_user`. *App roles*: add `CloudMart.Admin` (members: users/groups). In *Enterprise applications →
     CloudMart API → Users and groups*, assign yourself the role.
   - **CloudMart SPA**: platform **Single-page application**, redirect URIs `http://localhost:5173` and your SWA URL.
     *API permissions*: add *CloudMart API → access_as_user*.
   - Set the switches and redeploy infra and the SPA (the pipeline writes `config.json`). Locally, add the same values
     to `public/config.json` and an `AzureAd` section in `appsettings.Development.json`.
   - Verify: you must sign in; the Admin tab appears only with the role; `curl` without a token → 401. Paste a token
     into [jwt.ms](https://jwt.ms) and find `aud`, `scp`, `roles` and `oid`.
2. **Managed identities.** Remove the API identity's `Azure Service Bus Data Sender` role. Placing an order now
   fails with an authorisation error. Put it back (redeploy) and note how long RBAC takes to propagate.
3. **Key Vault, two ways.** The API reads `PaymentGateway--ApiKey` through the configuration provider; the Functions
   app reads the same secret through a **Key Vault reference** in an app setting. Confirmed orders show its last four
   characters. Rotate it with `az keyvault secret set`, and compare when each consumer picks up the new value.
4. **Defender for Cloud.** Open *Recommendations* for the resource group (foundational CSPM is free) and fix two of them.
   Optionally enable a paid plan, such as Defender for Storage, for one day:
   `az security pricing create -n StorageAccounts --tier Standard`, then set it back to `Free`.
5. **Identity governance tour.** A Microsoft Entra ID P2 trial is free for 30 days. Create a **Conditional Access**
   policy requiring MFA for *CloudMart SPA* in report-only mode; make yourself **PIM**-*eligible* (not active) for
   Contributor on the resource group; create an **access review** for whoever holds `CloudMart.Admin`.

### Architect's questions

| Requirement | Recommendation |
|---|---|
| App-to-Azure authentication without secrets | **Managed identity**: user-assigned when shared or pre-authorised, system-assigned for one-to-one lifecycle |
| CI/CD to Azure without secrets | **Workload identity federation** (OIDC) |
| Pods to Azure without secrets | **AKS workload identity** |
| Secrets, keys and certificates | **Key Vault** (RBAC mode); **Managed HSM** for single-tenant FIPS 140-3 Level 3 |
| Partners sign in with their own identity | **Entra External ID B2B** (guests) |
| Customers sign up for your app | **Entra External ID** for customers (Azure AD B2C is closed to new customers) |
| MFA or block by risk, location or device | **Conditional Access** (Entra ID P1); risk-based policies need P2 |
| Just-in-time admin rights | **Privileged Identity Management** (P2) |
| Periodic recertification of access | **Access reviews** / entitlement management (P2 / ID Governance) |
| Find misconfigurations, protect workloads | **Defender for Cloud** (CSPM + workload plans) |

---

## Phase 7 · Observability

**Switch (optional):** `deployGrafana = true` (Standard tier ≈ $60+/month; enable, learn, disable).

### Lab

1. **Application Insights.** *Application map* (SPA → API → Cosmos / SQL / Service Bus → Functions), *Live metrics*,
   *Failures* (Admin → Chaos → *Throw exception*), *Performance* (*3 s latency*), and *Transaction search* for an
   order id.
2. **KQL.** Run the queries in [`docs/kql/cloudmart.kql`](kql/cloudmart.kql) in Log Analytics: slowest operations,
   orders per minute from custom metrics, Key Vault audit (who read the secret), dead-letter counts, and more.
3. **Alerts.** Throw six exceptions within five minutes: the log search alert from
   [`monitoring.bicep`](../infra/modules/monitoring.bicep) emails you through the action group. Then add a
   *metric* alert on the Service Bus dead-letter count yourself.
4. **Routing logs.** Every module has a diagnostic setting to the workspace. Add a second one for Key Vault that
   archives to a storage account:
   `az monitor diagnostic-settings create --resource <kv-id> -n archive --storage-account <st-id> --logs '[{"categoryGroup":"audit","enabled":true}]'`.
   Destinations to know: Log Analytics (query), Storage (cheap archive), Event Hubs (stream to a SIEM or third party).
5. **Grafana.** Open the Managed Grafana URL. The Azure Monitor data source is pre-wired through Grafana's managed
   identity. Explore the built-in Azure dashboards, then build a panel from the `cloudmart.orders.placed` metric.
6. **Network Watcher.** *Connection troubleshoot* from the jumpbox to the SQL private endpoint on port 1433.

### Architect's questions

| Requirement | Recommendation |
|---|---|
| Collect VM / Arc server logs | **Azure Monitor Agent** + **data collection rules** (the old Log Analytics agent is retired) |
| Collect platform logs from PaaS | **Diagnostic settings** (Azure Policy can enforce them at scale) |
| Long, cheap retention | Workspace long-term retention, or archive to Storage |
| Send to Splunk / Sentinel / third party | Diagnostic settings → **Event Hubs** |
| Many teams, data residency, separate access | Multiple workspaces, or one workspace with resource-context RBAC |
| SIEM / SOAR | **Microsoft Sentinel** on the workspace |
| Dashboards | **Workbooks** (Azure-native), **Managed Grafana** (multi-source, Grafana skills), Azure dashboards (simple) |
| Is it Azure or my app? | **Service Health** (platform incidents) and **Resource Health** (this resource) |

---

## Phase 8 · DevOps

**Switch:** `deployAcr = true` for the container path.

### Lab

1. **Azure DevOps.** Create an organisation and a project, push this repository, and create the service connection
   from the header of [`pipelines/azure-pipelines.yml`](../pipelines/azure-pipelines.yml) using **workload identity
   federation**: no client secret exists to leak or rotate. It needs rights to create role assignments: Owner, or
   Contributor plus *Role Based Access Control Administrator* (constrained to the roles the template assigns).
2. **Environment and approval.** Create the `cloudmart-dev` environment and add an *Approvals* check. Run the
   pipeline: Build (tests, packages, Bicep lint) → Infrastructure (what-if, then deploy) → Applications (zip
   deploy, SPA with its per-environment `config.json`, container image via ACR Tasks).
3. **Deployment stacks.** Replace `az deployment sub create` with a stack:

   ```bash
   az stack sub create -n cloudmart-dev -l eastus2 -f infra/main.bicep -p infra/main.bicepparam \
     --action-on-unmanage deleteAll --deny-settings-mode none
   ```

   Now setting a switch to `false` really **deletes** that resource on the next run. That is the best cost control
   in this whole lab, and the modern answer to "Blueprints".
4. **Template specs.** `az ts create -g rg-shared -n cloudmart -v 1.0 -f infra/main.bicep`: a versioned, RBAC-shared
   template other teams can deploy without access to your repository.
5. **Blue/green.** With `appServiceSku = 'S1'`, deploy to a `staging` slot, warm it up, swap. For Container Apps,
   switch to `activeRevisionsMode: 'Multiple'` and split traffic 90/10 between revisions.

### Architect's questions

| Requirement | Recommendation |
|---|---|
| Azure-native IaC, day-zero support for new APIs | **Bicep** (Terraform when you are multi-cloud or already invested) |
| Preview changes before applying | `what-if` (Bicep) / `plan` (Terraform) |
| Delete what you removed from the template; protect against portal edits | **Deployment stacks** with deny settings |
| Share approved templates across teams | **Template specs** (or a private Bicep registry) |
| Pipeline auth to Azure | **Workload identity federation** (Azure Pipelines and GitHub Actions both support OIDC) |
| Zero-downtime release | App Service **slots**, Container Apps **revisions**, AKS rolling / blue-green |
| Private image registry with geo-replication and private endpoints | **ACR Premium** |

---

## Phase 9 · Governance

**Already deployed** (`deployGovernance = true`): an *allowed locations* policy (Deny), an *inherit environment tag*
policy (Modify, with a remediation identity) and a monthly budget with alerts.

### Lab

1. **Policy in action.** Try `az storage account create -g rg-cloudmart-dev -n stdenytest$RANDOM -l westus3`: it is
   denied. Create any small resource without tags: the `environment` tag appears (Modify). For resources that existed
   before the assignment, run a remediation task:
   `az policy remediation create -g rg-cloudmart-dev -n tag-fix --policy-assignment cloudmart-inherit-env-tag`.
2. **Initiatives and compliance.** Assign the *Microsoft cloud security benchmark* initiative (Audit) at subscription
   scope; read the compliance blade a few hours later. Then open *Defender for Cloud → Regulatory compliance*.
3. **Management groups.** Create `mg-cloudmart` → `mg-cloudmart-nonprod`, move your subscription under it (if your
   tenant allows), and re-assign the allowed-locations policy at management-group scope.
4. **Resource Graph.** `az extension add -n resource-graph`, then query across subscriptions:

   ```bash
   az graph query -q "Resources | where isnull(tags['environment']) | project name, type, resourceGroup"
   az graph query -q "Resources | where properties.publicNetworkAccess =~ 'Enabled' | project name, type"
   ```

5. **Cost Management.** *Cost analysis* grouped by the `application` tag and by service; create a scheduled export to
   storage; read the **Advisor** cost and reliability recommendations; compare reservations, savings plans and
   Azure Hybrid Benefit for a hypothetical always-on SQL workload.

### Architect's questions

| Requirement | Recommendation |
|---|---|
| Control **what** can be deployed | **Azure Policy** (RBAC controls **who**) |
| Block / report / auto-fix / deploy missing companion resources | `Deny` / `Audit` / `Modify` / `DeployIfNotExists` |
| Group policies and assign them once | **Initiative** (policy set) |
| Enterprise-scale structure, governance and networking from day one | **Azure landing zones** (Cloud Adoption Framework) |
| Package governance + resources for repeatable environments | **Template specs + deployment stacks** (Azure Blueprints is deprecated) |
| Inventory and compliance queries across subscriptions | **Azure Resource Graph** |
| Lower the cost of steady-state compute | **Reservations** (specific SKU/region) vs **savings plans** (flexible $/hour commitment), **Azure Hybrid Benefit** |

---

## Phase 10 · Architecture (edge, WAF, multi-region)

**Switches:** `deployFrontDoor = true`. Optional: `deployAppGateway = true` (needs `deployNetwork`; ≈ $0.45/hour
fixed, so deploy, test and remove the same day).

### Lab

1. **Front Door.** The SPA and API now share one host name (`/api/*` → App Service, `/*` → Static Web Apps), so there
   is no CORS. Product images are cached at the edge: check the `x-cache` response header (`TCP_HIT`).
2. **Origin lock.** Open the App Service host name directly: **403**. Only traffic that carries *your* profile's
   `X-Azure-FDID` header from the `AzureFrontDoor.Backend` service tag gets in.
3. **WAF.** Hammer the API: `for i in $(seq 400); do curl -s -o /dev/null -w "%{http_code}\n" https://<fd>/api/products; done | sort | uniq -c`.
   The rate-limit rule starts blocking. With `Premium_AzureFrontDoor`, the managed Default Rule Set also blocks
   `?q=1' OR '1'='1`. Standard has custom rules only.
4. **Application Gateway.** `curl http://<appGatewayUrl>/api/platform/info`, then send a SQL-injection query string
   and find the matched rule in the WAF logs (`AzureDiagnostics | where Category == "ApplicationGatewayFirewallLog"`).
   The policy is in *Detection* mode: switch it to *Prevention*.
5. **Active/passive across regions.** Deploy a second copy: a second parameter file with
   `environmentName = 'dr'`, `location = 'centralus'`, `deployFrontDoor = false`. Put its API host name in
   `secondaryApiHostName` of the first environment. Stop the primary web app: within a couple of probe intervals Front
   Door fails over, and the Platform page shows the other region. Data stays in the primary region until phase 11.

### Architect's questions

| Traffic | Scope | Choose |
|---|---|---|
| HTTP(S), global users, WAF, CDN, fast failover | Global | **Front Door** |
| Any protocol, DNS-level routing (priority, weighted, performance, geographic) | Global | **Traffic Manager** |
| HTTP(S), regional, L7 routing, WAF, private backends in a VNet | Regional | **Application Gateway** |
| TCP/UDP, regional, ultra-low latency | Regional | **Load Balancer** |
| Global HTTP edge **and** private regional backends | Both | Front Door Premium (Private Link origins), or Front Door → Application Gateway |

---

## Phase 11 · Business continuity (new: 15–20% of the exam)

**Switches:** `storageSku = 'Standard_RAGZRS'`, `cosmosSecondaryLocation = 'centralus'` (free-tier/provisioned mode).

### Lab

1. **Write the targets first.** Orders: RPO 5 minutes, RTO 1 hour. Catalog: RPO 1 hour, RTO 15 minutes. Images:
   RPO 1 day. Every design choice below must satisfy a line in that table.
2. **SQL auto-failover group.** Create a secondary server in the paired region and a failover group:

   ```bash
   az sql server create -g rg-cloudmart-dev -n sql-cloudmart-dr-<x> -l centralus --enable-ad-only-auth \
     --external-admin-principal-type User --external-admin-name <you> --external-admin-sid <your-object-id>
   az sql failover-group create -g rg-cloudmart-dev -s <primary-server> -n fog-cloudmart-<x> \
     --partner-server sql-cloudmart-dr-<x> --add-db cloudmart --failover-policy Automatic
   ```

   Point `ConnectionStrings__OrdersSql` at the listener `fog-cloudmart-<x>.database.windows.net`, then
   `az sql failover-group set-primary` on the secondary and watch the app reconnect. Delete it afterwards (the
   secondary database is billed).
3. **Cosmos DB multi-region.** With the secondary region added, run *Service-managed failover* in the portal. Discuss
   single-write versus multi-write regions and how the consistency level affects RPO.
4. **Storage.** With RA-GZRS, read from `https://<account>-secondary.blob.core.windows.net`, check the
   **Last Sync Time**, and read how customer-initiated account failover works.
5. **Azure Backup.** Create a Recovery Services vault, back up the jumpbox VM, restore a single file, and look at soft
   delete and immutable vaults. Create a **Backup vault** and enable operational backup for the blob containers.
6. **Azure Site Recovery.** Replicate the jumpbox to another region, run a **test failover** into an isolated VNet,
   then clean up the test.
7. **Point-in-time restore.** `az sql db restore --dest-name cloudmart-pitr --time <UTC 10 minutes ago>`;
   restore a Cosmos container from continuous backup.

### Architect's questions

| Requirement | Recommendation |
|---|---|
| Survive a datacentre failure | **Availability zones** (99.99% VM SLA) |
| Survive rack / update failures where zones are unavailable | **Availability sets** (99.95%) |
| Survive a region failure | Multi-region + replication: **SQL failover groups**, **Cosmos multi-region**, **GZRS/RA-GZRS**, **ASR** for VMs |
| Recover from deletion, corruption or ransomware | **Backup** (not replication: replication copies the corruption too), soft delete, immutability, PITR |
| One connection string that survives a SQL failover | **Auto-failover group** listener |
| Readable secondary database for reporting | Active geo-replication / failover-group read-only listener, or Business Critical read scale-out |
| Long-term (years) database backups for compliance | SQL **long-term retention** |
| VM DR with a minutes-level RPO | **Azure Site Recovery** |

---

## Phase 12 · Application integration (new)

**Switches:** `deployAppConfig = true`, `deployRedis = true` (≈ $15+/month), `deployApim = true` (Consumption tier).

### Lab

1. **App Configuration and feature flags.**

   ```bash
   az appconfig kv set --auth-mode login -n <appconfig> --key CloudMart:BannerMessage --value "Flash sale today" -y
   az appconfig feature set --auth-mode login -n <appconfig> --feature Trending -y      # created disabled
   az appconfig feature enable --auth-mode login -n <appconfig> --feature Trending -y
   ```

   Within ~30 seconds the banner appears. Trending is on by default *until a flag named `Trending` exists*; from then
   on the flag decides, so it vanishes when you create the (disabled) flag and returns when you enable it. No
   redeploy, no restart.
2. **Azure Managed Redis.** With `Redis__Endpoint` set, HybridCache uses Redis as a shared L2 cache behind each
   instance's in-memory L1. Look at the cache-hit metrics; scale the API to three instances and reason about why
   L2 matters there. Compare three cache layers: in-process, Redis, and the Front Door edge.
3. **API Management.** Import the API from its OpenAPI document:

   ```bash
   az apim api import -g rg-cloudmart-dev --service-name <apim> --api-id cloudmart --path cloudmart \
     --specification-format OpenApiJson --specification-url https://<api-host>/openapi/v1.json \
     --service-url https://<api-host>
   ```

   Add policies: `rate-limit-by-key`, `cache-lookup`/`cache-store` on `GET /api/products`, and `validate-jwt` once
   Entra ID is on. Call it with a subscription key through the gateway URL.
4. **Logic Apps (design).** Replace `NotifyCustomer` with a Consumption Logic App triggered by the `notifications`
   subscription and sending email through a connector. When does low-code win over a Function?

### Architect's questions

| Requirement | Recommendation |
|---|---|
| Publish, secure, throttle and version APIs for partners | **API Management** (Consumption: serverless; v2 tiers: production with VNet integration; Premium: multi-region, full VNet injection) |
| Shared, low-latency cache across instances | **Azure Managed Redis** |
| Cache static or semi-static HTTP responses near users | **Front Door** caching |
| Central settings and feature flags, dynamic refresh | **App Configuration** (secrets stay in Key Vault, referenced from App Configuration) |
| Integration workflows with SaaS connectors | **Logic Apps** |
| Code-first stateful orchestration | **Durable Functions** |

---

## Phase 13 · Hybrid networking and identity (new: design-first)

Real VPN and ExpressRoute need an on-premises device or a provider circuit, so this phase is mostly design. The one
hands-on taste: deploy a VPN Gateway (`VpnGw1`, ≈ $140/month, 30–45 minutes to create) for **one day** and connect
the CloudMart VNet to `vnet-onprem-sim` VNet-to-VNet, or your laptop point-to-site with Entra ID authentication.

**Draw** hub-and-spoke for CloudMart: a hub VNet with Azure Firewall, VPN/ExpressRoute gateway and Bastion; CloudMart
as a spoke; UDRs forcing spoke egress through the firewall; a **Private DNS Resolver** in the hub so on-premises can
resolve private endpoint names. Then redraw it with **Virtual WAN**.

| Requirement | Recommendation |
|---|---|
| Encrypted tunnel over the internet, quick to set up | **Site-to-site VPN** (route-based, active-active, zone-redundant SKUs) |
| Individual remote users to the VNet | **Point-to-site VPN** (Entra ID auth with OpenVPN) |
| Private, predictable, high bandwidth, not over the internet | **ExpressRoute** (+ VPN as backup); **Global Reach** links on-prem sites; **FastPath** bypasses the gateway |
| Many branches and regions, managed transit | **Virtual WAN** |
| On-prem must resolve `privatelink.*` names | **Azure DNS Private Resolver** + conditional forwarders |
| Sync on-prem AD users to Entra ID | **Entra Cloud Sync** (light, multi-forest) or **Connect Sync** (advanced scenarios); **password hash sync** is the recommended sign-in method |
| Users must authenticate against on-prem DCs | Pass-through authentication (or federation for third-party MFA/smartcards) |
| Publish an on-prem web app without a VPN | **Entra Application Proxy** (or Entra Private Access) |
| Legacy LDAP/Kerberos in Azure without DCs | **Entra Domain Services** |
| Manage on-prem / other-cloud servers and Kubernetes from Azure | **Azure Arc** (try it: install the Arc agent on a local Hyper-V VM) |

---

## Phase 14 · Data integration and analytics (new: light hands-on)

**Cheap lab:** create a Data Factory (pay per activity run), give its managed identity `db_datareader` on the SQL
database and Blob Data Contributor on a Data Lake Gen2 account, and build a pipeline that copies `Orders` to Parquet
nightly. **Free lab:** start a Microsoft Fabric trial, **mirror** the Azure SQL database into OneLake and build a
Power BI report on orders, with no ETL code.

| Requirement | Recommendation |
|---|---|
| Orchestrate ETL/ELT across 90+ sources | **Azure Data Factory** (or Data Factory in Fabric) |
| Unified SaaS analytics: lakehouse, warehouse, real-time, BI | **Microsoft Fabric** |
| Spark-heavy data engineering and ML | **Azure Databricks** |
| SQL over a lake, existing dedicated pools | **Synapse Analytics** (new builds lean to Fabric) |
| Real-time SQL over streams | **Stream Analytics** (or Fabric Real-Time Intelligence) |
| Land raw events in the lake | **Event Hubs Capture** → Data Lake Gen2 |
| Log/time-series exploration at scale | **Azure Data Explorer** |
| Catalogue, lineage, classification | **Microsoft Purview** |

---

## Phase 15 · Migration (new: design + small taste)

**Taste:** `azcopy login` (Entra ID) then `azcopy copy ./images "https://<account>.blob.core.windows.net/product-images" --recursive`.
If you have Hyper-V, deploy the **Azure Migrate** appliance against a local VM and read the assessment and
dependency map.

Know the CAF **Migrate** flow (assess → migrate → optimise → secure and manage) and the **Rs**: rehost, refactor,
rearchitect, rebuild, replace, retire/retain. CloudMart itself is a "rebuild" of a hypothetical on-premises shop:
which tier would you **rehost** first to hit a datacentre-exit deadline?

| Requirement | Recommendation |
|---|---|
| Discover and assess servers, databases, web apps; business case | **Azure Migrate** |
| Rehost VMs with minimal downtime | Azure Migrate server migration (built on ASR replication) |
| SQL Server → Azure SQL MI / DB, online with minimal downtime | **Azure Database Migration Service** (online mode) |
| Open-source databases | DMS / native tools (`pg_dump`, replication) to flexible server |
| Tens of TB, slow link | **Data Box** (offline; Data Box Heavy for petabytes) |
| Ongoing file-server sync | **Azure File Sync** |
| Large online copies, NAS shares | **AzCopy**, **Storage Mover** |
| Lots of legacy .NET web apps | App Service migration assistant / Azure Migrate web app assessment |

---

## Exam strategy

- Take the free [Microsoft practice assessment](https://learn.microsoft.com/credentials/certifications/exams/az-305/practice/assessment?assessment-type=practice&assessmentId=15)
  now for a baseline, and again before booking.
- Each "Architect's questions" table above is a flashcard deck: cover the right column and answer aloud, *with the reason*.
- Read 3–4 [Azure Architecture Center](https://learn.microsoft.com/azure/architecture/) reference architectures end
  to end, such as the baseline zone-redundant web app, AKS baseline and multi-region App Service, and map each box
  to a CloudMart phase.
- Case studies: read the requirements twice and underline the constraints (cost, "minimise administrative effort",
  RPO/RTO, compliance). The constraint usually decides between two technically valid answers.
- AZ-305 requires AZ-104 for the Solutions Architect Expert certification, which you already have.
