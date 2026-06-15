# Azure Environment Assessment Toolkit

**Centre Technologies | March 2026**

Two PowerShell scripts for running a comprehensive Azure environment assessment. The **Prep script** enables monitoring so you get real utilization data, and the **Assessment script** collects everything into a single zip of CSVs.

---

## Quick Start — Run Directly from Azure Cloud Shell

Open [Azure Cloud Shell](https://shell.azure.com) (PowerShell), then copy-paste:

```powershell
# Step 1 — Prep (run 7-14 days before assessment)
irm https://raw.githubusercontent.com/arieldavenport/azure-assessment-script/main/Azure-Assessment-Prep.ps1 | iex

# Step 2 — Assessment (run after metrics have accumulated)
irm https://raw.githubusercontent.com/arieldavenport/azure-assessment-script/main/Azure-Assessment-Complete.ps1 -OutFile Azure-Assessment-Complete.ps1
.\Azure-Assessment-Complete.ps1

# Step 3 — Download the zip
download ~/AzureAssessment_yyyyMMdd-HHmm.zip
```

> **Note:** The Prep script runs interactively via `Invoke-Expression` so you get the menu. The Assessment script is saved to a file first because it accepts parameters (e.g. `-SubscriptionId`, `-SkipMetrics`).

### Alternative — Download Both Scripts First

If you prefer to review before running, or need to pass parameters to the Prep script:

```powershell
# Download both scripts
irm https://raw.githubusercontent.com/arieldavenport/azure-assessment-script/main/Azure-Assessment-Prep.ps1 -OutFile Azure-Assessment-Prep.ps1
irm https://raw.githubusercontent.com/arieldavenport/azure-assessment-script/main/Azure-Assessment-Complete.ps1 -OutFile Azure-Assessment-Complete.ps1

# Run Prep (interactive menu)
.\Azure-Assessment-Prep.ps1

# Run Assessment (with optional parameters)
.\Azure-Assessment-Complete.ps1 -SubscriptionId "xxx" -SkipMetrics
```

---

## Scripts

### `Azure-Assessment-Prep.ps1` — Monitoring Enablement Menu

Interactive menu that prepares the environment for accurate data collection. Run this **7-14 days before** the assessment so metrics have time to accumulate.

| Option | What It Does |
|--------|-------------|
| **[1]** Check posture | Read-only audit — shows which VMs have agents, which resources have diagnostics, what alert rules exist |
| **[2]** Install modules | Installs all 23 required Az/Graph PowerShell modules |
| **[3]** Workspace | Creates or selects a Log Analytics workspace |
| **[4]** Install AMA | Deploys Azure Monitor Agent to all VMs (enables system-assigned managed identity) |
| **[5]** Data Collection Rules | Creates Windows + Linux perf counter DCRs (CPU, Memory, Disk, Network) and associates them with VMs |
| **[6]** Diagnostic Settings | Enables diagnostics on 16 resource types → sends logs/metrics to Log Analytics |
| **[7]** VM Insights | Installs Dependency Agent for connection mapping + enables VMInsights solution |
| **[8]** Register providers | Registers Microsoft.Insights, AlertsManagement, etc. |
| **[A]** Run ALL | Automated end-to-end (runs 3–8 in sequence) |
| **[S]** Switch subscription | Subscription selector |
| **[R]** Readiness report | Pass/fail checklist — tells you if the environment is ready for assessment |

```powershell
# Full auto-prep on a specific subscription
.\Azure-Assessment-Prep.ps1 -SubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"

# Or just launch the menu
.\Azure-Assessment-Prep.ps1
```

### `Azure-Assessment-Complete.ps1` — 1-Shot Assessment

Iterates all enabled subscriptions, collects 60+ CSVs across 19 categories, generates an executive summary, and zips everything up.

```powershell
# Assess all subscriptions (default)
.\Azure-Assessment-Complete.ps1

# Single subscription, skip metrics for a fast inventory run
.\Azure-Assessment-Complete.ps1 -SubscriptionId "xxx" -SkipMetrics

# Custom lookback period and output path
.\Azure-Assessment-Complete.ps1 -DaysBack 14 -OutputPath "./ClientName_Assessment"
```

**Parameters:**

| Parameter | Default | Description |
|-----------|---------|-------------|
| `-SubscriptionId` | All enabled | Assess a single subscription |
| `-OutputPath` | `./AzureAssessment_<timestamp>` | Output directory |
| `-SkipMetrics` | `$false` | Skip CPU/memory metric collection (faster) |
| `-DaysBack` | `30` | Lookback window for metrics |

---

## What Gets Assessed

| # | Category | CSVs | Key Findings |
|---|----------|------|-------------|
| 00 | Subscriptions | Subscription list with offer/agreement type | EA, MCA, CSP, PAYG classification, spending limits |
| 01 | Resource Inventory | Resource counts by type and location | Full resource map |
| 02 | Compute | VMs, VM Metrics, VM Scale Sets | Stopped VMs still billing, right-sizing (CPU <5% = deallocate, <15% = downsize) |
| 03 | App Services | App Service Plans, Web Apps | Empty plans (pure waste), HTTPS/TLS config |
| 04 | Functions | Azure Functions inventory | Runtime, plan, state |
| 05 | Logic Apps | Logic Apps inventory | Workflow state |
| 06 | Storage | Disks, Unattached Disks, Snapshots, Storage Accounts, File Shares | Orphaned disks, snapshots >90 days, public blob access, missing lifecycle policies |
| 07 | Networking | VNets, Public IPs, NSG Rules, LBs, App Gateways, Firewalls, Front Door, Bastion, NAT GW, VPN/ER, Peerings, Private Endpoints, DNS, CDN, Network Watchers | Orphaned public IPs, CRITICAL NSG rules (RDP/SSH/SQL open to internet) |
| 08 | Databases | SQL Servers, SQL DBs, SQL Managed Instances, Cosmos DB, MySQL, PostgreSQL, Redis | DTU usage, zone redundancy, non-SSL ports |
| 09 | Messaging | Service Bus, Event Hubs, API Management | SKU and namespace inventory |
| 10 | Containers | AKS Clusters, Node Pools, Container Instances, Container Apps, Container Registries | K8s version, autoscale config, admin-enabled ACRs |
| 11 | Data & Analytics | Data Factories | Pipeline inventory |
| 12 | Identity & RBAC | Role Assignments, High-Risk Roles, Custom Roles, Management Groups | Owner/Contributor sprawl, service principal assignments |
| 13 | Security | Defender Pricing, Secure Score, Alerts, Key Vaults, Expiring Secrets/Certs, Policy Compliance | Defender plan gaps, active alerts, secrets expiring <30 days |
| 14 | Cost | Advisor (All + Cost), Consumption by Service, Reservations, Budgets | Right-sizing recs, RI utilization, spend by service |
| 15 | Backup & DR | Recovery Vaults, Backup Items, Unprotected VMs | VMs with no backup configured |
| 16 | Monitoring | Log Analytics Workspaces, Diagnostic Settings, Alert Rules, Action Groups | Resources invisible to monitoring, unconfigured action groups |
| 17 | Governance | Tag Compliance, Resource Locks | Missing required tags (Environment, Owner, CostCenter, Application) |
| 18 | Automation & Hybrid | Automation Accounts, Arc Connected Machines | Agent status, OS inventory |
| 19 | Management Groups | Hierarchy | Tenant structure |

---

## Output

```
AzureAssessment_20260320-1430/
├── Subscriptions.csv               ← Subscription list with offer type (EA/MCA/CSP/PAYG)
├── 00_ExecutiveSummary.csv         ← Red/green metrics at a glance
├── 00_ExportManifest.csv           ← Which files have data and row counts
├── 02_VMs.csv
├── 02_VM_Metrics.csv
├── 06_UnattachedDisks.csv
├── 07_OpenNSGRules.csv
├── 12_HighRiskRoles.csv
├── 13_ExpiringSecretsCerts.csv
├── 15_UnprotectedVMs.csv
├── ... (60+ CSVs total)
└── AzureAssessment_20260320-1430.zip   ← Everything bundled
```

### Downloading from Azure Cloud Shell

The script auto-detects Cloud Shell and copies the zip to your home directory.

```powershell
# Option 1 — Built-in download (easiest, < 1GB)
download ~/AzureAssessment_20260320-1430.zip

# Option 2 — Cloud Shell file browser
#   Click the file-browser icon in the toolbar → right-click zip → Download

# Option 3 — Upload to Storage Account + generate SAS link (for sharing / > 1GB)
$ctx = (Get-AzStorageAccount -ResourceGroupName 'rg-name' -Name 'storagename').Context
Set-AzStorageBlobContent -File './AzureAssessment_20260320-1430.zip' -Container 'assessments' -Blob 'assessment.zip' -Context $ctx
New-AzStorageBlobSASToken -Container 'assessments' -Blob 'assessment.zip' -Context $ctx -Permission r -ExpiryTime (Get-Date).AddHours(24) -FullUri
```

---

## Permissions Required

### Assessment Script (read-only)

The assessment script is entirely read-only — it never creates, modifies, or deletes resources. Each role below grants access to a specific category of data that the script collects.

| Role | Scope | What it unlocks | Detailed reason |
|------|-------|-----------------|-----------------|
| **Reader** | All target subscriptions | Core resource inventory across all 19 assessment categories | The script calls 40+ `Get-Az*` cmdlets (`Get-AzVM`, `Get-AzVirtualNetwork`, `Get-AzSqlServer`, `Get-AzDisk`, `Get-AzAksCluster`, `Get-AzStorageAccount`, etc.) to enumerate every resource type. Without Reader, the script cannot see any resources and produces empty CSVs. This single role powers Sections 01–12 and parts of 15–18. |
| **Reader** | Management Group (root) | Management Group hierarchy (Section 19) | `Get-AzManagementGroup` requires read access at the management group scope — subscription-level Reader is not sufficient. The script walks the full management group tree to map your tenant's organizational hierarchy. If unavailable, only Section 19 is skipped. |
| **Security Reader** | All target subscriptions | Defender for Cloud posture, Secure Score, and active security alerts (Section 13) | The script calls `Get-AzSecurityPricing` to audit which Defender plans are enabled (VMs, SQL, Storage, etc.), `Get-AzSecuritySecureScore` to capture your overall security score, and `Get-AzSecurityAlert` to export active threat alerts. These APIs are behind the Security resource provider and require Security Reader — standard Reader cannot access them. |
| **Key Vault Reader** or Access Policy `List` | Each Key Vault | Secrets and certificates approaching expiry (Section 13) | The script calls `Get-AzKeyVaultSecret` and `Get-AzKeyVaultCertificate` on every vault to identify secrets and certificates expiring within 30/60/90 days. Key Vault has its own access control plane — subscription Reader can list vaults but cannot read their contents. You need either the Key Vault Reader RBAC role (if using RBAC authorization) or a Key Vault access policy granting `List` permission for secrets and certificates. |
| **Monitoring Reader** | All target subscriptions | VM CPU/memory metrics, diagnostic settings, alert rules, and action groups (Sections 02, 08, 16) | `Get-AzMetric` retrieves CPU percentage (and DTU for SQL) over the configured lookback window to identify idle, underutilized, and right-sizing candidates. `Get-AzDiagnosticSetting` checks whether each resource is sending logs/metrics to Log Analytics. `Get-AzMetricAlertRuleV2` and `Get-AzActionGroup` audit your alerting coverage. These Monitor APIs require Monitoring Reader — standard Reader cannot query metric data or alert configurations. |
| **Billing Reader** | Subscription or Enrollment | Cost breakdown by service, budgets, and reservation utilization (Section 14) | `Get-AzConsumptionUsageDetail` pulls the last 30 days of spend grouped by service to show where money is going. `Get-AzConsumptionBudget` lists configured budgets and their thresholds. `Get-AzReservation` checks RI utilization so you can spot underused reservations. Consumption and billing APIs are access-controlled separately from resource data — without Billing Reader, Section 14 (Cost) is skipped entirely. |
| **Directory Reader** *(Entra ID role)* | Tenant | *Optional* — Entra ID users, Conditional Access policies, app registrations, and license counts | Only needed if you run the Microsoft Graph sections. The script uses `Get-MgUser`, `Get-MgIdentityConditionalAccessPolicy`, and `Get-MgApplication` to audit identity posture. This is an Entra ID directory role (not an Azure RBAC role) and must be assigned in the Entra admin center. If skipped, all other assessment sections still run normally. |

> **Shortcut:** The built-in **Reader** + **Security Reader** + **Monitoring Reader** + **Billing Reader** roles at subscription scope cover everything except Key Vault secrets and Entra ID. For a quick engagement, request **Reader** at the management group root and add the others at subscription scope.

### Prep Script (makes changes)

The Prep script installs monitoring agents and creates resources so that the assessment script can collect utilization metrics. It requires write access. Each role below covers a specific set of changes the script makes.

| Role | Scope | What it unlocks | Detailed reason |
|------|-------|-----------------|-----------------|
| **Contributor** | All target subscriptions | Resource creation, agent installation, Data Collection Rules, and provider registration | The script calls `New-AzResourceGroup` and `New-AzOperationalInsightsWorkspace` to create the Log Analytics workspace that receives all monitoring data. It uses `Set-AzVMExtension` to deploy Azure Monitor Agent (AMA) and Dependency Agent to every VM. It makes REST API calls (`PUT .../dataCollectionRules/...`) to create Windows and Linux performance counter DCRs (CPU, memory, disk, network at 60-second intervals) and associate them with VMs. Finally, `Register-AzResourceProvider` ensures Microsoft.Insights and Microsoft.AlertsManagement are registered. Contributor is the broadest role here and covers all of these operations. |
| **Monitoring Contributor** | All target subscriptions | Diagnostic settings on 16 resource types and the VMInsights solution | `New-AzDiagnosticSetting` is called for each resource type (VMs, SQL, Storage, NSGs, Key Vaults, etc.) to route platform logs and metrics to the Log Analytics workspace. `Set-AzOperationalInsightsIntelligencePack` enables the VMInsights solution on the workspace for connection mapping. These are Monitor resource provider write operations that require Monitoring Contributor specifically — Contributor alone may not include write access to diagnostic settings in all configurations. |
| **Virtual Machine Contributor** | All target subscriptions | System-assigned managed identity and VM extension installation | `Update-AzVM -IdentityType SystemAssigned` enables the system-assigned managed identity on each VM — this is a prerequisite for Azure Monitor Agent, which authenticates using this identity instead of certificates or keys. `Set-AzVMExtension` then installs the AMA and Dependency Agent extensions. Without this role, VMs cannot authenticate to send metrics and the monitoring pipeline fails silently. |
| **Log Analytics Contributor** | Workspace resource group | Workspace creation and solution enablement | `New-AzOperationalInsightsWorkspace` creates the workspace (SKU: PerGB2018, 30-day retention) that serves as the central destination for all collected metrics and logs. `Set-AzOperationalInsightsIntelligencePack` enables the VMInsights intelligence pack. This role is scoped narrowly to just the workspace resource group — it does not grant write access to other resources. |

> **Shortcut:** **Contributor** at subscription scope covers all of the above. If you want least-privilege, use the individual roles listed.

### Microsoft Graph Scopes (optional, Entra ID only)

If running the Entra ID sections, connect with:
```powershell
Connect-MgGraph -Scopes 'User.Read.All','Policy.Read.All','Organization.Read.All','Application.Read.All'
```

| Scope | Why |
|-------|-----|
| `User.Read.All` | Enumerate all Entra ID users, their sign-in status, MFA registration, and license assignments for identity coverage analysis |
| `Policy.Read.All` | Read Conditional Access policies to audit MFA enforcement, device compliance requirements, and session controls |
| `Organization.Read.All` | Read tenant-level configuration including verified domains, directory sync status, and organization settings |
| `Application.Read.All` | List app registrations and service principals to identify apps with expiring credentials or excessive permissions |

---

## Prerequisites

**Required modules** (Prep script option [2] installs these automatically):

```
Az.Accounts          Az.Resources        Az.Compute          Az.Network
Az.Storage           Az.Monitor          Az.OperationalInsights  Az.Sql
Az.CosmosDB          Az.KeyVault         Az.RecoveryServices Az.Security
Az.Advisor           Az.PolicyInsights   Az.Aks              Az.ContainerRegistry
Az.RedisCache        Az.ConnectedMachine Az.Dns              Az.PrivateDns
Az.Billing
```

**Optional** (for Entra ID / Conditional Access sections):
```
Microsoft.Graph.Users
Microsoft.Graph.Identity.SignIns
Microsoft.Graph.Applications
```

---

## Recommended Workflow

```
Day 1       Run Azure-Assessment-Prep.ps1 → Option [A]
            Enables agents, DCRs, diagnostics across all VMs and resources

Day 1-14    Metrics accumulate (CPU, memory, disk, network)

Day 14+     Run Azure-Assessment-Complete.ps1
            Collects everything into timestamped CSVs + zip

            Download zip → review Executive Summary → build findings report
```

If you need a quick inventory without utilization data, you can skip the prep and run the assessment immediately with `-SkipMetrics`.

---

## Run via Azure Lighthouse + GDAP (partner mode)

`Azure-Assessment-Lighthouse.ps1` lets a Centre operator run the assessment (and optionally the prep) against customer tenants delegated to Centre via Azure Lighthouse — without leaving Centre's partner tenant. The Complete and Prep scripts themselves are unchanged for direct-tenant Cloud Shell use; the wrapper just orchestrates them per customer.

### Prerequisites

**Lighthouse delegation** (for Azure resource access):

Centre publishes a Lighthouse onboarding ARM template (managed outside this repo). Customers deploy it once to delegate the following built-in roles to a Centre security group at subscription scope:

| Role | Needed for |
|------|-----------|
| Reader | Sections 01–12, 15–18 inventory |
| Security Reader | Section 13 Defender, Secure Score, alerts |
| Monitoring Reader | Sections 02 / 08 metrics, Section 16 diagnostics/alerts |
| Billing Reader | Section 14 cost / consumption / reservations / budgets |
| Contributor | Prep — resource creation, provider registration |
| Monitoring Contributor | Prep — diagnostic settings, VMInsights |
| Virtual Machine Contributor | Prep — managed identity + AMA / DA extensions |
| Log Analytics Contributor | Prep — workspace creation |

**GDAP relationship** (for Microsoft Graph / Entra ID access):

Lighthouse covers Azure ARM only — Microsoft Graph is per-tenant and must be delegated separately. As Centre's customers' CSP partner, request a GDAP relationship assigning **Directory Readers** + **Security Reader** (or **Global Reader** as a shortcut) to the same Centre group. Then pass `-ConnectGraph` so the wrapper connects Graph to each customer tenant via `Connect-MgGraph -TenantId <customer>`.

> Note: the Complete script does not currently include Graph-based Entra ID sections. The `-ConnectGraph` switch is wired through the wrapper so the same UX works once those sections land.

### Usage

```powershell
# Discover delegated customers, pick one interactively
.\Azure-Assessment-Lighthouse.ps1

# Run against one specific customer
.\Azure-Assessment-Lighthouse.ps1 `
    -CustomerTenantId 11111111-1111-1111-1111-111111111111 `
    -CustomerName "Acme"

# Sweep every delegated customer (Assessment only)
.\Azure-Assessment-Lighthouse.ps1 -All -Mode Assessment

# Full prep + assessment for one customer
.\Azure-Assessment-Lighthouse.ps1 `
    -CustomerTenantId <guid> -CustomerName "Acme" -Mode Both

# Include Graph (requires GDAP + Microsoft.Graph.Authentication module)
.\Azure-Assessment-Lighthouse.ps1 -All -ConnectGraph
```

### Output layout

```
LighthouseAssessments/
├── Acme_20260615-1430/
│   ├── 00_ExecutiveSummary.csv         ← header rows include customer + tenant
│   ├── 02_VMs.csv, 06_UnattachedDisks.csv, ... (all standard CSVs)
│   └── Acme_AzureAssessment_20260615-1430.zip
├── Globex_20260615-1430/
│   └── ...
└── Lighthouse_Rollup_20260615-1430.csv  ← per-customer pass/fail + duration
```

### Wrapper parameters

| Parameter | Default | Purpose |
|-----------|---------|---------|
| `-CustomerTenantId` | — | GUID of a single customer tenant. Omit for picker / `-All` |
| `-CustomerName` | TenantId | Friendly label for output dir/zip |
| `-All` | off | Loop every delegated customer |
| `-Mode` | `Assessment` | `Assessment`, `Prep`, or `Both` |
| `-OutputRoot` | `./LighthouseAssessments` | Parent dir for per-customer outputs |
| `-SkipMetrics` | off | Pass-through to Assessment for speed |
| `-DaysBack` | `30` | Pass-through metric lookback window |
| `-PartnerTenantId` | current ctx | Override partner tenant (for `Connect-AzAccount -Tenant`) |
| `-ConnectGraph` | off | Connect Microsoft Graph to each customer via GDAP |

### Limitations under Lighthouse mode

- **Section 19 (Management Groups) is skipped.** Lighthouse cannot delegate management-group scope. Direct-tenant runs still collect it.
- **Key Vaults using Access Policy auth return no secrets/certs.** Lighthouse principals are only honored by RBAC-authorized vaults. The script prints a yellow warning per access-policy vault it encounters in Lighthouse mode.
- **Section 14 (Cost) depends on Billing Reader being included in the Lighthouse template.** EA / MCA billing scopes may require an additional billing-account role assignment that isn't part of the standard subscription-scope delegation.
- **Microsoft Graph (Entra ID, Conditional Access, app registrations) requires GDAP**, not Lighthouse. Use `-ConnectGraph` once Graph sections are present.

### Direct-tenant Cloud Shell flow is unchanged

The `-LighthouseMode`, `-CustomerName`, and `-CustomerTenantId` parameters on `Azure-Assessment-Complete.ps1` and `Azure-Assessment-Prep.ps1` all default to off/empty. Running either script the way today's docs show — from a customer's own Cloud Shell with no new flags — produces the same output as before.
