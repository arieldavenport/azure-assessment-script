#Requires -Modules Az.Accounts, Az.Resources, Az.Compute, Az.Network, Az.Storage, Az.Monitor
<#
.SYNOPSIS
    Azure Environment Assessment - Complete 1-Shot Script
    Centre Technologies | March 2026

.DESCRIPTION
    Runs a comprehensive Azure environment assessment across ALL subscriptions in a tenant.
    Collects inventory, utilization, security, cost, and governance data.
    Exports everything to timestamped CSV files for offline analysis.

.NOTES
    Run from Azure Cloud Shell (PowerShell) or any terminal with Az modules installed.
    Some sections require optional modules: Az.ConnectedMachine, Az.Aks, Microsoft.Graph
    The script will gracefully skip sections where modules are not available.

.PARAMETER SubscriptionId
    Optional. Assess a single subscription instead of all enabled subscriptions.

.PARAMETER OutputPath
    Optional. Base output directory. Defaults to ./AzureAssessment_<timestamp>

.PARAMETER SkipMetrics
    Optional. Skip metric collection (CPU/Memory/DTU) to speed up the run.

.PARAMETER DaysBack
    Optional. Number of days to look back for metrics. Default 30.
#>

[CmdletBinding()]
param(
    [string]$SubscriptionId,
    [string]$OutputPath,
    [switch]$SkipMetrics,
    [int]$DaysBack = 30,
    [string[]]$SubscriptionInclude,
    [string[]]$SubscriptionExclude,
    [int]$MaxRetries = 3,
    [switch]$FailOnSectionError
)

#region ── Setup ──────────────────────────────────────────────────────────────
$ErrorActionPreference = 'Continue'
$timestamp = Get-Date -Format 'yyyyMMdd-HHmm'
if (-not $OutputPath) { $OutputPath = "./AzureAssessment_$timestamp" }
New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null

# Transcript logging
$transcriptPath = "$OutputPath/Assessment-Transcript.log"
try { Start-Transcript -Path $transcriptPath -Append | Out-Null } catch {}

$startTime = Get-Date
$endTime = Get-Date
$metricsStart = (Get-Date).AddDays(-$DaysBack)

# Summary collector
$summaryData = [System.Collections.ArrayList]::new()

function Write-Section {
    param([string]$Title)
    Write-Host "`n╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║  $Title" -ForegroundColor Cyan
    Write-Host "╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
}

function Write-SubSection {
    param([string]$Title)
    Write-Host "  ► $Title" -ForegroundColor Yellow
}

function Export-SafeCsv {
    param($Data, [string]$FileName)
    $path = "$OutputPath/$FileName"
    if ($Data -and @($Data).Count -gt 0) {
        $Data | Export-Csv $path -NoTypeInformation
        $count = @($Data).Count
        Write-Host "    ✓ Exported $count rows → $FileName" -ForegroundColor Green
        $null = $summaryData.Add([PSCustomObject]@{ File=$FileName; Rows=$count })
    } else {
        Write-Host "    – No data for $FileName" -ForegroundColor DarkGray
    }
}

function Test-ModuleAvailable {
    param([string]$ModuleName)
    return [bool](Get-Module -ListAvailable -Name $ModuleName 2>$null)
}

function Get-MetricSafe {
    param([string]$ResourceId, [string]$MetricName, [string]$Aggregation = 'Average')
    try {
        $metric = Get-AzMetric -ResourceId $ResourceId `
            -MetricName $MetricName `
            -TimeGrain 1.00:00:00 `
            -StartTime $metricsStart `
            -EndTime $endTime `
            -AggregationType $Aggregation `
            -WarningAction SilentlyContinue `
            -ErrorAction SilentlyContinue
        return $metric
    } catch { return $null }
}

function Invoke-WithRetry {
    param([scriptblock]$ScriptBlock, [int]$Retries = $MaxRetries, [int]$BaseDelay = 2)
    for ($i = 0; $i -lt $Retries; $i++) {
        try { return & $ScriptBlock }
        catch {
            if ($i -eq ($Retries - 1)) { throw }
            if ($_.Exception.Message -match '429|throttle|too many requests') {
                $delay = $BaseDelay * [math]::Pow(2, $i) + (Get-Random -Minimum 0 -Maximum 2)
                Write-Host "    Throttled, retrying in ${delay}s..." -ForegroundColor DarkYellow
                Start-Sleep -Seconds $delay
            } else { throw }
        }
    }
}

# Section error/timing tracking
$sectionErrors = [System.Collections.ArrayList]::new()
$sectionTimings = [System.Collections.ArrayList]::new()
#endregion

#region ── Authentication Check ───────────────────────────────────────────────
Write-Section "0. Authentication & Subscription Selection"
$ctx = Get-AzContext
if (-not $ctx) {
    Write-Host "  Not authenticated. Running Connect-AzAccount..." -ForegroundColor Yellow
    Connect-AzAccount
    $ctx = Get-AzContext
}
Write-Host "  Signed in as: $($ctx.Account.Id)" -ForegroundColor Green
Write-Host "  Tenant:       $($ctx.Tenant.Id)" -ForegroundColor Green

if ($SubscriptionId) {
    $subscriptions = @(Get-AzSubscription -SubscriptionId $SubscriptionId)
} else {
    $subscriptions = Get-AzSubscription | Where-Object { $_.State -eq 'Enabled' }
}
if ($SubscriptionInclude) {
    $subscriptions = @($subscriptions | Where-Object { $_.Name -in $SubscriptionInclude -or $_.Id -in $SubscriptionInclude })
}
if ($SubscriptionExclude) {
    $subscriptions = @($subscriptions | Where-Object { $_.Name -notin $SubscriptionExclude -and $_.Id -notin $SubscriptionExclude })
}
Write-Host "  Subscriptions to assess: $($subscriptions.Count)" -ForegroundColor Green

# Export subscription list with offer/agreement type
$subscriptions | ForEach-Object {
    $quotaId = $_.SubscriptionPolicies.QuotaId
    $offerType = switch -Wildcard ($quotaId) {
        'EnterpriseAgreement*'    { 'EA' }
        '*MS-AZR-0017P*'          { 'EA' }
        '*MS-AZR-0145P*'          { 'CSP' }
        '*MS-AZR-0146P*'          { 'CSP' }
        '*MS-AZR-0003P*'          { 'PAYG' }
        '*MS-AZR-0023P*'          { 'PAYG' }
        'MicrosoftCustomer*'      { 'MCA' }
        '*MS-AZR-0015P*'          { 'MCA' }
        'Sponsored*'              { 'Sponsored' }
        '*MSDN*'                  { 'MSDN' }
        '*MS-AZR-0063P*'          { 'Free Trial' }
        '*MicrosoftPartner*'      { 'MPN' }
        default                   { 'Unknown' }
    }
    [PSCustomObject]@{
        Name          = $_.Name
        Id            = $_.Id
        State         = $_.State
        TenantId      = $_.TenantId
        QuotaId       = $quotaId
        SpendingLimit = $_.SubscriptionPolicies.SpendingLimit
        OfferType     = $offerType
    }
} | Export-Csv "$OutputPath/Subscriptions.csv" -NoTypeInformation
#endregion

# ═══════════════════════════════════════════════════════════════════════════════
# COLLECTION ARRAYS - Accumulate across all subscriptions
# ═══════════════════════════════════════════════════════════════════════════════
$allResources          = [System.Collections.ArrayList]::new()
$allVMs                = [System.Collections.ArrayList]::new()
$allVMMetrics          = [System.Collections.ArrayList]::new()
$allVMSS               = [System.Collections.ArrayList]::new()
$allDisks              = [System.Collections.ArrayList]::new()
$allSnapshots          = [System.Collections.ArrayList]::new()
$allStorageAccounts    = [System.Collections.ArrayList]::new()
$allAppServicePlans    = [System.Collections.ArrayList]::new()
$allWebApps            = [System.Collections.ArrayList]::new()
$allFunctions          = [System.Collections.ArrayList]::new()
$allLogicApps          = [System.Collections.ArrayList]::new()
$allSQLServers         = [System.Collections.ArrayList]::new()
$allSQLDatabases       = [System.Collections.ArrayList]::new()
$allSQLManagedInst     = [System.Collections.ArrayList]::new()
$allCosmosDB           = [System.Collections.ArrayList]::new()
$allMySQL              = [System.Collections.ArrayList]::new()
$allPostgreSQL         = [System.Collections.ArrayList]::new()
$allRedisCache         = [System.Collections.ArrayList]::new()
$allVNets              = [System.Collections.ArrayList]::new()
$allPublicIPs          = [System.Collections.ArrayList]::new()
$allNSGRules           = [System.Collections.ArrayList]::new()
$allLBs                = [System.Collections.ArrayList]::new()
$allAppGateways        = [System.Collections.ArrayList]::new()
$allFirewalls          = [System.Collections.ArrayList]::new()
$allFrontDoors         = [System.Collections.ArrayList]::new()
$allBastions           = [System.Collections.ArrayList]::new()
$allNATGateways        = [System.Collections.ArrayList]::new()
$allVPNGateways        = [System.Collections.ArrayList]::new()
$allExpressRoute       = [System.Collections.ArrayList]::new()
$allPeerings           = [System.Collections.ArrayList]::new()
$allPrivateEndpoints   = [System.Collections.ArrayList]::new()
$allPrivateDNS         = [System.Collections.ArrayList]::new()
$allPublicDNS          = [System.Collections.ArrayList]::new()
$allNSGs               = [System.Collections.ArrayList]::new()
$allAKS                = [System.Collections.ArrayList]::new()
$allAKSNodePools       = [System.Collections.ArrayList]::new()
$allContainerInstances = [System.Collections.ArrayList]::new()
$allContainerApps      = [System.Collections.ArrayList]::new()
$allContainerRegistries= [System.Collections.ArrayList]::new()
$allKeyVaults          = [System.Collections.ArrayList]::new()
$allExpiringSecrets    = [System.Collections.ArrayList]::new()
$allRBAC               = [System.Collections.ArrayList]::new()
$allCustomRoles        = [System.Collections.ArrayList]::new()
$allPolicyNonCompliant = [System.Collections.ArrayList]::new()
$allPolicyAssignments  = [System.Collections.ArrayList]::new()
$allDefenderPricing    = [System.Collections.ArrayList]::new()
$allSecureScore        = [System.Collections.ArrayList]::new()
$allSecurityAlerts     = [System.Collections.ArrayList]::new()
$allAdvisorCost        = [System.Collections.ArrayList]::new()
$allAdvisorPerf        = [System.Collections.ArrayList]::new()
$allAdvisorSecurity    = [System.Collections.ArrayList]::new()
$allAdvisorAll         = [System.Collections.ArrayList]::new()
$allBackupItems        = [System.Collections.ArrayList]::new()
$allUnprotectedVMs     = [System.Collections.ArrayList]::new()
$allLAWorkspaces       = [System.Collections.ArrayList]::new()
$allDiagSettings       = [System.Collections.ArrayList]::new()
$allAlertRules         = [System.Collections.ArrayList]::new()
$allActionGroups       = [System.Collections.ArrayList]::new()
$allTagCompliance      = [System.Collections.ArrayList]::new()
$allResourceLocks      = [System.Collections.ArrayList]::new()
$allRecoveryVaults     = [System.Collections.ArrayList]::new()
$allServiceBus         = [System.Collections.ArrayList]::new()
$allEventHubs          = [System.Collections.ArrayList]::new()
$allAPIM               = [System.Collections.ArrayList]::new()
$allDataFactories      = [System.Collections.ArrayList]::new()
$allAutomationAccts    = [System.Collections.ArrayList]::new()
$allBudgets            = [System.Collections.ArrayList]::new()
$allArcMachines        = [System.Collections.ArrayList]::new()
$allNetworkWatchers    = [System.Collections.ArrayList]::new()
$allCDNProfiles        = [System.Collections.ArrayList]::new()
$allConsumption        = [System.Collections.ArrayList]::new()
$allReservations       = [System.Collections.ArrayList]::new()
$allMgmtGroups         = [System.Collections.ArrayList]::new()
$allFileShares         = [System.Collections.ArrayList]::new()

# ═══════════════════════════════════════════════════════════════════════════════
# ITERATE SUBSCRIPTIONS
# ═══════════════════════════════════════════════════════════════════════════════
foreach ($sub in $subscriptions) {
    Write-Host "`n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor White
    Write-Host "  SUBSCRIPTION: $($sub.Name) ($($sub.Id))" -ForegroundColor White
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor White
    Set-AzContext -SubscriptionId $sub.Id | Out-Null
    $subName = $sub.Name

    #region ── 1. Resource Inventory ──────────────────────────────────────────
    Write-Section "1. Resource Inventory"
    $resources = Get-AzResource
    $resources | Group-Object ResourceType |
        Sort-Object Count -Descending |
        ForEach-Object {
            $null = $allResources.Add([PSCustomObject]@{
                Subscription = $subName
                ResourceType = $_.Name
                Count        = $_.Count
            })
        }
    Write-Host "    Total resources: $($resources.Count)" -ForegroundColor Green
    #endregion

    #region ── 2. Compute: Virtual Machines ───────────────────────────────────
    Write-Section "2. Compute: Virtual Machines"
    Write-SubSection "VM Inventory & Status"
    $vms = Get-AzVM -Status -ErrorAction SilentlyContinue
    foreach ($vm in $vms) {
        $null = $allVMs.Add([PSCustomObject]@{
            Subscription   = $subName
            Name           = $vm.Name
            ResourceGroup  = $vm.ResourceGroupName
            Location       = $vm.Location
            VMSize         = $vm.HardwareProfile.VmSize
            OsType         = $vm.StorageProfile.OsDisk.OsType
            PowerState     = $vm.PowerState
            AvailabilityZone = ($vm.Zones -join ', ')
            DiskEncryption = if ($vm.StorageProfile.OsDisk.EncryptionSettings -and $vm.StorageProfile.OsDisk.EncryptionSettings.Enabled) { 'Enabled' } else { 'Check ADE' }
        })
    }

    if (-not $SkipMetrics -and $vms) {
        Write-SubSection "VM CPU/Memory Metrics (${DaysBack}d)"
        $runningVMs = @($vms | Where-Object { $_.PowerState -eq 'VM running' })
        $vmCount = $runningVMs.Count
        $vmIndex = 0
        foreach ($vm in $runningVMs) {
            $vmIndex++
            Write-Host "    [$vmIndex/$vmCount] Collecting metrics for $($vm.Name)..." -ForegroundColor DarkGray -NoNewline
            try {
                $cpuMetric = Get-MetricSafe -ResourceId $vm.Id -MetricName 'Percentage CPU'
                $avgCpu = if ($cpuMetric) { ($cpuMetric.Data | Measure-Object -Property Average -Average).Average } else { -1 }
                $maxCpu = if ($cpuMetric) { ($cpuMetric.Data | Measure-Object -Property Average -Maximum).Maximum } else { -1 }
                $null = $allVMMetrics.Add([PSCustomObject]@{
                    Subscription = $subName
                    VM           = $vm.Name
                    VMSize       = $vm.HardwareProfile.VmSize
                    AvgCPU       = [math]::Round($avgCpu, 1)
                    PeakCPU      = [math]::Round($maxCpu, 1)
                    Recommendation = if ($avgCpu -lt 5) { 'Candidate for DEALLOCATION' }
                                     elseif ($avgCpu -lt 15) { 'Candidate for DOWNSIZE' }
                                     else { 'OK' }
                })
                Write-Host " done" -ForegroundColor DarkGray
            } catch { Write-Host " failed" -ForegroundColor DarkYellow }
        }
    }

    # VM Scale Sets
    Write-SubSection "VM Scale Sets"
    try {
        Get-AzVmss -ErrorAction SilentlyContinue | ForEach-Object {
            $null = $allVMSS.Add([PSCustomObject]@{
                Subscription  = $subName
                Name          = $_.Name
                ResourceGroup = $_.ResourceGroupName
                Location      = $_.Location
                SKU           = if ($_.Sku) { $_.Sku.Name } else { $null }
                Capacity      = if ($_.Sku) { $_.Sku.Capacity } else { $null }
                UpgradePolicy = if ($_.UpgradePolicy) { $_.UpgradePolicy.Mode } else { $null }
                Zones         = ($_.Zones -join ', ')
            })
        }
    } catch {}
    #endregion

    #region ── 3. App Services ────────────────────────────────────────────────
    Write-Section "3. App Service Plans & Web Apps"
    Write-SubSection "App Service Plans"
    $plans = Get-AzAppServicePlan -ErrorAction SilentlyContinue
    foreach ($plan in $plans) {
        $apps = Get-AzWebApp -AppServicePlan $plan.Name -ResourceGroupName $plan.ResourceGroup -ErrorAction SilentlyContinue
        $null = $allAppServicePlans.Add([PSCustomObject]@{
            Subscription  = $subName
            Name          = $plan.Name
            ResourceGroup = $plan.ResourceGroup
            Location      = $plan.Location
            SKU           = if ($plan.Sku) { $plan.Sku.Name } else { $null }
            Tier          = if ($plan.Sku) { $plan.Sku.Tier } else { $null }
            Workers       = if ($plan.Sku) { $plan.Sku.Capacity } else { $null }
            AppCount      = @($apps).Count
            Apps          = ($apps.Name -join ', ')
            Status        = $plan.Status
        })
    }

    Write-SubSection "Web Apps"
    Get-AzWebApp -ErrorAction SilentlyContinue | ForEach-Object {
        $null = $allWebApps.Add([PSCustomObject]@{
            Subscription   = $subName
            Name           = $_.Name
            ResourceGroup  = $_.ResourceGroup
            Plan           = if ($_.AppServicePlanId) { $_.AppServicePlanId.Split('/')[-1] } else { $null }
            State          = $_.State
            HttpsOnly      = $_.HttpsOnly
            MinTlsVersion  = if ($_.SiteConfig) { $_.SiteConfig.MinTlsVersion } else { $null }
            AlwaysOn       = if ($_.SiteConfig) { $_.SiteConfig.AlwaysOn } else { $null }
            Runtime        = ($_.SiteConfig.LinuxFxVersion + $_.SiteConfig.WindowsFxVersion)
        })
    }
    #endregion

    #region ── 4. Azure Functions ──────────────────────────────────────────────
    Write-Section "4. Azure Functions"
    try {
        Get-AzResource -ResourceType 'Microsoft.Web/sites' -ErrorAction SilentlyContinue |
            Where-Object { $_.Kind -match 'functionapp' } | ForEach-Object {
                $fa = Get-AzWebApp -ResourceGroupName $_.ResourceGroupName -Name $_.Name -ErrorAction SilentlyContinue
                if ($fa) {
                    $null = $allFunctions.Add([PSCustomObject]@{
                        Subscription  = $subName
                        Name          = $fa.Name
                        ResourceGroup = $fa.ResourceGroup
                        State         = $fa.State
                        Runtime       = ($fa.SiteConfig.LinuxFxVersion + $fa.SiteConfig.WindowsFxVersion)
                        HttpsOnly     = $fa.HttpsOnly
                        Plan          = if ($fa.AppServicePlanId) { $fa.AppServicePlanId.Split('/')[-1] } else { $null }
                        Kind          = $_.Kind
                    })
                }
            }
    } catch {}
    #endregion

    #region ── 5. Logic Apps ──────────────────────────────────────────────────
    Write-Section "5. Logic Apps"
    try {
        Get-AzResource -ResourceType 'Microsoft.Logic/workflows' -ErrorAction SilentlyContinue | ForEach-Object {
            $null = $allLogicApps.Add([PSCustomObject]@{
                Subscription  = $subName
                Name          = $_.Name
                ResourceGroup = $_.ResourceGroupName
                Location      = $_.Location
                State         = $_.Properties.state
            })
        }
    } catch {}
    #endregion

    #region ── 6. Storage ─────────────────────────────────────────────────────
    Write-Section "6. Storage Assessment"
    Write-SubSection "Managed Disks"
    Get-AzDisk -ErrorAction SilentlyContinue | ForEach-Object {
        $null = $allDisks.Add([PSCustomObject]@{
            Subscription  = $subName
            Name          = $_.Name
            ResourceGroup = $_.ResourceGroupName
            AttachedTo    = if ($_.ManagedBy) { $_.ManagedBy.Split('/')[-1] } else { 'UNATTACHED' }
            DiskSizeGB    = $_.DiskSizeGB
            SKU           = if ($_.Sku) { $_.Sku.Name } else { $null }
            IOPS          = $_.DiskIOPSReadWrite
            ThroughputMBps = $_.DiskMBpsReadWrite
            Encryption    = if ($_.EncryptionSettingsCollection) { $_.EncryptionSettingsCollection.Enabled } else { $null }
            Location      = $_.Location
            CreatedDate   = $_.TimeCreated
        })
    }

    Write-SubSection "Snapshots"
    Get-AzSnapshot -ErrorAction SilentlyContinue | ForEach-Object {
        $null = $allSnapshots.Add([PSCustomObject]@{
            Subscription  = $subName
            Name          = $_.Name
            ResourceGroup = $_.ResourceGroupName
            DiskSizeGB    = $_.DiskSizeGB
            AgeDays       = ((Get-Date) - $_.TimeCreated).Days
            CreatedDate   = $_.TimeCreated.ToString('yyyy-MM-dd')
            Recommendation = if (((Get-Date) - $_.TimeCreated).Days -gt 90) { 'REVIEW - Over 90 days old' } else { 'OK' }
        })
    }

    Write-SubSection "Storage Accounts"
    $storAccts = Get-AzStorageAccount -ErrorAction SilentlyContinue
    foreach ($sa in $storAccts) {
        $null = $allStorageAccounts.Add([PSCustomObject]@{
            Subscription   = $subName
            Name           = $sa.StorageAccountName
            ResourceGroup  = $sa.ResourceGroupName
            SKU            = if ($sa.Sku) { $sa.Sku.Name } else { $null }
            Kind           = $sa.Kind
            AccessTier     = $sa.AccessTier
            HttpsOnly      = $sa.EnableHttpsTrafficOnly
            MinTLS         = $sa.MinimumTlsVersion
            PublicAccess    = $sa.AllowBlobPublicAccess
            Location       = $sa.PrimaryLocation
        })

        # File Shares
        try {
            $saContext = $sa.Context
            Get-AzStorageShare -Context $saContext -ErrorAction SilentlyContinue | ForEach-Object {
                $null = $allFileShares.Add([PSCustomObject]@{
                    Subscription   = $subName
                    StorageAccount = $sa.StorageAccountName
                    ShareName      = $_.Name
                    QuotaGB        = $_.ShareProperties.QuotaInGB
                    AccessTier     = $_.ShareProperties.AccessTier
                })
            }
        } catch {}
    }
    #endregion

    #region ── 7. Networking ──────────────────────────────────────────────────
    Write-Section "7. Networking"
    Write-SubSection "Virtual Networks & Subnets"
    Get-AzVirtualNetwork -ErrorAction SilentlyContinue | ForEach-Object {
        $vnet = $_
        $vnet.Subnets | ForEach-Object {
            $null = $allVNets.Add([PSCustomObject]@{
                Subscription = $subName
                VNet         = $vnet.Name
                AddressSpace = ($vnet.AddressSpace.AddressPrefixes -join ', ')
                Subnet       = $_.Name
                SubnetPrefix = ($_.AddressPrefix -join ', ')
                NSG          = if ($_.NetworkSecurityGroup) { $_.NetworkSecurityGroup.Id.Split('/')[-1] } else { 'NONE' }
                RouteTable   = if ($_.RouteTable) { $_.RouteTable.Id.Split('/')[-1] } else { 'NONE' }
            })
        }

        # VNet Peerings
        $_.VirtualNetworkPeerings | ForEach-Object {
            $null = $allPeerings.Add([PSCustomObject]@{
                Subscription       = $subName
                VNet               = $vnet.Name
                PeeringName        = $_.Name
                RemoteVNet         = if ($_.RemoteVirtualNetwork -and $_.RemoteVirtualNetwork.Id) { $_.RemoteVirtualNetwork.Id.Split('/')[-1] } else { $null }
                State              = $_.PeeringState
                AllowForwarded     = $_.AllowForwardedTraffic
                AllowGatewayTransit = $_.AllowGatewayTransit
                UseRemoteGateway   = $_.UseRemoteGateways
            })
        }
    }

    Write-SubSection "Orphaned Public IPs"
    Get-AzPublicIpAddress -ErrorAction SilentlyContinue | ForEach-Object {
        if ($null -eq $_.IpConfiguration) {
            $null = $allPublicIPs.Add([PSCustomObject]@{
                Subscription  = $subName
                Name          = $_.Name
                ResourceGroup = $_.ResourceGroupName
                IpAddress     = $_.IpAddress
                SKU           = if ($_.Sku) { $_.Sku.Name } else { $null }
                Allocation    = $_.PublicIpAllocationMethod
            })
        }
    }

    Write-SubSection "NSG Rule Audit"
    Get-AzNetworkSecurityGroup -ErrorAction SilentlyContinue | ForEach-Object {
        $nsg = $_
        $_.SecurityRules | Where-Object {
            $_.Access -eq 'Allow' -and
            ($_.SourceAddressPrefix -eq '*' -or $_.SourceAddressPrefix -eq 'Internet') -and
            $_.Direction -eq 'Inbound'
        } | ForEach-Object {
            $severity = 'Medium'
            if ($_.DestinationPortRange -in @('22','3389','1433','3306','5432','445','*')) { $severity = 'CRITICAL' }
            $null = $allNSGRules.Add([PSCustomObject]@{
                Subscription  = $subName
                NSG           = $nsg.Name
                Rule          = $_.Name
                Priority      = $_.Priority
                DestPort      = $_.DestinationPortRange
                Source         = $_.SourceAddressPrefix
                Severity      = $severity
            })
        }
    }

    Write-SubSection "Load Balancers"
    Get-AzLoadBalancer -ErrorAction SilentlyContinue | ForEach-Object {
        $null = $allLBs.Add([PSCustomObject]@{
            Subscription  = $subName
            Name          = $_.Name
            ResourceGroup = $_.ResourceGroupName
            SKU           = if ($_.Sku) { $_.Sku.Name } else { $null }
            FrontendIPs   = $_.FrontendIpConfigurations.Count
            BackendPools  = $_.BackendAddressPools.Count
            Rules         = $_.LoadBalancingRules.Count
        })
    }

    Write-SubSection "Application Gateways"
    Get-AzApplicationGateway -ErrorAction SilentlyContinue | ForEach-Object {
        $null = $allAppGateways.Add([PSCustomObject]@{
            Subscription  = $subName
            Name          = $_.Name
            ResourceGroup = $_.ResourceGroupName
            Tier          = if ($_.Sku) { $_.Sku.Tier } else { $null }
            Capacity      = if ($_.Sku) { $_.Sku.Capacity } else { $null }
            WAFEnabled    = if ($_.WebApplicationFirewallConfiguration) { $_.WebApplicationFirewallConfiguration.Enabled } else { $null }
        })
    }

    Write-SubSection "Azure Firewalls"
    try {
        Get-AzFirewall -ErrorAction SilentlyContinue | ForEach-Object {
            $null = $allFirewalls.Add([PSCustomObject]@{
                Subscription  = $subName
                Name          = $_.Name
                ResourceGroup = $_.ResourceGroupName
                SKU           = if ($_.Sku) { $_.Sku.Tier } else { $null }
                ThreatIntel   = $_.ThreatIntelMode
                ProvisionState = $_.ProvisioningState
            })
        }
    } catch {}

    Write-SubSection "Azure Front Door"
    try {
        Get-AzResource -ResourceType 'Microsoft.Cdn/profiles' -ErrorAction SilentlyContinue |
            Where-Object { $_.Kind -match 'frontdoor' } | ForEach-Object {
                $null = $allFrontDoors.Add([PSCustomObject]@{
                    Subscription  = $subName
                    Name          = $_.Name
                    ResourceGroup = $_.ResourceGroupName
                    Location      = $_.Location
                    Kind          = $_.Kind
                })
            }
        Get-AzResource -ResourceType 'Microsoft.Network/frontDoors' -ErrorAction SilentlyContinue | ForEach-Object {
            $null = $allFrontDoors.Add([PSCustomObject]@{
                Subscription  = $subName
                Name          = $_.Name
                ResourceGroup = $_.ResourceGroupName
                Location      = $_.Location
                Kind          = 'Classic'
            })
        }
    } catch {}

    Write-SubSection "Azure Bastion"
    try {
        Get-AzResource -ResourceType 'Microsoft.Network/bastionHosts' -ErrorAction SilentlyContinue | ForEach-Object {
            $null = $allBastions.Add([PSCustomObject]@{
                Subscription  = $subName
                Name          = $_.Name
                ResourceGroup = $_.ResourceGroupName
                Location      = $_.Location
            })
        }
    } catch {}

    Write-SubSection "NAT Gateways"
    try {
        Get-AzNatGateway -ErrorAction SilentlyContinue | ForEach-Object {
            $null = $allNATGateways.Add([PSCustomObject]@{
                Subscription        = $subName
                Name                = $_.Name
                ResourceGroup       = $_.ResourceGroupName
                Location            = $_.Location
                IdleTimeoutMinutes  = $_.IdleTimeoutInMinutes
                PublicIpCount       = @($_.PublicIpAddresses).Count
            })
        }
    } catch {}

    Write-SubSection "VPN Gateways"
    Get-AzResource -ResourceType 'Microsoft.Network/virtualNetworkGateways' -ErrorAction SilentlyContinue | ForEach-Object {
        $gw = Get-AzVirtualNetworkGateway -ResourceId $_.ResourceId -ErrorAction SilentlyContinue
        if ($gw) {
            $null = $allVPNGateways.Add([PSCustomObject]@{
                Subscription  = $subName
                Name          = $gw.Name
                ResourceGroup = $gw.ResourceGroupName
                SKU           = if ($gw.Sku) { $gw.Sku.Name } else { $null }
                GatewayType   = $gw.GatewayType
                VpnType       = $gw.VpnType
                ActiveActive  = $gw.ActiveActive
            })
        }
    }

    Write-SubSection "ExpressRoute Circuits"
    Get-AzExpressRouteCircuit -ErrorAction SilentlyContinue | ForEach-Object {
        $null = $allExpressRoute.Add([PSCustomObject]@{
            Subscription  = $subName
            Name          = $_.Name
            SKU           = if ($_.Sku) { $_.Sku.Name } else { $null }
            Tier          = if ($_.Sku) { $_.Sku.Tier } else { $null }
            Bandwidth     = if ($_.ServiceProviderProperties) { $_.ServiceProviderProperties.BandwidthInMbps } else { $null }
            Provider      = if ($_.ServiceProviderProperties) { $_.ServiceProviderProperties.ServiceProviderName } else { $null }
            State         = $_.CircuitProvisioningState
        })
    }

    Write-SubSection "Private Endpoints & DNS"
    Get-AzPrivateEndpoint -ErrorAction SilentlyContinue | ForEach-Object {
        $null = $allPrivateEndpoints.Add([PSCustomObject]@{
            Subscription      = $subName
            Name              = $_.Name
            ResourceGroup     = $_.ResourceGroupName
            Subnet            = if ($_.Subnet -and $_.Subnet.Id) { $_.Subnet.Id.Split('/')[-1] } else { $null }
            PrivateLinkService = ($_.PrivateLinkServiceConnections.Name -join ', ')
        })
    }
    Get-AzPrivateDnsZone -ErrorAction SilentlyContinue | ForEach-Object {
        $null = $allPrivateDNS.Add([PSCustomObject]@{
            Subscription  = $subName
            Name          = $_.Name
            ResourceGroup = $_.ResourceGroupName
            RecordSets    = $_.NumberOfRecordSets
            VNetLinks     = $_.NumberOfVirtualNetworkLinks
        })
    }

    Write-SubSection "Public DNS Zones"
    try {
        Get-AzDnsZone -ErrorAction SilentlyContinue | ForEach-Object {
            $null = $allPublicDNS.Add([PSCustomObject]@{
                Subscription  = $subName
                Name          = $_.Name
                ResourceGroup = $_.ResourceGroupName
                RecordSets    = $_.NumberOfRecordSets
                NameServers   = ($_.NameServers -join ', ')
            })
        }
    } catch {}

    Write-SubSection "Network Watchers"
    try {
        Get-AzNetworkWatcher -ErrorAction SilentlyContinue | ForEach-Object {
            $null = $allNetworkWatchers.Add([PSCustomObject]@{
                Subscription      = $subName
                Name              = $_.Name
                ResourceGroup     = $_.ResourceGroupName
                Location          = $_.Location
                ProvisioningState = $_.ProvisioningState
            })
        }
    } catch {}

    Write-SubSection "CDN Profiles"
    try {
        Get-AzResource -ResourceType 'Microsoft.Cdn/profiles' -ErrorAction SilentlyContinue |
            Where-Object { $_.Kind -notmatch 'frontdoor' } | ForEach-Object {
                $null = $allCDNProfiles.Add([PSCustomObject]@{
                    Subscription  = $subName
                    Name          = $_.Name
                    ResourceGroup = $_.ResourceGroupName
                    Location      = $_.Location
                    SKU           = if ($_.Sku) { $_.Sku.Name } else { $null }
                })
            }
    } catch {}
    #endregion

    #region ── 8. Database Services ───────────────────────────────────────────
    Write-Section "8. Database Services"
    Write-SubSection "Azure SQL"
    Get-AzSqlServer -ErrorAction SilentlyContinue | ForEach-Object {
        $server = $_
        $null = $allSQLServers.Add([PSCustomObject]@{
            Subscription  = $subName
            ServerName    = $_.ServerName
            ResourceGroup = $_.ResourceGroupName
            Location      = $_.Location
            AdminLogin    = $_.SqlAdministratorLogin
            Version       = $_.ServerVersion
        })
        Get-AzSqlDatabase -ServerName $_.ServerName -ResourceGroupName $_.ResourceGroupName -ErrorAction SilentlyContinue |
            Where-Object { $_.DatabaseName -ne 'master' } | ForEach-Object {
                $null = $allSQLDatabases.Add([PSCustomObject]@{
                    Subscription     = $subName
                    Server           = $server.ServerName
                    Database         = $_.DatabaseName
                    Edition          = $_.Edition
                    ServiceObjective = $_.CurrentServiceObjectiveName
                    MaxSizeGB        = [math]::Round($_.MaxSizeBytes / 1GB, 2)
                    Status           = $_.Status
                    ZoneRedundant    = $_.ZoneRedundant
                })
            }
    }

    Write-SubSection "SQL Managed Instances"
    try {
        Get-AzSqlInstance -ErrorAction SilentlyContinue | ForEach-Object {
            $null = $allSQLManagedInst.Add([PSCustomObject]@{
                Subscription  = $subName
                Name          = $_.ManagedInstanceName
                ResourceGroup = $_.ResourceGroupName
                SKU           = if ($_.Sku) { $_.Sku.Name } else { $null }
                vCores        = $_.VCores
                StorageGB     = $_.StorageSizeInGB
                LicenseType   = $_.LicenseType
                State         = $_.State
            })
        }
    } catch {}

    Write-SubSection "Cosmos DB"
    Get-AzResource -ResourceType 'Microsoft.DocumentDB/databaseAccounts' -ErrorAction SilentlyContinue | ForEach-Object {
        $acct = Get-AzCosmosDBAccount -ResourceGroupName $_.ResourceGroupName -Name $_.Name -ErrorAction SilentlyContinue
        if ($acct) {
            $null = $allCosmosDB.Add([PSCustomObject]@{
                Subscription             = $subName
                Name                     = $acct.Name
                ResourceGroup            = $acct.ResourceGroupName
                Kind                     = $acct.Kind
                ConsistencyLevel         = $acct.ConsistencyPolicy.DefaultConsistencyLevel
                MultipleWriteLocations   = $acct.EnableMultipleWriteLocations
                Locations                = ($acct.Locations.LocationName -join ', ')
            })
        }
    }

    Write-SubSection "MySQL Flexible Servers"
    try {
        Get-AzResource -ResourceType 'Microsoft.DBforMySQL/flexibleServers' -ErrorAction SilentlyContinue | ForEach-Object {
            $srv = Get-AzMySqlFlexibleServer -ResourceGroupName $_.ResourceGroupName -Name $_.Name -ErrorAction SilentlyContinue
            if ($srv) {
                $null = $allMySQL.Add([PSCustomObject]@{
                    Subscription  = $subName
                    Name          = $srv.Name
                    ResourceGroup = $srv.ResourceGroupName
                    SKU           = $srv.SkuName
                    Tier          = $srv.SkuTier
                    StorageGB     = $srv.StorageSizeGb
                    Version       = $srv.Version
                    State         = $srv.State
                })
            }
        }
    } catch {}

    Write-SubSection "PostgreSQL Flexible Servers"
    try {
        Get-AzResource -ResourceType 'Microsoft.DBforPostgreSQL/flexibleServers' -ErrorAction SilentlyContinue | ForEach-Object {
            $srv = Get-AzPostgreSqlFlexibleServer -ResourceGroupName $_.ResourceGroupName -Name $_.Name -ErrorAction SilentlyContinue
            if ($srv) {
                $null = $allPostgreSQL.Add([PSCustomObject]@{
                    Subscription  = $subName
                    Name          = $srv.Name
                    ResourceGroup = $srv.ResourceGroupName
                    SKU           = $srv.SkuName
                    Tier          = $srv.SkuTier
                    StorageGB     = $srv.StorageSizeGb
                    Version       = $srv.Version
                    State         = $srv.State
                })
            }
        }
    } catch {}

    Write-SubSection "Redis Cache"
    try {
        Get-AzResource -ResourceType 'Microsoft.Cache/Redis' -ErrorAction SilentlyContinue | ForEach-Object {
            $cache = Get-AzRedisCache -ResourceGroupName $_.ResourceGroupName -Name $_.Name -ErrorAction SilentlyContinue
            if ($cache) {
                $null = $allRedisCache.Add([PSCustomObject]@{
                    Subscription  = $subName
                    Name          = $cache.Name
                    ResourceGroup = $cache.ResourceGroupName
                    SKU           = if ($cache.Sku) { $cache.Sku.Name } else { $null }
                    Size          = $cache.Size
                    ShardCount    = $cache.ShardCount
                    NonSslPort    = $cache.EnableNonSslPort
                    MinTLS        = $cache.MinimumTlsVersion
                    Location      = $cache.Location
                })
            }
        }
    } catch {}
    #endregion

    #region ── 9. Messaging & Integration ─────────────────────────────────────
    Write-Section "9. Messaging & Integration"
    Write-SubSection "Service Bus"
    try {
        Get-AzResource -ResourceType 'Microsoft.ServiceBus/namespaces' -ErrorAction SilentlyContinue | ForEach-Object {
            $null = $allServiceBus.Add([PSCustomObject]@{
                Subscription  = $subName
                Name          = $_.Name
                ResourceGroup = $_.ResourceGroupName
                Location      = $_.Location
                SKU           = if ($_.Sku) { $_.Sku.Name } else { $null }
            })
        }
    } catch {}

    Write-SubSection "Event Hubs"
    try {
        Get-AzResource -ResourceType 'Microsoft.EventHub/namespaces' -ErrorAction SilentlyContinue | ForEach-Object {
            $null = $allEventHubs.Add([PSCustomObject]@{
                Subscription  = $subName
                Name          = $_.Name
                ResourceGroup = $_.ResourceGroupName
                Location      = $_.Location
                SKU           = if ($_.Sku) { $_.Sku.Name } else { $null }
            })
        }
    } catch {}

    Write-SubSection "API Management"
    try {
        Get-AzResource -ResourceType 'Microsoft.ApiManagement/service' -ErrorAction SilentlyContinue | ForEach-Object {
            $null = $allAPIM.Add([PSCustomObject]@{
                Subscription  = $subName
                Name          = $_.Name
                ResourceGroup = $_.ResourceGroupName
                Location      = $_.Location
                SKU           = if ($_.Sku) { $_.Sku.Name } else { $null }
            })
        }
    } catch {}
    #endregion

    #region ── 10. Containers ─────────────────────────────────────────────────
    Write-Section "10. Containers"
    Write-SubSection "AKS Clusters"
    try {
        Get-AzResource -ResourceType 'Microsoft.ContainerService/managedClusters' -ErrorAction SilentlyContinue | ForEach-Object {
            $cluster = Get-AzAksCluster -ResourceGroupName $_.ResourceGroupName -Name $_.Name -ErrorAction SilentlyContinue
            if ($cluster) {
                $null = $allAKS.Add([PSCustomObject]@{
                    Subscription  = $subName
                    Name          = $cluster.Name
                    ResourceGroup = $cluster.ResourceGroupName
                    K8sVersion    = $cluster.KubernetesVersion
                    NodePools     = $cluster.AgentPoolProfiles.Count
                    NetworkPlugin = if ($cluster.NetworkProfile) { $cluster.NetworkProfile.NetworkPlugin } else { $null }
                    NetworkPolicy = if ($cluster.NetworkProfile) { $cluster.NetworkProfile.NetworkPolicy } else { $null }
                    RBAC          = $cluster.EnableRBAC
                })
                $cluster.AgentPoolProfiles | ForEach-Object {
                    $null = $allAKSNodePools.Add([PSCustomObject]@{
                        Subscription = $subName
                        Cluster      = $cluster.Name
                        Pool         = $_.Name
                        VMSize       = $_.VmSize
                        Count        = $_.Count
                        MinCount     = $_.MinCount
                        MaxCount     = $_.MaxCount
                        AutoScale    = $_.EnableAutoScaling
                        OsType       = $_.OsType
                        Mode         = $_.Mode
                    })
                }
            }
        }
    } catch {}

    Write-SubSection "Container Instances"
    try {
        Get-AzResource -ResourceType 'Microsoft.ContainerInstance/containerGroups' -ErrorAction SilentlyContinue | ForEach-Object {
            $null = $allContainerInstances.Add([PSCustomObject]@{
                Subscription  = $subName
                Name          = $_.Name
                ResourceGroup = $_.ResourceGroupName
                Location      = $_.Location
            })
        }
    } catch {}

    Write-SubSection "Container Apps"
    try {
        Get-AzResource -ResourceType 'Microsoft.App/containerApps' -ErrorAction SilentlyContinue | ForEach-Object {
            $null = $allContainerApps.Add([PSCustomObject]@{
                Subscription  = $subName
                Name          = $_.Name
                ResourceGroup = $_.ResourceGroupName
                Location      = $_.Location
            })
        }
    } catch {}

    Write-SubSection "Container Registries"
    try {
        Get-AzResource -ResourceType 'Microsoft.ContainerRegistry/registries' -ErrorAction SilentlyContinue | ForEach-Object {
            $reg = Get-AzContainerRegistry -ResourceGroupName $_.ResourceGroupName -Name $_.Name -ErrorAction SilentlyContinue
            if ($reg) {
                $null = $allContainerRegistries.Add([PSCustomObject]@{
                    Subscription  = $subName
                    Name          = $reg.Name
                    ResourceGroup = $reg.ResourceGroupName
                    SKU           = $reg.SkuName
                    AdminEnabled  = $reg.AdminUserEnabled
                    LoginServer   = $reg.LoginServer
                    Location      = $reg.Location
                })
            }
        }
    } catch {}
    #endregion

    #region ── 11. Data & Analytics ───────────────────────────────────────────
    Write-Section "11. Data & Analytics"
    Write-SubSection "Data Factories"
    try {
        Get-AzResource -ResourceType 'Microsoft.DataFactory/factories' -ErrorAction SilentlyContinue | ForEach-Object {
            $null = $allDataFactories.Add([PSCustomObject]@{
                Subscription  = $subName
                Name          = $_.Name
                ResourceGroup = $_.ResourceGroupName
                Location      = $_.Location
            })
        }
    } catch {}
    #endregion

    #region ── 12. Identity & RBAC ────────────────────────────────────────────
    Write-Section "12. Identity & RBAC"
    Write-SubSection "Role Assignments"
    Get-AzRoleAssignment -ErrorAction SilentlyContinue | ForEach-Object {
        $null = $allRBAC.Add([PSCustomObject]@{
            Subscription       = $subName
            DisplayName        = $_.DisplayName
            SignInName         = $_.SignInName
            RoleDefinitionName = $_.RoleDefinitionName
            Scope              = $_.Scope
            ObjectType         = $_.ObjectType
            HighRisk           = if ($_.RoleDefinitionName -in @('Owner','Contributor','User Access Administrator')) { 'YES' } else { 'No' }
        })
    }

    Write-SubSection "Custom Roles"
    Get-AzRoleDefinition -Custom -ErrorAction SilentlyContinue | ForEach-Object {
        $null = $allCustomRoles.Add([PSCustomObject]@{
            Subscription     = $subName
            Name             = $_.Name
            Description      = $_.Description
            Actions          = ($_.Actions -join '; ')
            AssignableScopes = ($_.AssignableScopes -join '; ')
        })
    }
    #endregion

    #region ── 13. Security & Compliance ──────────────────────────────────────
    Write-Section "13. Security & Compliance"
    Write-SubSection "Defender for Cloud"
    try {
        Get-AzSecurityPricing -ErrorAction SilentlyContinue | ForEach-Object {
            $null = $allDefenderPricing.Add([PSCustomObject]@{
                Subscription = $subName
                Plan         = $_.Name
                PricingTier  = $_.PricingTier
            })
        }
    } catch {}

    try {
        Get-AzSecuritySecureScore -ErrorAction SilentlyContinue | ForEach-Object {
            $null = $allSecureScore.Add([PSCustomObject]@{
                Subscription = $subName
                DisplayName  = $_.DisplayName
                Current      = $_.CurrentScore
                Max          = $_.MaxScore
                Percentage   = [math]::Round(($_.CurrentScore / $_.MaxScore) * 100, 1)
            })
        }
    } catch {}

    Write-SubSection "Security Alerts"
    try {
        Get-AzSecurityAlert -ErrorAction SilentlyContinue |
            Where-Object { $_.Status -eq 'Active' } | ForEach-Object {
                $null = $allSecurityAlerts.Add([PSCustomObject]@{
                    Subscription = $subName
                    Alert        = $_.AlertDisplayName
                    Severity     = $_.Severity
                    Resource     = $_.CompromisedEntity
                    StartTime    = $_.StartTimeUtc
                })
            }
    } catch {}

    Write-SubSection "Key Vaults"
    Get-AzResource -ResourceType 'Microsoft.KeyVault/vaults' -ErrorAction SilentlyContinue | ForEach-Object {
        $vault = Get-AzKeyVault -VaultName $_.Name -ResourceGroupName $_.ResourceGroupName -ErrorAction SilentlyContinue
        if ($vault) {
        $null = $allKeyVaults.Add([PSCustomObject]@{
            Subscription    = $subName
            VaultName       = $vault.VaultName
            ResourceGroup   = $vault.ResourceGroupName
            Location        = $vault.Location
            SoftDelete      = $vault.EnableSoftDelete
            PurgeProtection = $vault.EnablePurgeProtection
            SKU             = $vault.Sku
        })

        # Check for expiring secrets/certs
        try {
            Get-AzKeyVaultSecret -VaultName $vault.VaultName -ErrorAction SilentlyContinue |
                Where-Object { $_.Expires -and $_.Expires -lt (Get-Date).AddDays(30) } |
                ForEach-Object {
                    $null = $allExpiringSecrets.Add([PSCustomObject]@{
                        Subscription = $subName
                        Vault        = $vault.VaultName
                        Name         = $_.Name
                        Type         = 'Secret'
                        Expires      = $_.Expires
                        DaysLeft     = [math]::Max(0, ($_.Expires - (Get-Date)).Days)
                    })
                }
            Get-AzKeyVaultCertificate -VaultName $vault.VaultName -ErrorAction SilentlyContinue |
                Where-Object { $_.Expires -and $_.Expires -lt (Get-Date).AddDays(30) } |
                ForEach-Object {
                    $null = $allExpiringSecrets.Add([PSCustomObject]@{
                        Subscription = $subName
                        Vault        = $vault.VaultName
                        Name         = $_.Name
                        Type         = 'Certificate'
                        Expires      = $_.Expires
                        DaysLeft     = [math]::Max(0, ($_.Expires - (Get-Date)).Days)
                    })
                }
        } catch {}
        }
    }

    Write-SubSection "Policy Compliance"
    try {
        Get-AzPolicyState -SubscriptionId $sub.Id -Filter "ComplianceState eq 'NonCompliant'" -ErrorAction SilentlyContinue |
            Group-Object PolicyDefinitionName |
            Sort-Object Count -Descending |
            ForEach-Object {
                $null = $allPolicyNonCompliant.Add([PSCustomObject]@{
                    Subscription    = $subName
                    PolicyName      = $_.Name
                    NonCompliantCount = $_.Count
                })
            }
    } catch {}
    Get-AzPolicyAssignment -ErrorAction SilentlyContinue | ForEach-Object {
        $null = $allPolicyAssignments.Add([PSCustomObject]@{
            Subscription    = $subName
            Name            = $_.Name
            DisplayName     = $_.Properties.DisplayName
            Scope           = $_.Properties.Scope
            EnforcementMode = $_.Properties.EnforcementMode
        })
    }
    #endregion

    #region ── 14. Cost & Advisor ─────────────────────────────────────────────
    Write-Section "14. Cost Optimization & Advisor"
    Write-SubSection "Advisor Recommendations"
    try {
        $advisorRecs = Get-AzAdvisorRecommendation -ErrorAction SilentlyContinue
        $advisorRecs | ForEach-Object {
            $null = $allAdvisorAll.Add([PSCustomObject]@{
                Subscription = $subName
                Category     = $_.Category
                Impact       = $_.Impact
                Problem      = $_.ShortDescription.Problem
                Solution     = $_.ShortDescription.Solution
                Resource     = if ($_.ResourceMetadata -and $_.ResourceMetadata.ResourceId) { $_.ResourceMetadata.ResourceId.Split('/')[-1] } else { $null }
            })
        }
        $advisorRecs | Where-Object { $_.Category -eq 'Cost' } | ForEach-Object {
            $null = $allAdvisorCost.Add([PSCustomObject]@{
                Subscription = $subName
                Impact       = $_.Impact
                Problem      = $_.ShortDescription.Problem
                Solution     = $_.ShortDescription.Solution
                Resource     = if ($_.ResourceMetadata -and $_.ResourceMetadata.ResourceId) { $_.ResourceMetadata.ResourceId.Split('/')[-1] } else { $null }
            })
        }
    } catch {}

    Write-SubSection "Consumption (Last 30 Days)"
    try {
        Get-AzConsumptionUsageDetail -StartDate (Get-Date).AddDays(-30) -EndDate (Get-Date) -ErrorAction SilentlyContinue |
            Group-Object ConsumedService |
            Select-Object Name, @{N='TotalCost';E={
                [math]::Round(($_.Group | Measure-Object -Property PretaxCost -Sum).Sum, 2)
            }} |
            Sort-Object TotalCost -Descending |
            ForEach-Object {
                $null = $allConsumption.Add([PSCustomObject]@{
                    Subscription  = $subName
                    Service       = $_.Name
                    TotalCost30d  = $_.TotalCost
                })
            }
    } catch {}

    Write-SubSection "Reservations"
    try {
        Get-AzReservation -ErrorAction SilentlyContinue | ForEach-Object {
            $null = $allReservations.Add([PSCustomObject]@{
                Subscription = $subName
                DisplayName  = $_.DisplayName
                SKU          = $_.Sku
                Location     = $_.Location
                Quantity     = $_.Quantity
                ExpiryDate   = $_.ExpiryDate
                Utilization  = $_.Utilization
            })
        }
    } catch {}

    Write-SubSection "Budgets"
    try {
        Get-AzConsumptionBudget -ErrorAction SilentlyContinue | ForEach-Object {
            $null = $allBudgets.Add([PSCustomObject]@{
                Subscription = $subName
                Name         = $_.Name
                Amount       = $_.Amount
                TimeGrain    = $_.TimeGrain
                CurrentSpend = $_.CurrentSpend.Amount
                Currency     = $_.CurrentSpend.Unit
            })
        }
    } catch {}
    #endregion

    #region ── 15. Backup & DR ────────────────────────────────────────────────
    Write-Section "15. Backup & Disaster Recovery"
    Write-SubSection "Recovery Services Vaults & Backup Items"
    $vaults = Get-AzResource -ResourceType 'Microsoft.RecoveryServices/vaults' -ErrorAction SilentlyContinue | ForEach-Object {
        Get-AzRecoveryServicesVault -ResourceGroupName $_.ResourceGroupName -Name $_.Name -ErrorAction SilentlyContinue
    }
    $backedUpVMNames = @()
    foreach ($vault in $vaults) {
        $null = $allRecoveryVaults.Add([PSCustomObject]@{
            Subscription  = $subName
            Name          = $vault.Name
            ResourceGroup = $vault.ResourceGroupName
            Location      = $vault.Location
        })
        try {
            Set-AzRecoveryServicesVaultContext -Vault $vault
            $containers = Get-AzRecoveryServicesBackupContainer -ContainerType AzureVM -BackupManagementType AzureIaasVM -ErrorAction SilentlyContinue
            foreach ($container in $containers) {
                $items = Get-AzRecoveryServicesBackupItem -Container $container -WorkloadType AzureVM -ErrorAction SilentlyContinue
                foreach ($item in $items) {
                    $vmName = $item.Name.Split(';')[-1]
                    $backedUpVMNames += $vmName
                    $null = $allBackupItems.Add([PSCustomObject]@{
                        Subscription       = $subName
                        Vault              = $vault.Name
                        VM                 = $vmName
                        ProtectionStatus   = $item.ProtectionStatus
                        LastBackup         = $item.LastBackupTime
                        LatestRecoveryPoint = $item.LatestRecoveryPoint
                    })
                }
            }
        } catch {}
    }

    # Unprotected VMs
    $vmNames = ($vms | Select-Object -ExpandProperty Name)
    $vmNames | Where-Object { $_ -notin $backedUpVMNames } | ForEach-Object {
        $null = $allUnprotectedVMs.Add([PSCustomObject]@{
            Subscription = $subName
            VM           = $_
            Status       = 'NO BACKUP CONFIGURED'
        })
    }
    #endregion

    #region ── 16. Monitoring ─────────────────────────────────────────────────
    Write-Section "16. Monitoring & Log Analytics"
    Write-SubSection "Log Analytics Workspaces"
    Get-AzResource -ResourceType 'Microsoft.OperationalInsights/workspaces' -ErrorAction SilentlyContinue | ForEach-Object {
        $ws = Get-AzOperationalInsightsWorkspace -ResourceGroupName $_.ResourceGroupName -Name $_.Name -ErrorAction SilentlyContinue
        if ($ws) {
            $null = $allLAWorkspaces.Add([PSCustomObject]@{
                Subscription  = $subName
                Name          = $ws.Name
                ResourceGroup = $ws.ResourceGroupName
                SKU           = $ws.Sku
                RetentionDays = $ws.RetentionInDays
                DailyCapGB    = $ws.WorkspaceCapping.DailyQuotaGb
            })
        }
    }

    Write-SubSection "Diagnostic Settings Coverage"
    $criticalTypes = @(
        'Microsoft.Compute/virtualMachines',
        'Microsoft.Sql/servers/databases',
        'Microsoft.Network/networkSecurityGroups',
        'Microsoft.KeyVault/vaults',
        'Microsoft.Web/sites',
        'Microsoft.Network/applicationGateways',
        'Microsoft.Network/azureFirewalls',
        'Microsoft.ContainerService/managedClusters'
    )
    Get-AzResource -ErrorAction SilentlyContinue | Where-Object {
        $_.ResourceType -in $criticalTypes
    } | ForEach-Object {
        $diag = Get-AzDiagnosticSetting -ResourceId $_.ResourceId -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
        $null = $allDiagSettings.Add([PSCustomObject]@{
            Subscription   = $subName
            Resource       = $_.Name
            Type           = $_.ResourceType.Split('/')[-1]
            HasDiagnostics = [bool]$diag
            Destinations   = if ($diag) { ($diag.WorkspaceId | ForEach-Object { $_.Split('/')[-1] }) -join ', ' } else { 'NONE' }
        })
    }

    Write-SubSection "Alert Rules"
    try {
        Get-AzResource -ResourceType 'Microsoft.Insights/metricAlerts' -ErrorAction SilentlyContinue | ForEach-Object {
            $alert = Get-AzMetricAlertRuleV2 -ResourceGroupName $_.ResourceGroupName -Name $_.Name -ErrorAction SilentlyContinue
            if ($alert) {
                $null = $allAlertRules.Add([PSCustomObject]@{
                    Subscription  = $subName
                    Name          = $alert.Name
                    ResourceGroup = $alert.ResourceGroupName
                    Severity      = $alert.Severity
                    Enabled       = $alert.Enabled
                    TargetResource = $alert.TargetResourceId.Split('/')[-1]
                })
            }
        }
    } catch {}

    Write-SubSection "Action Groups"
    try {
        Get-AzResource -ResourceType 'Microsoft.Insights/actionGroups' -ErrorAction SilentlyContinue | ForEach-Object {
            $ag = Get-AzActionGroup -ResourceGroupName $_.ResourceGroupName -Name $_.Name -ErrorAction SilentlyContinue
            if ($ag) {
                $null = $allActionGroups.Add([PSCustomObject]@{
                    Subscription  = $subName
                    Name          = $ag.Name
                    ResourceGroup = $ag.ResourceGroupName
                    Enabled       = $ag.Enabled
                    EmailReceivers = ($ag.EmailReceivers.Name -join ', ')
                    SMSReceivers   = ($ag.SmsReceivers.Name -join ', ')
                    WebhookReceivers = ($ag.WebhookReceivers.Name -join ', ')
                })
            }
        }
    } catch {}
    #endregion

    #region ── 17. Governance & Tags ──────────────────────────────────────────
    Write-Section "17. Governance & Tagging"
    Write-SubSection "Tag Compliance"
    $requiredTags = @('Environment', 'Owner', 'CostCenter', 'Application')
    Get-AzResource -ErrorAction SilentlyContinue | ForEach-Object {
        $resource = $_
        $missing = $requiredTags | Where-Object {
            -not ($resource.Tags -and $resource.Tags.ContainsKey($_))
        }
        if ($missing) {
            $null = $allTagCompliance.Add([PSCustomObject]@{
                Subscription = $subName
                Resource     = $resource.Name
                Type         = $resource.ResourceType.Split('/')[-1]
                MissingTags  = ($missing -join ', ')
            })
        }
    }

    Write-SubSection "Resource Locks"
    Get-AzResourceLock -ErrorAction SilentlyContinue | ForEach-Object {
        $null = $allResourceLocks.Add([PSCustomObject]@{
            Subscription  = $subName
            Name          = $_.Name
            ResourceGroup = $_.ResourceGroupName
            LockLevel     = $_.Properties.Level
            Resource      = $_.ResourceId.Split('/')[-1]
            Notes         = $_.Properties.Notes
        })
    }
    #endregion

    #region ── 18. Automation & Hybrid ────────────────────────────────────────
    Write-Section "18. Automation & Hybrid"
    Write-SubSection "Automation Accounts"
    try {
        Get-AzResource -ResourceType 'Microsoft.Automation/automationAccounts' -ErrorAction SilentlyContinue | ForEach-Object {
            $null = $allAutomationAccts.Add([PSCustomObject]@{
                Subscription  = $subName
                Name          = $_.Name
                ResourceGroup = $_.ResourceGroupName
                Location      = $_.Location
            })
        }
    } catch {}

    Write-SubSection "Azure Arc Machines"
    try {
        if (Test-ModuleAvailable 'Az.ConnectedMachine') {
            Get-AzResource -ResourceType 'Microsoft.HybridCompute/machines' -ErrorAction SilentlyContinue | ForEach-Object {
                $machine = Get-AzConnectedMachine -ResourceGroupName $_.ResourceGroupName -Name $_.Name -ErrorAction SilentlyContinue
                if ($machine) {
                    $null = $allArcMachines.Add([PSCustomObject]@{
                        Subscription     = $subName
                        Name             = $machine.Name
                        ResourceGroup    = $machine.ResourceGroupName
                        OS               = $machine.OsName
                        Status           = $machine.Status
                        AgentVersion     = $machine.AgentVersion
                        LastStatusChange = $machine.LastStatusChange
                    })
                }
            }
        }
    } catch {}
    #endregion

} # End subscription loop

# ═══════════════════════════════════════════════════════════════════════════════
# MANAGEMENT GROUPS (tenant-level, outside sub loop)
# ═══════════════════════════════════════════════════════════════════════════════
Write-Section "19. Management Groups"
try {
    Get-AzManagementGroup -ErrorAction SilentlyContinue | ForEach-Object {
        $null = $allMgmtGroups.Add([PSCustomObject]@{
            Name        = $_.Name
            DisplayName = $_.DisplayName
            Id          = $_.Id
        })
    }
} catch {}

# ═══════════════════════════════════════════════════════════════════════════════
# EXPORT ALL DATA
# ═══════════════════════════════════════════════════════════════════════════════
Write-Section "EXPORTING ALL DATA"

# Core Infrastructure
Export-SafeCsv $allResources           "01_ResourceInventory.csv"
Export-SafeCsv $allVMs                 "02_VMs.csv"
Export-SafeCsv $allVMMetrics           "02_VM_Metrics.csv"
Export-SafeCsv $allVMSS               "02_VMScaleSets.csv"
Export-SafeCsv $allAppServicePlans     "03_AppServicePlans.csv"
Export-SafeCsv $allWebApps             "03_WebApps.csv"
Export-SafeCsv $allFunctions           "04_Functions.csv"
Export-SafeCsv $allLogicApps           "05_LogicApps.csv"

# Storage
Export-SafeCsv $allDisks               "06_Disks.csv"
Export-SafeCsv ($allDisks | Where-Object { $_.AttachedTo -eq 'UNATTACHED' }) "06_UnattachedDisks.csv"
Export-SafeCsv $allSnapshots           "06_Snapshots.csv"
Export-SafeCsv $allStorageAccounts     "06_StorageAccounts.csv"
Export-SafeCsv $allFileShares          "06_FileShares.csv"

# Networking
Export-SafeCsv $allVNets               "07_VNets_Subnets.csv"
Export-SafeCsv $allPublicIPs           "07_OrphanedPublicIPs.csv"
Export-SafeCsv $allNSGRules            "07_OpenNSGRules.csv"
Export-SafeCsv $allLBs                 "07_LoadBalancers.csv"
Export-SafeCsv $allAppGateways         "07_AppGateways.csv"
Export-SafeCsv $allFirewalls           "07_AzureFirewalls.csv"
Export-SafeCsv $allFrontDoors          "07_FrontDoors.csv"
Export-SafeCsv $allBastions            "07_Bastions.csv"
Export-SafeCsv $allNATGateways         "07_NATGateways.csv"
Export-SafeCsv $allVPNGateways         "07_VPNGateways.csv"
Export-SafeCsv $allExpressRoute        "07_ExpressRoute.csv"
Export-SafeCsv $allPeerings            "07_VNetPeerings.csv"
Export-SafeCsv $allPrivateEndpoints    "07_PrivateEndpoints.csv"
Export-SafeCsv $allPrivateDNS          "07_PrivateDNS.csv"
Export-SafeCsv $allPublicDNS           "07_PublicDNS.csv"
Export-SafeCsv $allNetworkWatchers     "07_NetworkWatchers.csv"
Export-SafeCsv $allCDNProfiles         "07_CDNProfiles.csv"

# Databases
Export-SafeCsv $allSQLServers          "08_SQLServers.csv"
Export-SafeCsv $allSQLDatabases        "08_SQLDatabases.csv"
Export-SafeCsv $allSQLManagedInst      "08_SQLManagedInstances.csv"
Export-SafeCsv $allCosmosDB            "08_CosmosDB.csv"
Export-SafeCsv $allMySQL               "08_MySQL.csv"
Export-SafeCsv $allPostgreSQL          "08_PostgreSQL.csv"
Export-SafeCsv $allRedisCache          "08_RedisCache.csv"

# Messaging & Integration
Export-SafeCsv $allServiceBus          "09_ServiceBus.csv"
Export-SafeCsv $allEventHubs           "09_EventHubs.csv"
Export-SafeCsv $allAPIM                "09_APIM.csv"

# Containers
Export-SafeCsv $allAKS                 "10_AKS_Clusters.csv"
Export-SafeCsv $allAKSNodePools        "10_AKS_NodePools.csv"
Export-SafeCsv $allContainerInstances  "10_ContainerInstances.csv"
Export-SafeCsv $allContainerApps       "10_ContainerApps.csv"
Export-SafeCsv $allContainerRegistries "10_ContainerRegistries.csv"

# Data & Analytics
Export-SafeCsv $allDataFactories       "11_DataFactories.csv"

# Identity & RBAC
Export-SafeCsv $allRBAC                "12_RoleAssignments.csv"
Export-SafeCsv ($allRBAC | Where-Object { $_.HighRisk -eq 'YES' }) "12_HighRiskRoles.csv"
Export-SafeCsv $allCustomRoles         "12_CustomRoles.csv"
Export-SafeCsv $allMgmtGroups          "12_ManagementGroups.csv"

# Security
Export-SafeCsv $allDefenderPricing     "13_DefenderPricing.csv"
Export-SafeCsv $allSecureScore         "13_SecureScore.csv"
Export-SafeCsv $allSecurityAlerts      "13_SecurityAlerts.csv"
Export-SafeCsv $allKeyVaults           "13_KeyVaults.csv"
Export-SafeCsv $allExpiringSecrets     "13_ExpiringSecretsCerts.csv"
Export-SafeCsv $allPolicyNonCompliant  "13_PolicyNonCompliant.csv"
Export-SafeCsv $allPolicyAssignments   "13_PolicyAssignments.csv"

# Cost
Export-SafeCsv $allAdvisorAll          "14_AdvisorAll.csv"
Export-SafeCsv $allAdvisorCost         "14_AdvisorCost.csv"
Export-SafeCsv $allConsumption         "14_ConsumptionByService.csv"
Export-SafeCsv $allReservations        "14_Reservations.csv"
Export-SafeCsv $allBudgets             "14_Budgets.csv"

# Backup & DR
Export-SafeCsv $allRecoveryVaults      "15_RecoveryVaults.csv"
Export-SafeCsv $allBackupItems         "15_BackupItems.csv"
Export-SafeCsv $allUnprotectedVMs      "15_UnprotectedVMs.csv"

# Monitoring
Export-SafeCsv $allLAWorkspaces        "16_LogAnalyticsWorkspaces.csv"
Export-SafeCsv $allDiagSettings        "16_DiagnosticSettings.csv"
Export-SafeCsv $allAlertRules          "16_AlertRules.csv"
Export-SafeCsv $allActionGroups        "16_ActionGroups.csv"

# Governance
Export-SafeCsv $allTagCompliance       "17_TagCompliance.csv"
Export-SafeCsv $allResourceLocks       "17_ResourceLocks.csv"

# Automation & Hybrid
Export-SafeCsv $allAutomationAccts     "18_AutomationAccounts.csv"
Export-SafeCsv $allArcMachines         "18_ArcMachines.csv"

# ═══════════════════════════════════════════════════════════════════════════════
# EXECUTIVE SUMMARY
# ═══════════════════════════════════════════════════════════════════════════════
Write-Section "EXECUTIVE SUMMARY"

$executiveSummary = [ordered]@{
    "Subscriptions Assessed"      = $subscriptions.Count
    "Total VMs"                   = @($allVMs).Count
    "Deallocated/Stopped VMs"     = @($allVMs | Where-Object { $_.PowerState -match 'stopped|deallocated' }).Count
    "VMs Without Backup"          = @($allUnprotectedVMs).Count
    "VM Scale Sets"               = @($allVMSS).Count
    "Unattached Disks"            = @($allDisks | Where-Object { $_.AttachedTo -eq 'UNATTACHED' }).Count
    "Old Snapshots (>90d)"        = @($allSnapshots | Where-Object { $_.AgeDays -gt 90 }).Count
    "Orphaned Public IPs"         = @($allPublicIPs).Count
    "Critical NSG Rules"          = @($allNSGRules | Where-Object { $_.Severity -eq 'CRITICAL' }).Count
    "App Service Plans"           = @($allAppServicePlans).Count
    "Empty App Plans (waste)"     = @($allAppServicePlans | Where-Object { $_.AppCount -eq 0 }).Count
    "Azure Functions"             = @($allFunctions).Count
    "Logic Apps"                  = @($allLogicApps).Count
    "SQL Databases"               = @($allSQLDatabases).Count
    "SQL Managed Instances"       = @($allSQLManagedInst).Count
    "Cosmos DB Accounts"          = @($allCosmosDB).Count
    "Redis Caches"                = @($allRedisCache).Count
    "AKS Clusters"                = @($allAKS).Count
    "Container Apps"              = @($allContainerApps).Count
    "Container Registries"        = @($allContainerRegistries).Count
    "Key Vaults"                  = @($allKeyVaults).Count
    "Expiring Secrets/Certs"      = @($allExpiringSecrets).Count
    "Advisor Cost Recommendations"= @($allAdvisorCost).Count
    "Security Alerts (Active)"    = @($allSecurityAlerts).Count
    "Policy Non-Compliant"        = @($allPolicyNonCompliant).Count
    "Resources Missing Tags"      = @($allTagCompliance).Count
    "Resources w/o Diagnostics"   = @($allDiagSettings | Where-Object { -not $_.HasDiagnostics }).Count
    "Azure Firewalls"             = @($allFirewalls).Count
    "Front Doors"                 = @($allFrontDoors).Count
    "Bastions"                    = @($allBastions).Count
    "Service Bus Namespaces"      = @($allServiceBus).Count
    "Event Hub Namespaces"        = @($allEventHubs).Count
    "API Management Instances"    = @($allAPIM).Count
    "Data Factories"              = @($allDataFactories).Count
    "Automation Accounts"         = @($allAutomationAccts).Count
    "Arc Connected Machines"      = @($allArcMachines).Count
}

$executiveSummary.GetEnumerator() | ForEach-Object {
    $color = 'Green'
    if ($_.Key -match 'Unattached|Orphaned|Critical|Without|Expiring|Missing|Non-Compliant|Alert|Empty|waste|w/o') {
        if ($_.Value -gt 0) { $color = 'Red' }
    }
    Write-Host "  $($_.Key): $($_.Value)" -ForegroundColor $color
}

# Export summary
$executiveSummary.GetEnumerator() | ForEach-Object {
    [PSCustomObject]@{ Metric = $_.Key; Value = $_.Value }
} | Export-Csv "$OutputPath/00_ExecutiveSummary.csv" -NoTypeInformation

Export-SafeCsv $summaryData "00_ExportManifest.csv"
Export-SafeCsv $sectionErrors "00_SectionErrors.csv"
Export-SafeCsv $sectionTimings "00_SectionTimings.csv"

# Run summary JSON
$runSummary = [ordered]@{
    StartTime       = $startTime.ToString('o')
    EndTime         = (Get-Date).ToString('o')
    ElapsedMinutes  = [math]::Round(((Get-Date) - $startTime).TotalMinutes, 1)
    Subscriptions   = $subscriptions.Count
    TotalErrors     = @($sectionErrors).Count
    SectionTimings  = @($sectionTimings)
    SectionErrors   = @($sectionErrors)
}
$runSummary | ConvertTo-Json -Depth 5 | Set-Content "$OutputPath/Assessment-RunSummary.json"
Write-Host "    ✓ Run summary → Assessment-RunSummary.json" -ForegroundColor Green

# ═══════════════════════════════════════════════════════════════════════════════
# BUNDLE INTO ZIP
# ═══════════════════════════════════════════════════════════════════════════════
Write-Section "PACKAGING RESULTS"

$csvFiles = Get-ChildItem $OutputPath -Filter *.csv
$zipPath = "$OutputPath.zip"

try {
    # Remove existing zip if re-running
    if (Test-Path $zipPath) { Remove-Item $zipPath -Force }

    # Use .NET compression (available in PS 5.1+ and PS 7+)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::CreateFromDirectory(
        (Resolve-Path $OutputPath).Path,
        (Join-Path (Resolve-Path (Split-Path $OutputPath -Parent)).Path (Split-Path $zipPath -Leaf)),
        [System.IO.Compression.CompressionLevel]::Optimal,
        $true  # includeBaseDirectory - puts CSVs inside a folder in the zip
    )

    $zipSize = [math]::Round((Get-Item $zipPath).Length / 1MB, 2)
    Write-Host "  ✓ Zipped $($csvFiles.Count) CSVs → $zipPath ($zipSize MB)" -ForegroundColor Green
} catch {
    # Fallback: try Compress-Archive (PS 5.1+)
    try {
        Compress-Archive -Path "$OutputPath/*" -DestinationPath $zipPath -Force
        $zipSize = [math]::Round((Get-Item $zipPath).Length / 1MB, 2)
        Write-Host "  ✓ Zipped $($csvFiles.Count) CSVs → $zipPath ($zipSize MB)" -ForegroundColor Green
    } catch {
        Write-Host "  ⚠ Could not create zip. CSVs are still available in: $OutputPath" -ForegroundColor Yellow
        Write-Host "    To zip manually: Compress-Archive -Path '$OutputPath/*' -DestinationPath '$zipPath'" -ForegroundColor DarkYellow
    }
}

$elapsed = (Get-Date) - $startTime
Write-Host "`n═══════════════════════════════════════════════════════════════" -ForegroundColor Green
Write-Host "  ASSESSMENT COMPLETE" -ForegroundColor Green
Write-Host "  Output directory: $OutputPath" -ForegroundColor Green
Write-Host "  Zip package:      $zipPath" -ForegroundColor Green
Write-Host "  Total CSV files:  $($csvFiles.Count)" -ForegroundColor Green
Write-Host "  Elapsed time:     $($elapsed.ToString('hh\:mm\:ss'))" -ForegroundColor Green
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Green
Get-ChildItem $OutputPath -Filter *.csv | Sort-Object Name | Format-Table Name, @{N='SizeKB';E={[math]::Round($_.Length/1KB,1)}} -AutoSize

# ═══════════════════════════════════════════════════════════════════════════════
# DOWNLOAD OPTIONS
# ═══════════════════════════════════════════════════════════════════════════════
Write-Host ""
Write-Host "  ┌─────────────────────────────────────────────────────────────┐" -ForegroundColor Cyan
Write-Host "  │  HOW TO DOWNLOAD                                            │" -ForegroundColor Cyan
Write-Host "  └─────────────────────────────────────────────────────────────┘" -ForegroundColor Cyan
Write-Host ""

# Detect if running in Azure Cloud Shell
$isCloudShell = $env:AZUREPS_HOST_ENVIRONMENT -match 'cloud-shell' -or $env:ACC_CLOUD -or (Test-Path '/home/*/.cloudconsole' 2>$null)

if ($isCloudShell) {
    # Copy zip to home directory for Cloud Shell download command
    $homeZip = Join-Path $HOME (Split-Path $zipPath -Leaf)
    Copy-Item $zipPath $homeZip -Force -ErrorAction SilentlyContinue

    Write-Host "  OPTION 1 — Cloud Shell built-in download (easiest)" -ForegroundColor Yellow
    Write-Host "    Run this command:" -ForegroundColor White
    Write-Host "    download $homeZip" -ForegroundColor Green
    Write-Host ""
    Write-Host "  OPTION 2 — Cloud Shell file browser" -ForegroundColor Yellow
    Write-Host "    Click the file-browser icon (page icon) in the Cloud Shell toolbar" -ForegroundColor White
    Write-Host "    Navigate to: $(Split-Path $homeZip -Leaf)" -ForegroundColor White
    Write-Host "    Right-click → Download" -ForegroundColor White
    Write-Host ""
    Write-Host "  OPTION 3 — Upload to Storage Account + SAS link" -ForegroundColor Yellow
    Write-Host "    (Useful for sharing with team or if file > 1GB)" -ForegroundColor White
    Write-Host @"
    `$ctx = (Get-AzStorageAccount -ResourceGroupName '<rg>' -Name '<storageacct>').Context
    New-AzStorageContainer -Name 'assessments' -Context `$ctx -Permission Off -ErrorAction SilentlyContinue
    Set-AzStorageBlobContent -File '$zipPath' -Container 'assessments' -Blob '$(Split-Path $zipPath -Leaf)' -Context `$ctx
    New-AzStorageBlobSASToken -Container 'assessments' -Blob '$(Split-Path $zipPath -Leaf)' -Context `$ctx ``
        -Permission r -ExpiryTime (Get-Date).AddHours(24) -FullUri
"@ -ForegroundColor DarkGray
} else {
    Write-Host "  Local terminal detected — zip is already on disk:" -ForegroundColor Yellow
    Write-Host "    $((Resolve-Path $zipPath -ErrorAction SilentlyContinue) ?? $zipPath)" -ForegroundColor Green
    Write-Host ""
    Write-Host "  To upload to Azure Storage for sharing:" -ForegroundColor Yellow
    Write-Host @"
    `$ctx = (Get-AzStorageAccount -ResourceGroupName '<rg>' -Name '<storageacct>').Context
    New-AzStorageContainer -Name 'assessments' -Context `$ctx -Permission Off -ErrorAction SilentlyContinue
    Set-AzStorageBlobContent -File '$zipPath' -Container 'assessments' -Blob '$(Split-Path $zipPath -Leaf)' -Context `$ctx
    New-AzStorageBlobSASToken -Container 'assessments' -Blob '$(Split-Path $zipPath -Leaf)' -Context `$ctx ``
        -Permission r -ExpiryTime (Get-Date).AddHours(24) -FullUri
"@ -ForegroundColor DarkGray
}
Write-Host ""

# Stop transcript logging
try { Stop-Transcript | Out-Null } catch {}
