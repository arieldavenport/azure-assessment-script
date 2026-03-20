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

| Role | Scope | Why |
|------|-------|-----|
| **Reader** | All target subscriptions | Enumerate all resources, VMs, networking, databases, etc. |
| **Reader** | Management Group (root) | `Get-AzManagementGroup` hierarchy |
| **Security Reader** | All target subscriptions | Defender pricing, Secure Score, security alerts, policy state |
| **Key Vault Reader** or Access Policy `List` | Each Key Vault | List secrets/certificates and check expiry dates |
| **Monitoring Reader** | All target subscriptions | Read metrics (CPU, DTU), diagnostic settings, alert rules, action groups |
| **Billing Reader** | Subscription or Enrollment | `Get-AzConsumptionUsageDetail`, budgets, reservations |
| **Directory Reader** *(Entra ID role)* | Tenant | *Optional* — only needed for Section 15 (Entra users, Conditional Access, licenses via Microsoft Graph) |

> **Shortcut:** The built-in **Reader** + **Security Reader** + **Monitoring Reader** + **Billing Reader** roles at subscription scope cover everything except Key Vault secrets and Entra ID. For a quick engagement, request **Reader** at the management group root and add the others at subscription scope.

### Prep Script (makes changes)

The Prep script installs agents and creates resources, so it needs write access:

| Role | Scope | Why |
|------|-------|-----|
| **Contributor** | All target subscriptions | Create Log Analytics workspace, install VM extensions (AMA, Dependency Agent), create Data Collection Rules and associations |
| **Monitoring Contributor** | All target subscriptions | Create/modify diagnostic settings on resources, enable VM Insights solution |
| **Virtual Machine Contributor** | All target subscriptions | Enable system-assigned managed identity on VMs (required for AMA) |
| **Log Analytics Contributor** | Workspace resource group | Create workspace, enable solutions |

> **Shortcut:** **Contributor** at subscription scope covers all of the above. If you want least-privilege, use the individual roles listed.

### Microsoft Graph Scopes (optional, Entra ID only)

If running the Entra ID sections, connect with:
```powershell
Connect-MgGraph -Scopes 'User.Read.All','Policy.Read.All','Organization.Read.All','Application.Read.All'
```

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
