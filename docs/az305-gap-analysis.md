# AZ-305 gap analysis

Your 10-phase list was checked against the official AZ-305 "skills measured" outline dated **17 April 2026**
([study guide](https://learn.microsoft.com/en-us/credentials/certifications/resources/study-guides/az-305)).
Check that page again before you book: Microsoft revises the outline periodically.

| Exam domain | Weight |
|---|---|
| Design identity, governance, and monitoring solutions | 25–30% |
| Design data storage solutions | 20–25% |
| Design business continuity solutions | 15–20% |
| Design infrastructure solutions | 30–35% |

**Bottom line:** your list covers the infrastructure building blocks well. It is light on four things the exam
weights heavily:

1. **Business continuity**: a whole 15–20% domain. Your phase 10 mentions it in one line.
2. **Hybrid connectivity and hybrid identity**: "connect Azure to on-premises" and "authorise access to on-premises
   resources" are explicit objectives.
3. **Application integration**: API Management, caching and app configuration are explicit objectives.
4. **Data integration and migrations**: two explicit objective groups that are entirely missing.

Also, AZ-305 is a *design* exam. Most questions read "a company needs X under constraints Y: what do you recommend?"
Every phase in [learning-path.md](learning-path.md) therefore ends with **Architect's questions**: the "choose
between" decisions the exam actually tests.

---

## Objective by objective

✅ covered by your list · ➕ added in this repo · ⚠️ partly covered: expanded here

### Design identity, governance, and monitoring (25–30%)

| Objective | Status | What to add | Where |
|---|---|---|---|
| Recommend a logging solution | ✅ | Diagnostic settings, data collection rules, Azure Monitor Agent, workspace design (one vs many, retention, daily cap, table plans) | Phase 7 |
| Recommend a solution for routing logs | ⚠️ | Diagnostic settings → Log Analytics / Storage (archive) / Event Hubs (SIEM). Every CloudMart module routes its logs | Phase 7 |
| Recommend a monitoring solution | ✅ | Alerts + action groups, workbooks, Network Watcher, Service Health / Resource Health | Phase 7 |
| Recommend an authentication solution | ⚠️ | **Conditional Access**, MFA, passwordless, **Entra External ID** (B2B and customer identity; Azure AD B2C is closed to new customers) | Phase 6 |
| Recommend an identity management solution | ➕ | **Hybrid identity**: Entra Connect Sync vs Cloud Sync, password hash sync vs pass-through auth vs federation | Phase 13 |
| Authorise access to Azure resources | ✅ | RBAC scope inheritance, custom roles, ABAC conditions, data-plane vs control-plane roles | Phases 1, 6 |
| Authorise access to **on-premises** resources | ➕ | **Entra Application Proxy**, Entra Private Access, Kerberos constrained delegation | Phase 13 |
| Manage secrets, certificates and keys | ✅ | Key Vault vs Managed HSM, customer-managed keys, certificate rotation, Key Vault references | Phase 6 |
| Management groups, subscriptions, RGs, **tagging strategy** | ⚠️ | **Management-group hierarchy**, subscription vending, **Azure landing zones**, tag taxonomy | Phases 1, 9 |
| Recommend a solution for managing compliance | ⚠️ | Policy **initiatives**, regulatory compliance dashboard in Defender for Cloud, Microsoft Purview | Phase 9 |
| Recommend a solution for **identity governance** | ➕ | **PIM**, **access reviews**, **entitlement management**, break-glass accounts | Phase 6 |

### Design data storage (20–25%)

| Objective | Status | What to add | Where |
|---|---|---|---|
| Store relational data | ⚠️ | **SQL Managed Instance** and SQL Server on VMs: when each fits | Phase 4 |
| Service tier and compute tier | ➕ | DTU vs vCore; General Purpose vs Business Critical vs **Hyperscale**; serverless vs provisioned | Phase 4 |
| Database scalability | ➕ | **Elastic pools**, read scale-out, sharding, Hyperscale named replicas | Phase 4 |
| Data protection | ⚠️ | TDE (service- vs customer-managed key), **Always Encrypted**, dynamic data masking, auditing, Defender for SQL | Phases 4, 6 |
| Semi-structured data | ✅ | Cosmos DB partition key design, **consistency levels**, RU/s vs serverless vs autoscale | Phase 4 |
| Unstructured data | ⚠️ | **Access tiers** (Hot/Cool/Cold/Archive), **lifecycle management**, **Data Lake Storage Gen2**, Azure Files | Phase 4 |
| Balance features, performance and cost | ➕ | Premium vs standard storage, reserved capacity, the redundancy ladder | Phase 4 |
| Protection and durability | ⚠️ | **LRS / ZRS / GRS / GZRS / RA-GZRS**, soft delete, versioning, immutability (WORM), point-in-time restore | Phases 4, 11 |
| **Data integration** | ➕ | **Data Factory**, **Fabric** / Synapse, Databricks, Stream Analytics, Event Hubs Capture | Phase 14 |
| **Data analysis** | ➕ | Lakehouse vs warehouse, Power BI, Azure Data Explorer | Phase 14 |

### Design business continuity (15–20%): entirely added

| Objective | What to learn | Where |
|---|---|---|
| Recovery solution that meets RTO/RPO, including hybrid | **Azure Site Recovery**, RTO/RPO maths, recovery plans, paired regions | Phase 11 |
| Backup and recovery for compute | **Azure Backup** (Recovery Services vault vs Backup vault), VM/AKS backup, soft delete, immutable vaults | Phase 11 |
| Backup and recovery for databases | SQL automated backups + **PITR** + **LTR**, geo-restore, Cosmos continuous backup | Phase 11 |
| Backup and recovery for unstructured data | Blob soft delete/versioning/PITR, **object replication**, Azure Files backup | Phase 11 |
| HA for compute | **Availability zones vs availability sets**, VM Scale Sets, zone-redundant App Service / Container Apps / AKS | Phase 11 |
| HA for relational data | **Auto-failover groups**, active geo-replication, zone-redundant databases, Business Critical replicas | Phase 11 |
| HA for semi-structured/unstructured data | Cosmos multi-region (single vs multi-write), service-managed failover, GZRS / RA-GZRS | Phase 11 |

### Design infrastructure (30–35%)

| Objective | Status | What to add | Where |
|---|---|---|---|
| Compute components for a workload | ✅ | The compute decision tree; SKU families | Phase 3 |
| VM-based solution | ⚠️ | **VM Scale Sets**, Spot, Dedicated Host, **Azure Virtual Desktop**, Azure VMware Solution | Phase 3 |
| Container-based solution | ✅ | **ACI** vs Container Apps vs AKS; AKS networking and identity | Phase 3 |
| Serverless solution | ✅ | Functions hosting plans (Flex Consumption, Premium, Dedicated), **Durable Functions** (built as the order saga), **Logic Apps** | Phases 3, 12, 16 |
| **Batch processing** | ➕ | **Azure Batch**, Container Apps jobs, Functions vs Batch vs Databricks | Phase 3 |
| Messaging architecture | ✅ | Service Bus vs **Storage queues**; sessions, transactions, DLQ | Phase 5 |
| Event-driven architecture | ✅ | Event Grid vs Event Hubs vs Service Bus; Event Grid namespaces (MQTT/pull) | Phase 5 |
| **API integration** | ➕ | **API Management**: tiers, policies, products, self-hosted gateway | Phase 12 |
| Service-to-service integration | ➕ | **Saga** with compensation, idempotent APIs, managed identity + **app roles**, private endpoints for App Service, resilience | Phase 16 |
| **Caching** | ➕ | **Azure Managed Redis**, cache-aside, Front Door/CDN edge caching | Phase 12 |
| **Application configuration management** | ➕ | **App Configuration**, feature flags, Key Vault references | Phase 12 |
| Automated deployment | ✅ | Bicep, deployment stacks, template specs, GitHub Actions vs Azure Pipelines | Phase 8 |
| **Migrations** (5 objectives) | ➕ | **Cloud Adoption Framework**, **Azure Migrate**, **Database Migration Service**, **Data Box** / AzCopy / Storage Mover, the 6 Rs | Phase 15 |
| Connect to the internet | ✅ | Public IPs, NAT Gateway, Front Door, Application Gateway | Phases 2, 10 |
| Connect to **on-premises** | ➕ | **VPN Gateway** (S2S/P2S), **ExpressRoute** (+ Global Reach, FastPath), **Virtual WAN** | Phase 13 |
| Optimise network performance | ➕ | Accelerated networking, proximity placement groups, ExpressRoute vs VPN, Front Door | Phases 10, 13 |
| Optimise network security | ⚠️ | **Azure Firewall** (hands-on in phase 13: hub, UDRs, an allow-list policy), **DDoS Protection**, ASGs, **service endpoints vs private endpoints**, Bastion | Phases 2, 13 |
| Load balancing and routing | ✅ | **Traffic Manager** (DNS) vs Front Door vs Application Gateway vs Load Balancer | Phases 2, 10 |

---

## Your list, amended

| # | Phase | Your services | Add |
|---|---|---|---|
| 1 | Foundations | RGs, subscriptions, ARM, CLI, RBAC | **Management groups**, tags, resource locks, **Well-Architected Framework** + **CAF** vocabulary |
| 2 | Networking | VNets, subnets, NSGs, private endpoints, DNS, Load Balancer | **Peering / hub-spoke**, ASGs, **service endpoints vs private endpoints**, **Bastion**, NAT Gateway, UDRs |
| 3 | Compute | VMs, App Service, Functions, AKS, Container Apps | **VM Scale Sets**, **ACI**, **Azure Batch**, AVD (concept), Spot |
| 4 | Data | SQL, PostgreSQL, Cosmos DB, Storage | **SQL MI**, DTU/vCore/Hyperscale, **elastic pools**, access tiers + lifecycle, **Data Lake Gen2** |
| 5 | Messaging | Service Bus, Event Grid, Event Hubs, Functions | **Storage queues**, transactional outbox, Event Hubs Capture |
| 6 | Security | Entra ID, managed identities, Key Vault, Defender | **Conditional Access**, **PIM**, **access reviews**, **External ID**, app registrations / app roles |
| 7 | Observability | Monitor, App Insights, Log Analytics, Grafana | **Diagnostic settings / DCRs**, **alerts + action groups**, Network Watcher |
| 8 | DevOps | Azure DevOps, Pipelines, Bicep, ACR | **Workload identity federation**, deployment stacks, template specs, what-if |
| 9 | Governance | Policy, Resource Graph, Cost Management, Advisor | **Management groups**, **initiatives**, **landing zones**, reservations / savings plans, Blueprints → template specs + deployment stacks |
| 10 | Architecture | Front Door, App Gateway, WAF, resilience, DR | **Traffic Manager**, the load-balancer decision tree |
| **11** | **Business continuity** | (new) | **Azure Backup**, **Site Recovery**, SQL failover groups, Cosmos multi-region, GZRS, availability zones vs sets |
| **12** | **Application integration** | (new) | **API Management**, **App Configuration**, **Azure Managed Redis**, Logic Apps |
| **13** | **Hybrid networking + identity** | (new) | **VPN Gateway**, **ExpressRoute**, **Virtual WAN**, **Azure Firewall**, **Entra Connect / Cloud Sync**, **Application Proxy**, **Azure Arc** |
| **14** | **Data integration + analytics** | (new) | **Data Factory**, **Fabric** / Synapse, Databricks, Stream Analytics, Purview |
| **15** | **Migration** | (new) | **CAF Migrate**, **Azure Migrate**, **DMS**, **Data Box**, Storage Mover |

Phases 11–12 are built into CloudMart (Bicep switches + code), and so is phase 13's hub firewall (`deployFirewall`).
The rest of phase 13 and phases 14–15 involve on-premises systems or large data platforms that are impractical or
expensive to build for real, so they are design labs: diagrams and decision tables, plus a cheap hands-on taste where
one exists.
