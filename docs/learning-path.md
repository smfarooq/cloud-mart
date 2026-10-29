# CloudMart learning path: hands-on prep for AZ-305

Sixteen phases: your ten, five more the exam needs (see [az305-gap-analysis.md](az305-gap-analysis.md)), and a
microservices phase that splits checkout into a Payments API, a Shipping API and a Durable Functions saga.
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
| Rules by role, not IP | **Application security groups** (CloudMart puts Cosmos DB's private endpoint in one, so a single rule can open direct mode's ports to it alone) |
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
   - `pe-nsg` lets in only the app subnets (443, 1433, 5432, 5671-5672) and the jumpbox (admin ports), and denies the
     rest. Two services needed more thought ([network.bicep](../infra/modules/network.bicep)):
     - **SQL** uses the **Proxy** connection policy, so every connection stays on 1433. Redirect would be faster, but it
       needs 1433-65535 open to the endpoint.
     - **Cosmos DB's** SDK defaults to *direct* mode, which reaches replicas on ports anywhere in 0-65535 through a
       private endpoint. Its endpoint sits in an **application security group**, and one rule opens every port to that
       group only.
   - Storage keeps public access **on**, because the browser uploads to it directly. Discuss: is a short-lived,
     write-only, single-blob SAS acceptable, or should uploads go through the API (or Front Door Premium + Private Link)?

### Break it

- **Unlink a DNS zone.** Delete the `privatelink.documents.azure.com` zone's VNet link. The API now resolves Cosmos DB
  to its public IP, which is blocked, and readiness fails. Fix it by redeploying: Bicep puts back what drifted.
- **Close Cosmos DB's ports.** Delete `pe-nsg`'s `AllowAppsToCosmosDirectMode` rule. Within a minute the catalog fails
  with **503**s, because direct mode can't reach the replicas, while SQL and Key Vault keep working. Redeploy to put
  the rule back. The alternative is *gateway* mode (`ConnectionMode.Gateway`): 443 only, at the cost of an extra hop
  on every request.

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
Event Grid is effectively free at this volume. With `enablePrivateEndpoints` on from phase 4, Event Hubs also gets a
private endpoint (≈ $7/month) and loses its public access. Service Bus Standard can't have one, so it stays public.

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
   - **Dead letters.** Event Grid retries a failed delivery for up to an hour. After that it doesn't drop the event:
     it writes it as JSON to the `eventgrid-deadletter` container, with the reason and the last error. Stop the
     Functions app (`az functionapp stop`) and upload an image. A stopped app answers 403, which Event Grid doesn't
     retry, so the event is dead-lettered within a few minutes and the *Event Grid dead letters* alert emails you
     (phase 7). Start the app again and replay the event by uploading the image again. The original stays in
     `product-uploads` until the lifecycle rule removes it a day later.
7. **What's private and what isn't** (with `enablePrivateEndpoints` on). From the jumpbox,
   `nslookup <event-hubs-namespace>.servicebus.windows.net` returns a **10.20.6.x** address from the
   `privatelink.servicebus.windows.net` zone. The same lookup for the Service Bus namespace returns a public IP:
   Standard has no private endpoints. Both still accept only Entra ID, and the apps reach both through VNet
   integration. Event Grid is the third case: Storage hands it events inside Azure, but it *pushes* them to the
   Function App's public endpoint, because push delivery can't reach a private endpoint. Discuss what "no public
   endpoints anywhere" would cost: Service Bus Premium (≈ $680/month per messaging unit) with a private endpoint, and
   Event Grid delivering to a Storage queue or Service Bus that the function reads through a private endpoint.
8. **Design exercise: transactional outbox.** A database transaction can't include a Service Bus send. Save the order
   and *then* publish (a "dual write"), and a failed publish leaves the order Pending. A client retry with the same
   `Idempotency-Key` (phase 16) could publish again, but a client that gives up leaves it stuck. Design the fix before
   you read CloudMart's: write an `Outbox` row in the same transaction as the order, and let a relay publish it and
   mark it sent. Decide:
   - where the relay runs: a timer Function, a background service in the API, or change data capture;
   - how two relays avoid taking the same row;
   - what happens when a relay dies between publishing and marking the row sent;
   - what a client retry of a Pending order should do now.

   **Then compare** with the reference implementation:
   - [OrderService.cs](../src/CloudMart.Core/Services/OrderService.cs) writes the order and its `OrderPlaced` row
     in one `SaveChanges`, then wakes the relay. The checkout never waits for Service Bus. A retry of a Pending order
     only makes sure the row exists.
   - [OutboxRelay.cs](../src/CloudMart.Core/Outbox/OutboxRelay.cs) is a `BackgroundService` in the API, not a timer
     Function, for two reasons:
     - Until this phase the event goes to the in-process worker, which only the API process can reach.
     - It runs only when there is work: at startup, when an order is placed, and when a retry is due. A timer polling
       every few seconds would keep a serverless SQL database from ever auto-pausing.
   - [OrdersDb.cs](../src/CloudMart.Core/Azure/OrdersDb.cs) has the `OutboxMessages` DDL and the claim. One statement
     takes a batch of due rows and leases them: `UPDATE ... OUTPUT` with `READPAST` on SQL Server, `FOR UPDATE SKIP
     LOCKED` on PostgreSQL. The lease pushes the row's `NextAttemptUtc` forward, like a queue's visibility timeout.
     Failed publishes back off: 5 s, 10 s, 20 s, 40 s, then every minute.
   - Delivery is at least once. A relay that dies after publishing leaves the row unsent, so the row goes out again
     with the same `MessageId` once its lease ends. Duplicate detection drops the copy, and the saga ignores orders
     that aren't Pending.
   - The row carries the checkout's trace context, so step 1's end-to-end trace still runs through the relay.
9. **Watch the outbox catch up** (needs the orders database from phase 4). Stop the `orders` topic from accepting
   messages:

   ```bash
   az servicebus topic update -g rg-cloudmart-dev --namespace-name <service-bus-namespace> -n orders --status SendDisabled
   ```

   Place an order. You still get **202** and *Pending*, with no error: the checkout never talks to Service Bus. Run
   this in the query editor a few times (on PostgreSQL, put the names in double quotes):

   ```sql
   SELECT Id, Attempts, NextAttemptUtc, LastError FROM OutboxMessages WHERE SentUtc IS NULL;
   ```

   `Attempts` climbs as the relay backs off, and `LastError` says the topic is disabled. The API logs a warning for
   each attempt (*Could not publish outbox message*). Re-enable the topic:

   ```bash
   az servicebus topic update -g rg-cloudmart-dev --namespace-name <service-bus-namespace> -n orders --status Active
   ```

   Within a minute the relay's next attempt gets through, `SentUtc` fills in, and the order confirms. In the order's
   trace, the gap between the request and the `OutboxRelay` span that finally sent it is the outage.

### Architect's questions

| Requirement | Recommendation |
|---|---|
| Business commands that must not be lost: ordering, transactions, DLQ, duplicate detection | **Service Bus** (queues; topics for pub/sub) |
| Simple, huge, cheap queue; no ordering or DLQ guarantees | **Storage queues** |
| React to state changes ("a blob was created"), push delivery, fan-out | **Event Grid** |
| Telemetry or click-streams, millions of events/s, replay, many readers | **Event Hubs** (Kafka-compatible) |
| Ordered processing per customer in Service Bus | **Sessions** |
| Private endpoints, isolation, zones, geo-replication for Service Bus | **Premium** tier |
| Event Hubs reachable only from your VNet | **Standard** (or higher) + private endpoint, public network access disabled |
| Event Grid delivery with no public endpoint on the handler | Deliver to a **Storage queue** or **Service Bus** (managed identity), then pull |
| Archive the raw stream to a data lake | **Event Hubs Capture** |
| IoT / MQTT clients | **Event Grid namespaces** (MQTT broker) or IoT Hub |
| Save state and publish an event without losing either, with no distributed transaction | **Transactional outbox**: the event is a row in the same database transaction, and a relay publishes it at least once. Consumers de-duplicate: Service Bus **duplicate detection** and idempotent handlers. To skip writing a relay, use **change data capture** on the table, or the Cosmos DB **change feed** |

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
   The secret also has an **expiry date**: 90 days from each deployment (`secretValidityDays` in
   [keyvault.bicep](../infra/modules/keyvault.bicep)). Expiry doesn't block reads; it's a promise to rotate.
   - Key Vault publishes `Microsoft.KeyVault.SecretNearExpiry` to Event Grid 30 days before the date. Subscribe a
     Function or a Logic App that rotates the secret.
   - Assign the built-in policy *Key Vault secrets should have an expiration date* to catch secrets that never expire.
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
3. **Alerts.** Exceptions are only one symptom. Six alert rules email you through one action group, each defined
   next to the resource it watches:

   | Alert | Fires when | Kind | Defined in |
   |---|---|---|---|
   | Exception spike | More than 5 server exceptions in 5 minutes | Log search | [`monitoring.bicep`](../infra/modules/monitoring.bicep) |
   | Order needs manual review | A refund failed, or a charge timed out and may have gone through | Log search | [`monitoring.bicep`](../infra/modules/monitoring.bicep) |
   | Service Bus dead letters | Any topic has a dead-lettered message | Metric | [`messaging.bicep`](../infra/modules/messaging.bicep) |
   | Service Bus backlog | More than 100 active messages for 15 minutes | Metric | [`messaging.bicep`](../infra/modules/messaging.bicep) |
   | Event Grid dead letters | An upload event was dead-lettered | Metric | [`eventgrid-subscription.bicep`](../infra/modules/eventgrid-subscription.bicep) |
   | Cosmos DB throttling | More than 10 HTTP 429s in 5 minutes | Metric | [`cosmos.bicep`](../infra/modules/cosmos.bicep) |

   Fire three of them:
   - Throw six exceptions with Admin → Chaos.
   - Dead-letter an order with phase 5's *Simulate a processing failure*.
   - In phase 16, set `Chaos__FailureRate = 1` on the Payments app and place an order. The charge fails after its
     retries, and the order is flagged for review.

   Metric alerts are *stateful*: the dead-letter alert stays fired until the queue is empty. Resubmit or purge the
   message in Service Bus Explorer and it resolves on its own. Log search alerts fire once per evaluation that matches.
   Cost: about $1.50/month for each 5-minute log search alert and $0.10/month per metric time series, so roughly
   $4/month for all six.
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
| Alert on a platform metric, near real time, cheaply | **Metric alert** (stateful: fires once, resolves on its own) |
| Alert on anything you can query, including app logs and business events | **Log search alert** (KQL; priced per rule by evaluation frequency) |
| Know about failures before customers do | Alert on symptoms across the flow: dead letters, backlog, throttling, failed compensations, not just exceptions |

---

## Phase 8 · DevOps

**Switch:** `deployAcr = true` for the container path.

**The picture:** [operations.svg](operations.svg) ([PNG](operations.png)) shows the pipeline's stages, its identity and
approval, where deployment outputs go, schema delivery, and how to roll back each service.

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

   The SPA's own host, `*.azurestaticapps.net`, still answers directly and skips the WAF. Set
   `lockStaticWebAppToFrontDoor = true`. That moves Static Web Apps to Standard (about $9/month), and the pipeline
   writes a `forwardingGateway` block into `staticwebapp.config.json` with your Front Door ID and host. The SPA's
   host now answers **403** too. Free can't do this.
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
   Then give the second copy `deploySql = false` and the first environment's `sqlListenerFqdn` output as
   `sharedSqlListenerFqdn`, so it works on the same replicated databases.

### Architect's questions

| Traffic | Scope | Choose |
|---|---|---|
| HTTP(S), global users, WAF, CDN, fast failover | Global | **Front Door** |
| Any protocol, DNS-level routing (priority, weighted, performance, geographic) | Global | **Traffic Manager** |
| HTTP(S), regional, L7 routing, WAF, private backends in a VNet | Regional | **Application Gateway** |
| TCP/UDP, regional, ultra-low latency | Regional | **Load Balancer** |
| Global HTTP edge **and** private regional backends | Both | Front Door Premium (Private Link origins), or Front Door → Application Gateway |
| Network-layer (L3/L4) DDoS against public IPs in a VNet | Regional | **DDoS Network Protection**: about $2,900/month per plan, covering up to 100 public IPs, with cost protection and rapid response. **DDoS IP Protection**: billed per IP. Front Door and Static Web Apps already absorb these attacks at their edge; WAF covers L7, not L3/L4 |

---

## Phase 11 · Business continuity (new: 15–20% of the exam)

**The picture:** [continuity.svg](continuity.svg) ([PNG](continuity.png)) shows each service's copy in the second
region, what that copy costs, and the failover order.

**Switches** (in `main.bicepparam`; try them one at a time):

| Switch | What you get | Cost |
|---|---|---|
| `sqlBackupRedundancy = 'Geo'` (the default) | Backups copied to the paired region, so you can **geo-restore** anywhere (RPO up to 1 hour, RTO hours) | Little or nothing at this size |
| `storageSku = 'Standard_RAGZRS'` | Zones in this region, plus a readable copy in the paired region | Roughly 2x LRS per GB |
| `cosmosSecondaryLocation = 'centralus'` | A read region with service-managed failover (free-tier or provisioned mode only) | The RU/s again in the second region |
| `sqlSecondaryLocation = 'centralus'` | An auto-failover group for both databases; the apps connect through its listener | **About $750/month**: geo-replicated serverless databases never auto-pause |
| `eventHubsSecondaryLocation = 'centralus'` | A paired namespace behind an alias (metadata only) | About $22/month |
| `zoneRedundant = true` | Zone-redundant SQL, Cosmos DB and App Service plan (P1v3 x 2) | About $250/month for the plan. Set it before the first deployment |

The expensive ones bill by the hour: deploy them, run the drill, and remove them the same day.

### Lab

1. **Write the targets first.** Orders: RPO 5 minutes, RTO 1 hour. Catalog: RPO 1 hour, RTO 15 minutes. Images:
   RPO 1 day. Every design choice below must satisfy a line in that table.
2. **SQL auto-failover group.** Set `sqlSecondaryLocation = 'centralus'` and redeploy.
   [`sql.bicep`](../infra/modules/sql.bicep) creates a secondary server (`<server>-dr`) and a failover group with both
   databases. Every app already connects through the listener `<server>-fog.database.windows.net`, so nothing else
   changes. The database users replicate with the databases, so the grant script doesn't need to run again. Fail over
   while placing orders:

   ```bash
   az sql failover-group set-primary -g rg-cloudmart-dev -s <server>-dr -n <server>-fog
   ```

   Fail back with the same command and `-s <server>`. The group's policy is **customer-managed**, which is Microsoft's
   recommendation: you decide when to fail over. With *Automatic*, Microsoft fails over only during a region-wide
   outage, after a grace period, which can be later than your RTO. When you're done, remove the switch and delete
   `<server>-dr`: the failover group keeps both databases from auto-pausing.
3. **Cosmos DB multi-region.** With the secondary region added, run *Service-managed failover* in the portal. Discuss
   single-write versus multi-write regions and how the consistency level affects RPO.
4. **Storage.** With RA-GZRS, read from `https://<account>-secondary.blob.core.windows.net`, check the
   **Last Sync Time**, and read how customer-initiated account failover works.
5. **Event Hubs geo-disaster recovery.** Set `eventHubsSecondaryLocation = 'centralus'`. The apps now connect to the
   alias `<namespace>-geo.servicebus.windows.net` ([`messaging.bicep`](../infra/modules/messaging.bicep)). Open the
   secondary namespace:
   - The `telemetry` hub and the `functions` consumer group appeared on their own.
   - There are no events.
   - There are no role assignments of its own, so Bicep adds them. Without them, a failover would lock the apps out.

   Then fail over:

   ```bash
   az eventhubs georecovery-alias fail-over -g rg-cloudmart-dev --namespace-name <namespace>-dr -a <namespace>-geo
   ```

   The pairing is gone, and the old primary keeps any events nobody read: failover is one-way. Clicks flow again
   once the Functions app restarts. If its trigger complains about checkpoints, delete the consumer group's blobs in
   the `azure-webjobs-eventhub` container. To pair again, redeploy with a new secondary.
6. **Zones.** `zoneRedundant` survives a datacentre failure for much less than a second region costs. Work out:
   - what it costs here;
   - what it protects against;
   - why it can't help with a region-wide outage or a bad deployment.
7. **Azure Backup.** Create a Recovery Services vault, back up the jumpbox VM, restore a single file, and look at soft
   delete and immutable vaults. Create a **Backup vault** and enable operational backup for the blob containers.
8. **Azure Site Recovery.** Replicate the jumpbox to another region, run a **test failover** into an isolated VNet,
   then clean up the test.
9. **Point-in-time restore and geo-restore.**
   - `az sql db restore --dest-name cloudmart-pitr --time <UTC 10 minutes ago>` restores the database as it was ten
     minutes ago.
   - Restore a Cosmos DB container from continuous backup.
   - With geo-redundant backups, the portal's *Geo-restore* (or `az sql db geo-backup restore`) recreates a database
     in another region from its latest geo-replicated backup. No standby is needed, but expect hours, not minutes.
10. **The drill.** Combine this with phase 10's second copy and follow the runbook below. Time each step: the total is
    your real RTO.

### Failover runbook

Do it in this order: data first, then compute, then traffic. If traffic moves before the data has failed over, users
reach an app that can't write.

| Step | Action | Check |
|---|---|---|
| 1 Declare | One named person decides to fail over. The RTO clock started at the outage, not at the decision. | Service Health shows a regional incident, not just a problem in your app |
| 2 Data | **SQL:** `az sql failover-group set-primary` on `<server>-dr`, with `--allow-data-loss` if the primary is unreachable. **Cosmos DB:** service-managed failover. **Storage:** customer-initiated account failover. **Event Hubs:** `georecovery-alias fail-over`. | Each service reports the second region as primary |
| 3 Compute | The phase 10 second copy is already deployed with `deploySql = false` and `sharedSqlListenerFqdn` set to the listener. Scale it out, and delete the Event Hubs checkpoints. | `/health/ready` is green in the second region |
| 4 Traffic | Front Door's probes have already moved traffic to priority 2. Disable the primary origin so traffic can't flap back while it's half healthy. | The Platform page shows the second region |
| 5 Verify | Place an order and follow its trace; watch the phase 7 alerts. | The order confirms, with no dead letters |
| 6 Fail back | Once the primary region is healthy, do the same in reverse. **SQL** and **Cosmos DB:** switch primary and write region back. **Storage:** turn geo-redundancy on again, because an account failover leaves it LRS. **Event Hubs:** pair again. | The same checks, in the first region |

**What you lose:**
- **SQL:** nothing in a planned failover. With `--allow-data-loss`, the last few seconds of replication lag. With
  geo-restore alone, up to an hour.
- **Service Bus Standard:** messages still queued in the primary namespace. They're delivered when the region comes
  back, or never. Their orders stay Pending, but their outbox rows (phase 5) say *sent*, so nothing tries again.
  After the outage, mark them unsent and restart the API, because its relay checks the outbox when it starts:

  ```sql
  UPDATE OutboxMessages SET SentUtc = NULL, NextAttemptUtc = SYSDATETIMEOFFSET()
  WHERE Id IN (SELECT Id FROM Orders WHERE Status = 'Pending');
  ```

  Some of those messages did arrive. Duplicate detection drops their copies, and the saga ignores orders that
  aren't Pending.
- **Sagas in flight:** their Durable Functions state is in the primary storage account. They resume after the
  storage account fails over, or when the primary region returns.
- **Event Hubs:** events nobody had read yet in the primary namespace. The click stream is best effort, so that's
  accepted.

**The second copy's identities.** The second copy's managed identities are different principals. Before the drill, run
[grant-managed-identities.sql](../deploy/sql/grant-managed-identities.sql) once more on the **primary** server, with
the second copy's identity names. The users then replicate to the secondary. With private endpoints on, the second
copy's VNet also needs private endpoints to both SQL servers and a link to their DNS records: phase 13's
hub-and-spoke DNS problem.

### Architect's questions

| Requirement | Recommendation |
|---|---|
| Survive a datacentre failure | **Availability zones** (99.99% VM SLA): zone-redundant SQL and Cosmos DB, ZRS storage, a zone-redundant App Service plan (Premium v2 or later, at least 2 instances) |
| Cheapest cross-region recovery for Azure SQL | **Geo-restore** from geo-redundant backups: RPO up to 1 hour, RTO in hours, no standby to pay for |
| SQL failover with an RPO of seconds and no config change | **Auto-failover group**: asynchronous geo-replication plus a listener. Serverless replicas don't auto-pause |
| Who triggers the SQL failover | A **customer-managed** policy (recommended). Microsoft-managed waits for a region-wide outage and a grace period |
| Event Hubs regional DR | **Geo-disaster recovery** (Standard and up): metadata only, an alias, one-way. **Geo-replication** (Premium, Dedicated): the events too |
| Service Bus regional DR | **Premium**: geo-disaster recovery (metadata) or geo-replication (messages). Standard has neither |
| Key Vault during a regional outage | Built in: a read-only copy in the paired region until the region recovers |
| Order of a regional failover | Data, then compute, then traffic. Fail back in the reverse order |
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

## Phase 13 · Hybrid networking and identity (new: hub-and-spoke lab, then design)

**Switches:** `deployFirewall = true`. It needs `deployNetwork` and `enablePrivateEndpoints` (phases 2 and 4): the
firewall allows only the few public services the apps use, so the data stores must already be private. Keep
`deployMessaging` (phase 5) on for the break-it step.

**Cost:** Azure Firewall **Basic** is about $0.40/hour, or **≈ $290/month**, plus about $0.065 per GB it processes and
two Standard public IPs (≈ $4/month each). It is billed every hour it exists, so deploy it, do the lab and remove it the
same day (≈ $10). Setting the switch back to `false` doesn't delete it: see step 6.

**What changes:**

- **Hub:** a hub VNet `vnet-cloudmart-dev-hub` (10.0.0.0/16), peered both ways with the CloudMart VNet, which is now a
  spoke. It holds `AzureFirewallSubnet` and `AzureFirewallManagementSubnet` (both /26). Basic always has a management
  NIC with its own public IP, so Microsoft's management traffic never depends on your rules.
- **Route table:** `vnet-cloudmart-dev-egress-rt` sends `0.0.0.0/0` to the firewall's private IP from
  `snet-appservice`, `snet-functions` and `snet-containerapps`. App Service (`vnetRouteAllEnabled`) and Flex
  Consumption already put all their outbound traffic into those subnets.
- **Platform:** order events show **Service Bus (WebSockets)**. The API and the Functions trigger switch from AMQP
  (port 5671) to AMQP over WebSockets (443). Why: Basic can match a name only in an *application* rule, which handles
  HTTP(S) and SQL. A name in a *network* rule (any port) needs DNS proxy, which starts at Standard. On 5671 the only
  option would be the `ServiceBus` service tag, which covers every customer's namespace.

The firewall policy (`afwp-cloudmart-dev`, read it in [firewall-hub.bicep](../infra/modules/firewall-hub.bicep))
allows only what the apps call on public endpoints. Everything else is denied and logged:

| Rule | Type | Destination | Who needs it |
|---|---|---|---|
| `entra-id` | Network | `AzureActiveDirectory` tag, TCP 443 | Validating Entra tokens (API, Payments, Shipping); managed identity in Container Apps |
| `azure-monitor` | Network | `AzureMonitor` tag, TCP 443 | Application Insights from every app and the Functions host |
| `service-bus` | Application | `sbns-cloudmart-dev-xxxxxx.servicebus.windows.net`, HTTPS 443 | The API sends order events; the Functions triggers receive them |
| `app-configuration` | Application | `appcs-cloudmart-dev-xxxxxx.azconfig.io` | The API at startup (only with `deployAppConfig`) |
| `container-apps-platform` | Application | `mcr.microsoft.com`, `*.data.mcr.microsoft.com`, `packages.aks.azure.com`, `acs-mirror.azureedge.net` | The Container Apps environment (only with `deployContainerApps`) |
| `container-registry` | Network | `AzureContainerRegistry` tag | Your image from ACR (only with Container Apps and `containerImage`) |

Some traffic never reaches the firewall:

- **Private endpoints.** Each private endpoint adds a `/32` route, which is more specific than `0.0.0.0/0`. So SQL,
  Cosmos DB, Key Vault, Event Hubs, Storage and the Payments and Shipping APIs are reached directly, and so is the
  Durable Functions task hub, which lives in Storage.
- **Platform endpoints.** Azure DNS (168.63.129.16) and the managed identity endpoints are answered by the platform
  and aren't routed.
- **Inbound traffic.** Front Door → App Service and Event Grid → Functions never enter the VNet, so the firewall
  doesn't see them and can't route them asymmetrically.
- **Azure Managed Redis (phase 12).** Its port 10000 is TLS but not HTTPS, so Basic can't allow it by name. Give it
  a private endpoint, or use Standard with DNS proxy.

### Lab

1. **Deploy.** Run `what-if` first. It lists the hub VNet, two public IPs, the policy and its rule collection group,
   the firewall, the route table, the two peerings, a `routeTable` on three subnets, and `ServiceBus__TransportType`
   on the apps. The firewall takes about 10 minutes to create.

   It also locks Service Bus to the firewall. Every app request now leaves from the firewall's public IP, so the
   namespace's IP firewall accepts that one address and denies the rest. Standard has no private endpoints, but it
   does have IP rules. Put your own public IP (`curl ifconfig.me`) in `adminIpAddresses`, or the portal's Service Bus
   Explorer and your local runs are refused too.
2. **Follow the packet.**

   ```bash
   az network vnet peering list -g rg-cloudmart-dev --vnet-name vnet-cloudmart-dev -o table      # Connected
   az network route-table route list -g rg-cloudmart-dev --route-table-name vnet-cloudmart-dev-egress-rt -o table
   az network firewall show -g rg-cloudmart-dev -n afw-cloudmart-dev --query "ipConfigurations[0].privateIPAddress"
   ```

   (The first `az network firewall` command installs the CLI's `azure-firewall` extension.) The route's next hop is
   the firewall's private IP. Azure picks it, and stopping and starting the firewall can change it, which is why the
   Bicep reads it from the firewall instead of hard-coding `10.0.0.4`.
3. **Use the shop, then read the logs.** Place an order, open a few products and upload an image: everything works.
   Then in Log Analytics:

   ```kusto
   AZFWApplicationRule
   | where TimeGenerated > ago(30m)
   | summarize count() by SourceIp, Fqdn, Action, Rule
   ```

   ```kusto
   AZFWNetworkRule
   | where TimeGenerated > ago(30m)
   | summarize count() by SourceIp, DestinationIp, DestinationPort, Action, Rule
   ```

   `10.20.1.x` is the App Service plan (API, Payments, Shipping) and `10.20.2.x` the Functions app. Look for what
   is *missing*: no database, Key Vault or Storage traffic, because the private endpoints' routes win. The
   `firewallPublicIp` deployment output is now the one address all of it leaves from: the address a partner would
   allow-list.
4. **Watch a denied flow.** Open the API's **SSH** console (App Service → Development Tools) and run
   `curl -sv https://www.bing.com -o /dev/null`. The TLS handshake is cut off. Find it:

   ```kusto
   AZFWApplicationRule
   | where Action == "Deny"
   | project TimeGenerated, SourceIp, Fqdn, DestinationPort, ActionReason
   ```

   Then try `timeout 5 bash -c '</dev/tcp/www.bing.com/443' && echo open`. It prints *open*. The firewall answers the
   TCP handshake on 80 and 443 itself and decides only when it sees the HTTP request or TLS hello. A TCP connect test
   proves nothing through Azure Firewall.
5. **Stretch: inspect the private endpoints too.** In [network.bicep](../infra/modules/network.bicep), add a route for
   `10.20.6.0/24` to the firewall. `snet-private-endpoints` already has `privateEndpointNetworkPolicies` enabled, which
   lets that route override the `/32`s. Then add application rules (HTTPS for Key Vault, Storage and Cosmos DB, MSSQL
   for SQL). Application rules SNAT the traffic, so the replies come back through the firewall instead of around it.
6. **Clean up.** Set `deployFirewall = false` and redeploy. That removes the route first, so the apps don't lose
   their way out. Then delete the billed parts:

   ```bash
   az network firewall delete -g rg-cloudmart-dev -n afw-cloudmart-dev
   az network public-ip delete -g rg-cloudmart-dev -n pip-afw-cloudmart-dev
   az network public-ip delete -g rg-cloudmart-dev -n pip-afw-cloudmart-dev-mgmt
   ```

### Break it

- **Remove the Service Bus rule.** In the portal, open the firewall policy → *Application rules* → `app-dependencies`
  and delete `service-bus`, or run:

  ```bash
  az network firewall policy rule-collection-group collection rule remove -g rg-cloudmart-dev \
    --policy-name afwp-cloudmart-dev --rcg-name cloudmart-egress --collection-name app-dependencies --name service-bus
  ```

  Wait a minute, then place an order. The API saves it before it publishes, so the checkout call fails after the
  Service Bus client's retries, and the order stays **Pending**. It's the lost event from phase 5's outbox exercise,
  caused this time by the network. `AZFWApplicationRule | where Fqdn endswith "servicebus.windows.net"` shows `Deny`
  from `10.20.1.x` (the API sending) and from `10.20.2.x` (the Functions triggers, which can't receive either).
  **Fix it:** redeploy, and Bicep puts the rule back. New orders confirm; the stuck one stays Pending, because
  nothing ever published its event.
- **Go back to AMQP.** With the rule back, set the API's app setting `ServiceBus__TransportType` to `AmqpTcp`. New
  orders get stuck again. The rule allows the namespace on 443 only, and Basic can't allow 5671 by name. Redeploy to
  restore it.
- **Leave your IP out.** Deploy with `adminIpAddresses = []` and open Service Bus Explorer in the portal: the
  namespace rejects your IP. Orders still confirm, because the apps' traffic comes from the firewall's IP.

### Architect's questions

**Draw** the rest of the hub: a VPN or ExpressRoute gateway (`allowGatewayTransit` on the hub's peering,
`useRemoteGateways` on the spoke's), Bastion, and a **Private DNS Resolver** so on-premises can resolve private
endpoint names. Then redraw it with **Virtual WAN** and a secured virtual hub.

Real VPN and ExpressRoute need an on-premises device or a provider circuit. For a hands-on taste, deploy a VPN Gateway
(`VpnGw1`, ≈ $140/month, 30–45 minutes to create) for **one day** and connect the CloudMart VNet to
`vnet-onprem-sim` VNet-to-VNet, or your laptop point-to-site with Entra ID authentication.

| Requirement | Recommendation |
|---|---|
| Central allow-list and logs for outbound traffic from many spokes | **Azure Firewall** in a hub, plus a **UDR** `0.0.0.0/0` → firewall on each spoke subnet |
| Which Azure Firewall SKU? | **Basic**: up to 250 Mbps, names only in application rules (HTTP(S), SQL), threat intelligence alerts only. **Standard**: DNS proxy (so FQDNs in network rules, any port), web categories, threat intelligence deny. **Premium**: TLS inspection, IDPS, URL filtering |
| Restrict a PaaS endpoint that has no private endpoint (Service Bus Standard) | Its **IP firewall**, allowing only a fixed egress IP: Azure Firewall or NAT Gateway. App Service's own outbound IPs are shared and change |
| Stop data exfiltration to *other customers'* PaaS resources | Allow your own **FQDNs**, or use private endpoints. Service tags such as `ServiceBus` or `Storage` cover every customer's resources |
| Inspect traffic to private endpoints too | A UDR covering the private endpoint subnet, `privateEndpointNetworkPolicies` enabled, and application rules (they SNAT, so replies return through the firewall) |
| Same rules for many firewalls and regions | **Firewall Manager** with parent and child **firewall policies**; **Virtual Network Manager** for peerings and UDRs at scale |
| Spoke-to-spoke traffic | Through the hub firewall, with a UDR for the other spoke's prefix. Peering isn't transitive |
| Lots of outbound connections, SNAT port exhaustion | **NAT Gateway** on the firewall subnet, or more public IPs on the firewall |

| | NSG with service tags | Azure Firewall | NAT Gateway |
|---|---|---|---|
| Does | Allow or deny by IP, port, service tag | Allow or deny by FQDN, service tag or IP; SNAT, DNAT, threat intelligence | SNAT only: a fixed outbound IP, no filtering |
| Layer | L3–L4 | L3–L7 | L3–L4 |
| Filters by name | No | Yes: application rules; network rules with DNS proxy (Standard and up) | No |
| Where | On every subnet or NIC, distributed | Central, in the hub, shared by spokes | Per subnet |
| Logs | VNet flow logs | Allow and deny per rule (`AZFW*` tables) | Metrics only |
| Cost | Free | Basic ≈ $290/month, Standard ≈ $900/month, plus per GB | ≈ $33/month plus per GB |
| Use it for | Separating tiers, coarse egress limits | Central egress control, exfiltration protection | A predictable outbound IP and SNAT scale, often next to a firewall |

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

## Phase 16 · Microservices: Payments, Shipping and a saga

**Switches:** `deployPayments = true`, `deployShipping = true`. Both services run on the API's App Service plan, so
there is no extra compute cost. The payments database is one more serverless SQL database that auto-pauses.
The phase builds on earlier ones:

- `deployMessaging` (phase 5) for the Durable Functions saga.
- `deploySql` (phase 4) for the ledger table.
- `deployNetwork` + `enablePrivateEndpoints` (phase 2) to make the services private.

**What changes:**

- **Platform:** *Payments* and *Shipping* switch from *In-process* to *Payments API* / *Shipping API*, and readiness
  lists `payments-api` and `shipping-api`.
- **Orders:** show a payment id and a tracking number.

**The design.** Checkout used to be one in-process step. Now it is a **saga** across two services that each own their
data:

1. Charge the payment: the **Payments API**, with an Azure SQL **ledger** table.
2. Book the parcel: the **Shipping API**, with **Table Storage**.
3. If shipping fails after the charge, **refund** it. That is the *compensating transaction*.

There is no distributed transaction. Each step commits on its own, and correctness comes from:

- **Idempotent steps.** Payments uses POST + `Idempotency-Key`; Shipping uses PUT `/shipments/{orderId}`.
- **Durable orchestration.** [OrderSaga.cs](../src/CloudMart.Core/Services/OrderSaga.cs) is the orchestrator. It runs
  in-process on a laptop, and as a Durable Functions orchestration in Azure
  ([OrderSagaFunctions.cs](../src/CloudMart.Functions/OrderSagaFunctions.cs)).

### Lab

1. **Run the three services locally.** No Azure needed. Start each one in its own terminal:

   ```bash
   dotnet run --project src/CloudMart.Payments     # http://localhost:5081
   ```

   ```bash
   dotnet run --project src/CloudMart.Shipping     # http://localhost:5082
   ```

   Then start the API pointed at them. In PowerShell:

   ```powershell
   $env:Payments__BaseUrl = "http://localhost:5081"; $env:Shipping__BaseUrl = "http://localhost:5082"
   dotnet run --project src/CloudMart.Api
   ```

   Place three orders and read each result on the Orders page:

   | Order | Result |
   |---|---|
   | 1 desk lamp | *Confirmed*, with a payment id and a tracking number |
   | 3 workstations | *Payment declined* (over the 10,000 limit); nothing to undo |
   | 11 desk lamps | *Shipping rejected* (more than 10 items per parcel), **refunded** |

   Confirm the refund in the Payments API itself: `curl "http://localhost:5081/payments?orderId=<id>"`.
2. **Idempotency, three ways.**
   - **Placing the order.** The SPA sends an `Idempotency-Key` with each checkout and reuses it if you retry. Send
     the same POST twice: same order id, one order. Change the cart but keep the key: **422**.

     ```bash
     curl -i -X POST localhost:5080/api/orders -H "Idempotency-Key: checkout-1" -H "Content-Type: application/json" \
       -d '{"lines":[{"productId":"woodgrove-desk-lamp","quantity":1}]}'
     ```

     The order id is a hash of your user id and the key
     ([OrderService.cs](../src/CloudMart.Core/Services/OrderService.cs)). That way the primary key does the
     de-duplication, with no new column and no schema change. A retry that arrives while the order is still Pending
     doesn't publish anything. It makes sure the order's `OrderPlaced` message is in the outbox (phase 5) and leaves
     the sending to the relay. That repairs an order saved before the outbox existed.
   - **POST to Payments with an idempotency key.** Send the same request twice. The first answers 201 and the second 200, with
     the same payment id. Then reuse the key for another order and get 409.

     ```bash
     curl -i -X POST localhost:5081/payments -H "Idempotency-Key: demo-1" -H "Content-Type: application/json" \
       -d '{"orderId":"8f3c2c1e-0000-4000-8000-000000000001","customerId":"me","amount":42}'
     ```

   - **PUT to a client-chosen URL.** `PUT localhost:5082/shipments/<guid>` is idempotent by definition, so a retry needs
     no extra header.

   Why all three? Because every retry layer re-sends the same request: the browser (or a proxy) retrying the POST,
   the HTTP client, the Durable activity retry and Service Bus redelivery.
3. **Deploy.** Flip the switches and redeploy.
   1. Run the second half of
      [grant-managed-identities.sql](../deploy/sql/grant-managed-identities.sql) against the `payments` database.
   2. Run [setup-service-auth.sh](../deploy/entra/setup-service-auth.sh). It creates the two app registrations with
      their **application** app roles, and assigns those roles to the Functions and API managed identities. The
      portal can't assign app roles to a managed identity; this is a Microsoft Graph call.
   3. Put the printed client ids in `main.bicepparam` and redeploy.
   4. Check the secret moved. The API's *Secret PaymentGateway--ApiKey loaded* goes off on the Platform page, and
      confirmed orders say *charged via gateway key ****xxxx*. Only the Payments identity can read Key Vault now.
4. **Watch the saga in Durable Functions.** In the portal, open the storage account's Storage browser and go to Tables.
   - `CloudMartSagaInstances` has one row per order: the instance id is the order id.
   - `CloudMartSagaHistory` holds every step for that order: `TaskScheduled ChargePayment`, `TaskCompleted`, and so on.
   - For the 11-lamp order, find `RefundPayment` in the history.

   Restart the Functions app in the middle of a saga. It resumes, and does not charge again.

   Then follow one order end to end. [`host.json`](../src/CloudMart.Functions/host.json) turns on Durable Functions
   distributed tracing (V2). In Application Insights → *Transaction search*, open the order's POST: one trace should
   run through Service Bus, the orchestration and each activity, and into the Payments and Shipping APIs. If the
   trace stops at the orchestrator, check that the setting deployed.
5. **Resilience.** Set the app setting `Chaos__FailureRate = 0.5` on the Shipping app, then place five orders. In
   Application Insights:
   - Transaction search shows 503s, each followed by a retry, and every order still confirms.
   - Set the rate to `1` and the circuit breaker opens. After the Durable retries (3 attempts) the saga **refunds**.
   - Set it back to `0` when you're done.
6. **Private endpoints.**
   - With `enablePrivateEndpoints`, `curl https://<payments-app>.azurewebsites.net/health/live` from your laptop gets
     **403**: the public entrance is closed.
   - From the jumpbox it works. `nslookup` there shows the `privatelink.azurewebsites.net` CNAME and a `10.20.6.x`
     address.
7. **Ledger.** In the query editor, against the `payments` database:

   ```sql
   SELECT * FROM dbo.Payments_Ledger ORDER BY ledger_transaction_id, ledger_sequence_number;
   UPDATE dbo.Payments SET Amount = 1 WHERE Id = '<some payment>';   -- as the admin, "fixing" the books
   SELECT * FROM dbo.Payments_Ledger WHERE Id = '<some payment>';    -- the old amount is still there
   ```

   The history is append-only and hash-chained. To make it tamper-*evident* outside the database too, turn on
   automatic digest storage (Azure SQL > Ledger), then run `sys.sp_verify_database_ledger_from_digest_storage`.

### Break it

- **Remove an app role.** Remove the Functions identity's `Payments.Process` assignment and restart the Functions app.
  Payments answers **403**, the Durable retries run out, and the order ends *Payment service unavailable* with a
  review flag. Then put the assignment back.
- **Unlink a DNS zone.** Remove `privatelink.azurewebsites.net`'s VNet link. The Functions app resolves the public IP
  and gets **403 Ip Forbidden**. It's the same failure as phase 4's "it times out", but for an app instead of a
  database.

### Architect's questions

| Requirement | Recommendation |
|---|---|
| A business transaction across services, without distributed transactions | **Saga**: local commits plus compensating actions |
| Orchestration or choreography? | **Orchestration** (Durable Functions, Logic Apps): one place to read and change the flow, easier to trace. **Choreography** (services reacting to events on Service Bus): looser coupling, harder to follow |
| Long-running stateful workflow in code that survives restarts | **Durable Functions**. The Azure Storage backend is the default; **Durable Task Scheduler** is the managed, higher-throughput backend |
| Service-to-service calls with no secrets | **Managed identity** + an **app role** on the target's app registration (client-credentials flow, `roles` claim) |
| Retry a non-idempotent call safely | An **idempotency key** (POST), or **PUT** to a client-chosen id |
| A retried checkout must not create a second order | An `Idempotency-Key` per checkout, stored with the order or hashed into its id; same key, different body → 422 |
| Event-handler failures must not lose events | Event Grid **dead-lettering** to Blob Storage (with a managed identity) + an alert + a replay procedure |
| Ride out transient faults between services | **Retries with backoff and jitter, timeouts, circuit breaker** (`Microsoft.Extensions.Http.Resilience`) |
| Tamper-evident records for auditors | **Azure SQL ledger** tables (updatable or append-only) + automatic digest storage |
| Cheap key-value storage, lookups by key only | **Table Storage**; **Cosmos DB for Table** for global distribution, SLAs and automatic indexing |
| A backend API reachable only from the VNet | **App Service private endpoint** + closing the public entrance (access restrictions or `publicNetworkAccess`) |
| Each service owns its data | **Database per service**: other services go through its API, never its tables |

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
