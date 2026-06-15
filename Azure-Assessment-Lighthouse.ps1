#Requires -Modules Az.Accounts, Az.Resources
<#
.SYNOPSIS
    Azure Assessment — Lighthouse (partner-tenant) runner
    Centre Technologies | March 2026

.DESCRIPTION
    Drives Azure-Assessment-Complete.ps1 and/or Azure-Assessment-Prep.ps1 against
    customer tenants delegated to Centre via Azure Lighthouse. The operator signs
    into Centre's partner tenant once; this script discovers delegated customer
    tenants visible to that identity, lets the operator pick one (or all), then
    invokes the existing assessment / prep scripts with the right per-customer
    context.

    The underlying Complete and Prep scripts are unchanged for direct-tenant use.
    This wrapper simply orchestrates them and passes the new -LighthouseMode,
    -CustomerName, and -CustomerTenantId switches.

.PARAMETER CustomerTenantId
    GUID of a single customer tenant to assess. If omitted and -All is not set,
    an interactive picker is shown.

.PARAMETER CustomerName
    Friendly label for output dir/zip ("Acme_AzureAssessment_<timestamp>"). When
    omitted, the customer tenant ID is used as the label.

.PARAMETER All
    Loop every delegated customer tenant discovered. Per-customer failures are
    logged to the rollup CSV but do not abort the batch.

.PARAMETER Mode
    Which underlying script(s) to run per customer:
      Assessment (default) — runs Azure-Assessment-Complete.ps1
      Prep                  — runs Azure-Assessment-Prep.ps1 with -RunAll
      Both                  — Prep then Assessment

.PARAMETER OutputRoot
    Parent directory for per-customer output. Defaults to ./LighthouseAssessments.

.PARAMETER SkipMetrics
    Passed through to the assessment script (skip metric collection for speed).

.PARAMETER DaysBack
    Passed through to the assessment script (metric lookback window).

.PARAMETER PartnerTenantId
    GUID of Centre's partner tenant. When omitted, the script uses the tenant
    of the current signed-in context. Subscriptions whose TenantId matches the
    partner tenant are excluded from customer discovery.

.PARAMETER ConnectGraph
    Connect Microsoft Graph to each customer tenant via GDAP before running the
    assessment. Requires Centre to have a GDAP relationship with the customer
    assigning Directory Readers / Security Reader (or Global Reader) to the
    operator's group. Currently a no-op against the Complete script (which has
    no Graph sections yet), but included so the same wrapper UX works once
    Graph sections land.

.EXAMPLE
    # Sign in to Centre partner tenant, pick a customer interactively
    .\Azure-Assessment-Lighthouse.ps1

.EXAMPLE
    # One specific customer, friendly label on the output
    .\Azure-Assessment-Lighthouse.ps1 -CustomerTenantId 11111111-1111-1111-1111-111111111111 -CustomerName "Acme"

.EXAMPLE
    # Sweep every delegated customer
    .\Azure-Assessment-Lighthouse.ps1 -All -Mode Assessment

.EXAMPLE
    # Full enablement + assessment for one customer
    .\Azure-Assessment-Lighthouse.ps1 -CustomerTenantId <guid> -CustomerName "Acme" -Mode Both
#>

[CmdletBinding()]
param(
    [string]$CustomerTenantId,
    [string]$CustomerName,
    [switch]$All,
    [ValidateSet('Assessment','Prep','Both')]
    [string]$Mode = 'Assessment',
    [string]$OutputRoot = './LighthouseAssessments',
    [switch]$SkipMetrics,
    [int]$DaysBack = 30,
    [string]$PartnerTenantId,
    [switch]$ConnectGraph
)

$ErrorActionPreference = 'Continue'

# ───────────────────────────────────────────────────────────────────────────────
# Resolve sibling script paths so the wrapper works whether invoked from the
# repo root or with a fully-qualified path.
# ───────────────────────────────────────────────────────────────────────────────
$scriptDir       = Split-Path -Parent $MyInvocation.MyCommand.Path
$completeScript  = Join-Path $scriptDir 'Azure-Assessment-Complete.ps1'
$prepScript      = Join-Path $scriptDir 'Azure-Assessment-Prep.ps1'

foreach ($p in @($completeScript, $prepScript)) {
    if (-not (Test-Path $p)) {
        Write-Host "ERROR: Required sibling script not found: $p" -ForegroundColor Red
        Write-Host "       This wrapper must live in the same directory as the assessment scripts." -ForegroundColor Red
        return
    }
}

# ───────────────────────────────────────────────────────────────────────────────
# Banner
# ───────────────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "  ╔═══════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "  ║   Azure Assessment — Lighthouse (Partner) Runner             ║" -ForegroundColor Cyan
Write-Host "  ║   Centre Technologies                                        ║" -ForegroundColor Cyan
Write-Host "  ╚═══════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

# ───────────────────────────────────────────────────────────────────────────────
# Auth — operator must be signed in to Centre's partner tenant. Delegated
# customer subscriptions become visible automatically via Lighthouse.
# ───────────────────────────────────────────────────────────────────────────────
$ctx = Get-AzContext
if (-not $ctx) {
    Write-Host "  Not authenticated. Running Connect-AzAccount..." -ForegroundColor Yellow
    if ($PartnerTenantId) {
        Connect-AzAccount -Tenant $PartnerTenantId
    } else {
        Connect-AzAccount
    }
    $ctx = Get-AzContext
}
if (-not $ctx) {
    Write-Host "  ERROR: Authentication failed." -ForegroundColor Red
    return
}

if (-not $PartnerTenantId) { $PartnerTenantId = $ctx.Tenant.Id }

Write-Host "  Signed in as:    $($ctx.Account.Id)" -ForegroundColor Green
Write-Host "  Partner tenant:  $PartnerTenantId" -ForegroundColor Green
Write-Host ""

# ───────────────────────────────────────────────────────────────────────────────
# Discover delegated customer tenants. Lighthouse-delegated subscriptions appear
# in Get-AzSubscription with the customer's TenantId, distinct from the
# partner's. Group those subs by tenant to surface customer-level choices.
# ───────────────────────────────────────────────────────────────────────────────
Write-Host "  Discovering delegated customer tenants..." -ForegroundColor Yellow

$allSubs = Get-AzSubscription -ErrorAction SilentlyContinue | Where-Object { $_.State -eq 'Enabled' }
$customerSubs = @($allSubs | Where-Object { $_.TenantId -and $_.TenantId -ne $PartnerTenantId })

if (-not $customerSubs -or $customerSubs.Count -eq 0) {
    Write-Host "  No delegated customer subscriptions found." -ForegroundColor Red
    Write-Host "  Confirm that Centre has Lighthouse delegation in place and that you're" -ForegroundColor Yellow
    Write-Host "  signed in with an identity in the delegated security group." -ForegroundColor Yellow
    return
}

$customers = $customerSubs |
    Group-Object TenantId |
    ForEach-Object {
        [PSCustomObject]@{
            TenantId      = $_.Name
            Subscriptions = @($_.Group)
            SubCount      = $_.Group.Count
            DisplayName   = ($_.Group | Select-Object -First 1).Name  # best-effort label
        }
    } |
    Sort-Object TenantId

Write-Host "  Found $($customers.Count) delegated customer tenant(s), $($customerSubs.Count) total subscription(s)." -ForegroundColor Green
Write-Host ""

# ───────────────────────────────────────────────────────────────────────────────
# Resolve the target customer set: -CustomerTenantId, -All, or interactive picker.
# ───────────────────────────────────────────────────────────────────────────────
$targets = @()

if ($CustomerTenantId) {
    $match = $customers | Where-Object { $_.TenantId -eq $CustomerTenantId }
    if (-not $match) {
        Write-Host "  ERROR: No delegated subscriptions visible for tenant $CustomerTenantId." -ForegroundColor Red
        return
    }
    if ($CustomerName) { $match.DisplayName = $CustomerName }
    $targets = @($match)
}
elseif ($All) {
    $targets = $customers
}
else {
    Write-Host "  Delegated customers:" -ForegroundColor Cyan
    $i = 0
    foreach ($c in $customers) {
        $i++
        Write-Host ("    [{0,2}]  {1,-40}  Tenant: {2}  Subs: {3}" -f $i, $c.DisplayName, $c.TenantId, $c.SubCount) -ForegroundColor White
    }
    Write-Host "    [A]   Run ALL customers" -ForegroundColor Yellow
    Write-Host "    [Q]   Quit" -ForegroundColor White
    Write-Host ""
    $choice = Read-Host "  Select customer"

    if     ($choice -match '^[Qq]$') { return }
    elseif ($choice -match '^[Aa]$') { $targets = $customers }
    elseif ($choice -match '^\d+$' -and [int]$choice -ge 1 -and [int]$choice -le $customers.Count) {
        $selected = $customers[[int]$choice - 1]
        $promptedName = Read-Host "  Friendly name for output (default: $($selected.DisplayName))"
        if ($promptedName) { $selected.DisplayName = $promptedName }
        $targets = @($selected)
    }
    else {
        Write-Host "  Invalid selection." -ForegroundColor Red
        return
    }
}

# ───────────────────────────────────────────────────────────────────────────────
# Run loop. Per-customer failures don't abort the batch; everything goes into
# a rollup CSV at the end so the operator can see at a glance which customers
# succeeded.
# ───────────────────────────────────────────────────────────────────────────────
New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null
$batchTimestamp = Get-Date -Format 'yyyyMMdd-HHmm'
$rollup = [System.Collections.ArrayList]::new()
$batchStart = Get-Date

foreach ($t in $targets) {
    $custLabel = ($t.DisplayName -replace '[^a-zA-Z0-9_-]', '_')
    if (-not $custLabel) { $custLabel = $t.TenantId }

    Write-Host ""
    Write-Host "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor White
    Write-Host "  CUSTOMER: $custLabel  (tenant $($t.TenantId))" -ForegroundColor White
    Write-Host "  Subscriptions: $($t.SubCount)" -ForegroundColor White
    Write-Host "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor White

    # Set context to the first customer sub so downstream Get-AzContext.Tenant.Id
    # reflects the customer tenant. The Complete script's per-sub Set-AzContext
    # will iterate the rest of the customer's subs from -SubscriptionInclude.
    try {
        Set-AzContext -SubscriptionId $t.Subscriptions[0].Id -TenantId $t.TenantId | Out-Null
    } catch {
        Write-Host "  ERROR setting context: $($_.Exception.Message)" -ForegroundColor Red
        $null = $rollup.Add([PSCustomObject]@{
            Customer        = $custLabel
            TenantId        = $t.TenantId
            Mode            = $Mode
            Status          = 'FAILED (set-context)'
            Error           = $_.Exception.Message
            OutputPath      = ''
            DurationSeconds = 0
        })
        continue
    }

    # GDAP Graph connect (best-effort, no-op for Complete today).
    if ($ConnectGraph) {
        try {
            if (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication) {
                Import-Module Microsoft.Graph.Authentication -ErrorAction SilentlyContinue
                Connect-MgGraph -TenantId $t.TenantId `
                    -Scopes 'User.Read.All','Policy.Read.All','Organization.Read.All','Application.Read.All' `
                    -NoWelcome -ErrorAction SilentlyContinue | Out-Null
                Write-Host "  Graph connected to customer tenant via GDAP." -ForegroundColor Green
            } else {
                Write-Host "  -ConnectGraph requested but Microsoft.Graph.Authentication not installed; skipping." -ForegroundColor Yellow
            }
        } catch {
            Write-Host "  Graph connect failed: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }

    $custSubIds = @($t.Subscriptions | ForEach-Object { $_.Id })
    $custOutput = Join-Path $OutputRoot ("${custLabel}_${batchTimestamp}")
    $custStart  = Get-Date
    $custStatus = 'OK'
    $custError  = ''

    try {
        if ($Mode -in @('Prep','Both')) {
            Write-Host "  Running Prep (-RunAll)..." -ForegroundColor Cyan
            & $prepScript `
                -SubscriptionId $t.Subscriptions[0].Id `
                -RunAll `
                -LighthouseMode `
                -CustomerName $custLabel `
                -CustomerTenantId $t.TenantId
        }

        if ($Mode -in @('Assessment','Both')) {
            Write-Host "  Running Assessment..." -ForegroundColor Cyan
            & $completeScript `
                -OutputPath $custOutput `
                -SubscriptionInclude $custSubIds `
                -SkipMetrics:$SkipMetrics `
                -DaysBack $DaysBack `
                -LighthouseMode `
                -CustomerName $custLabel `
                -CustomerTenantId $t.TenantId
        }
    }
    catch {
        $custStatus = 'FAILED'
        $custError  = $_.Exception.Message
        Write-Host "  Customer run failed: $custError" -ForegroundColor Red
    }

    $duration = [math]::Round(((Get-Date) - $custStart).TotalSeconds, 0)
    $null = $rollup.Add([PSCustomObject]@{
        Customer        = $custLabel
        TenantId        = $t.TenantId
        Mode            = $Mode
        Status          = $custStatus
        Error           = $custError
        OutputPath      = if ($Mode -ne 'Prep') { $custOutput } else { '' }
        DurationSeconds = $duration
    })
}

# ───────────────────────────────────────────────────────────────────────────────
# Cross-customer rollup
# ───────────────────────────────────────────────────────────────────────────────
$rollupPath = Join-Path $OutputRoot "Lighthouse_Rollup_$batchTimestamp.csv"
$rollup | Export-Csv -Path $rollupPath -NoTypeInformation

$totalElapsed = [math]::Round(((Get-Date) - $batchStart).TotalMinutes, 1)
$okCount   = @($rollup | Where-Object { $_.Status -eq 'OK' }).Count
$failCount = @($rollup | Where-Object { $_.Status -ne 'OK' }).Count

Write-Host ""
Write-Host "  ═══════════════════════════════════════════════════════════════" -ForegroundColor Green
Write-Host "  LIGHTHOUSE BATCH COMPLETE" -ForegroundColor Green
Write-Host "  ═══════════════════════════════════════════════════════════════" -ForegroundColor Green
Write-Host "  Customers processed: $($rollup.Count)   OK: $okCount   Failed: $failCount" -ForegroundColor Green
Write-Host "  Elapsed:             $totalElapsed minutes" -ForegroundColor Green
Write-Host "  Per-customer output: $OutputRoot/<CustomerName>_$batchTimestamp/" -ForegroundColor Green
Write-Host "  Rollup CSV:          $rollupPath" -ForegroundColor Green
Write-Host ""
