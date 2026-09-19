#Requires -Version 7.0
<#
.SYNOPSIS
    Azure FinOps Executive Assessment v7.0 - executive HTML report, CSV exports and JSON summary.

.DESCRIPTION
    Assesses every ENABLED Azure subscription visible to the signed-in Azure CLI identity in the
    current tenant and produces a client-ready month-to-date FinOps deliverable.

    Design guarantees (unchanged from v6.2, tightened in v7.0):
      * Billing data comes ONLY from the asynchronous Cost Management "Cost Details" report
        (POST generateCostDetailsReport -> HTTP 202 -> poll Location -> download CSV -> process locally).
        The synchronous Cost Management Query API is never used.
      * Azure Retry-After headers are honoured on every throttled/accepted response. Retries and polling
        are bounded by a per-subscription deadline and an attempt ceiling; nothing loops forever.
      * A failed or unreadable cost report is NEVER treated as zero cost. If any enabled subscription
        cannot be fully assessed (inventory or cost), no consolidated report is produced.
      * Live ARM inventory is enumerated independently and billing records are reconciled against it
        (normalised ResourceId -> parent resource -> subscription + resource group + name).
      * Currency is whatever Azure returns. Different currencies are never added together.
      * Nothing is invented: budgets, official forecast, anomalies, commitment utilisation and
        savings are reported as "Not assessed" / "Not available from this assessment".

    Outputs (in a timestamped folder under -OutputRoot):
      <Company>-Azure-FinOps-Report.html, 01..12 CSV exports, 13-Assessment-Summary.json

.PARAMETER OutputRoot
    Parent folder for the report folder and the local cost-details cache.
.PARAMETER CompanyName
    Display name for the report. Defaults to the Entra tenant display name.
.PARAMETER MaxWaitMinutesPerSubscription
    Upper bound for generating one subscription's cost-details report (throttle waits included).
.PARAMETER CacheHours
    Re-use a subscription's downloaded cost-details for this many hours. 0 disables the cache.
.PARAMETER ForceRefresh
    Ignore the local cache and request fresh cost details.
.PARAMETER NoOpen
    Do not open the HTML report when finished.
.PARAMETER RequiredTags
    Tags counted in Cost Governance Readiness. Matching ignores case, spaces, dashes and underscores.
.PARAMETER HistoricalSuppressionThresholdPct
    When historical/deleted spend is at or above this share of MTD spend, the Indicative Month-End
    Run Rate is not calculated (it would be distorted by resources that no longer exist).
.PARAMETER LowSpendThreshold
    MTD total (in the billing currency) at or below which the headline describes spend as "low".
.PARAMETER CommitmentMinMonthlyActiveSpend
    Minimum indicative monthly ACTIVE spend (billing currency units) before commitment discounts are
    even considered. Below this the guardrail statement is shown instead of a recommendation.
.PARAMETER CommitmentMinDaysOfData
    Minimum days of active-spend history required to judge stability.
.PARAMETER CommitmentMaxDailyVariation
    Maximum coefficient of variation of daily active spend for the baseline to count as "stable".
.PARAMETER MaxDetailRows
    Row cap for ranked tables in the HTML report (CSV exports are never truncated).
.PARAMETER MinPollSeconds
    Floor for the wait between cost-report polls (Azure's Retry-After is used when it is larger).
.PARAMETER CostApiVersion
    Cost Management API version used for generateCostDetailsReport.
.PARAMETER ResourceManagerUrl
    ARM endpoint. Defaults to public Azure. Only known Azure endpoints are accepted.
.PARAMETER AllowCustomEndpoint
    Permit a non-Azure or non-HTTPS endpoint (offline testing only). Credentials would be sent there.

.NOTES
    SECURITY AND DATA HANDLING
    - Read-only: the script never creates, changes or deletes an Azure resource. Its only write-like call is
      asking Cost Management to generate a cost report, which is a read of billing data.
    - Network: it talks only to Azure Resource Manager, Microsoft Graph (tenant name), and the Azure Blob Storage
      link Azure returns for the cost report. Nothing is sent to any other service; there is no telemetry.
    - Credentials: it reuses your Azure CLI sign-in. Tokens are held in memory only, are never written to disk or
      logs, and are sent only to the Azure Resource Manager host. Downloads use Azure's short-lived signed link.
    - Endpoint safety: non-Azure endpoints are refused unless -AllowCustomEndpoint is given (testing only).
    - Local files: reports go to -OutputRoot. Cost-details CSVs are cached in a hidden folder there for
      -CacheHours hours; use -CacheHours 0 to keep nothing, or delete that folder after use.
    - CSV exports neutralize spreadsheet formula injection (values starting with = + - @ are prefixed).
    - The HTML report is self-contained and carries a Content-Security-Policy that blocks any external loading.
    - Required Azure roles: Reader and Cost Management Reader on each subscription.

.EXAMPLE
    pwsh ./Azure-FinOps-Assessment.ps1 -CompanyName "Contoso"
.EXAMPLE
    pwsh ./Azure-FinOps-Assessment.ps1 -ForceRefresh -RequiredTags CostCenter,Owner,Environment,Application
#>
[CmdletBinding()]
param(
    [string]$OutputRoot = (Join-Path ([Environment]::GetFolderPath('UserProfile')) 'Downloads'),
    [string]$CompanyName = '',
    [ValidateRange(1, 240)][int]$MaxWaitMinutesPerSubscription = 30,
    [ValidateRange(0, 168)][int]$CacheHours = 4,
    [switch]$ForceRefresh,
    [switch]$NoOpen,
    [string[]]$RequiredTags = @('CostCenter', 'Owner', 'Environment'),
    [ValidateRange(1, 100)][double]$HistoricalSuppressionThresholdPct = 50,
    [double]$LowSpendThreshold = 100,
    [double]$CommitmentMinMonthlyActiveSpend = 2000,
    [ValidateRange(7, 31)][int]$CommitmentMinDaysOfData = 14,
    [double]$CommitmentMaxDailyVariation = 0.30,
    [ValidateRange(5, 500)][int]$MaxDetailRows = 25,
    [ValidateRange(1, 120)][int]$MinPollSeconds = 5,
    [string]$CostApiVersion = '2026-06-01',
    [string]$ResourceManagerUrl = 'https://management.azure.com',
    [switch]$AllowCustomEndpoint
)

# Strict mode surfaces typos/undefined variables immediately. Anything read from external JSON goes
# through Get-Prop so an unexpected payload shape cannot crash the run with a property error.
Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # progress rendering makes large downloads dramatically slower
if (Get-Variable PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
    $PSNativeCommandUseErrorActionPreference = $false   # we inspect $LASTEXITCODE ourselves
}

# Invariant culture everywhere: the -f operator and implicit conversions follow the current culture,
# which would otherwise turn "1,234.50" into "1.234,50" on some workstations.
$Invariant = [System.Globalization.CultureInfo]::InvariantCulture
[System.Threading.Thread]::CurrentThread.CurrentCulture = $Invariant
[System.Threading.Thread]::CurrentThread.CurrentUICulture = $Invariant

$ScriptVersion = '7.0.0'
$ResourceManagerUrl = $ResourceManagerUrl.TrimEnd('/')

# Credential safety: the Azure token is only ever sent to a recognised Azure Resource Manager host over HTTPS.
$TrustedArmHosts = @('management.azure.com', 'management.usgovcloudapi.net', 'management.chinacloudapi.cn')
$TrustedBlobSuffixes = @('.blob.core.windows.net', '.blob.core.usgovcloudapi.net', '.blob.core.chinacloudapi.cn')
$ArmEndpoint = $null
if (-not [Uri]::TryCreate($ResourceManagerUrl, [UriKind]::Absolute, [ref]$ArmEndpoint)) { throw "ResourceManagerUrl '$ResourceManagerUrl' is not a valid URL." }
if (($ArmEndpoint.Scheme -ne 'https' -or $TrustedArmHosts -notcontains $ArmEndpoint.Host)) {
    if (-not $AllowCustomEndpoint) { throw "Refusing to use '$($ArmEndpoint.Host)': your Azure token would be sent to a non-Azure or non-HTTPS endpoint. Use -AllowCustomEndpoint only for offline testing." }
    Write-Warning "-AllowCustomEndpoint is set: credentials will be sent to $($ArmEndpoint.Host). Use for testing only."
}

function Test-TrustedBlobUri {
    # Cost-report downloads must come from Azure Blob Storage over HTTPS.
    param([string]$Uri)
    $Parsed = $null
    if (-not [Uri]::TryCreate($Uri, [UriKind]::Absolute, [ref]$Parsed)) { return $false }
    if ($AllowCustomEndpoint) { return $true }
    if ($Parsed.Scheme -ne 'https') { return $false }
    foreach ($Suffix in $TrustedBlobSuffixes) { if ($Parsed.Host.EndsWith($Suffix, [StringComparison]::OrdinalIgnoreCase)) { return $true } }
    return $false
}

function Protect-CsvRow {
    # Spreadsheet formula-injection defence: text starting with = + - @ (or tab / CR) is prefixed with an apostrophe.
    # Numbers (decimal / int) are left untouched.
    param($Row)
    $Clean = [ordered]@{}
    foreach ($Property in $Row.PSObject.Properties) {
        $Value = $Property.Value
        if ($Value -is [string] -and $Value.Length -gt 0 -and $Value[0] -in @('=', '+', '-', '@', "`t", "`r")) { $Value = "'" + $Value }
        $Clean[$Property.Name] = $Value
    }
    return [PSCustomObject]$Clean
}

# ---- Classification vocabulary (single source of truth; never re-typed elsewhere) -------------------
$StateCurrent = 'Current'
$StateHistorical = 'Historical / Deleted'
$StateUnmapped = 'Unmapped Charge'
$CategoryCurrentWithCost = 'Current - With MTD Cost'
$CategoryCurrentNoCost = 'Current - No MTD Cost'
$CategoryHistoricalWithCost = 'Historical/Deleted - With MTD Cost'
$CategoryHistoricalZeroCost = 'Historical/Deleted - Zero MTD Cost'
$CategoryUnmapped = 'Unmapped Charge'

# Charge types that are not "usage of a resource". If one of these cannot be matched to a live
# resource it is reported as Unmapped rather than being asserted to be a deleted resource.
$NonUsageChargeTypes = @('Purchase', 'Refund', 'UnusedReservation', 'UnusedSavingsPlan', 'RoundingAdjustment')

# ---- Reporting period (UTC, because Azure billing dates are UTC) ----------------------------------
$GeneratedAtLocal = Get-Date
$GeneratedAtUtc = [DateTime]::UtcNow
$Stamp = $GeneratedAtLocal.ToString('yyyy-MM-dd_HHmm', $Invariant)
$MonthStart = [DateTime]::new($GeneratedAtUtc.Year, $GeneratedAtUtc.Month, 1, 0, 0, 0, [DateTimeKind]::Utc)
$MonthKey = $MonthStart.ToString('yyyy-MM', $Invariant)
$DaysInMonth = [DateTime]::DaysInMonth($GeneratedAtUtc.Year, $GeneratedAtUtc.Month)

# ---- Run state shared by helpers -------------------------------------------------------------------
$script:ArmToken = $null
$script:ArmTokenAcquiredUtc = [DateTime]::MinValue
$script:LiveById = @{}        # normalised ARM id            -> live resource
$script:LiveByName = @{}      # sub|rg|name                  -> List[live resource]
$script:ExtraLive = [System.Collections.Generic.List[object]]::new()   # resources found by direct lookup that the inventory listing missed
$script:LiveTypeSet = @{}     # sub|resourceType             -> $true (types that ARM inventory returned)
$script:AssessedSubIds = @{}  # lower-case subscription id   -> $true
$script:ResourceAgg = @{}     # billing aggregate per resource (+ currency)
$script:ServiceAgg = @{}
$script:ResourceGroupAgg = @{}
$script:DailyActive = @{}     # "CUR|yyyy-MM-dd" -> active (Current) cost, used for commitment stability
$script:DateCache = @{}
$script:RawChunk = [System.Collections.Generic.List[object]]::new()
$script:RawCsvPath = ''
$script:MaxDateKey = ''
$script:Counters = @{
    CostRows = 0; OutOfMonthRows = 0; ZeroCostBlankCurrencyRows = 0
    FallbackMatches = 0; ParentMatches = 0; CommitmentPricedRows = 0
    DirectLookupMatches = 0; DeletionConfirmed = 0; DeletionUnverified = 0; DeletionChecksRun = 0
}

#region ---------------------------------------------------------------- Console helpers
function Write-Banner {
    param([string]$Text, [string]$Color = 'Cyan')
    Write-Host ''
    Write-Host ('=' * 72) -ForegroundColor $Color
    Write-Host " $Text" -ForegroundColor $Color
    Write-Host ('=' * 72) -ForegroundColor $Color
}

function Write-Note {
    param([string]$Text, [string]$Color = 'DarkGray')
    Write-Host $Text -ForegroundColor $Color
}
#endregion

#region ---------------------------------------------------------------- Formatting / parsing helpers
function Get-SafeName {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return 'Azure-Tenant' }
    return (($Value -replace '[\\/:*?"<>|]', '-') -replace '\s+', '-').Trim('-')
}

function Format-Amount {
    # Small amounts keep four decimals (FinOps assessments of small estates need that precision).
    param($Amount)
    if ($null -eq $Amount) { return 'n/a' }
    $Value = [decimal]$Amount
    if ([math]::Abs($Value) -lt 100) { return $Value.ToString('N4', $Invariant) }
    return $Value.ToString('N2', $Invariant)
}

function Format-Money {
    param($Amount, [string]$Currency)
    $Text = Format-Amount $Amount
    if ($Currency) { return "$Text $Currency" }
    return $Text
}

function Format-Percent {
    param($Value)
    if ($null -eq $Value) { return 'n/a' }
    return ([double]$Value).ToString('0.#', $Invariant) + '%'
}

function Get-Percent {
    param($Part, $Whole)
    if ($null -eq $Whole -or [decimal]$Whole -le 0) { return $null }
    return [math]::Round(([double]$Part / [double]$Whole) * 100, 1)
}

function Format-Number {
    param($Value, [string]$Format = '0.##')
    return ([double]$Value).ToString($Format, $Invariant)
}

function ConvertTo-HtmlText {
    param($Value)
    if ($null -eq $Value) { return '' }
    return [System.Net.WebUtility]::HtmlEncode([string]$Value)
}

function Get-Prop {
    # Null-safe, case-insensitive property read for objects that came from external JSON.
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    $Property = $Object.PSObject.Properties[$Name]
    if ($null -ne $Property -and $null -ne $Property.Value) { return $Property.Value }
    return $Default
}

function ConvertFrom-JsonArray {
    # ConvertFrom-Json unrolls single-element arrays; -NoEnumerate + @() gives a stable array shape
    # for empty, single-result and multi-result payloads alike.
    param([string]$Json)
    if ([string]::IsNullOrWhiteSpace($Json)) { return @() }
    $Parsed = $Json | ConvertFrom-Json -NoEnumerate
    if ($null -eq $Parsed) { return @() }
    return @($Parsed)
}

function ConvertTo-InvariantDecimal {
    # A cost value that cannot be parsed is an error - it must never silently become zero.
    param($Value, [string]$Context = 'cost value')
    if ($null -eq $Value) { return [decimal]0 }
    $Text = ([string]$Value).Trim()
    if ($Text -eq '') { return [decimal]0 }
    $Parsed = [decimal]0
    $Styles = [System.Globalization.NumberStyles]::Float -bor [System.Globalization.NumberStyles]::AllowThousands
    if (-not [decimal]::TryParse($Text, $Styles, $Invariant, [ref]$Parsed)) {
        throw "Unable to parse $Context '$Text' as a decimal. Report aborted rather than treating unreadable billing data as zero."
    }
    return $Parsed
}

function Get-DecimalSum {
    param([object[]]$Items, [string]$Property)
    $Sum = [decimal]0
    foreach ($Item in $Items) { $Sum += [decimal]$Item.$Property }
    return $Sum
}
#endregion

#region ---------------------------------------------------------------- Resource-ID helpers
function ConvertTo-NormalizedResourceId {
    # Billing and ARM disagree on casing, trailing slashes and (rarely) URL-encoding.
    param([string]$ResourceId)
    if ([string]::IsNullOrWhiteSpace($ResourceId)) { return '' }
    $Value = $ResourceId.Trim()
    if ($Value.Contains('%')) {
        try { $Value = [System.Uri]::UnescapeDataString($Value) } catch { }
    }
    return $Value.TrimEnd('/').ToLowerInvariant()
}

function Test-ArmResourceId {
    # True only for ids shaped like a real resource: /subscriptions/x/resourceGroups/y/providers/ns/type/name
    param([string]$NormalizedId)
    return [bool]($NormalizedId -match '^/subscriptions/[^/]+/resourcegroups/[^/]+/providers/[^/]+/[^/]+/[^/]+')
}

function Get-LastProvidersIndex {
    param([string[]]$Parts)
    for ($Index = $Parts.Count - 1; $Index -ge 0; $Index--) {
        if ($Parts[$Index] -ieq 'providers') { return $Index }
    }
    return -1
}

function Get-ResourceTypeFromId {
    # Handles child types (ns/type/childType) and extension resources (last 'providers' segment wins).
    param([string]$ResourceId)
    if ([string]::IsNullOrWhiteSpace($ResourceId)) { return '' }
    $Parts = @($ResourceId.Trim('/') -split '/')
    $Index = Get-LastProvidersIndex $Parts
    if ($Index -lt 0 -or ($Index + 3) -ge $Parts.Count) { return '' }
    $Type = '{0}/{1}' -f $Parts[$Index + 1], $Parts[$Index + 2]
    for ($Position = $Index + 4; ($Position + 1) -lt $Parts.Count; $Position += 2) {
        $Type += '/' + $Parts[$Position]
    }
    return $Type
}

function Get-ResourceGroupFromId {
    param([string]$ResourceId)
    if ($ResourceId -match '(?i)/resourcegroups/([^/]+)') { return [string]$Matches[1] }
    return ''
}

function Get-SubscriptionIdFromId {
    param([string]$ResourceId)
    if ($ResourceId -match '(?i)^/subscriptions/([^/]+)') { return ([string]$Matches[1]).ToLowerInvariant() }
    return ''
}

function Get-ResourceNameFromId {
    param([string]$ResourceId)
    if ([string]::IsNullOrWhiteSpace($ResourceId)) { return '' }
    return [string](@($ResourceId.TrimEnd('/') -split '/') | Select-Object -Last 1)
}

function Get-ParentResourceIds {
    # Ancestors of a child resource id, nearest first, never shorter than ns/type/name.
    param([string]$NormalizedId)
    $Parts = @($NormalizedId.Trim('/') -split '/')
    $Index = Get-LastProvidersIndex $Parts
    $Parents = [System.Collections.Generic.List[string]]::new()
    if ($Index -lt 0) { return $Parents.ToArray() }
    $Length = $Parts.Count - 2
    while ($Length -ge ($Index + 4)) {
        $Parents.Add('/' + (($Parts[0..($Length - 1)]) -join '/'))
        $Length -= 2
    }
    return $Parents.ToArray()
}

function Get-ResourceMatchKey {
    param([string]$SubscriptionId, [string]$ResourceGroup, [string]$ResourceName)
    return ('{0}|{1}|{2}' -f $SubscriptionId.ToLowerInvariant(), $ResourceGroup.ToLowerInvariant(), $ResourceName.ToLowerInvariant())
}

function Resolve-LiveResource {
    <#
        Reconciles ONE billed resource against the live ARM inventory. Order matters and is the core
        safeguard against calling an active resource "historical":
          1. exact normalised ResourceId
          2. live PARENT of a billed child, but only when ARM inventory returned no resource of the
             child's type at all in that subscription (i.e. ARM listings do not enumerate that child type)
          3. subscription + resource group + name (type must agree when both sides know it)
    #>
    param(
        [string]$SubscriptionId,
        [string]$NormalizedId,
        [string]$ResourceName,
        [string]$ResourceGroup,
        [string]$ResourceType
    )

    if ($NormalizedId) {
        if ($script:LiveById.ContainsKey($NormalizedId)) {
            return [PSCustomObject]@{ Live = $script:LiveById[$NormalizedId]; Method = 'ResourceId' }
        }

        $IdSubscription = Get-SubscriptionIdFromId $NormalizedId
        $TypeKey = ('{0}|{1}' -f $IdSubscription, $ResourceType.ToLowerInvariant())
        if (-not $script:LiveTypeSet.ContainsKey($TypeKey)) {
            foreach ($ParentId in @(Get-ParentResourceIds $NormalizedId)) {
                if ($script:LiveById.ContainsKey($ParentId)) {
                    return [PSCustomObject]@{ Live = $script:LiveById[$ParentId]; Method = 'ParentResource' }
                }
            }
        }
    }

    if ($ResourceName) {
        $Key = Get-ResourceMatchKey -SubscriptionId $SubscriptionId -ResourceGroup $ResourceGroup -ResourceName $ResourceName
        if ($script:LiveByName.ContainsKey($Key)) {
            foreach ($Candidate in $script:LiveByName[$Key]) {
                if (-not $ResourceType -or $Candidate.ResourceType -ieq $ResourceType) {
                    return [PSCustomObject]@{ Live = $Candidate; Method = 'Sub+RG+Name' }
                }
            }
        }
    }

    return [PSCustomObject]@{ Live = $null; Method = 'None' }
}
#endregion

#region ---------------------------------------------------------------- Tag helpers
function Get-TagKey {
    # "Cost Center", "cost-center" and "CostCenter" are the same governance tag.
    param([string]$Name)
    return ($Name -replace '[^A-Za-z0-9]', '').ToLowerInvariant()
}

function ConvertTo-TagMap {
    param($Tags)
    $Map = @{}
    if ($null -eq $Tags) { return $Map }
    foreach ($Property in $Tags.PSObject.Properties) {
        $Key = Get-TagKey $Property.Name
        $Value = [string]$Property.Value
        if ($Key -and -not [string]::IsNullOrWhiteSpace($Value) -and -not $Map.ContainsKey($Key)) {
            $Map[$Key] = $Value
        }
    }
    return $Map
}
#endregion

#region ---------------------------------------------------------------- Tag value helpers
function ConvertTo-TagPairs {
    # ARM tags object -> ordered name/value pairs (original tag-name casing preserved for reporting).
    param($Tags)
    $Pairs = [ordered]@{}
    if ($null -eq $Tags) { return $Pairs }
    foreach ($Property in $Tags.PSObject.Properties) {
        $Value = [string]$Property.Value
        if (-not [string]::IsNullOrWhiteSpace($Value) -and -not $Pairs.Contains($Property.Name)) { $Pairs[$Property.Name] = $Value }
    }
    return $Pairs
}

function ConvertFrom-CostTags {
    # The Cost Details "Tags" column holds text such as:  "env": "prod","owner": "jane"
    param([string]$Text)
    $Pairs = [ordered]@{}
    if ([string]::IsNullOrWhiteSpace($Text)) { return $Pairs }
    foreach ($Match in [regex]::Matches($Text, '"((?:[^"\\]|\\.)+)"\s*:\s*"((?:[^"\\]|\\.)*)"')) {
        $Name = $Match.Groups[1].Value
        $Value = $Match.Groups[2].Value
        if (-not [string]::IsNullOrWhiteSpace($Value) -and -not $Pairs.Contains($Name)) { $Pairs[$Name] = $Value }
    }
    return $Pairs
}

function Get-TagValue {
    # Value of a governance tag, matching "Cost Center" / "cost-center" / "CostCenter" as the same tag.
    param($Tags, [string]$Name)
    if ($null -eq $Tags) { return '' }
    $Wanted = Get-TagKey $Name
    foreach ($Key in $Tags.Keys) {
        if ((Get-TagKey ([string]$Key)) -eq $Wanted) {
            $Value = [string]$Tags[$Key]
            if (-not [string]::IsNullOrWhiteSpace($Value)) { return $Value }
        }
    }
    return ''
}

function Format-TagText {
    param($Tags)
    if ($null -eq $Tags -or $Tags.Count -eq 0) { return '' }
    return (@($Tags.Keys | Sort-Object | ForEach-Object { '{0}={1}' -f $_, $Tags[$_] }) -join '; ')
}
#endregion

#region ---------------------------------------------------------------- Azure CLI wrapper
function Invoke-AzCli {
    # Runs az, captures stdout/stderr separately, never throws on a non-zero exit (caller decides).
    param([Parameter(Mandatory)][string[]]$Arguments)
    $Previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $Output = & az @Arguments 2>&1
        $ExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $Previous
    }

    $ErrorLines = @($Output | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] } | ForEach-Object { $_.ToString() })
    $StdLines = @($Output | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] } | ForEach-Object { [string]$_ })

    return [PSCustomObject]@{
        ExitCode = $ExitCode
        Output   = ($StdLines -join "`n").Trim()
        Error    = ($ErrorLines -join "`n").Trim()
    }
}

function Get-ArmAccessToken {
    # Token is reused (CLI tokens live ~60+ minutes) instead of shelling out to az per request.
    param([switch]$ForceNew)
    $AgeMinutes = ([DateTime]::UtcNow - $script:ArmTokenAcquiredUtc).TotalMinutes
    if (-not $ForceNew -and $script:ArmToken -and $AgeMinutes -lt 40) { return $script:ArmToken }

    $Result = Invoke-AzCli -Arguments @('account', 'get-access-token', '--resource', "$ResourceManagerUrl/", '--query', 'accessToken', '-o', 'tsv', '--only-show-errors')
    if ($Result.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($Result.Output)) {
        throw "Unable to obtain an Azure Resource Manager token. Run 'az login' and retry."
    }
    $script:ArmToken = $Result.Output
    $script:ArmTokenAcquiredUtc = [DateTime]::UtcNow
    return $script:ArmToken
}
#endregion

#region ---------------------------------------------------------------- HTTP: throttling-aware ARM requests
function Get-HeaderValue {
    # Works for both response-header shapes PowerShell 7 can hand back (dictionary and HttpHeaders).
    # The v6.2 implementation indexed HttpResponseHeaders directly, which throws and was swallowed,
    # so Azure's Retry-After on a 429 was silently ignored.
    param($Headers, [string]$Name)
    if ($null -eq $Headers) { return $null }
    foreach ($Entry in $Headers.GetEnumerator()) {
        if ([string]$Entry.Key -ieq $Name) {
            $Value = $Entry.Value
            if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
                $Value = @($Value) | Select-Object -First 1
            }
            return [string]$Value
        }
    }
    return $null
}

function Get-RetryAfterSeconds {
    # Returns the LONGEST wait Azure asks for across Retry-After and the Cost Management rate-limit
    # headers (entity / tenant / client / qpu variants), so no limiter is retried early.
    param($Headers, [int]$FallbackSeconds = 30)
    $Longest = 0
    if ($null -ne $Headers) {
        foreach ($Entry in $Headers.GetEnumerator()) {
            $Key = [string]$Entry.Key
            if ($Key -ine 'Retry-After' -and $Key -inotlike 'x-ms-ratelimit-microsoft.costmanagement-*-retry-after') { continue }

            $Raw = $Entry.Value
            if ($Raw -is [System.Collections.IEnumerable] -and $Raw -isnot [string]) { $Raw = @($Raw) | Select-Object -First 1 }
            $Raw = ([string]$Raw).Trim()

            $Seconds = 0
            if ([int]::TryParse($Raw, [System.Globalization.NumberStyles]::Integer, $Invariant, [ref]$Seconds)) {
                # numeric delay-seconds
            }
            else {
                $When = [DateTimeOffset]::MinValue
                if ([DateTimeOffset]::TryParse($Raw, $Invariant, [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref]$When)) {
                    $Seconds = [int][math]::Ceiling(($When - [DateTimeOffset]::UtcNow).TotalSeconds)
                }
            }
            if ($Seconds -gt $Longest) { $Longest = $Seconds }
        }
    }
    if ($Longest -gt 0) { return $Longest }
    return $FallbackSeconds
}

function Get-ArmErrorSummary {
    param($Response)
    $Content = ''
    try { $Content = [string]$Response.Content } catch { }
    if ([string]::IsNullOrWhiteSpace($Content)) { return '' }
    try {
        $Json = $Content | ConvertFrom-Json
        $ErrorObject = Get-Prop $Json 'error'
        $Message = Get-Prop $ErrorObject 'message'
        if ($Message) { return ([string]$Message -replace '\s+', ' ').Trim() }
    }
    catch { }
    $Flat = ($Content -replace '\s+', ' ').Trim()
    if ($Flat.Length -gt 300) { $Flat = $Flat.Substring(0, 300) }
    return $Flat
}

function Invoke-ArmRequest {
    <#
        One Azure Resource Manager call with bounded, header-driven retries.
          429            -> wait the Retry-After Azure asked for, then retry
          500/502/503/504-> wait (Retry-After or gentle backoff), then retry
          transport error-> short backoff, then retry
          401            -> refresh the token once
          403 / other    -> fail with a clear message
        Bounded by both an attempt ceiling and the caller's deadline - never infinite.
    #>
    param(
        [Parameter(Mandatory)][string]$Method,
        [Parameter(Mandatory)][string]$Uri,
        [string]$Body = '',
        [Parameter(Mandatory)][datetime]$Deadline,
        [string]$Activity = 'Azure Cost Management',
        [int]$MaxAttempts = 8
    )

    $TargetUri = $null
    if (-not [Uri]::TryCreate($Uri, [UriKind]::Absolute, [ref]$TargetUri) -or $TargetUri.Host -ne $ArmEndpoint.Host) {
        throw 'Refusing to send Azure credentials to a host other than the configured Azure Resource Manager endpoint.'
    }
    $Attempt = 0
    $TokenRefreshed = $false

    while ($true) {
        $Attempt++

        $Parameters = @{
            Method             = $Method
            Uri                = $Uri
            Headers            = @{ Authorization = "Bearer $(Get-ArmAccessToken)" }
            SkipHttpErrorCheck = $true      # return 4xx/5xx as a response so headers are always readable
            ErrorAction        = 'Stop'
        }
        if ($Body) {
            $Parameters['Body'] = $Body
            $Parameters['ContentType'] = 'application/json'
        }

        $Response = $null
        $TransportError = $null
        try { $Response = Invoke-WebRequest @Parameters } catch { $TransportError = $_.Exception.Message }

        $Wait = 0
        $Reason = ''

        if ($null -ne $Response) {
            $Status = [int]$Response.StatusCode
            if ($Status -in 200, 202, 204) { return $Response }

            if ($Status -eq 401) {
                if ($TokenRefreshed) { throw 'Azure authentication failed. Run ''az login'' and retry.' }
                $TokenRefreshed = $true
                [void](Get-ArmAccessToken -ForceNew)
                continue
            }
            if ($Status -eq 403) {
                throw "$Activity access denied (HTTP 403). Cost Management Reader (or equivalent billing/cost access) is required on every subscription."
            }
            if ($Status -eq 429) {
                $Wait = Get-RetryAfterSeconds -Headers $Response.Headers -FallbackSeconds ([math]::Min(300, 30 * $Attempt))
                $Reason = 'is throttling requests (HTTP 429)'
            }
            elseif ($Status -in 500, 502, 503, 504) {
                $Wait = Get-RetryAfterSeconds -Headers $Response.Headers -FallbackSeconds ([math]::Min(180, 20 * $Attempt))
                $Reason = "is temporarily unavailable (HTTP $Status)"
            }
            else {
                $Detail = Get-ArmErrorSummary $Response
                throw "$Activity request failed with HTTP ${Status}: $Detail"
            }
        }
        else {
            $Wait = [math]::Min(60, 10 * $Attempt)
            $Reason = "could not be reached ($TransportError)"
        }

        if ($Attempt -ge $MaxAttempts) {
            throw "$Activity $Reason and did not recover after $Attempt attempts."
        }
        if ((Get-Date).AddSeconds($Wait) -gt $Deadline) {
            throw "Timed out waiting for $Activity ($Reason; Azure asked for a $Wait second wait which exceeds the remaining time budget). Increase -MaxWaitMinutesPerSubscription or retry later - cached data from earlier runs is reused automatically."
        }
        Write-Note "$Activity $Reason. Waiting $Wait seconds as requested before retrying..." 'DarkYellow'
        Start-Sleep -Seconds $Wait
    }
}
#endregion

#region ---------------------------------------------------------------- Async Cost Details + local cache
function Expand-GzipIfNeeded {
    # Cost Details blobs may be gzip-compressed; detect by magic bytes rather than trusting extensions.
    param([string]$Path)
    $Stream = [System.IO.File]::OpenRead($Path)
    try { $First = $Stream.ReadByte(); $Second = $Stream.ReadByte() } finally { $Stream.Dispose() }
    if ($First -ne 0x1F -or $Second -ne 0x8B) { return }

    $Expanded = "$Path.expanded"
    $InStream = [System.IO.File]::OpenRead($Path)
    $Gzip = [System.IO.Compression.GZipStream]::new($InStream, [System.IO.Compression.CompressionMode]::Decompress)
    $OutStream = [System.IO.File]::Create($Expanded)
    try { $Gzip.CopyTo($OutStream) } finally { $OutStream.Dispose(); $Gzip.Dispose(); $InStream.Dispose() }
    Move-Item -LiteralPath $Expanded -Destination $Path -Force
}

function Get-CachedCostDetails {
    # A cache entry is valid only if: meta file present (written LAST, so it proves the download
    # completed), same subscription, same calendar month, young enough, and every part still exists.
    param([string]$SubscriptionId, [string]$CacheRoot)
    if ($ForceRefresh -or $CacheHours -le 0) { return $null }

    $MetaPath = Join-Path $CacheRoot "$SubscriptionId-$MonthKey.meta.json"
    if (-not (Test-Path -LiteralPath $MetaPath)) { return $null }

    try {
        $Meta = Get-Content -LiteralPath $MetaPath -Raw | ConvertFrom-Json
        if ([string](Get-Prop $Meta 'SubscriptionId') -ne $SubscriptionId) { return $null }
        if ([string](Get-Prop $Meta 'PeriodMonth') -ne $MonthKey) { return $null }

        $Generated = [DateTimeOffset]::FromUnixTimeSeconds([long](Get-Prop $Meta 'GeneratedUnix' 0)).UtcDateTime
        $AgeHours = ([DateTime]::UtcNow - $Generated).TotalHours
        if ($AgeHours -ge $CacheHours -or $AgeHours -lt 0) { return $null }

        $Parts = @()
        foreach ($Name in @(Get-Prop $Meta 'Parts' @())) {
            $Path = Join-Path $CacheRoot ([string]$Name)
            if (-not (Test-Path -LiteralPath $Path)) { return $null }
            $Parts += $Path
        }

        return [PSCustomObject]@{ Parts = $Parts; Source = 'Cache'; AgeHours = [math]::Round($AgeHours, 1); NoData = ($Parts.Count -eq 0) }
    }
    catch {
        return $null    # corrupt cache entry => treat as a miss and regenerate
    }
}

function Read-CostDetailsResult {
    # Interprets a 200 body from generateCostDetailsReport / its operation-status URL.
    param($Response)
    $Json = $null
    try { $Json = [string]$Response.Content | ConvertFrom-Json } catch { }
    $Status = [string](Get-Prop $Json 'status' 'Completed')

    if ($Status -ieq 'Failed') {
        $Message = Get-Prop (Get-Prop $Json 'error') 'message' 'no detail returned'
        throw "Azure reported the cost-details report generation as failed: $Message"
    }
    if ($Status -ieq 'NoDataFound') { return [PSCustomObject]@{ State = 'NoData'; Manifest = $null } }
    if ($Status -inotin 'Completed', 'Succeeded') { return [PSCustomObject]@{ State = 'Pending'; Manifest = $null } }

    $Manifest = Get-Prop $Json 'manifest'
    $Blobs = @(Get-Prop $Manifest 'blobs' @())
    if ($null -eq $Manifest -or $Blobs.Count -eq 0) { return [PSCustomObject]@{ State = 'NoData'; Manifest = $null } }
    return [PSCustomObject]@{ State = 'Ready'; Manifest = $Manifest }
}

function Get-CostDetails {
    <#
        Workflow (async Cost Details - deliberately NOT the synchronous Query API):
          1. POST generateCostDetailsReport
          2. HTTP 202 -> read Location + Retry-After
          3. wait (never less than Retry-After, never less than -MinPollSeconds), poll Location
          4. Completed -> download the SAS blob CSV parts (no bearer token is sent to blob storage)
          5. store parts in the local cache, meta file last
        Returns the CSV part paths. Throws if anything is incomplete - never returns "zero" on failure.
    #>
    param([Parameter(Mandatory)]$Subscription, [Parameter(Mandatory)][string]$CacheRoot)

    $SubscriptionId = [string]$Subscription.Id
    $Cached = Get-CachedCostDetails -SubscriptionId $SubscriptionId -CacheRoot $CacheRoot
    if ($null -ne $Cached) {
        Write-Note ("Using local cost-details cache for {0} ({1} h old)." -f $Subscription.Name, $Cached.AgeHours)
        return $Cached
    }

    $Deadline = (Get-Date).AddMinutes($MaxWaitMinutesPerSubscription)
    $CreateUri = "$ResourceManagerUrl/subscriptions/$SubscriptionId/providers/Microsoft.CostManagement/generateCostDetailsReport?api-version=$CostApiVersion"
    $RequestBody = '{"metric":"ActualCost"}'   # no timePeriod => Azure's documented default: the current month

    Write-Host "Requesting asynchronous cost-details report for $($Subscription.Name)..." -ForegroundColor Cyan
    $Response = Invoke-ArmRequest -Method POST -Uri $CreateUri -Body $RequestBody -Deadline $Deadline

    $Result = $null
    $Status = [int]$Response.StatusCode
    if ($Status -eq 204) {
        $Result = [PSCustomObject]@{ State = 'NoData'; Manifest = $null }
    }
    elseif ($Status -eq 200) {
        $Result = Read-CostDetailsResult $Response
    }

    if ($null -eq $Result -or $Result.State -eq 'Pending') {
        $PollUri = Get-HeaderValue -Headers $Response.Headers -Name 'Location'
        if (-not $PollUri) { throw 'Azure accepted the cost-details request but returned no Location header to poll.' }

        $Last = $Response
        $PollCount = 0
        while ($true) {
            $PollCount++
            $Wait = [math]::Max($MinPollSeconds, (Get-RetryAfterSeconds -Headers $Last.Headers -FallbackSeconds ([math]::Min(60, 15 * $PollCount))))
            if ((Get-Date).AddSeconds($Wait) -gt $Deadline) {
                throw "Timed out waiting for the cost-details report for $($Subscription.Name). Increase -MaxWaitMinutesPerSubscription or retry later."
            }
            Write-Note "Azure is preparing the report for $($Subscription.Name). Checking again in $Wait seconds..."
            Start-Sleep -Seconds $Wait

            $Poll = Invoke-ArmRequest -Method GET -Uri $PollUri -Deadline $Deadline -Activity 'Azure Cost Management (report status)'
            $PollStatus = [int]$Poll.StatusCode
            if ($PollStatus -eq 202) {
                $Last = $Poll
                $NextLocation = Get-HeaderValue -Headers $Poll.Headers -Name 'Location'
                if ($NextLocation) { $PollUri = $NextLocation }
                continue
            }
            if ($PollStatus -eq 204) { $Result = [PSCustomObject]@{ State = 'NoData'; Manifest = $null }; break }

            $Result = Read-CostDetailsResult $Poll
            if ($Result.State -eq 'Pending') { $Last = $Poll; continue }
            break
        }
    }

    # ---- download into a private temp folder, then commit atomically -------------------------------
    $Pending = Join-Path $CacheRoot ('pending-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $Pending -Force | Out-Null
    try {
        $StagedParts = @()
        if ($Result.State -eq 'Ready') {
            $Index = 0
            foreach ($Blob in @(Get-Prop $Result.Manifest 'blobs' @())) {
                $Index++
                $BlobLink = [string](Get-Prop $Blob 'blobLink')
                if (-not $BlobLink) { throw "Cost-details manifest entry $Index has no download link." }

                $Staged = Join-Path $Pending "part$Index.csv"
                if (-not (Test-TrustedBlobUri $BlobLink)) { throw 'The cost-report download link is not an Azure Blob Storage HTTPS address; download refused.' }
                Invoke-WebRequest -Uri $BlobLink -OutFile $Staged -MaximumRetryCount 3 -RetryIntervalSec 5 -ErrorAction Stop
                Expand-GzipIfNeeded -Path $Staged
                if ((Get-Item -LiteralPath $Staged).Length -gt 0) { $StagedParts += $Staged }
            }
        }

        # Replace any previous parts for this subscription+month, move new ones in, write meta LAST.
        Get-ChildItem -LiteralPath $CacheRoot -Filter "$SubscriptionId-$MonthKey-part*.csv" -ErrorAction SilentlyContinue |
            Remove-Item -Force -ErrorAction SilentlyContinue

        $FinalParts = @()
        $PartNumber = 0
        foreach ($Staged in $StagedParts) {
            $PartNumber++
            $FinalPath = Join-Path $CacheRoot "$SubscriptionId-$MonthKey-part$PartNumber.csv"
            Move-Item -LiteralPath $Staged -Destination $FinalPath -Force
            $FinalParts += $FinalPath
        }

        $Meta = [ordered]@{
            SubscriptionId = $SubscriptionId
            PeriodMonth    = $MonthKey
            GeneratedUnix  = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
            Parts          = @($FinalParts | ForEach-Object { Split-Path -Leaf $_ })
            ApiVersion     = $CostApiVersion
        }
        $MetaPath = Join-Path $CacheRoot "$SubscriptionId-$MonthKey.meta.json"
        $MetaTemp = "$MetaPath.tmp"
        $Meta | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $MetaTemp -Encoding utf8
        Move-Item -LiteralPath $MetaTemp -Destination $MetaPath -Force

        return [PSCustomObject]@{ Parts = $FinalParts; Source = 'Azure'; AgeHours = 0; NoData = ($FinalParts.Count -eq 0) }
    }
    finally {
        Remove-Item -LiteralPath $Pending -Recurse -Force -ErrorAction SilentlyContinue
    }
}
#endregion

#region ---------------------------------------------------------------- Direct deletion check
function Confirm-ResourceMissing {
    <#
        Second, independent proof before anything is called "deleted": ask Azure for the resource by its exact id.
        Exists  -> the inventory listing missed it (it will be treated as Current)
        Deleted -> Azure says it is not found
        Unknown -> the lookup itself failed (permissions, network); the resource stays Historical but is flagged unverified
    #>
    param([string]$RawId, [string]$SubscriptionId)
    $Result = Invoke-AzCli -Arguments @('resource', 'show', '--ids', $RawId, '--subscription', $SubscriptionId, '-o', 'json', '--only-show-errors')
    if ($Result.ExitCode -eq 0 -and $Result.Output) {
        try { return [PSCustomObject]@{ Status = 'Exists'; Resource = ($Result.Output | ConvertFrom-Json) } } catch { }
    }
    if ($Result.ExitCode -ne 0 -and $Result.Error -match '(?i)ResourceNotFound|ResourceGroupNotFound|was not found|could not be found|NotFound') {
        return [PSCustomObject]@{ Status = 'Deleted'; Resource = $null }
    }
    return [PSCustomObject]@{ Status = 'Unknown'; Resource = $null }
}

function New-LiveResourceFromLookup {
    param($Item, [string]$SubscriptionName, [string]$SubscriptionId, [string]$FallbackId)
    $RawId = [string](Get-Prop $Item 'id' $FallbackId)
    $NormId = ConvertTo-NormalizedResourceId $RawId
    $Type = [string](Get-Prop $Item 'type' ''); if (-not $Type) { $Type = Get-ResourceTypeFromId $NormId }
    $Name = [string](Get-Prop $Item 'name' ''); if (-not $Name) { $Name = Get-ResourceNameFromId $NormId }
    $Group = [string](Get-Prop $Item 'resourceGroup' ''); if (-not $Group) { $Group = Get-ResourceGroupFromId $NormId }
    $TagMap = ConvertTo-TagMap (Get-Prop $Item 'tags' $null)
    $RequiredKeys = @($RequiredTags | ForEach-Object { Get-TagKey $_ } | Where-Object { $_ })
    $Missing = @($RequiredKeys | Where-Object { -not $TagMap.ContainsKey($_) })
    return [PSCustomObject]@{
        Subscription = $SubscriptionName; SubscriptionId = $SubscriptionId; ResourceName = $Name; ResourceGroup = $Group
        ResourceType = $Type; Location = [string](Get-Prop $Item 'location' ''); ResourceId = $RawId; NormId = $NormId
        TagMap = $TagMap; TagsRaw = (ConvertTo-TagPairs (Get-Prop $Item 'tags' $null))
        FullyTagged = ($RequiredKeys.Count -gt 0 -and $Missing.Count -eq 0)
        IsTopLevel = (@($Type -split '/').Count -le 2)
    }
}
#endregion

#region ---------------------------------------------------------------- Cost CSV processing (streaming)
function Find-CsvColumn {
    param([string[]]$Names, [string[]]$Candidates)
    foreach ($Candidate in $Candidates) {
        foreach ($Name in $Names) {
            if ($Name -ieq $Candidate) { return [string]$Name }
        }
    }
    return $null
}

function Get-CostColumnMap {
    # Column names are resolved ONCE per CSV part from its header; per-row access is then direct.
    # A CSV without any recognised cost column is a hard error, never "zero cost".
    param($SampleRow)
    $Names = @($SampleRow.PSObject.Properties.Name)
    $Map = @{
        ResourceId    = Find-CsvColumn $Names @('ResourceId', 'InstanceId')
        ResourceName  = Find-CsvColumn $Names @('ResourceName', 'InstanceName')
        ResourceGroup = Find-CsvColumn $Names @('ResourceGroup', 'ResourceGroupName')
        ResourceType  = Find-CsvColumn $Names @('ResourceType')
        Location      = Find-CsvColumn $Names @('ResourceLocation')
        Service       = Find-CsvColumn $Names @('ServiceName', 'MeterCategory', 'ServiceFamily', 'ConsumedService', 'ProductName', 'Product')
        Family        = Find-CsvColumn $Names @('ServiceFamily')
        Currency      = Find-CsvColumn $Names @('BillingCurrency', 'BillingCurrencyCode', 'Currency')
        Cost          = Find-CsvColumn $Names @('CostInBillingCurrency', 'PreTaxCost', 'Cost')
        ChargeType    = Find-CsvColumn $Names @('ChargeType')
        PricingModel  = Find-CsvColumn $Names @('PricingModel')
        Date          = Find-CsvColumn $Names @('Date', 'UsageDate')
        Tags          = Find-CsvColumn $Names @('Tags', 'ResourceTags')
    }
    if (-not $Map.Cost) {
        throw 'The cost-details CSV has no recognised cost column (CostInBillingCurrency / PreTaxCost / Cost). Report aborted to avoid treating unreadable billing data as zero cost.'
    }
    return $Map
}

function Get-DateKey {
    # 'yyyy-MM-dd' for a billing date in any of the formats Azure emits; '' if unparseable. Cached
    # because a month only has ~31 distinct dates.
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    if ($script:DateCache.ContainsKey($Text)) { return $script:DateCache[$Text] }
    $Parsed = [datetime]::MinValue
    $Key = ''
    $Formats = [string[]]@('yyyy-MM-dd', 'MM/dd/yyyy', 'M/d/yyyy', 'yyyy-MM-ddTHH:mm:ss', 'yyyy-MM-ddTHH:mm:ssZ')
    if ([datetime]::TryParseExact($Text.Trim(), $Formats, $Invariant, [System.Globalization.DateTimeStyles]::None, [ref]$Parsed) -or
        [datetime]::TryParse($Text.Trim(), $Invariant, [System.Globalization.DateTimeStyles]::None, [ref]$Parsed)) {
        $Key = $Parsed.ToString('yyyy-MM-dd', $Invariant)
    }
    $script:DateCache[$Text] = $Key
    return $Key
}

function Add-StateAmount {
    param($Target, [string]$State, [decimal]$Amount)
    $Target.Cost += $Amount
    if ($State -eq $StateCurrent) { $Target.Active += $Amount }
    elseif ($State -eq $StateHistorical) { $Target.Historical += $Amount }
    else { $Target.Unmapped += $Amount }
}

function Save-RawChunk {
    # Raw normalised rows are streamed to disk in chunks so enterprise-size months stay memory-lean.
    if ($script:RawChunk.Count -eq 0) { return }
    $script:RawChunk | ForEach-Object { Protect-CsvRow $_ } | Export-Csv -LiteralPath $script:RawCsvPath -NoTypeInformation -Append -Encoding utf8BOM
    $script:RawChunk.Clear()
}

function Import-CostDetailParts {
    <#
        Streams every CSV part of one subscription, classifies each billing line against the live
        inventory at aggregate-creation time, and folds it into per-resource / service / RG / daily
        aggregates. Only aggregates are kept in memory.
    #>
    param([Parameter(Mandatory)]$Subscription, [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Parts)

    $ReportSubscriptionId = ([string]$Subscription.Id).ToLowerInvariant()
    $Rows = 0
    foreach ($Part in $Parts) {
        $Map = $null

        Import-Csv -LiteralPath $Part | ForEach-Object {
            $Row = $_
            if ($null -eq $Map) { $Map = Get-CostColumnMap $Row }
            $Rows++
            $script:Counters.CostRows++

            # ---- read fields (direct property access via the header map) ---------------------------
            $Cost = ConvertTo-InvariantDecimal $Row.($Map.Cost) 'cost value'
            $Currency = ''
            if ($Map.Currency) { $Currency = ([string]$Row.($Map.Currency)).Trim().ToUpperInvariant() }
            if (-not $Currency) {
                if ($Cost -ne 0) {
                    throw "A non-zero cost line for '$($Subscription.Name)' has no billing currency. Report aborted rather than guessing a currency."
                }
                $script:Counters.ZeroCostBlankCurrencyRows++
            }

            $RawId = ''; if ($Map.ResourceId) { $RawId = ([string]$Row.($Map.ResourceId)).Trim() }
            $NormId = ConvertTo-NormalizedResourceId $RawId
            $Name = ''; if ($Map.ResourceName) { $Name = ([string]$Row.($Map.ResourceName)).Trim() }
            $Group = ''; if ($Map.ResourceGroup) { $Group = ([string]$Row.($Map.ResourceGroup)).Trim() }
            $Type = ''; if ($Map.ResourceType) { $Type = ([string]$Row.($Map.ResourceType)).Trim() }
            $Location = ''; if ($Map.Location) { $Location = ([string]$Row.($Map.Location)).Trim() }
            $Service = ''; if ($Map.Service) { $Service = ([string]$Row.($Map.Service)).Trim() }
            $Family = ''; if ($Map.Family) { $Family = ([string]$Row.($Map.Family)).Trim() }
            $ChargeType = ''; if ($Map.ChargeType) { $ChargeType = ([string]$Row.($Map.ChargeType)).Trim() }
            $Pricing = ''; if ($Map.PricingModel) { $Pricing = ([string]$Row.($Map.PricingModel)).Trim() }
            $DateKey = ''; if ($Map.Date) { $DateKey = Get-DateKey ([string]$Row.($Map.Date)) }
            $TagText = ''; if ($Map.Tags) { $TagText = [string]$Row.($Map.Tags) }

            # The resource id is the most reliable source for name / group / type; columns fill gaps.
            if ($NormId) {
                # Derive display values from the ORIGINAL id so casing stays readable (matching is case-insensitive).
                $IdGroup = Get-ResourceGroupFromId $RawId
                $IdType = Get-ResourceTypeFromId $RawId
                $IdName = Get-ResourceNameFromId $RawId
                if (-not $Group) { $Group = $IdGroup }
                if ($IdType) { $Type = $IdType }
                if ($IdName) { $Name = $IdName }
            }
            if (-not $Service) { $Service = '(Unspecified)' }

            if ($DateKey) {
                if ($DateKey -gt $script:MaxDateKey -and $DateKey.StartsWith($MonthKey, [StringComparison]::Ordinal)) { $script:MaxDateKey = $DateKey }
                if (-not $DateKey.StartsWith($MonthKey, [StringComparison]::Ordinal)) { $script:Counters.OutOfMonthRows++ }
            }
            if ($Pricing -match '(?i)reservation|savings\s*plan') { $script:Counters.CommitmentPricedRows++ }

            # ---- aggregate key: one aggregate per resource (+ currency) --------------------------------
            if ($NormId) {
                $AggKey = "$ReportSubscriptionId|$NormId|$Currency"
            }
            elseif ($Name) {
                $AggKey = "$ReportSubscriptionId|noid|$($Group.ToLowerInvariant())|$($Name.ToLowerInvariant())|$Currency"
            }
            else {
                $AggKey = "$ReportSubscriptionId|nores|$($Service.ToLowerInvariant())|$Currency"
            }

            $Agg = $script:ResourceAgg[$AggKey]
            if ($null -eq $Agg) {
                $IdSubscription = ''; if ($NormId) { $IdSubscription = Get-SubscriptionIdFromId $NormId }
                $MatchSubscription = if ($IdSubscription) { $IdSubscription } else { $ReportSubscriptionId }
                $Match = Resolve-LiveResource -SubscriptionId $MatchSubscription -NormalizedId $NormId -ResourceName $Name -ResourceGroup $Group -ResourceType $Type

                $IsArmId = $NormId -and (Test-ArmResourceId $NormId)
                $Verification = ''
                if (-not $Match.Live -and $IsArmId -and $script:AssessedSubIds.ContainsKey($IdSubscription) -and $ChargeType -notin $NonUsageChargeTypes) {
                    # Never trust the listing alone for a "deleted" verdict: look the resource up directly.
                    $Verification = 'Not verified'
                    if ($script:Counters.DeletionChecksRun -lt 100) {
                        $script:Counters.DeletionChecksRun++
                        $Check = Confirm-ResourceMissing -RawId $RawId -SubscriptionId $IdSubscription
                        if ($Check.Status -eq 'Exists') {
                            $Found = New-LiveResourceFromLookup -Item $Check.Resource -SubscriptionName ([string]$Subscription.Name) -SubscriptionId ([string]$Subscription.Id) -FallbackId $RawId
                            if (-not $script:LiveById.ContainsKey($Found.NormId)) {
                                $script:LiveById[$Found.NormId] = $Found
                                $FoundKey = Get-ResourceMatchKey -SubscriptionId $IdSubscription -ResourceGroup $Found.ResourceGroup -ResourceName $Found.ResourceName
                                if (-not $script:LiveByName.ContainsKey($FoundKey)) { $script:LiveByName[$FoundKey] = [System.Collections.Generic.List[object]]::new() }
                                $script:LiveByName[$FoundKey].Add($Found)
                                $script:LiveTypeSet["$IdSubscription|$($Found.ResourceType.ToLowerInvariant())"] = $true
                                $script:ExtraLive.Add($Found)
                            }
                            $Match = [PSCustomObject]@{ Live = $script:LiveById[$Found.NormId]; Method = 'DirectLookup' }
                            $script:Counters.DirectLookupMatches++
                            $Verification = ''
                        }
                        elseif ($Check.Status -eq 'Deleted') { $Verification = 'Confirmed deleted'; $script:Counters.DeletionConfirmed++ }
                        else { $script:Counters.DeletionUnverified++ }
                    }
                    else { $script:Counters.DeletionUnverified++ }
                }
                if ($Match.Live) {
                    $State = $StateCurrent
                    if ($Match.Method -eq 'Sub+RG+Name') { $script:Counters.FallbackMatches++ }
                    if ($Match.Method -eq 'ParentResource') { $script:Counters.ParentMatches++ }
                }
                elseif ($IsArmId -and $script:AssessedSubIds.ContainsKey($IdSubscription) -and $ChargeType -notin $NonUsageChargeTypes) {
                    # Only an ARM-shaped id in an ASSESSED subscription that is absent from live inventory
                    # is asserted to be historical/deleted. Everything else is reported as unmapped.
                    $State = $StateHistorical
                }
                else {
                    $State = $StateUnmapped
                }

                $DisplayName = $Name
                if (-not $DisplayName) { $DisplayName = "(Unmapped charge) $Service" }
                if ($Match.Live -and $Match.Method -ne 'ParentResource') {
                    # Prefer the live resource's own casing for a cleaner report.
                    $DisplayName = $Match.Live.ResourceName
                    $Group = $Match.Live.ResourceGroup
                    $Type = $Match.Live.ResourceType
                    if ($Match.Live.Location) { $Location = $Match.Live.Location }
                }

                $Agg = [PSCustomObject]@{
                    Subscription   = [string]$Subscription.Name
                    SubscriptionId = [string]$Subscription.Id
                    ResourceName   = $DisplayName
                    ResourceGroup  = $Group
                    ResourceType   = $Type
                    Location       = $Location
                    State          = $State
                    MatchMethod    = $Match.Method
                    Live           = $Match.Live
                    Currency       = $Currency
                    Cost           = [decimal]0
                    Rows           = 0
                    Services       = @{}
                    Families       = @{}
                    CsvTags        = [ordered]@{}
                    LastBilled     = ''
                    Verification   = $Verification
                    ResourceId     = $RawId
                }
                $script:ResourceAgg[$AggKey] = $Agg
            }

            $Agg.Cost += $Cost
            $Agg.Rows++
            if ($DateKey -and $Cost -ne 0 -and $DateKey.StartsWith($MonthKey, [StringComparison]::Ordinal) -and $DateKey -gt $Agg.LastBilled) { $Agg.LastBilled = $DateKey }
            if ($TagText -and $Agg.CsvTags.Count -eq 0) { $Agg.CsvTags = ConvertFrom-CostTags $TagText }   # tags as billed (only source for deleted resources)
            $Agg.Services[$Service] = ([decimal]$Agg.Services[$Service]) + $Cost
            if ($Family) { $Agg.Families[$Family] = ([decimal]$Agg.Families[$Family]) + $Cost }

            # ---- service and resource-group roll-ups (state-aware) --------------------------------------
            $ServiceKey = "$ReportSubscriptionId|$($Service.ToLowerInvariant())|$Currency"
            $ServiceEntry = $script:ServiceAgg[$ServiceKey]
            if ($null -eq $ServiceEntry) {
                $ServiceEntry = [PSCustomObject]@{ Subscription = [string]$Subscription.Name; Service = $Service; Currency = $Currency; Cost = [decimal]0; Active = [decimal]0; Historical = [decimal]0; Unmapped = [decimal]0 }
                $script:ServiceAgg[$ServiceKey] = $ServiceEntry
            }
            Add-StateAmount $ServiceEntry $Agg.State $Cost

            $GroupKey = "$ReportSubscriptionId|$($Agg.ResourceGroup.ToLowerInvariant())|$Currency"
            $GroupEntry = $script:ResourceGroupAgg[$GroupKey]
            if ($null -eq $GroupEntry) {
                $GroupLabel = if ($Agg.ResourceGroup) { $Agg.ResourceGroup } else { '(No resource group)' }
                $GroupEntry = [PSCustomObject]@{ Subscription = [string]$Subscription.Name; ResourceGroup = $GroupLabel; Currency = $Currency; Cost = [decimal]0; Active = [decimal]0; Historical = [decimal]0; Unmapped = [decimal]0 }
                $script:ResourceGroupAgg[$GroupKey] = $GroupEntry
            }
            Add-StateAmount $GroupEntry $Agg.State $Cost

            if ($Agg.State -eq $StateCurrent -and $DateKey -and $Currency) {
                $DailyKey = "$Currency|$DateKey"
                $script:DailyActive[$DailyKey] = ([decimal]$script:DailyActive[$DailyKey]) + $Cost
            }

            $script:RawChunk.Add([PSCustomObject]@{
                    Subscription = [string]$Subscription.Name
                    SubscriptionId = [string]$Subscription.Id
                    Date = $DateKey
                    ResourceName = $Agg.ResourceName
                    ResourceGroup = $Agg.ResourceGroup
                    ResourceType = $Agg.ResourceType
                    Service = $Service
                    ServiceFamily = $Family
                    Location = $Location
                    Cost = $Cost
                    Currency = $Currency
                    ChargeType = $ChargeType
                    PricingModel = $Pricing
                    ResourceState = $Agg.State
                    MatchMethod = $Agg.MatchMethod
                    ResourceId = $RawId
                })
            if ($script:RawChunk.Count -ge 5000) { Save-RawChunk }
        }
        Save-RawChunk
    }
    return $Rows
}
#endregion

#region ---------------------------------------------------------------- Analytics: profiles, governance, actions, narrative
function Get-TopKey {
    # Highest-value key of a name->decimal table; ties broken alphabetically so output is deterministic.
    param([hashtable]$Table)
    if ($null -eq $Table -or $Table.Count -eq 0) { return '' }
    $Top = $Table.GetEnumerator() |
        Sort-Object @{ Expression = { [decimal]$_.Value }; Descending = $true }, @{ Expression = { [string]$_.Key } } |
        Select-Object -First 1
    return [string]$Top.Key
}

function Join-Natural {
    param([string[]]$Items)
    $List = @($Items | Where-Object { $_ })
    if ($List.Count -eq 0) { return '' }
    if ($List.Count -eq 1) { return $List[0] }
    if ($List.Count -eq 2) { return "$($List[0]) and $($List[1])" }
    return (($List[0..($List.Count - 2)]) -join ', ') + ', and ' + $List[-1]
}

function Get-DailyStability {
    # Coefficient of variation of daily ACTIVE spend across the observed span (missing days count as 0).
    # Uses the Date column already present in the downloaded cost details - no extra API calls.
    param([string]$Currency)

    $Prefix = "$Currency|"
    $Days = @{}
    foreach ($Key in $script:DailyActive.Keys) {
        if ($Key.StartsWith($Prefix, [StringComparison]::Ordinal)) {
            $Days[$Key.Substring($Prefix.Length)] = [decimal]$script:DailyActive[$Key]
        }
    }
    if ($Days.Count -eq 0) {
        return [PSCustomObject]@{ DaysObserved = 0; Mean = [double]0; CoefficientOfVariation = $null }
    }

    $Dates = @($Days.Keys | Sort-Object)
    $First = [datetime]::ParseExact([string]$Dates[0], 'yyyy-MM-dd', $Invariant)
    $Last = [datetime]::ParseExact([string]$Dates[-1], 'yyyy-MM-dd', $Invariant)
    $Span = ($Last - $First).Days + 1

    $Values = [System.Collections.Generic.List[double]]::new()
    for ($Offset = 0; $Offset -lt $Span; $Offset++) {
        $DayKey = $First.AddDays($Offset).ToString('yyyy-MM-dd', $Invariant)
        if ($Days.ContainsKey($DayKey)) { $Values.Add([double]$Days[$DayKey]) } else { $Values.Add([double]0) }
    }

    $Sum = 0.0
    foreach ($Value in $Values) { $Sum += $Value }
    $Mean = $Sum / $Values.Count
    $SquaredDeviations = 0.0
    foreach ($Value in $Values) { $SquaredDeviations += [math]::Pow($Value - $Mean, 2) }
    $StandardDeviation = [math]::Sqrt($SquaredDeviations / $Values.Count)

    $Variation = $null
    if ($Mean -gt 0) { $Variation = [math]::Round($StandardDeviation / $Mean, 3) }
    return [PSCustomObject]@{ DaysObserved = $Span; Mean = $Mean; CoefficientOfVariation = $Variation }
}

function New-CurrencyProfile {
    <#
        Everything the executive summary says about ONE billing currency. Nothing here ever combines
        currencies. Percentages are null (shown as n/a) when the currency's total is not positive.
    #>
    param(
        [Parameter(Mandatory)][string]$Currency,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$ResourceCosts,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$ServiceTotals,
        [string]$DataThroughKey
    )

    $Rows = @($ResourceCosts | Where-Object { $_.Currency -eq $Currency })
    $CurrentRows = @($Rows | Where-Object { $_.ResourceState -eq $StateCurrent })
    $HistoricalRows = @($Rows | Where-Object { $_.ResourceState -eq $StateHistorical })
    $UnmappedRows = @($Rows | Where-Object { $_.ResourceState -eq $StateUnmapped })

    $Total = Get-DecimalSum $Rows 'Cost'
    $Active = Get-DecimalSum $CurrentRows 'Cost'
    $Historical = Get-DecimalSum $HistoricalRows 'Cost'
    $Unmapped = Get-DecimalSum $UnmappedRows 'Cost'

    $ActivePct = Get-Percent $Active $Total
    $HistoricalPct = Get-Percent $Historical $Total
    $UnmappedPct = Get-Percent $Unmapped $Total

    # Elapsed days follow the last date Azure actually billed (cost data lags), not the wall clock.
    $ElapsedDays = $GeneratedAtUtc.Day
    if ($DataThroughKey) {
        $DataDate = [datetime]::ParseExact($DataThroughKey, 'yyyy-MM-dd', $Invariant)
        $ElapsedDays = ($DataDate.Date - $MonthStart.Date).Days + 1
    }
    $ElapsedDays = [math]::Max(1, [math]::Min($DaysInMonth, $ElapsedDays))

    # ---- Indicative Month-End Run Rate (NOT the Azure Cost Management Forecast) ---------------------
    # Suppressed when deleted resources dominate the baseline. Otherwise: ACTIVE spend is extrapolated
    # linearly; historical/deleted and unmapped charges are held at their MTD amount (deleted resources
    # cannot accrue more; extrapolating them would overstate the run rate).
    $RunRate = $null
    $RunRateNote = ''
    if ($Total -le 0) {
        $RunRateNote = 'Not calculated because no net month-to-date cost was recorded.'
    }
    elseif ($HistoricalPct -ge $HistoricalSuppressionThresholdPct) {
        $RunRateNote = "Not calculated because historical/deleted resources represent $(Format-Percent $HistoricalPct) of month-to-date spend."
    }
    elseif ($Active -le 0) {
        $RunRateNote = 'Not calculated because no active-resource spend was recorded month to date.'
    }
    else {
        $RunRate = [math]::Round(($Active * $DaysInMonth / $ElapsedDays) + $Historical + $Unmapped, 4)
        $RunRateNote = "Active spend projected linearly from $ElapsedDays of $DaysInMonth days; historical/deleted and unmapped charges held at month-to-date amounts. Indicative only - not the Azure Cost Management forecast."
    }

    # ---- drivers -------------------------------------------------------------------------------------
    $ByCost = @($Rows | Sort-Object -Property @{ Expression = { [decimal]$_.Cost }; Descending = $true })
    $TopResource = $null
    if ($Total -gt 0 -and $ByCost.Count -gt 0 -and $ByCost[0].Cost -gt 0) { $TopResource = $ByCost[0] }
    $TopCurrent = $ByCost | Where-Object { $_.ResourceState -eq $StateCurrent -and $_.Cost -gt 0 } | Select-Object -First 1
    $TopHistorical = $ByCost | Where-Object { $_.ResourceState -eq $StateHistorical -and $_.Cost -gt 0 } | Select-Object -First 1

    $ServiceRollup = @{}
    foreach ($Entry in @($ServiceTotals | Where-Object { $_.Currency -eq $Currency })) {
        $ServiceRollup[[string]$Entry.Service] = ([decimal]$ServiceRollup[[string]$Entry.Service]) + [decimal]$Entry.Cost
    }
    $TopServiceName = Get-TopKey $ServiceRollup
    $TopServiceCost = if ($TopServiceName) { [decimal]$ServiceRollup[$TopServiceName] } else { [decimal]0 }
    $TopServicePct = if ($TopServiceCost -gt 0) { Get-Percent $TopServiceCost $Total } else { $null }

    $TopResourcePct = $null
    if ($TopResource) { $TopResourcePct = Get-Percent $TopResource.Cost $Total }

    # Spend that sits on fully tagged resources (cost-weighted view of governance readiness).
    $ActiveTaggedCost = [decimal]0
    foreach ($Row in $CurrentRows) { if ($Row.FullyTagged) { $ActiveTaggedCost += [decimal]$Row.Cost } }
    $ActiveTaggedPct = Get-Percent $ActiveTaggedCost $Active

    # ---- commitment guardrail --------------------------------------------------------------------------
    $Stability = Get-DailyStability $Currency
    $MonthlyActive = if ($Active -gt 0) { [math]::Round($Active * $DaysInMonth / $ElapsedDays, 4) } else { [decimal]0 }
    $CommitmentReasons = [System.Collections.Generic.List[string]]::new()
    if ($MonthlyActive -lt [decimal]$CommitmentMinMonthlyActiveSpend) { $CommitmentReasons.Add('Indicative monthly active spend is below the commitment-analysis threshold.') }
    if ($Stability.DaysObserved -lt $CommitmentMinDaysOfData) { $CommitmentReasons.Add('Insufficient days of active-spend history to judge stability.') }
    elseif ($null -eq $Stability.CoefficientOfVariation -or $Stability.CoefficientOfVariation -gt $CommitmentMaxDailyVariation) { $CommitmentReasons.Add('Daily active spend is not stable enough to justify a commitment.') }
    $CommitmentEligible = ($CommitmentReasons.Count -eq 0)

    return [PSCustomObject]@{
        Currency                = $Currency
        Total                   = $Total
        Active                  = $Active
        Historical              = $Historical
        Unmapped                = $Unmapped
        ActivePct               = $ActivePct
        HistoricalPct           = $HistoricalPct
        UnmappedPct             = $UnmappedPct
        ActiveResourceCount     = @($CurrentRows | Where-Object { $_.Cost -ne 0 }).Count
        HistoricalResourceCount = @($HistoricalRows | Where-Object { $_.Cost -ne 0 }).Count
        UnmappedItemCount       = @($UnmappedRows | Where-Object { $_.Cost -ne 0 }).Count
        ElapsedDays             = $ElapsedDays
        RunRate                 = $RunRate
        RunRateNote             = $RunRateNote
        TopResource             = $TopResource
        TopResourcePct          = $TopResourcePct
        TopCurrentResource      = $TopCurrent
        TopHistoricalResource   = $TopHistorical
        TopServiceName          = $TopServiceName
        TopServicePct           = $TopServicePct
        ActiveTaggedPct         = $ActiveTaggedPct
        MonthlyActiveEstimate   = $MonthlyActive
        DaysOfActiveHistory     = $Stability.DaysObserved
        DailyVariation          = $Stability.CoefficientOfVariation
        CommitmentEligible      = $CommitmentEligible
        CommitmentReasons       = @($CommitmentReasons)
    }
}

function Get-GovernanceReadiness {
    param([object[]]$LiveResources, [string[]]$RequiredTagNames)

    $Total = $LiveResources.Count
    $TopLevel = @($LiveResources | Where-Object { $_.IsTopLevel })
    $TagRows = [System.Collections.Generic.List[object]]::new()

    foreach ($TagName in $RequiredTagNames) {
        $Key = Get-TagKey $TagName
        $Tagged = 0
        $TopLevelTagged = 0
        foreach ($Resource in $LiveResources) {
            if ($Resource.TagMap.ContainsKey($Key)) {
                $Tagged++
                if ($Resource.IsTopLevel) { $TopLevelTagged++ }
            }
        }
        $TagRows.Add([PSCustomObject]@{
                Tag                    = $TagName
                Tagged                 = $Tagged
                CoveragePct            = if ($Total -gt 0) { Get-Percent $Tagged $Total } else { $null }
                TopLevelTagged         = $TopLevelTagged
                TopLevelCoveragePct    = if ($TopLevel.Count -gt 0) { Get-Percent $TopLevelTagged $TopLevel.Count } else { $null }
            })
    }

    $FullyTagged = @($LiveResources | Where-Object { $_.FullyTagged }).Count
    $TopLevelFullyTagged = @($TopLevel | Where-Object { $_.FullyTagged }).Count
    $FullyTaggedPct = if ($Total -gt 0) { Get-Percent $FullyTagged $Total } else { $null }
    $TopLevelFullyTaggedPct = if ($TopLevel.Count -gt 0) { Get-Percent $TopLevelFullyTagged $TopLevel.Count } else { $null }

    # Tagging-based indicator only: budgets, policy enforcement and alerting are outside this assessment.
    $Maturity = 'Not assessed'
    $MaturityNote = 'No live resources were inventoried.'
    if ($null -ne $FullyTaggedPct) {
        if ($FullyTaggedPct -lt 25) { $Maturity = 'Foundational' }
        elseif ($FullyTaggedPct -lt 60) { $Maturity = 'Developing' }
        elseif ($FullyTaggedPct -lt 90) { $Maturity = 'Established' }
        else { $Maturity = 'Advanced' }
        $MaturityNote = 'Indicator based on the share of live resources carrying every required tag. Budgets, policy enforcement and anomaly alerting were not assessed.'
    }

    $TagList = Join-Natural $RequiredTagNames
    $HasGap = ($null -ne $FullyTaggedPct -and $FullyTaggedPct -lt 100)
    $Opportunity = if ($Total -eq 0) {
        'Governance readiness could not be measured because no live resources were inventoried.'
    }
    elseif ($HasGap) {
        "Governance opportunity: introduce $TagList tagging standards to improve accountability, showback, and future chargeback readiness."
    }
    else {
        "All live resources carry the required tags ($TagList). Maintain the standard through policy and periodic review."
    }

    return [PSCustomObject]@{
        TotalResources         = $Total
        TopLevelResources      = $TopLevel.Count
        Tags                   = @($TagRows)
        FullyTagged            = $FullyTagged
        FullyTaggedPct         = $FullyTaggedPct
        TopLevelFullyTagged    = $TopLevelFullyTagged
        TopLevelFullyTaggedPct = $TopLevelFullyTaggedPct
        Maturity               = $Maturity
        MaturityNote           = $MaturityNote
        Opportunity            = $Opportunity
        HasGap                 = $HasGap
        RequiredTagNames       = @($RequiredTagNames)
    }
}

function Get-CommitmentStatement {
    # The guardrail: a commitment recommendation exists only for meaningful, stable, recurring ACTIVE spend.
    param([object[]]$Profiles)
    $Eligible = @($Profiles | Where-Object { $_.CommitmentEligible })
    if ($Eligible.Count -eq 0) {
        return 'No commitment recommendation is made at this time because the current active-cost baseline is insufficient for a meaningful commitment analysis.'
    }
    $Detail = @($Eligible | ForEach-Object {
            "$($_.Currency): about $(Format-Money $_.MonthlyActiveEstimate $_.Currency) per month of active spend with a daily variation of $(Format-Number $_.DailyVariation '0.00') over $($_.DaysOfActiveHistory) days"
        }) -join '; '
    return "The active-cost baseline appears recurring and reasonably stable ($Detail). Reservations or Savings Plans may merit evaluation. Commitment utilization and eligible savings were not assessed here and must be validated before any purchase."
}

function New-ExecutiveActions {
    <#
        Prioritised plan: Immediate / Near-Term / Strategic. Every item is driven by assessment data.
        Reservations / Savings Plans are never an Immediate or Near-Term action, and are only advanced
        as a Strategic evaluation when the guardrail in Get-CommitmentStatement passes.
    #>
    param([object[]]$Profiles, $Governance, [int]$UnmappedItems)

    $Actions = [System.Collections.Generic.List[object]]::new()
    function Add-Action { param([string]$Priority, [string]$Action, [string]$Detail) $Actions.Add([PSCustomObject]@{ Priority = $Priority; Action = $Action; Detail = $Detail }) }

    $WithHistory = @($Profiles | Where-Object { $_.HistoricalResourceCount -gt 0 })
    $WithActive = @($Profiles | Where-Object { $_.Active -gt 0 })

    # ---------------- Immediate ----------------
    if ($WithHistory.Count -gt 0) {
        $Lead = $WithHistory | Sort-Object { $_.Historical } -Descending | Select-Object -First 1
        $LeadName = if ($Lead.TopHistoricalResource) { " Start with $($Lead.TopHistoricalResource.ResourceName), the largest historical charge." } else { '' }
        Add-Action 'Immediate' 'Confirm deleted resources have no residual billable dependencies.' "Check for attached or related billable items (for example public IPs, disks, gateways or private endpoints) that may outlive the removed resource.$LeadName"
        Add-Action 'Immediate' 'Verify historical charges do not recur in the next billing period.' 'Re-run this assessment after the next billing cycle and confirm the historical/deleted lines no longer accrue new cost.'
    }
    if ($UnmappedItems -gt 0) {
        Add-Action 'Immediate' 'Review unmapped charges with the billing owner.' 'These lines cannot be tied to a live or historical resource (typically purchases, marketplace, support or adjustments) and need an accountable owner.'
    }
    if ($WithActive.Count -gt 0) {
        $Names = @($WithActive | ForEach-Object { if ($_.TopCurrentResource) { $_.TopCurrentResource.ResourceName } } | Select-Object -First 2)
        $Lead = if ($Names.Count -gt 0) { " Start with $(Join-Natural $Names)." } else { '' }
        Add-Action 'Immediate' 'Validate business need, sizing and pricing model of the largest active cost drivers.' "Confirm the highest-cost active resources are intended and right-sized.$Lead"
    }
    if (@($Actions | Where-Object { $_.Priority -eq 'Immediate' }).Count -eq 0) {
        Add-Action 'Immediate' 'No urgent cost action was identified.' 'Maintain the current review cadence and re-run the assessment monthly.'
    }

    # ---------------- Near-Term ----------------
    if ($Governance.HasGap) {
        Add-Action 'Near-Term' "Improve $(Join-Natural $Governance.RequiredTagNames) tagging." 'Define the standard, backfill existing resources and enforce it for new deployments (for example with Azure Policy) so spend can be attributed.'
    }
    Add-Action 'Near-Term' 'Establish baseline cost ownership.' 'Assign an accountable owner to each subscription and resource group so every material cost line has a named owner.'
    Add-Action 'Near-Term' 'Define budgets and alert thresholds where appropriate.' 'Budget configuration was not assessed here. Set thresholds proportionate to the size and volatility of each subscription.'

    # ---------------- Strategic ----------------
    $Commitment = Get-CommitmentStatement $Profiles
    Add-Action 'Strategic' 'Evaluate commitment discounts only when stable active spend justifies them.' $Commitment
    Add-Action 'Strategic' 'Move from showback to chargeback as tagging coverage matures.' 'Use CostCenter and Owner data to report cost to the teams that drive it, then decide with Finance whether to recharge it.'
    Add-Action 'Strategic' 'Embed cost governance in platform engineering and landing-zone standards.' 'Make required tags, budgets and cost-visibility defaults part of subscription and workload provisioning.'

    return @($Actions)
}

function New-CurrencyHeadline {
    param($CurrencyProfile, $Governance)

    $Currency = $CurrencyProfile.Currency
    $TotalText = Format-Money $CurrencyProfile.Total $Currency
    if ($CurrencyProfile.Total -le 0) {
        return "No net billable Azure spend has been recorded month to date in $Currency. The focus is keeping it that way and strengthening cost-accountability tagging."
    }

    $Position = if ($CurrencyProfile.Total -le [decimal]$LowSpendThreshold) { "Azure cost position is currently low. Verified month-to-date spend is $TotalText" } else { "Verified Azure month-to-date spend is $TotalText" }

    $DriverPhrase = ''
    if ($CurrencyProfile.TopHistoricalResource) {
        $Family = [string]$CurrencyProfile.TopHistoricalResource.PrimaryServiceFamily
        if ($Family) { $DriverPhrase = $Family.ToLowerInvariant() + ' ' }
        elseif ($CurrencyProfile.TopHistoricalResource.PrimaryService) { $DriverPhrase = ([string]$CurrencyProfile.TopHistoricalResource.PrimaryService).ToLowerInvariant() + ' ' }
    }

    $Composition = ''
    if ($CurrencyProfile.HistoricalPct -ge 95) {
        $Composition = ", with essentially all recorded cost attributable to ${DriverPhrase}resources that are no longer deployed"
    }
    elseif ($CurrencyProfile.HistoricalPct -ge $HistoricalSuppressionThresholdPct) {
        $Composition = ", with $(Format-Percent $CurrencyProfile.HistoricalPct) of recorded cost attributable to ${DriverPhrase}resources that are no longer deployed"
    }
    elseif ($CurrencyProfile.Historical -gt 0) {
        $Composition = ", of which $(Format-Money $CurrencyProfile.Historical $Currency) ($(Format-Percent $CurrencyProfile.HistoricalPct)) relates to resources that are no longer deployed and $(Format-Money $CurrencyProfile.Active $Currency) ($(Format-Percent $CurrencyProfile.ActivePct)) comes from active resources"
    }
    elseif ($CurrencyProfile.UnmappedPct -ge 95) {
        $Composition = ', with essentially all recorded cost relating to charges that cannot be tied to a specific resource'
    }
    else {
        $Composition = ', all attributable to active resources'
        if ($CurrencyProfile.TopServiceName) { $Composition += "; the largest cost category is $($CurrencyProfile.TopServiceName)" }
    }
    if ($CurrencyProfile.UnmappedPct -ge 10 -and $CurrencyProfile.UnmappedPct -lt 95) {
        $Composition += "; $(Format-Percent $CurrencyProfile.UnmappedPct) cannot be tied to a specific resource"
    }

    $Tagging = if ($Governance.HasGap) { ' and strengthening cost-accountability tagging' } else { '' }
    $Focus = if ($CurrencyProfile.Historical -gt 0) {
        "The immediate focus is confirming these charges do not recur$Tagging."
    }
    elseif ($CurrencyProfile.Active -gt 0) {
        "The immediate focus is validating the largest active cost drivers$Tagging."
    }
    else {
        "The immediate focus is reviewing the unmapped charges$Tagging."
    }

    return "$Position$Composition. $Focus"
}

function New-ExecutiveHeadline {
    param([object[]]$Profiles, $Governance, [int]$LiveResourceCount, [int]$SubscriptionCount)

    if ($Profiles.Count -eq 0) {
        return [PSCustomObject]@{
            Headline = "No month-to-date Azure cost was recorded across $SubscriptionCount enabled subscription(s). $LiveResourceCount live resource(s) were inventoried, so the focus is confirming that zero-cost is expected and establishing cost-accountability tagging."
            PerCurrency = @()
        }
    }
    if ($Profiles.Count -eq 1) {
        return [PSCustomObject]@{ Headline = (New-CurrencyHeadline $Profiles[0] $Governance); PerCurrency = @() }
    }

    $Codes = Join-Natural @($Profiles | ForEach-Object { $_.Currency })
    return [PSCustomObject]@{
        Headline    = "Azure spend was recorded in multiple billing currencies ($Codes). Totals are reported separately by currency and no conversion is performed without an approved FX policy."
        PerCurrency = @($Profiles | ForEach-Object { [PSCustomObject]@{ Currency = $_.Currency; Text = (New-CurrencyHeadline $_ $Governance) } })
    }
}

function Get-KeyConsideration {
    # One plain-English "what should leadership pay attention to" statement per currency.
    param($CurrencyProfile, $Governance)
    $Currency = $CurrencyProfile.Currency

    $Stopped = ''
    $TopHist = $CurrencyProfile.TopHistoricalResource
    if ($TopHist -and $TopHist.LastBilled -and $script:MaxDateKey) {
        $Gap = ([datetime]::ParseExact($script:MaxDateKey, 'yyyy-MM-dd', $Invariant) - [datetime]::ParseExact([string]$TopHist.LastBilled, 'yyyy-MM-dd', $Invariant)).Days
        $Name = $TopHist.ResourceName
        $Proof = if ($TopHist.Verification -eq 'Confirmed deleted') { "For $Name, the largest of them, Azure confirmed by direct lookup that the resource no longer exists" } else { "$Name, the largest of them, was absent from the live inventory but a direct lookup could not confirm the deletion" }
        if ($Gap -ge 1) { $Stopped = " $Proof; its last charge was dated $($TopHist.LastBilled), $Gap day(s) before the latest billing data, so the cost appears to have stopped." }
        else { $Stopped = " $Proof; its last charge is dated $($TopHist.LastBilled), the latest billing date. That is consistent with removal today or very recently (the latest day is partial), so re-check tomorrow that no new charge appears." }
    }
    if ($CurrencyProfile.HistoricalPct -ge $HistoricalSuppressionThresholdPct) {
        return "Historical/deleted resources represent $(Format-Percent $CurrencyProfile.HistoricalPct) of month-to-date spend ($(Format-Money $CurrencyProfile.Historical $Currency)). Because those resources are no longer deployed the cost is expected to stop; confirm it does not recur in the next billing period.$Stopped"
    }
    if ($CurrencyProfile.Historical -gt 0) {
        return "$(Format-Percent $CurrencyProfile.HistoricalPct) of month-to-date spend ($(Format-Money $CurrencyProfile.Historical $Currency)) relates to resources that are no longer deployed. Review these lines for expected versus avoidable spend."
    }
    if ($CurrencyProfile.UnmappedPct -ge 10) {
        return "$(Format-Percent $CurrencyProfile.UnmappedPct) of month-to-date spend ($(Format-Money $CurrencyProfile.Unmapped $Currency)) cannot be tied to a specific resource (for example purchases, marketplace, support or adjustments) and needs an accountable owner."
    }
    if ($CurrencyProfile.TopResourcePct -ge 70) {
        return "Spend is concentrated: the largest resource represents $(Format-Percent $CurrencyProfile.TopResourcePct) of month-to-date spend, so its sizing and pricing model deserve attention first."
    }
    if ($Governance.HasGap) { return $Governance.Opportunity }
    return 'No material cost-governance concern was identified from the data available in this assessment.'
}

function Get-OptimizationFocus {
    param($CurrencyProfile)
    if ($CurrencyProfile.Historical -gt 0) {
        return 'Review historical/deleted charges first, then assess the highest-cost active workloads for right-sizing and pricing-model opportunities once active spend is material.'
    }
    if ($CurrencyProfile.TopServiceName) {
        return "Prioritize the $($CurrencyProfile.TopServiceName) service category for cost-efficiency review because it is the largest cost driver."
    }
    return 'Continue monitoring spend and revisit optimization as workload patterns emerge.'
}
#endregion

#region ---------------------------------------------------------------- HTML rendering helpers
$script:Html = [System.Text.StringBuilder]::new(262144)

function Add-Html {
    param([string]$Text)
    [void]$script:Html.AppendLine($Text)
}

function Get-StateClass {
    # Maps a state OR a zero-cost category to one of three visual classes.
    param([string]$Value)
    if ($Value.StartsWith('Current', [StringComparison]::OrdinalIgnoreCase)) { return 'current' }
    if ($Value.StartsWith('Historical', [StringComparison]::OrdinalIgnoreCase)) { return 'historical' }
    return 'unmapped'
}

function Get-PillHtml {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    $Class = Get-StateClass $Value
    return "<span class=`"pill $Class`">$(ConvertTo-HtmlText $Value)</span>"
}

function New-KpiCardHtml {
    param([string]$Label, [string]$Value, [string]$Sub = '', [string]$Tone = '')
    $ToneClass = if ($Tone) { " $Tone" } else { '' }
    $SubHtml = if ($Sub) { "<div class=`"kpi-sub`">$(ConvertTo-HtmlText $Sub)</div>" } else { '' }
    return "<div class=`"kpi$ToneClass`"><div class=`"kpi-label`">$(ConvertTo-HtmlText $Label)</div><div class=`"kpi-value`">$(ConvertTo-HtmlText $Value)</div>$SubHtml</div>"
}

function ConvertTo-HtmlTable {
    <#
        Renders rows as a real table with one <th> per column (the v6.2 output concatenated headers).
        Column definition: @{ Header = 'Text'; Property = 'Name'; Type = 'text|money|number|pct|state' }
        money / number / pct are right-aligned; state renders a colour pill.
    #>
    param(
        [object[]]$Rows,
        [Parameter(Mandatory)][object[]]$Columns,
        [string]$EmptyMessage = 'No records to display.'
    )

    $RowList = @($Rows)
    if ($RowList.Count -eq 0) {
        return "<p class=`"muted`">$(ConvertTo-HtmlText $EmptyMessage)</p>"
    }

    $Sb = [System.Text.StringBuilder]::new()
    [void]$Sb.Append('<div class="table-wrap"><table><thead><tr>')
    foreach ($Column in $Columns) {
        $Align = if ($Column.Type -in @('money', 'number', 'pct', 'numtext')) { ' class="num"' } else { '' }
        [void]$Sb.Append("<th$Align>$(ConvertTo-HtmlText $Column.Header)</th>")
    }
    [void]$Sb.Append('</tr></thead><tbody>')

    foreach ($Row in $RowList) {
        $StateValue = [string](Get-Prop $Row 'ResourceState' (Get-Prop $Row 'State' ''))
        $RowClass = if ($StateValue) { " class=`"row-$(Get-StateClass $StateValue)`"" } else { '' }
        [void]$Sb.Append("<tr$RowClass>")
        foreach ($Column in $Columns) {
            $Value = Get-Prop $Row $Column.Property $null
            switch ($Column.Type) {
                'money' { [void]$Sb.Append("<td class=`"num`">$(ConvertTo-HtmlText (Format-Amount $Value))</td>") }
                'number' { [void]$Sb.Append("<td class=`"num`">$(ConvertTo-HtmlText (Format-Number $(if ($null -eq $Value) { 0 } else { $Value }) '#,##0'))</td>") }
                'numtext' { [void]$Sb.Append("<td class=`"num`">$(ConvertTo-HtmlText ([string]$Value))</td>") }
                'pct' { [void]$Sb.Append("<td class=`"num`">$(ConvertTo-HtmlText (Format-Percent $Value))</td>") }
                'state' { [void]$Sb.Append("<td>$(Get-PillHtml ([string]$Value))</td>") }
                default {
                    $Text = [string]$Value
                    if ([string]::IsNullOrEmpty($Text)) { $Text = [string][char]0x2014 }
                    [void]$Sb.Append("<td>$(ConvertTo-HtmlText $Text)</td>")
                }
            }
        }
        [void]$Sb.Append('</tr>')
    }
    [void]$Sb.Append('</tbody></table></div>')
    return $Sb.ToString()
}

function Get-ReportCss {
    # Single-quoted here-string: CSS braces and $ are never interpreted by PowerShell.
    return @'
:root { --bg:#f4f6f9; --panel:#ffffff; --ink:#1b2733; --muted:#5f6f7f; --line:#dde3ea; --navy:#12324f; --navy2:#1d4a73;
  --current:#1f7a4d; --current-bg:#e6f4ec; --hist:#9a6a00; --hist-bg:#fff3d6; --unm:#4a5a6a; --unm-bg:#e8edf2;
  --ok:#1f7a4d; --warn:#9a6a00; --accent:#1d4a73; }
* { box-sizing:border-box; }
body { margin:0; background:var(--bg); color:var(--ink); font-family:"Segoe UI",-apple-system,BlinkMacSystemFont,Roboto,Helvetica,Arial,sans-serif; font-size:14px; line-height:1.5; }
.wrap { max-width:1180px; margin:0 auto; padding:0 20px 48px; }
header.top { background:linear-gradient(135deg,var(--navy),var(--navy2)); color:#fff; padding:28px 0 22px; }
header.top .wrap { padding-bottom:0; }
header.top h1 { margin:0 0 4px; font-size:26px; font-weight:600; letter-spacing:.2px; }
header.top .sub { opacity:.9; font-size:14px; }
header.top .meta { margin-top:10px; display:flex; flex-wrap:wrap; gap:6px 22px; font-size:12.5px; opacity:.85; }
.badges { display:flex; flex-wrap:wrap; gap:8px; margin:16px 0 0; }
.badge { display:inline-flex; align-items:center; gap:7px; background:#fff; border:1px solid var(--line); border-radius:999px; padding:5px 12px; font-size:12.5px; color:var(--ink); }
.badge .dot { width:9px; height:9px; border-radius:50%; background:var(--ok); }
.badge.warn .dot { background:var(--warn); }
.badge b { font-weight:600; }
.badge .val { color:var(--muted); }
section { margin-top:26px; }
h2 { font-size:17px; margin:0 0 10px; color:var(--navy); font-weight:600; }
h3 { font-size:14.5px; margin:16px 0 6px; color:var(--navy); font-weight:600; }
.panel { background:var(--panel); border:1px solid var(--line); border-radius:10px; padding:18px 20px; }
.headline { border-left:5px solid var(--navy2); font-size:17px; line-height:1.55; }
.headline p { margin:0 0 8px; } .headline p:last-child { margin-bottom:0; }
.cur-title { font-size:12.5px; text-transform:uppercase; letter-spacing:.6px; color:var(--muted); margin:18px 0 8px; font-weight:600; }
.kpis { display:grid; grid-template-columns:repeat(auto-fit,minmax(170px,1fr)); gap:12px; }
.kpi { background:var(--panel); border:1px solid var(--line); border-radius:10px; padding:14px 16px; }
.kpi-label { font-size:11.5px; text-transform:uppercase; letter-spacing:.5px; color:var(--muted); }
.kpi-value { font-size:22px; font-weight:600; margin-top:4px; word-break:break-word; }
.kpi-sub { font-size:12px; color:var(--muted); margin-top:2px; }
.kpi.current { border-top:3px solid var(--current); } .kpi.historical { border-top:3px solid #d99a00; } .kpi.unmapped { border-top:3px solid var(--unm); } .kpi.neutral { border-top:3px solid var(--navy2); }
.kpi-value.small { font-size:17px; }
.bar { display:flex; height:16px; border-radius:8px; overflow:hidden; background:var(--unm-bg); margin:12px 0 6px; }
.bar span { display:block; height:100%; }
.bar .b-current { background:var(--current); } .bar .b-historical { background:#d99a00; } .bar .b-unmapped { background:#8fa0b1; }
.legend { display:flex; flex-wrap:wrap; gap:6px 18px; font-size:12.5px; color:var(--muted); }
.legend i { display:inline-block; width:10px; height:10px; border-radius:2px; margin-right:6px; vertical-align:middle; }
.note { font-size:12.5px; color:var(--muted); margin:8px 0 0; }
.muted { color:var(--muted); }
.grid2 { display:grid; grid-template-columns:repeat(auto-fit,minmax(340px,1fr)); gap:14px; }
.grid3 { display:grid; grid-template-columns:repeat(auto-fit,minmax(300px,1fr)); gap:14px; }
.callout { background:#f0f5fa; border:1px solid #cfdcea; border-radius:10px; padding:14px 18px; }
.callout .k { font-size:11.5px; text-transform:uppercase; letter-spacing:.5px; color:var(--muted); margin-bottom:4px; }
.callout p { margin:0; }
.action-card { background:var(--panel); border:1px solid var(--line); border-top:4px solid var(--navy2); border-radius:10px; padding:14px 18px; }
.action-card.immediate { border-top-color:#c0392b; } .action-card.near { border-top-color:#d99a00; } .action-card.strategic { border-top-color:var(--current); }
.action-card h3 { margin:0 0 8px; }
.action-card ul { margin:0; padding-left:18px; } .action-card li { margin-bottom:10px; }
.action-card li span { display:block; color:var(--muted); font-size:12.5px; }
.na { background:#f8fafc; border:1px dashed #b9c4d0; border-radius:10px; padding:12px 16px; }
.na b { display:block; font-size:13px; } .na span { color:var(--muted); font-size:12.5px; }
.table-wrap { overflow-x:auto; background:var(--panel); border:1px solid var(--line); border-radius:10px; }
table { border-collapse:collapse; width:100%; font-size:13px; }
thead th { background:#eef2f6; color:var(--navy); text-align:left; font-weight:600; padding:9px 12px; border-bottom:1px solid var(--line); white-space:nowrap; }
tbody td { padding:8px 12px; border-bottom:1px solid #edf1f5; vertical-align:top; }
tbody tr:nth-child(even) { background:#fafbfd; } tbody tr:hover { background:#f0f5fa; }
th.num, td.num { text-align:right; font-variant-numeric:tabular-nums; white-space:nowrap; }
tr.row-current td:first-child { box-shadow:inset 3px 0 0 var(--current); }
tr.row-historical td:first-child { box-shadow:inset 3px 0 0 #d99a00; }
tr.row-unmapped td:first-child { box-shadow:inset 3px 0 0 #8fa0b1; }
.pill { display:inline-block; padding:2px 9px; border-radius:999px; font-size:11.5px; font-weight:600; white-space:nowrap; }
.pill.current { background:var(--current-bg); color:var(--current); } .pill.historical { background:var(--hist-bg); color:var(--hist); } .pill.unmapped { background:var(--unm-bg); color:var(--unm); }
.detail-note { font-size:12.5px; color:var(--muted); margin:6px 2px 0; }
details.appendix { background:var(--panel); border:1px solid var(--line); border-radius:10px; padding:4px 18px 12px; margin-top:12px; }
details.appendix summary { cursor:pointer; font-weight:600; color:var(--navy); padding:10px 0; }
details.appendix ul { margin:6px 0 0; padding-left:18px; } details.appendix li { margin-bottom:5px; }
footer { margin-top:34px; font-size:12px; color:var(--muted); border-top:1px solid var(--line); padding-top:12px; }
.nav { display:flex; flex-wrap:wrap; gap:6px 16px; margin:14px 0 0; font-size:13px; }
.nav a { color:var(--accent); text-decoration:none; border-bottom:1px solid transparent; } .nav a:hover { border-bottom-color:var(--accent); }
.guide { display:grid; grid-template-columns:repeat(auto-fit,minmax(260px,1fr)); gap:10px; margin-top:12px; font-size:12.5px; color:var(--muted); }
.guide div { background:var(--panel); border:1px solid var(--line); border-radius:8px; padding:8px 12px; }
.drivers { padding:8px 20px; }
.drv { display:grid; grid-template-columns:minmax(160px,2fr) 3fr minmax(120px,1.2fr); gap:14px; align-items:center; padding:9px 0; border-bottom:1px solid #edf1f5; }
.drv:last-child { border-bottom:none; }
.drv-name { font-weight:600; } .drv-sub { font-size:12px; color:var(--muted); font-weight:400; }
.drv-bar { background:var(--unm-bg); border-radius:6px; height:12px; overflow:hidden; } .drv-bar span { display:block; height:100%; }
.drv-bar .current { background:var(--current); } .drv-bar .historical { background:#d99a00; } .drv-bar .unmapped { background:#8fa0b1; }
.drv-val { text-align:right; font-variant-numeric:tabular-nums; font-weight:600; }
@media (max-width:640px) { .drv { grid-template-columns:1fr; gap:4px; } .drv-val { text-align:left; } }
header.top .wrap { position:relative; }
.btn-pdf { position:absolute; top:0; right:20px; background:#fff; color:var(--navy); border:0; border-radius:8px; padding:9px 16px; font:600 13px "Segoe UI",Arial,sans-serif; cursor:pointer; box-shadow:0 1px 3px rgba(0,0,0,.25); }
.btn-pdf:hover { background:#eef2f6; }
@page { size:A4; margin:12mm; }
@media print { * { -webkit-print-color-adjust:exact !important; print-color-adjust:exact !important; }
  .nav, .btn-pdf { display:none !important; } body { font-size:11.5px; } tr, .kpi, .callout, .action-card, .panel, .na, .drv { break-inside:avoid; } h2, h3 { break-after:avoid; } thead { display:table-header-group; } .wrap { max-width:none; padding:0 4px; }
  .table-wrap { overflow:visible !important; } table { width:100%; table-layout:auto; font-size:10px; }
  th { white-space:normal !important; overflow-wrap:normal; word-break:normal; hyphens:none; padding:4px 5px !important; } td { white-space:normal !important; overflow-wrap:break-word; padding:4px 5px !important; } td.num, th.num { white-space:nowrap !important; }
  .kpis { grid-template-columns:repeat(3,1fr) !important; } .grid2 { grid-template-columns:repeat(2,1fr) !important; } .grid3 { grid-template-columns:repeat(3,1fr) !important; } .drv { grid-template-columns:2fr 3fr 1.2fr !important; } }
@media (max-width:640px) { header.top h1 { font-size:21px; } .kpi-value { font-size:19px; } .headline { font-size:15.5px; } }
@media print { body { background:#fff; } header.top { background:#12324f !important; -webkit-print-color-adjust:exact; print-color-adjust:exact; } .table-wrap { overflow:visible; } details.appendix { display:block; }}
'@
}
#endregion

#region ---------------------------------------------------------------- Main: collection and reconciliation
function Invoke-FinOpsAssessment {
    Write-Banner "AZURE FINOPS EXECUTIVE ASSESSMENT v$ScriptVersion  |  asynchronous Cost Details mode"

    # ---- 1. identity and tenant ------------------------------------------------------------------------
    $Account = Invoke-AzCli -Arguments @('account', 'show', '-o', 'json', '--only-show-errors')
    if ($Account.ExitCode -ne 0 -or -not $Account.Output) { throw "Azure CLI is not authenticated. Run 'az login' first." }
    $CurrentAccount = $Account.Output | ConvertFrom-Json
    $TenantId = [string](Get-Prop $CurrentAccount 'tenantId')
    if (-not $TenantId) { throw 'Unable to determine the current Azure tenant.' }

    # Tenant display name / default domain are cosmetic. Failure here never blocks the assessment.
    $TenantDisplayName = ''
    $TenantDomain = ''
    try {
        $Org = Invoke-AzCli -Arguments @('rest', '--method', 'get', '--url', 'https://graph.microsoft.com/v1.0/organization?$select=id,displayName,verifiedDomains', '-o', 'json', '--only-show-errors')
        if ($Org.ExitCode -eq 0 -and $Org.Output) {
            $OrgItem = @((Get-Prop ($Org.Output | ConvertFrom-Json) 'value' @())) | Select-Object -First 1
            if ($OrgItem) {
                $TenantDisplayName = [string](Get-Prop $OrgItem 'displayName' '')
                $Domains = @(Get-Prop $OrgItem 'verifiedDomains' @())
                $Default = $Domains | Where-Object { (Get-Prop $_ 'isDefault' $false) -eq $true } | Select-Object -First 1
                if (-not $Default) { $Default = $Domains | Where-Object { (Get-Prop $_ 'isInitial' $false) -eq $true } | Select-Object -First 1 }
                if ($Default) { $TenantDomain = [string](Get-Prop $Default 'name' '') }
            }
        }
    }
    catch { Write-Note 'Tenant display name could not be resolved (cosmetic only).' }

    if (-not $TenantDisplayName) { $TenantDisplayName = 'Azure tenant' }
    if (-not $script:CompanyName) { $script:CompanyName = $TenantDisplayName }

    $SafeCompany = Get-SafeName $script:CompanyName
    $ReportDir = Join-Path $OutputRoot "$SafeCompany-Azure-FinOps-Assessment-$Stamp"
    $CacheRoot = Join-Path $OutputRoot '.Azure-FinOps-CostDetails-Cache'
    New-Item -ItemType Directory -Path $ReportDir -Force | Out-Null
    New-Item -ItemType Directory -Path $CacheRoot -Force | Out-Null
    $script:RawCsvPath = Join-Path $ReportDir '09-Raw-Cost-Details-Normalized.csv'

    # ---- 2. enumerate ENABLED subscriptions in this tenant --------------------------------------------------
    $List = Invoke-AzCli -Arguments @('account', 'list', '--all', '--refresh', '--output', 'json', '--only-show-errors')
    if ($List.ExitCode -ne 0) { $List = Invoke-AzCli -Arguments @('account', 'list', '--all', '--output', 'json', '--only-show-errors') }
    if ($List.ExitCode -ne 0) { throw 'Unable to enumerate Azure subscriptions.' }

    $AllInTenant = @(ConvertFrom-JsonArray $List.Output | Where-Object { [string](Get-Prop $_ 'tenantId' '') -ieq $TenantId })
    $Subscriptions = @($AllInTenant |
            Where-Object { [string](Get-Prop $_ 'state' '') -ieq 'Enabled' } |
            ForEach-Object { [PSCustomObject]@{ Name = [string](Get-Prop $_ 'name' ''); Id = ([string](Get-Prop $_ 'id' '')).ToLowerInvariant() } } |
            Sort-Object Name)
    $NotEnabledCount = $AllInTenant.Count - $Subscriptions.Count
    if ($Subscriptions.Count -eq 0) { throw 'No enabled subscriptions were found in the current tenant.' }

    Write-Host "Company / Tenant : $($script:CompanyName)" -ForegroundColor Green
    Write-Host "Tenant           : $TenantDisplayName $(if ($TenantDomain) { "($TenantDomain)" })"
    Write-Host "Subscriptions    : $($Subscriptions.Count) enabled"
    if ($NotEnabledCount -gt 0) { Write-Note "Not in scope    : $NotEnabledCount subscription(s) in this tenant are not in the Enabled state." }

    # ---- 3. PHASE 1 - live ARM inventory for EVERY subscription, before any billing data is classified ----------
    # Doing all inventories first means (a) an inventory failure aborts before slow cost reports are requested
    # and (b) a billing line whose resource lives in another subscription can still be matched.
    Write-Banner 'Phase 1 of 2 - live resource inventory (Azure Resource Manager)'
    $LiveList = [System.Collections.Generic.List[object]]::new()
    $SubStatus = [System.Collections.Generic.List[object]]::new()
    $RequiredTagKeys = @($RequiredTags | ForEach-Object { Get-TagKey $_ } | Where-Object { $_ })

    foreach ($Sub in $Subscriptions) {
        $Inventory = $null
        for ($Attempt = 1; $Attempt -le 2 -and $null -eq $Inventory; $Attempt++) {
            $Result = Invoke-AzCli -Arguments @('resource', 'list', '--subscription', $Sub.Id, '--query', '[].{name:name,resourceGroup:resourceGroup,type:type,location:location,id:id,tags:tags}', '-o', 'json', '--only-show-errors')
            if ($Result.ExitCode -eq 0) { $Inventory = @(ConvertFrom-JsonArray $Result.Output) }
            elseif ($Attempt -lt 2) { Start-Sleep -Seconds 5 }
            else {
                $Reason = if ($Result.Error) { " Azure CLI said: $($Result.Error)" } else { '' }
                throw "Unable to retrieve the current Azure resource inventory for subscription '$($Sub.Name)'. The report was aborted rather than risk classifying active resources as historical.$Reason"
            }
        }

        $Added = 0
        foreach ($Item in $Inventory) {
            $RawId = [string](Get-Prop $Item 'id' '')
            $NormId = ConvertTo-NormalizedResourceId $RawId
            if (-not $NormId) { continue }
            if ($script:LiveById.ContainsKey($NormId)) { continue }   # duplicate listing of the same resource

            $Type = [string](Get-Prop $Item 'type' '')
            if (-not $Type) { $Type = Get-ResourceTypeFromId $NormId }
            $Name = [string](Get-Prop $Item 'name' '')
            if (-not $Name) { $Name = Get-ResourceNameFromId $NormId }
            $Group = [string](Get-Prop $Item 'resourceGroup' '')
            if (-not $Group) { $Group = Get-ResourceGroupFromId $NormId }
            $IdSubscription = Get-SubscriptionIdFromId $NormId
            if (-not $IdSubscription) { $IdSubscription = $Sub.Id }

            $TagMap = ConvertTo-TagMap (Get-Prop $Item 'tags' $null)
            $Missing = @($RequiredTagKeys | Where-Object { -not $TagMap.ContainsKey($_) })

            $Live = [PSCustomObject]@{
                Subscription   = $Sub.Name
                SubscriptionId = $Sub.Id
                ResourceName   = $Name
                ResourceGroup  = $Group
                ResourceType   = $Type
                Location       = [string](Get-Prop $Item 'location' '')
                ResourceId     = $RawId
                NormId         = $NormId
                TagMap         = $TagMap
                TagsRaw        = (ConvertTo-TagPairs (Get-Prop $Item 'tags' $null))
                FullyTagged    = ($RequiredTagKeys.Count -gt 0 -and $Missing.Count -eq 0)
                IsTopLevel     = (@($Type -split '/').Count -le 2)   # ns/type only; child types excluded
            }
            $LiveList.Add($Live)
            $script:LiveById[$NormId] = $Live
            $NameKey = Get-ResourceMatchKey -SubscriptionId $IdSubscription -ResourceGroup $Group -ResourceName $Name
            if (-not $script:LiveByName.ContainsKey($NameKey)) { $script:LiveByName[$NameKey] = [System.Collections.Generic.List[object]]::new() }
            $script:LiveByName[$NameKey].Add($Live)
            $script:LiveTypeSet["$IdSubscription|$($Type.ToLowerInvariant())"] = $true
            $Added++
        }

        $script:AssessedSubIds[$Sub.Id] = $true
        $SubStatus.Add([PSCustomObject]@{
                Name = $Sub.Name; Id = $Sub.Id; LiveCount = $Added; CostRows = 0
                CostSource = ''; CacheAgeHours = 0; CostAssessed = $false
            })
        Write-Note ("  {0}: {1} live resources" -f $Sub.Name, $Added)
    }

    # ---- 4. PHASE 2 - asynchronous cost details, one subscription at a time ---------------------------------------
    Write-Banner 'Phase 2 of 2 - month-to-date cost details (asynchronous report)'
    foreach ($Status in $SubStatus) {
        $Sub = $Subscriptions | Where-Object { $_.Id -eq $Status.Id } | Select-Object -First 1
        $CostResult = Get-CostDetails -Subscription $Sub -CacheRoot $CacheRoot
        $Imported = @(Import-CostDetailParts -Subscription $Sub -Parts @($CostResult.Parts))
        $Status.CostRows = [int]$Imported[-1]
        $Status.CostSource = [string]$CostResult.Source
        $Status.CacheAgeHours = $CostResult.AgeHours
        $Status.CostAssessed = $true
        Write-Note ("  {0}: {1} cost lines processed ({2})" -f $Sub.Name, $Status.CostRows, $Status.CostSource)
    }
    Save-RawChunk
    if (-not (Test-Path -LiteralPath $script:RawCsvPath)) {
        # No billing lines at all: still leave a valid, header-only export.
        'Subscription,SubscriptionId,Date,ResourceName,ResourceGroup,ResourceType,Service,ServiceFamily,Location,Cost,Currency,ChargeType,PricingModel,ResourceState,MatchMethod,ResourceId' |
            Set-Content -LiteralPath $script:RawCsvPath -Encoding utf8BOM
    }

    foreach ($Extra in $script:ExtraLive) {
        $LiveList.Add($Extra)
        $Owner = $SubStatus | Where-Object { $_.Id -eq $Extra.SubscriptionId } | Select-Object -First 1
        if ($Owner) { $Owner.LiveCount++ }
    }
    if ($script:ExtraLive.Count -gt 0) { Write-Note "  $($script:ExtraLive.Count) resource(s) missing from the inventory listing were found by direct lookup and treated as Current." 'Yellow' }

    # Fail closed: every enabled subscription must have completed BOTH phases.
    $Incomplete = @($SubStatus | Where-Object { -not $_.CostAssessed -or -not $script:AssessedSubIds.ContainsKey($_.Id) })
    if ($Incomplete.Count -gt 0 -or $SubStatus.Count -ne $Subscriptions.Count) {
        throw 'Not every enabled subscription was assessed. No consolidated report is produced.'
    }

    return [PSCustomObject]@{
        TenantDisplayName = $TenantDisplayName
        TenantDomain      = $TenantDomain
        ReportDir         = $ReportDir
        Subscriptions     = $Subscriptions
        NotEnabledCount   = $NotEnabledCount
        LiveList          = $LiveList
        SubStatus         = $SubStatus
    }
}
#endregion

#region ---------------------------------------------------------------- Build report tables from aggregates
function New-ReportTables {
    param($Collected)

    # ---- resource-level rows ----------------------------------------------------------------------------------
    $ResourceCosts = [System.Collections.Generic.List[object]]::new()
    $TagRows = [System.Collections.Generic.List[object]]::new()
    foreach ($Agg in $script:ResourceAgg.Values) {
        $Cost = [decimal]$Agg.Cost
        $FullyTagged = $false
        if ($Agg.State -eq $StateCurrent -and $null -ne $Agg.Live) { $FullyTagged = [bool]$Agg.Live.FullyTagged }

        # Zero cost never decides state; it only refines the reporting category.
        $Category = $CategoryUnmapped
        if ($Agg.State -eq $StateCurrent) { $Category = if ($Cost -ne 0) { $CategoryCurrentWithCost } else { $CategoryCurrentNoCost } }
        elseif ($Agg.State -eq $StateHistorical) { $Category = if ($Cost -ne 0) { $CategoryHistoricalWithCost } else { $CategoryHistoricalZeroCost } }

        $EffectiveTags = $Agg.CsvTags
        if ($null -ne $Agg.Live -and $Agg.Live.TagsRaw.Count -gt 0) { $EffectiveTags = $Agg.Live.TagsRaw }   # live ARM tags win; billed tags cover deleted resources
        $NewRow = [PSCustomObject]@{
                Subscription       = $Agg.Subscription
                SubscriptionId     = $Agg.SubscriptionId
                ResourceName       = $Agg.ResourceName
                ResourceGroup      = $Agg.ResourceGroup
                ResourceType       = $Agg.ResourceType
                Location           = $Agg.Location
                ResourceState      = $Agg.State
                Category           = $Category
                MatchMethod        = $Agg.MatchMethod
                Cost               = $Cost
                Currency           = $Agg.Currency
                CostRows           = $Agg.Rows                PrimaryService     = Get-TopKey $Agg.Services
                PrimaryServiceFamily = Get-TopKey $Agg.Families
                FullyTagged        = $FullyTagged
                ResourceId         = $Agg.ResourceId
                LiveId             = if ($null -ne $Agg.Live) { $Agg.Live.NormId } else { '' }
                Tags               = Format-TagText $EffectiveTags
                LastBilled         = $Agg.LastBilled
                Verification       = $Agg.Verification
            }
        foreach ($TagName in $RequiredTags) { Add-Member -InputObject $NewRow -NotePropertyName "Tag_$TagName" -NotePropertyValue (Get-TagValue $EffectiveTags $TagName) }
        $TagParts = @($RequiredTags | ForEach-Object { $V = Get-TagValue $EffectiveTags $_; if ($V) { "${_}: $V" } })
        Add-Member -InputObject $NewRow -NotePropertyName 'RequiredTagsText' -NotePropertyValue ($TagParts -join '; ')
        $ResourceCosts.Add($NewRow)
        $TagRows.Add([PSCustomObject]@{ Row = $NewRow; Tags = $EffectiveTags })
    }
    $ResourceCosts = @($ResourceCosts | Sort-Object -Property @{ Expression = { $_.Currency } }, @{ Expression = { [decimal]$_.Cost }; Descending = $true }, @{ Expression = { $_.ResourceName } })

    # ---- current inventory joined to its month-to-date cost (a live resource may have NO billing row) ----------------
    $CostByLive = @{}
    foreach ($Row in $ResourceCosts) {
        if ($Row.ResourceState -eq $StateCurrent -and $Row.LiveId) {
            if (-not $CostByLive.ContainsKey($Row.LiveId)) { $CostByLive[$Row.LiveId] = [System.Collections.Generic.List[object]]::new() }
            $CostByLive[$Row.LiveId].Add($Row)
        }
    }
    $CurrentResources = [System.Collections.Generic.List[object]]::new()
    foreach ($Live in $Collected.LiveList) {
        $Costs = @()
        if ($CostByLive.ContainsKey($Live.NormId)) { $Costs = @($CostByLive[$Live.NormId]) }
        $Net = [decimal]0
        foreach ($C in $Costs) { $Net += [decimal]$C.Cost }
        $Currencies = Join-Natural @($Costs | Where-Object { $_.Currency } | ForEach-Object { $_.Currency } | Sort-Object -Unique)
        $CurrentRow = [PSCustomObject]@{
                Subscription   = $Live.Subscription
                SubscriptionId = $Live.SubscriptionId
                ResourceName   = $Live.ResourceName
                ResourceGroup  = $Live.ResourceGroup
                ResourceType   = $Live.ResourceType
                Location       = $Live.Location
                State          = $StateCurrent
                Category       = $(if ($Net -ne 0) { $CategoryCurrentWithCost } else { $CategoryCurrentNoCost })
                MtdCost        = $Net
                Currency       = $Currencies
                FullyTagged    = $Live.FullyTagged
                ResourceId     = $Live.ResourceId
                Tags           = Format-TagText $Live.TagsRaw
            }
        foreach ($TagName in $RequiredTags) { Add-Member -InputObject $CurrentRow -NotePropertyName "Tag_$TagName" -NotePropertyValue (Get-TagValue $Live.TagsRaw $TagName) }
        $CurrentResources.Add($CurrentRow)
    }
    $CurrentResources = @($CurrentResources | Sort-Object Subscription, ResourceGroup, ResourceType, ResourceName)
    $CurrentNoCost = @($CurrentResources | Where-Object { $_.Category -eq $CategoryCurrentNoCost })
    $HistoricalRows = @($ResourceCosts | Where-Object { $_.ResourceState -eq $StateHistorical })

    # ---- integrity checks: three independent roll-ups must agree, and every cost line must be accounted for -----------
    $IntegrityFailures = [System.Collections.Generic.List[string]]::new()
    $CurrencyKeys = @($ResourceCosts | ForEach-Object { [string]$_.Currency } | Sort-Object -Unique)
    foreach ($Code in $CurrencyKeys) {
        $FromResources = Get-DecimalSum @($ResourceCosts | Where-Object { $_.Currency -eq $Code }) 'Cost'
        $FromServices = Get-DecimalSum @($script:ServiceAgg.Values | Where-Object { $_.Currency -eq $Code }) 'Cost'
        $FromGroups = Get-DecimalSum @($script:ResourceGroupAgg.Values | Where-Object { $_.Currency -eq $Code }) 'Cost'
        if ([math]::Abs($FromResources - $FromServices) -gt 0.000001 -or [math]::Abs($FromResources - $FromGroups) -gt 0.000001) {
            $IntegrityFailures.Add("Roll-up totals disagree for currency '$Code'.")
        }
    }
    $AggregatedLines = 0
    foreach ($Row in $ResourceCosts) { $AggregatedLines += [int]$Row.CostRows }
    if ($AggregatedLines -ne $script:Counters.CostRows) { $IntegrityFailures.Add('The number of aggregated cost lines does not match the number of cost lines read.') }
    if ($IntegrityFailures.Count -gt 0) { throw ('Integrity check failed: ' + ($IntegrityFailures -join ' ')) }

    # ---- service / resource-group tables ---------------------------------------------------------------------------
    $ServiceTotals = @($script:ServiceAgg.Values | ForEach-Object {
            [PSCustomObject]@{ Subscription = $_.Subscription; Service = $_.Service; Currency = $_.Currency; Cost = [decimal]$_.Cost; Active = [decimal]$_.Active; Historical = [decimal]$_.Historical; Unmapped = [decimal]$_.Unmapped }
        } | Sort-Object Currency, @{ Expression = { $_.Cost }; Descending = $true }, Service)
    $ResourceGroupTotals = @($script:ResourceGroupAgg.Values | ForEach-Object {
            [PSCustomObject]@{ Subscription = $_.Subscription; ResourceGroup = $_.ResourceGroup; Currency = $_.Currency; Cost = [decimal]$_.Cost; Active = [decimal]$_.Active; Historical = [decimal]$_.Historical; Unmapped = [decimal]$_.Unmapped }
        } | Sort-Object Currency, @{ Expression = { $_.Cost }; Descending = $true }, ResourceGroup)

    # ---- per-subscription totals (every enabled subscription appears, even with no cost) ---------------------------
    $SubscriptionTotals = [System.Collections.Generic.List[object]]::new()
    foreach ($Status in $Collected.SubStatus) {
        $Mine = @($ResourceCosts | Where-Object { $_.SubscriptionId -eq $Status.Id })
        $Codes = @($Mine | ForEach-Object { [string]$_.Currency } | Sort-Object -Unique)
        if ($Codes.Count -eq 0) { $Codes = @('') }
        foreach ($Code in $Codes) {
            $Subset = @($Mine | Where-Object { $_.Currency -eq $Code })
            $Lines = 0; foreach ($S in $Subset) { $Lines += [int]$S.CostRows }
            $SubscriptionTotals.Add([PSCustomObject]@{
                    Subscription     = $Status.Name
                    Status           = 'Enabled'
                    Currency         = $Code
                    Cost             = Get-DecimalSum @($Subset) 'Cost'
                    Active           = Get-DecimalSum @($Subset | Where-Object { $_.ResourceState -eq $StateCurrent }) 'Cost'
                    Historical       = Get-DecimalSum @($Subset | Where-Object { $_.ResourceState -eq $StateHistorical }) 'Cost'
                    Unmapped         = Get-DecimalSum @($Subset | Where-Object { $_.ResourceState -eq $StateUnmapped }) 'Cost'
                    CurrentResources = $Status.LiveCount
                    CostLines        = $Lines
                })
        }
    }

    # ---- cost by tag -----------------------------------------------------------------------------------------------
    # Required governance tags always appear (with an explicit "(Not tagged)" bucket so tagged + untagged = total).
    # Any other tag seen on billed resources is listed too. A resource with several tags is counted under each of
    # them, so rows for DIFFERENT tags are not additive; rows within ONE required tag are.
    $RequiredKeys = @{}
    foreach ($Name in $RequiredTags) { $RequiredKeys[(Get-TagKey $Name)] = $Name }
    $TagAgg = @{}
    function Add-TagCost {
        param([string]$TagName, [string]$Value, [bool]$Required, $Row)
        $Key = "$($Row.Currency)|$($TagName.ToLowerInvariant())|$($Value.ToLowerInvariant())"
        $Entry = $TagAgg[$Key]
        if ($null -eq $Entry) {
            $Entry = [PSCustomObject]@{ TagName = $TagName; TagValue = $Value; Currency = $Row.Currency; Required = $(if ($Required) { 'Yes' } else { 'No' }); Cost = [decimal]0; Active = [decimal]0; Historical = [decimal]0; Unmapped = [decimal]0; Resources = 0; PctOfTotal = $null }
            $TagAgg[$Key] = $Entry
        }
        Add-StateAmount $Entry $Row.ResourceState $Row.Cost
        if ($Row.Cost -ne 0) { $Entry.Resources++ }
    }
    foreach ($Item in $TagRows) {
        $Row = $Item.Row
        if (-not $Row.Currency) { continue }
        foreach ($Name in $RequiredTags) {
            $Value = Get-TagValue $Item.Tags $Name
            if (-not $Value) { $Value = '(Not tagged)' }
            Add-TagCost $Name $Value $true $Row
        }
        foreach ($Key in $Item.Tags.Keys) {
            if ($RequiredKeys.ContainsKey((Get-TagKey ([string]$Key)))) { continue }
            Add-TagCost ([string]$Key) ([string]$Item.Tags[$Key]) $false $Row
        }
    }
    $CurrencyTotals = @{}
    foreach ($Row in $ResourceCosts) { $CurrencyTotals[[string]$Row.Currency] = ([decimal]$CurrencyTotals[[string]$Row.Currency]) + [decimal]$Row.Cost }
    foreach ($Entry in $TagAgg.Values) { $Entry.PctOfTotal = Get-Percent $Entry.Cost $CurrencyTotals[[string]$Entry.Currency] }
    $TagCosts = @($TagAgg.Values | Sort-Object -Property @{ Expression = { $_.Required }; Descending = $true }, TagName, Currency, @{ Expression = { [decimal]$_.Cost }; Descending = $true }, TagValue)

    return [PSCustomObject]@{
        TagCosts            = $TagCosts
        ResourceCosts       = $ResourceCosts
        CurrentResources    = $CurrentResources
        CurrentNoCost       = $CurrentNoCost
        HistoricalRows      = $HistoricalRows
        ServiceTotals       = $ServiceTotals
        ResourceGroupTotals = $ResourceGroupTotals
        SubscriptionTotals  = @($SubscriptionTotals)
        CurrencyCodes       = @($CurrencyKeys | Where-Object { $_ })
        IntegrityOk         = ($IntegrityFailures.Count -eq 0)
    }
}
#endregion

#region ---------------------------------------------------------------- Tagging recommendations (works with or without tags)
function New-TaggingPlan {
    <#
        Turns the tag findings into practical advice. It is useful whether tags are absent, partial or only present
        on resources that have since been deleted. It never estimates savings; it describes measured coverage and
        where to begin. Only LIVE resources are ever recommended for backfill (deleted ones cannot be tagged).
    #>
    param($Tables, [object[]]$Profiles, $Governance, [object[]]$LiveResources)

    $Rows = [System.Collections.Generic.List[object]]::new()
    foreach ($Live in $Tables.CurrentResources) {
        $Absent = @($RequiredTags | Where-Object { -not (Get-Prop $Live "Tag_$_" '') })
        if ($Absent.Count -eq 0) { continue }
        $Rows.Add([PSCustomObject]@{ ResourceName = $Live.ResourceName; ResourceType = $Live.ResourceType; ResourceGroup = $Live.ResourceGroup; Subscription = $Live.Subscription; ResourceState = $Live.State; Cost = $Live.MtdCost; Currency = $Live.Currency; MissingTags = ($Absent -join ', ') })
    }
    foreach ($Row in $Tables.ResourceCosts) {
        if ($Row.ResourceState -ne $StateHistorical -or $Row.Cost -le 0) { continue }   # listed for information only
        $Absent = @($RequiredTags | Where-Object { -not (Get-Prop $Row "Tag_$_" '') })
        if ($Absent.Count -eq 0) { continue }
        $Rows.Add([PSCustomObject]@{ ResourceName = $Row.ResourceName; ResourceType = $Row.ResourceType; ResourceGroup = $Row.ResourceGroup; Subscription = $Row.Subscription; ResourceState = $Row.ResourceState; Cost = $Row.Cost; Currency = $Row.Currency; MissingTags = ($Absent -join ', ') })
    }
    $UntaggedRows = @($Rows | Sort-Object -Property @{ Expression = { [decimal]$_.Cost }; Descending = $true }, ResourceName)

    $LiveTotal = $LiveResources.Count
    $LiveWithAnyTag = @($LiveResources | Where-Object { $_.TagsRaw.Count -gt 0 }).Count
    $LiveWithRequired = @($LiveResources | Where-Object { $R = $_; @($RequiredTags | Where-Object { Get-TagValue $R.TagsRaw $_ }).Count -gt 0 }).Count
    $LiveMissing = @($UntaggedRows | Where-Object { $_.ResourceState -eq $StateCurrent })
    $LiveMissingWithCost = @($LiveMissing | Where-Object { $_.Cost -ne 0 })
    $AnyTagsFound = (@($Tables.TagCosts | Where-Object { $_.TagValue -ne '(Not tagged)' }).Count -gt 0)
    $BilledTagsFound = (@($Tables.TagCosts | Where-Object { $_.TagValue -ne '(Not tagged)' -and $_.Historical -ne 0 }).Count -gt 0)
    $TagList = Join-Natural $RequiredTags

    $Items = [System.Collections.Generic.List[string]]::new()
    $Situation = ''
    if ($LiveTotal -gt 0 -and $LiveWithRequired -eq 0) {
        $Situation = "None of the $LiveTotal live resource(s) carries any of the required tags ($TagList)."
        if ($LiveWithAnyTag -gt 0) { $Situation += " $LiveWithAnyTag carry other tags, but none of the required ones." }
        if ($BilledTagsFound) { $Situation += ' Tags do appear on the bills of resources that have since been deleted, so a tagging standard was applied there but was not carried over to the live estate.' }
        $Items.Add("Start at resource-group level: tag every resource group with the required tags ($TagList), then use the built-in Azure Policy `"Inherit a tag from the resource group`" (Modify effect) so resources pick the tags up automatically. This lifts coverage fastest for the least effort.")
    }
    elseif (-not $AnyTagsFound) {
        $Situation = 'No tags were found on any resource or on any billing line. Cost cannot currently be attributed to a cost center, owner or environment, so the report groups cost by subscription, resource group and service instead.'
        $Items.Add("Start at resource-group level: tag every resource group with the required tags ($TagList), then use the built-in Azure Policy `"Inherit a tag from the resource group`" (Modify effect) so resources pick the tags up automatically. This lifts coverage fastest for the least effort.")
    }
    else {
        $Situation = "Tags exist but coverage is incomplete: $LiveWithRequired of $LiveTotal live resource(s) carry at least one required tag. The tables above show which tag values carry the cost and how much sits under `"(Not tagged)`"."
        $Items.Add('Close the gap at the source: apply Azure Policy to inherit the required tags from the resource group and to require them on new resources, then backfill existing resources.')
    }

    if ($LiveMissing.Count -gt 0) {
        $Zero = $LiveMissing.Count - $LiveMissingWithCost.Count
        $Text = "$($LiveMissing.Count) of $LiveTotal live resource(s) are missing at least one required tag."
        if ($LiveMissingWithCost.Count -eq 0) { $Text += ' None currently carries month-to-date cost, so this is the cheapest moment to tag them - before any spend starts and needs attributing.' }
        elseif ($Zero -gt 0) { $Text += " $($LiveMissingWithCost.Count) carry month-to-date cost (tag these first); the other $Zero carry none yet." }
        else { $Text += ' All of them carry month-to-date cost, so tag the most expensive first.' }
        $Items.Add($Text)
    }
    foreach ($P in $Profiles) {
        $ForCurrency = @($LiveMissingWithCost | Where-Object { $_.Currency -eq $P.Currency })
        if ($ForCurrency.Count -gt 0 -and $P.Total -gt 0) {
            $UntaggedCost = Get-DecimalSum $ForCurrency 'Cost'
            $First = @($ForCurrency | Select-Object -First 3 | ForEach-Object { $_.ResourceName })
            $Items.Add("$($P.Currency): $(Format-Money $UntaggedCost $P.Currency) ($(Format-Percent (Get-Percent $UntaggedCost $P.Total)) of month-to-date cost) sits on live resources missing a required tag - start with $(Join-Natural $First).")
        }
        if ($LiveWithRequired -eq 0 -and $P.Active -gt 0) {
            $TopGroup = @($Tables.ResourceGroupTotals | Where-Object { $_.Currency -eq $P.Currency -and $_.Active -gt 0 } | Sort-Object -Property @{ Expression = { [decimal]$_.Active }; Descending = $true } | Select-Object -First 1)
            if ($TopGroup.Count -gt 0) { $Items.Add("$($P.Currency) interim showback: until tags exist, treat resource group '$($TopGroup[0].ResourceGroup)' ($(Format-Percent (Get-Percent $TopGroup[0].Active $P.Active)) of active spend) as the first ownership conversation, then work down the resource-group table.") }
        }
    }
    if ($LiveTotal -gt 0) {
        $Items.Add('Agree tag names and allowed values once (for example a CostCenter list from Finance) so reports group cleanly; this assessment treats "Cost Center", "cost-center" and "CostCenter" as the same tag, but reporting tools may not.')
    }
    $Items.Add('Re-run this assessment after each tagging wave; the "Not tagged" share and the missing-tags list below should shrink each time.')

    $Quality = @(Get-TagQualityFindings -LiveResources $LiveResources -RequiredTagNames $RequiredTags)
    if ($Quality.Count -gt 0) { $Items.Add("$($Quality.Count) tag-quality issue(s) were detected - see the findings below. Tags that exist but are inconsistent split cost across groups just as missing tags do.") }
    return [PSCustomObject]@{ Situation = $Situation; Items = @($Items); UntaggedRows = $UntaggedRows; AnyTagsFound = $AnyTagsFound; Quality = $Quality; BestPractices = @(Get-TaggingBestPractices) }
}

#endregion

#region ---------------------------------------------------------------- Tag quality and best practice
function Get-TagQualityFindings {
    <#
        Looks at HOW resources are tagged, not just whether they are: inconsistent tag names, values that differ only
        by case, synonym values, placeholder values and stray whitespace. Only measured issues are reported.
    #>
    param([object[]]$LiveResources, [string[]]$RequiredTagNames)

    $Findings = [System.Collections.Generic.List[object]]::new()
    $Display = @{}          # lower-case name -> first-seen spelling
    $Spellings = @{}        # tag key (letters/digits only) -> lower-case name -> resources
    $Values = @{}           # required tag key -> lower-case value -> exact value -> resources
    $Placeholders = @('tbd', 'todo', 'unknown', 'n/a', 'na', 'none', 'null', 'xxx', 'test', '?', '-', 'tba', 'undefined')
    $PlaceholderHits = @{}  # required tag name -> resources
    $WhitespaceHits = @{}   # required tag name -> resources
    $RequiredKeys = @{}
    foreach ($Name in $RequiredTagNames) { $RequiredKeys[(Get-TagKey $Name)] = $Name }

    foreach ($Resource in $LiveResources) {
        foreach ($TagName in $Resource.TagsRaw.Keys) {
            $Lower = ([string]$TagName).ToLowerInvariant()
            $Key = Get-TagKey ([string]$TagName)
            if (-not $Display.ContainsKey($Lower)) { $Display[$Lower] = [string]$TagName }
            if (-not $Spellings.ContainsKey($Key)) { $Spellings[$Key] = @{} }
            $Spellings[$Key][$Lower] = 1 + [int]$Spellings[$Key][$Lower]

            if ($RequiredKeys.ContainsKey($Key)) {
                $Label = $RequiredKeys[$Key]
                $Raw = [string]$Resource.TagsRaw[$TagName]
                if ($Raw -ne $Raw.Trim()) { $WhitespaceHits[$Label] = 1 + [int]$WhitespaceHits[$Label] }
                if ($Placeholders -contains $Raw.Trim().ToLowerInvariant()) { $PlaceholderHits[$Label] = 1 + [int]$PlaceholderHits[$Label] }
                if (-not $Values.ContainsKey($Key)) { $Values[$Key] = @{} }
                $ValueLower = $Raw.Trim().ToLowerInvariant()
                if (-not $Values[$Key].ContainsKey($ValueLower)) { $Values[$Key][$ValueLower] = @{} }
                $Values[$Key][$ValueLower][$Raw.Trim()] = 1 + [int]$Values[$Key][$ValueLower][$Raw.Trim()]
            }
        }
    }

    # 1. the same tag spelled several ways (Azure tag names ignore case, but not spaces or hyphens)
    foreach ($Key in ($Spellings.Keys | Sort-Object)) {
        if ($Spellings[$Key].Count -gt 1) {
            $Parts = @($Spellings[$Key].GetEnumerator() | Sort-Object { $_.Value } -Descending | ForEach-Object { "$($Display[$_.Key]) ($($_.Value))" })
            $Findings.Add([PSCustomObject]@{
                    Area = 'Tag names'; Tag = ($(if ($RequiredKeys.ContainsKey($Key)) { $RequiredKeys[$Key] } else { $Display[@($Spellings[$Key].Keys)[0]] }))
                    Finding = "The same tag is spelled several ways: $($Parts -join ', ')."
                    BestPractice = 'Publish one approved spelling per tag and rename the variants. Differences in spaces or hyphens create separate tags, so cost splits across them in reports.'
                })
        }
    }

    foreach ($Key in ($Values.Keys | Sort-Object)) {
        $Label = $RequiredKeys[$Key]
        # 2. same value, different letter case (tag VALUES are case-sensitive in Azure)
        $CaseSplits = @()
        foreach ($Lower in $Values[$Key].Keys) { if ($Values[$Key][$Lower].Count -gt 1) { $CaseSplits += (@($Values[$Key][$Lower].Keys | Sort-Object) -join ' / ') } }
        if ($CaseSplits.Count -gt 0) {
            $Findings.Add([PSCustomObject]@{ Area = 'Tag values'; Tag = $Label; Finding = "Values differ only by letter case: $(($CaseSplits | Select-Object -First 5) -join '; ')."; BestPractice = 'Tag values are case-sensitive in Azure, so "Prod" and "prod" report as different groups. Define allowed values (an approved list) and enforce them with Azure Policy.' })
        }
        # 3. synonym values for environment-style tags
        if ($Key -eq 'environment' -or $Key -eq 'env') {
            $Present = @($Values[$Key].Keys)
            foreach ($Set in @(@('prod', 'production', 'prd'), @('dev', 'development'), @('test', 'testing', 'tst'), @('stage', 'staging', 'uat'))) {
                $Overlap = @($Set | Where-Object { $Present -contains $_ })
                if ($Overlap.Count -gt 1) {
                    $Findings.Add([PSCustomObject]@{ Area = 'Tag values'; Tag = $Label; Finding = "Values that mean the same thing are used side by side: $($Overlap -join ', ')."; BestPractice = 'Choose one value per environment (for example Production, Development, Test) and migrate the rest so environment cost is not split.' })
                }
            }
        }
    }
    foreach ($Label in ($PlaceholderHits.Keys | Sort-Object)) {
        $Findings.Add([PSCustomObject]@{ Area = 'Tag values'; Tag = $Label; Finding = "$($PlaceholderHits[$Label]) resource(s) carry a placeholder value (for example TBD, unknown or none)."; BestPractice = 'A tag that exists but holds a placeholder gives false comfort and still leaves cost unattributed. Treat placeholders as untagged and require real values.' })
    }
    foreach ($Label in ($WhitespaceHits.Keys | Sort-Object)) {
        $Findings.Add([PSCustomObject]@{ Area = 'Tag values'; Tag = $Label; Finding = "$($WhitespaceHits[$Label]) resource(s) have leading or trailing spaces in the value."; BestPractice = 'Trailing spaces make "x" and "x " different values. Clean them up and validate input in deployment templates.' })
    }
    return @($Findings)
}

function Get-TaggingBestPractices {
    # Reference standard shown with every report so the advice is complete even when no issue was detected.
    return @(
        [PSCustomObject]@{ Practice = 'Define a small mandatory tag set'; Detail = 'Start with CostCenter, Owner and Environment (add Application or Project if needed). A short standard is followed; a long one is ignored.' }
        [PSCustomObject]@{ Practice = 'Standardize names and allowed values'; Detail = 'One approved spelling per tag and an approved value list (for example environments, cost-center codes). Azure tag names ignore case; values do not.' }
        [PSCustomObject]@{ Practice = 'Enforce with Azure Policy, not reminders'; Detail = 'Use policy to require tags on new resources and to inherit tags from the resource group or subscription. Azure does not copy tags down automatically.' }
        [PSCustomObject]@{ Practice = 'Tag resource groups and subscriptions too'; Detail = 'This gives every resource an owner by default. Microsoft Cost Management also offers a tag inheritance setting on some billing account types, which applies subscription and resource-group tags to cost records; check availability for your agreement.' }
        [PSCustomObject]@{ Practice = 'Name a real owner'; Detail = 'Prefer a team or shared mailbox over one individual, so ownership survives people changing roles.' }
        [PSCustomObject]@{ Practice = 'Keep secrets and personal data out of tags'; Detail = 'Tags are visible to anyone who can read the resource and appear in billing data.' }
        [PSCustomObject]@{ Practice = 'Review on a schedule'; Detail = 'Re-run this assessment monthly and track the untagged share and quality findings until they reach zero.' }
    )
}
#endregion

#region ---------------------------------------------------------------- Final calculations
function New-FinalCalculations {
    <#
        Independent re-computation of every headline figure from a different angle (by state, subscription,
        service, resource group, tag). Any mismatch aborts the run - a report with figures that do not tie out
        is never produced.
    #>
    param($Collected, $Tables, [object[]]$Profiles)

    $Rows = [System.Collections.Generic.List[object]]::new()
    function Add-Check {
        param([string]$Check, [string]$Currency, $Calculated, $Expected)
        $Difference = [decimal]$Calculated - [decimal]$Expected
        $Rows.Add([PSCustomObject]@{ Check = $Check; Currency = $Currency; Calculated = [decimal]$Calculated; Expected = [decimal]$Expected; Difference = $Difference; Result = $(if ([math]::Abs($Difference) -le 0.000001) { 'Pass' } else { 'FAIL' }) })
    }

    foreach ($P in $Profiles) {
        $Code = $P.Currency
        Add-Check 'Active + Historical/Deleted + Unmapped = MTD actual cost' $Code ($P.Active + $P.Historical + $P.Unmapped) $P.Total
        Add-Check 'Sum of subscriptions = MTD actual cost' $Code (Get-DecimalSum @($Tables.SubscriptionTotals | Where-Object { $_.Currency -eq $Code }) 'Cost') $P.Total
        Add-Check 'Sum of services = MTD actual cost' $Code (Get-DecimalSum @($Tables.ServiceTotals | Where-Object { $_.Currency -eq $Code }) 'Cost') $P.Total
        Add-Check 'Sum of resource groups = MTD actual cost' $Code (Get-DecimalSum @($Tables.ResourceGroupTotals | Where-Object { $_.Currency -eq $Code }) 'Cost') $P.Total
        Add-Check 'Sum of all resource cost lines = MTD actual cost' $Code (Get-DecimalSum @($Tables.ResourceCosts | Where-Object { $_.Currency -eq $Code }) 'Cost') $P.Total
        foreach ($Name in $RequiredTags) {
            $ForTag = @($Tables.TagCosts | Where-Object { $_.Currency -eq $Code -and $_.TagName -eq $Name -and $_.Required -eq 'Yes' })
            Add-Check "Tag '$Name': tagged + not tagged = MTD actual cost" $Code (Get-DecimalSum $ForTag 'Cost') $P.Total
        }
    }
    Add-Check 'Live resources: with cost + without cost = total live resources' '' (@($Tables.CurrentResources | Where-Object { $_.Category -eq $CategoryCurrentWithCost }).Count + $Tables.CurrentNoCost.Count) $Collected.LiveList.Count
    Add-Check 'Cost lines aggregated = cost lines read from Azure' '' (Get-DecimalSum @($Tables.ResourceCosts) 'CostRows') $script:Counters.CostRows

    $Failed = @($Rows | Where-Object { $_.Result -ne 'Pass' })
    if ($Failed.Count -gt 0) { throw ("Final calculation check failed: " + (@($Failed | ForEach-Object { $_.Check }) -join '; ')) }
    return @($Rows)
}
#endregion

#region ---------------------------------------------------------------- Executive HTML report
function Get-DominanceSentence {
    param($CurrencyProfile)
    if ($CurrencyProfile.Total -le 0) { return 'No net month-to-date cost was recorded in this currency.' }
    if ($CurrencyProfile.HistoricalPct -ge $HistoricalSuppressionThresholdPct) {
        return "Historical/deleted resources represent $(Format-Percent $CurrencyProfile.HistoricalPct) of month-to-date spend - most of the cost comes from resources that no longer exist."
    }
    if ($CurrencyProfile.UnmappedPct -ge $HistoricalSuppressionThresholdPct) {
        return "Unmapped charges represent $(Format-Percent $CurrencyProfile.UnmappedPct) of month-to-date spend - most of the cost cannot be tied to a specific resource."
    }
    if ($CurrencyProfile.ActivePct -ge 50) {
        return "Active resources account for $(Format-Percent $CurrencyProfile.ActivePct) of month-to-date spend."
    }
    return 'Spend is spread across active, historical/deleted and unmapped categories.'
}

function Get-PctWidth {
    param($Value)
    if ($null -eq $Value) { return '0' }
    return ([math]::Max(0, [math]::Min(100, [double]$Value))).ToString('0.##', $Invariant)
}


function New-DriverBarsHtml {
    # Horizontal bars for the largest cost lines of ONE currency (share of that currency's total).
    param([object[]]$Rows, $CurrencyProfile, [int]$Top = 5)
    $Lines = @($Rows | Where-Object { $_.Currency -eq $CurrencyProfile.Currency -and $_.Cost -gt 0 } | Sort-Object -Property @{ Expression = { [decimal]$_.Cost }; Descending = $true } | Select-Object -First $Top)
    if ($Lines.Count -eq 0 -or $CurrencyProfile.Total -le 0) { return '' }
    $Sb = [System.Text.StringBuilder]::new()
    [void]$Sb.Append('<div class="panel drivers">')
    foreach ($Line in $Lines) {
        $Share = Get-Percent $Line.Cost $CurrencyProfile.Total
        $Class = Get-StateClass $Line.ResourceState
        [void]$Sb.Append("<div class=`"drv`"><div class=`"drv-name`">$(ConvertTo-HtmlText $Line.ResourceName) $(Get-PillHtml $Line.ResourceState)<div class=`"drv-sub`">$(ConvertTo-HtmlText $Line.PrimaryService)</div></div><div class=`"drv-bar`"><span class=`"$Class`" style=`"width:$(Get-PctWidth $Share)%`"></span></div><div class=`"drv-val`">$(ConvertTo-HtmlText (Format-Money $Line.Cost $CurrencyProfile.Currency))<div class=`"drv-sub`">$(ConvertTo-HtmlText (Format-Percent $Share)) of total</div></div></div>")
    }
    [void]$Sb.Append('</div>')
    return $Sb.ToString()
}

function New-LeadershipDecisions {
    # Concrete, data-driven decisions leadership can take. Nothing here is fabricated: every item
    # is triggered by a measured condition in this run.
    param([object[]]$Profiles, $Governance, [int]$UnmappedItems)
    $Items = [System.Collections.Generic.List[object]]::new()
    $HistCurrencies = @($Profiles | Where-Object { $_.Historical -gt 0 })
    if ($HistCurrencies.Count -gt 0) {
        $Items.Add([PSCustomObject]@{ Decision = 'Confirm the removed resources were intentionally decommissioned and are no longer billing.'; Owner = 'Cloud / infrastructure lead'; Why = 'Charges tied to deleted resources should stop; recurrence would indicate leftover dependencies.' })
    }
    if ($Governance.HasGap) {
        $Items.Add([PSCustomObject]@{ Decision = "Approve a mandatory tagging standard ($(Join-Natural $Governance.RequiredTagNames)) with an enforcement date."; Owner = 'CIO / platform owner'; Why = 'Without ownership tags, cost cannot be attributed, shown back or charged back.' })
    }
    if ($UnmappedItems -gt 0) {
        $Items.Add([PSCustomObject]@{ Decision = 'Name an accountable owner for charges that are not tied to a resource.'; Owner = 'Finance / billing owner'; Why = 'Purchases, support and adjustments otherwise have no owner.' })
    }
    $Items.Add([PSCustomObject]@{ Decision = 'Nominate a cost owner per subscription and agree budget thresholds.'; Owner = 'Finance with IT'; Why = 'Budgets were not assessed here; thresholds should match each subscription''s size and volatility.' })
    $Eligible = @($Profiles | Where-Object { $_.CommitmentEligible })
    if ($Eligible.Count -gt 0) {
        $Items.Add([PSCustomObject]@{ Decision = 'Authorize a Reservation / Savings Plan evaluation.'; Owner = 'Finance with IT'; Why = 'Active spend looks recurring and stable, but utilization and savings must be validated before any purchase.' })
    }
    else {
        $Items.Add([PSCustomObject]@{ Decision = 'No commitment purchase (Reservation / Savings Plan) is needed now.'; Owner = 'Finance with IT'; Why = 'The active-cost baseline is not yet large or stable enough to justify one.' })
    }
    return @($Items)
}

function Write-ExecutiveHtml {
    param($Collected, $Tables, [object[]]$Profiles, $Governance, $Headline, [object[]]$Actions, [object[]]$StatusItems, [string]$CommitmentText, [object[]]$Calculations, $TagPlan)

    $PeriodText = $MonthStart.ToString('MMMM yyyy', $Invariant)
    $ThroughText = if ($script:MaxDateKey) { "Billing data through $($script:MaxDateKey) (UTC)" } else { 'No dated billing lines returned' }
    $TenantText = $Collected.TenantDisplayName
    if ($Collected.TenantDomain -and $Collected.TenantDomain -ine $Collected.TenantDisplayName) { $TenantText += " ($($Collected.TenantDomain))" }
    $MultiCurrency = ($Profiles.Count -gt 1)
    $TagColumns = @(@{ Header = 'Required tags'; Property = 'RequiredTagsText'; Type = 'text' })
    $UnmappedTotal = 0
    foreach ($Pf in $Profiles) { $UnmappedTotal += [int]$Pf.UnmappedItemCount }

    Add-Html '<!DOCTYPE html><html lang="en"><head><meta charset="utf-8">'
    Add-Html '<meta http-equiv="Content-Security-Policy" content="default-src &#39;none&#39;; style-src &#39;unsafe-inline&#39;; script-src &#39;unsafe-inline&#39;; img-src data:; base-uri &#39;none&#39;; form-action &#39;none&#39;">'
    Add-Html '<meta name="referrer" content="no-referrer">'
    Add-Html '<meta name="viewport" content="width=device-width, initial-scale=1">'
    Add-Html "<title>Azure FinOps Executive Assessment - $(ConvertTo-HtmlText $script:CompanyName) - $MonthKey</title>"
    Add-Html "<style>$(Get-ReportCss)</style></head><body>"

    # ---- 1. title / tenant / period -------------------------------------------------------------------------------
    Add-Html '<header class="top"><div class="wrap">'
    Add-Html '<button type="button" class="btn-pdf" onclick="savePdf()" title="Opens the print dialog - choose Save as PDF">Save as PDF</button>'
    Add-Html '<h1>Azure FinOps Executive Assessment</h1>'
    Add-Html "<div class=`"sub`">$(ConvertTo-HtmlText $script:CompanyName) &middot; Month-to-date cost position, $(ConvertTo-HtmlText $PeriodText)</div>"
    Add-Html "<div class=`"meta`"><span>Tenant: $(ConvertTo-HtmlText $TenantText)</span><span>$(ConvertTo-HtmlText $ThroughText)</span><span>Generated $($GeneratedAtUtc.ToString('yyyy-MM-dd HH:mm', $Invariant)) UTC</span></div>"
    Add-Html '</div></header><div class="wrap">'

    # ---- 2. verification badges (derived from real run state) -----------------------------------------------------
    Add-Html '<div class="badges">'
    foreach ($Item in $StatusItems) {
        $Class = if ($Item.Level -eq 'ok') { 'badge' } else { 'badge warn' }
        Add-Html "<span class=`"$Class`" title=`"$(ConvertTo-HtmlText $Item.Detail)`"><span class=`"dot`"></span><b>$(ConvertTo-HtmlText $Item.Label):</b> <span class=`"val`">$(ConvertTo-HtmlText $Item.Value)</span></span>"
    }
    Add-Html '</div>'
    Add-Html '<div class="nav"><a href="#glance">Spend at a glance</a><a href="#drivers">Cost drivers</a><a href="#governance">Governance</a><a href="#actions">Actions</a><a href="#decisions">Decisions</a><a href="#detail">Detail</a><a href="#calculations">Calculations</a><a href="#appendix">Methodology</a></div>'
    Add-Html '<div class="guide"><div><b>Active</b> - cost from resources that exist today.</div><div><b>Historical / Deleted</b> - cost from resources that no longer exist; expected to stop.</div><div><b>Unmapped</b> - charges with no specific resource (purchases, support, adjustments).</div></div>'

    # ---- 3. executive financial headline ---------------------------------------------------------------------------
    Add-Html '<section><h2>Executive Financial Headline</h2><div class="panel headline">'
    Add-Html "<p>$(ConvertTo-HtmlText $Headline.Headline)</p>"
    foreach ($Line in @($Headline.PerCurrency)) {
        Add-Html "<p><strong>$(ConvertTo-HtmlText $Line.Currency):</strong> $(ConvertTo-HtmlText $Line.Text)</p>"
    }
    Add-Html '</div></section>'

    # ---- 4. KPI cards + active/historical/unmapped breakdown -------------------------------------------------------
    Add-Html '<section id="glance"><h2>Spend at a glance</h2>'
    if ($Profiles.Count -eq 0) {
        Add-Html '<div class="panel"><p class="muted">No month-to-date cost was recorded, so no spend breakdown is shown.</p></div>'
    }
    foreach ($P in $Profiles) {
        $Code = $P.Currency
        Add-Html "<div class=`"cur-title`">Amounts in $(ConvertTo-HtmlText $Code)</div><div class=`"kpis`">"
        Add-Html (New-KpiCardHtml 'MTD Actual Cost' (Format-Money $P.Total $Code) 'Month-to-date, billing currency' 'neutral')
        Add-Html (New-KpiCardHtml 'Active Spend' (Format-Money $P.Active $Code) "$(Format-Percent $P.ActivePct) of total - resources that exist today" 'current')
        Add-Html (New-KpiCardHtml 'Historical / Deleted Spend' (Format-Money $P.Historical $Code) "$(Format-Percent $P.HistoricalPct) of total - resources no longer deployed" 'historical')
        Add-Html (New-KpiCardHtml 'Unmapped Spend' (Format-Money $P.Unmapped $Code) "$(Format-Percent $P.UnmappedPct) of total - not tied to a resource" 'unmapped')
        if ($null -ne $P.RunRate) {
            Add-Html (New-KpiCardHtml 'Indicative Month-End Run Rate' (Format-Money $P.RunRate $Code) 'Indicative only' 'neutral')
        }
        else {
            Add-Html (New-KpiCardHtml 'Indicative Month-End Run Rate' 'Not calculated' 'See note below' 'neutral')
        }
        Add-Html '</div>'
        if ($P.Total -gt 0) {
            Add-Html "<div class=`"bar`" role=`"img`" aria-label=`"Spend split`"><span class=`"b-current`" style=`"width:$(Get-PctWidth $P.ActivePct)%`"></span><span class=`"b-historical`" style=`"width:$(Get-PctWidth $P.HistoricalPct)%`"></span><span class=`"b-unmapped`" style=`"width:$(Get-PctWidth $P.UnmappedPct)%`"></span></div>"
            Add-Html "<div class=`"legend`"><span><i style=`"background:var(--current)`"></i>Active $(Format-Percent $P.ActivePct)</span><span><i style=`"background:#d99a00`"></i>Historical / Deleted $(Format-Percent $P.HistoricalPct)</span><span><i style=`"background:#8fa0b1`"></i>Unmapped $(Format-Percent $P.UnmappedPct)</span></div>"
        }
        Add-Html "<p class=`"note`"><strong>$(ConvertTo-HtmlText (Get-DominanceSentence $P))</strong></p>"
        Add-Html "<p class=`"note`">Run rate: $(ConvertTo-HtmlText $P.RunRateNote)</p>"
    }
    Add-Html '<div class="cur-title">Estate</div><div class="kpis">'
    Add-Html (New-KpiCardHtml 'Enabled Subscriptions' ([string]$Collected.Subscriptions.Count) 'All assessed' 'neutral')
    Add-Html (New-KpiCardHtml 'Current ARM Resources' (Format-Number $Collected.LiveList.Count '#,##0') 'Independently enumerated live inventory' 'current')
    Add-Html (New-KpiCardHtml 'Current Resources With No MTD Cost' (Format-Number $Tables.CurrentNoCost.Count '#,##0') 'Deployed but not billing this month' 'neutral')
    Add-Html '</div></section>'

    # ---- 5. primary cost driver + 6. key consideration ---------------------------------------------------------------
    Add-Html '<section id="drivers"><h2>Primary cost drivers</h2>'
    foreach ($P in $Profiles) {
        if ($MultiCurrency) { Add-Html "<div class=`"cur-title`">Top cost lines in $(ConvertTo-HtmlText $P.Currency)</div>" }
        Add-Html (New-DriverBarsHtml -Rows $Tables.ResourceCosts -CurrencyProfile $P)
    }
    Add-Html '<div class="grid2" style="margin-top:12px">'
    foreach ($P in $Profiles) {
        $Code = $P.Currency
        if ($P.TopResource) {
            $Top = $P.TopResource
            $Service = if ($Top.PrimaryService) { " Billed mainly under $($Top.PrimaryService)." } else { '' }
            Add-Html "<div class=`"callout`"><div class=`"k`">$(ConvertTo-HtmlText $Code) - largest single cost line</div><p><strong>$(ConvertTo-HtmlText $Top.ResourceName)</strong> $(Get-PillHtml $Top.ResourceState)<br>$(ConvertTo-HtmlText (Format-Money $Top.Cost $Code)) &middot; $(ConvertTo-HtmlText (Format-Percent $P.TopResourcePct)) of month-to-date spend.$(ConvertTo-HtmlText $Service)</p></div>"
        }
        else {
            Add-Html "<div class=`"callout`"><div class=`"k`">$(ConvertTo-HtmlText $Code)</div><p>No single cost driver: no positive resource-level cost was recorded.</p></div>"
        }
        if ($P.TopServiceName) {
            Add-Html "<div class=`"callout`"><div class=`"k`">$(ConvertTo-HtmlText $Code) - largest service category</div><p><strong>$(ConvertTo-HtmlText $P.TopServiceName)</strong><br>$(ConvertTo-HtmlText (Format-Percent $P.TopServicePct)) of month-to-date spend.</p></div>"
        }
    }
    if ($Profiles.Count -eq 0) { Add-Html '<div class="callout"><div class="k">Cost driver</div><p>Not applicable - no cost recorded.</p></div>' }
    Add-Html '</div></section>'

    Add-Html '<section><h2>Key financial and governance consideration</h2><div class="grid2">'
    foreach ($P in $Profiles) {
        $Prefix = if ($MultiCurrency) { "$($P.Currency): " } else { '' }
        Add-Html "<div class=`"callout`"><p>$(ConvertTo-HtmlText ($Prefix + (Get-KeyConsideration $P $Governance)))</p></div>"
        Add-Html "<div class=`"callout`"><div class=`"k`">Optimization focus</div><p>$(ConvertTo-HtmlText ($Prefix + (Get-OptimizationFocus $P)))</p></div>"
    }
    if ($Profiles.Count -eq 0) { Add-Html "<div class=`"callout`"><p>$(ConvertTo-HtmlText $Governance.Opportunity)</p></div>" }
    Add-Html '</div></section>'

    # ---- 7. cost governance readiness ---------------------------------------------------------------------------
    Add-Html '<section id="governance"><h2>Cost governance readiness</h2><div class="kpis">'
    foreach ($TagRow in $Governance.Tags) {
        Add-Html (New-KpiCardHtml "$($TagRow.Tag) tag coverage" (Format-Percent $TagRow.CoveragePct) "$($TagRow.Tagged) of $($Governance.TotalResources) live resources" 'neutral')
    }
    Add-Html (New-KpiCardHtml 'Fully tagged' (Format-Percent $Governance.FullyTaggedPct) "$($Governance.FullyTagged) of $($Governance.TotalResources) carry all required tags" 'neutral')
    Add-Html (New-KpiCardHtml 'Readiness stage' $Governance.Maturity 'Tagging-based indicator' 'neutral')
    Add-Html '</div>'
    Add-Html "<div class=`"callout`" style=`"margin-top:12px`"><p>$(ConvertTo-HtmlText $Governance.Opportunity)</p></div>"
    Add-Html "<p class=`"note`">$(ConvertTo-HtmlText $Governance.MaturityNote) Top-level resources only: $(Format-Percent $Governance.TopLevelFullyTaggedPct) fully tagged ($($Governance.TopLevelFullyTagged) of $($Governance.TopLevelResources)).</p>"
    Add-Html '<h3>Tagging recommendations</h3>'
    Add-Html "<div class=`"callout`"><p>$(ConvertTo-HtmlText $TagPlan.Situation)</p></div>"
    Add-Html '<div class="panel" style="margin-top:10px"><ul style="margin:0;padding-left:18px">'
    foreach ($PlanItem in $TagPlan.Items) { Add-Html "<li style=`"margin-bottom:8px`">$(ConvertTo-HtmlText $PlanItem)</li>" }
    Add-Html '</ul></div>'
    Add-Html '<h3>Tag quality findings</h3>'
    if (-not $TagPlan.AnyTagsFound) {
        Add-Html '<p class="muted">Not applicable - no tags were found, so there is no tag quality to assess yet.</p>'
    }
    else {
        Add-Html (ConvertTo-HtmlTable -Rows $TagPlan.Quality -EmptyMessage 'No naming or value inconsistencies were detected in the tags found on live resources.' -Columns @(
                @{ Header = 'Area'; Property = 'Area'; Type = 'text' },
                @{ Header = 'Tag'; Property = 'Tag'; Type = 'text' },
                @{ Header = 'Finding'; Property = 'Finding'; Type = 'text' },
                @{ Header = 'Best practice'; Property = 'BestPractice'; Type = 'text' }))
    }
    Add-Html '<h3>Tagging best-practice standard</h3>'
    Add-Html (ConvertTo-HtmlTable -Rows $TagPlan.BestPractices -Columns @(
            @{ Header = 'Practice'; Property = 'Practice'; Type = 'text' },
            @{ Header = 'What it means'; Property = 'Detail'; Type = 'text' }))
    Add-Html '<h3>Resources missing required tags (start here)</h3>'
    Add-Html (ConvertTo-HtmlTable -Rows @($TagPlan.UntaggedRows | Select-Object -First $MaxDetailRows) -EmptyMessage 'Every live resource carries all required tags.' -Columns @(
            @{ Header = 'Resource'; Property = 'ResourceName'; Type = 'text' },
            @{ Header = 'Type'; Property = 'ResourceType'; Type = 'text' },
            @{ Header = 'Resource Group'; Property = 'ResourceGroup'; Type = 'text' },
            @{ Header = 'State'; Property = 'ResourceState'; Type = 'state' },
            @{ Header = 'Missing Tags'; Property = 'MissingTags'; Type = 'text' },
            @{ Header = 'MTD Cost'; Property = 'Cost'; Type = 'money' },
            @{ Header = 'Currency'; Property = 'Currency'; Type = 'text' }))
    Add-Html '<p class="detail-note">Full list: 15-Untagged-Cost.csv.</p></section>'


    # ---- 8. prioritised actions ---------------------------------------------------------------------------------
    Add-Html '<section id="actions"><h2>Prioritized executive actions</h2><div class="grid3">'
    foreach ($Group in @(@('Immediate', 'immediate', 'Immediate'), @('Near-Term', 'near', 'Near-Term'), @('Strategic', 'strategic', 'Strategic'))) {
        $Items = @($Actions | Where-Object { $_.Priority -eq $Group[0] })
        Add-Html "<div class=`"action-card $($Group[1])`"><h3>$(ConvertTo-HtmlText $Group[2])</h3><ul>"
        foreach ($Action in $Items) {
            Add-Html "<li><strong>$(ConvertTo-HtmlText $Action.Action)</strong><span>$(ConvertTo-HtmlText $Action.Detail)</span></li>"
        }
        Add-Html '</ul></div>'
    }
    Add-Html '</div></section>'

    # ---- 9. scope: what this assessment did NOT measure ----------------------------------------------------------------
    Add-Html '<section id="decisions"><h2>Decisions for leadership</h2>'
    $Decisions = New-LeadershipDecisions -Profiles $Profiles -Governance $Governance -UnmappedItems $UnmappedTotal
    Add-Html (ConvertTo-HtmlTable -Rows $Decisions -Columns @(
            @{ Header = 'Decision'; Property = 'Decision'; Type = 'text' },
            @{ Header = 'Suggested owner'; Property = 'Owner'; Type = 'text' },
            @{ Header = 'Why it matters'; Property = 'Why'; Type = 'text' }))
    Add-Html '</section><section><h2>Financial planning notes and scope</h2><div class="grid2">'
    Add-Html "<div class=`"callout`"><div class=`"k`">Commitment discounts</div><p>$(ConvertTo-HtmlText $CommitmentText)</p></div>"
    Add-Html '<div class="callout"><div class="k">Capital and operating expenditure</div><p>Where Finance distinguishes capital and operating expenditure, use this assessment as an input to Finance review rather than as an accounting classification engine. Final treatment should follow organizational accounting policy and applicable standards.</p></div>'
    Add-Html '<div class="callout"><div class="k">Currency</div><p>All amounts are shown in the billing currency returned by Azure. Different currencies are never added together, and no currency conversion is performed without an approved FX policy.</p></div>'
    Add-Html '</div><h3>Not covered by this assessment</h3><div class="grid2">'
    foreach ($NA in @(
            @('Azure budgets', 'Not assessed'),
            @('Official Azure cost forecast', 'Not available from this assessment'),
            @('Cost anomaly alerts', 'Not assessed'),
            @('Commitment utilization and savings', 'Not assessed'))) {
        Add-Html "<div class=`"na`"><b>$(ConvertTo-HtmlText $NA[0])</b><span>$(ConvertTo-HtmlText $NA[1])</span></div>"
    }
    Add-Html '</div></section>'

    # ---- 10. detail tables ----------------------------------------------------------------------------------------------
    Add-Html '<section id="detail"><h2>Detailed analysis</h2>'

    $CurrencyRows = @($Profiles | ForEach-Object {
            $Pf = $_
            [PSCustomObject]@{
                Currency = $Pf.Currency; Total = $Pf.Total; Active = $Pf.Active; Historical = $Pf.Historical; Unmapped = $Pf.Unmapped
                HistoricalPct = $Pf.HistoricalPct
                RunRateText = $(if ($null -ne $Pf.RunRate) { Format-Money $Pf.RunRate $Pf.Currency } else { 'Not calculated' })
            }
        })
    Add-Html '<h3>Currency and consolidation</h3>'
    Add-Html (ConvertTo-HtmlTable -Rows $CurrencyRows -EmptyMessage 'No cost was recorded in any currency.' -Columns @(
            @{ Header = 'Currency'; Property = 'Currency'; Type = 'text' },
            @{ Header = 'MTD Actual Cost'; Property = 'Total'; Type = 'money' },
            @{ Header = 'Active'; Property = 'Active'; Type = 'money' },
            @{ Header = 'Historical / Deleted'; Property = 'Historical'; Type = 'money' },
            @{ Header = 'Unmapped'; Property = 'Unmapped'; Type = 'money' },
            @{ Header = 'Historical %'; Property = 'HistoricalPct'; Type = 'pct' },
            @{ Header = 'Indicative Run Rate'; Property = 'RunRateText'; Type = 'text' }))
    Add-Html '<p class="detail-note">Each currency is a separate total. Nothing is converted or added across currencies.</p>'

    Add-Html '<h3>Cost by subscription</h3>'
    Add-Html (ConvertTo-HtmlTable -Rows $Tables.SubscriptionTotals -Columns @(
            @{ Header = 'Subscription'; Property = 'Subscription'; Type = 'text' },
            @{ Header = 'Status'; Property = 'Status'; Type = 'text' },
            @{ Header = 'Currency'; Property = 'Currency'; Type = 'text' },
            @{ Header = 'MTD Cost'; Property = 'Cost'; Type = 'money' },
            @{ Header = 'Active'; Property = 'Active'; Type = 'money' },
            @{ Header = 'Historical / Deleted'; Property = 'Historical'; Type = 'money' },
            @{ Header = 'Unmapped'; Property = 'Unmapped'; Type = 'money' },
            @{ Header = 'Current Resources'; Property = 'CurrentResources'; Type = 'number' },
            @{ Header = 'Cost Lines'; Property = 'CostLines'; Type = 'number' }))

    $NoLines = @($Collected.SubStatus | Where-Object { $_.CostRows -eq 0 })
    if ($NoLines.Count -gt 0) {
        Add-Html "<p class=`"detail-note`">No cost lines were returned for: $(ConvertTo-HtmlText (($NoLines | ForEach-Object { $_.Name }) -join ', ')). That is expected for an unused subscription; if activity was expected there, confirm the signed-in account has Cost Management Reader on it.</p>"
    }
    $HistoricalWithCost = @($Tables.HistoricalRows | Where-Object { $_.Cost -ne 0 } | Select-Object -First $MaxDetailRows)
    Add-Html '<h3>Historical / deleted resource cost</h3>'
    Add-Html (ConvertTo-HtmlTable -Rows $HistoricalWithCost -EmptyMessage 'No historical/deleted resource cost was identified.' -Columns (@(
            @{ Header = 'Resource'; Property = 'ResourceName'; Type = 'text' },
            @{ Header = 'Type'; Property = 'ResourceType'; Type = 'text' },
            @{ Header = 'Resource Group'; Property = 'ResourceGroup'; Type = 'text' },
            @{ Header = 'State'; Property = 'ResourceState'; Type = 'state' },
            @{ Header = 'Last Billed'; Property = 'LastBilled'; Type = 'text' },
            @{ Header = 'Deletion Check'; Property = 'Verification'; Type = 'text' },
            @{ Header = 'MTD Cost'; Property = 'Cost'; Type = 'money' },
            @{ Header = 'Currency'; Property = 'Currency'; Type = 'text' }) + $TagColumns))
    $HistZero = @($Tables.HistoricalRows | Where-Object { $_.Cost -eq 0 }).Count
    Add-Html "<p class=`"detail-note`">Full list, including $HistZero historical/deleted resource(s) with zero month-to-date cost: 07-Historical-Deleted-Resource-Cost.csv.</p>"

    $TopResources = @($Tables.ResourceCosts | Where-Object { $_.Cost -ne 0 } | Sort-Object -Property @{ Expression = { $_.Currency } }, @{ Expression = { [decimal]$_.Cost }; Descending = $true } | Select-Object -First $MaxDetailRows)
    Add-Html '<h3>Top resource costs</h3>'
    Add-Html (ConvertTo-HtmlTable -Rows $TopResources -EmptyMessage 'No resource-level cost was recorded.' -Columns (@(
            @{ Header = 'Resource'; Property = 'ResourceName'; Type = 'text' },
            @{ Header = 'Type'; Property = 'ResourceType'; Type = 'text' },
            @{ Header = 'Resource Group'; Property = 'ResourceGroup'; Type = 'text' },
            @{ Header = 'State'; Property = 'ResourceState'; Type = 'state' },
            @{ Header = 'MTD Cost'; Property = 'Cost'; Type = 'money' },
            @{ Header = 'Currency'; Property = 'Currency'; Type = 'text' }) + $TagColumns))
    Add-Html "<p class=`"detail-note`">Showing up to $MaxDetailRows lines. Complete list: 01-Cost-By-Resource.csv.</p>"

    # Current inventory summarised by type: counts every live ARM resource, billed or not.
    $TypeSummary = @($Tables.CurrentResources | Group-Object -Property ResourceType | ForEach-Object {
            $Members = @($_.Group)
            [PSCustomObject]@{
                ResourceType = $_.Name
                Count        = $Members.Count
                WithCost     = @($Members | Where-Object { $_.Category -eq $CategoryCurrentWithCost }).Count
                NoCost       = @($Members | Where-Object { $_.Category -eq $CategoryCurrentNoCost }).Count
                FullyTagged  = @($Members | Where-Object { $_.FullyTagged }).Count
            }
        } | Sort-Object @{ Expression = { $_.Count }; Descending = $true }, ResourceType)
    Add-Html '<h3>Current Azure resource inventory</h3>'
    Add-Html (ConvertTo-HtmlTable -Rows @($TypeSummary | Select-Object -First $MaxDetailRows) -EmptyMessage 'No live resources were inventoried.' -Columns @(
            @{ Header = 'Resource Type'; Property = 'ResourceType'; Type = 'text' },
            @{ Header = 'Live Resources'; Property = 'Count'; Type = 'number' },
            @{ Header = 'With MTD Cost'; Property = 'WithCost'; Type = 'number' },
            @{ Header = 'No MTD Cost'; Property = 'NoCost'; Type = 'number' },
            @{ Header = 'Fully Tagged'; Property = 'FullyTagged'; Type = 'number' }))
    Add-Html "<p class=`"detail-note`">$($TypeSummary.Count) resource type(s), $($Collected.LiveList.Count) live resource(s) in total. A live resource with zero cost is still Current. Full list: 05-Current-Resources.csv.</p>"

    Add-Html '<h3>Current resources with no month-to-date cost</h3>'
    Add-Html (ConvertTo-HtmlTable -Rows @($Tables.CurrentNoCost | Select-Object -First $MaxDetailRows) -EmptyMessage 'Every current resource has month-to-date cost.' -Columns @(
            @{ Header = 'Resource'; Property = 'ResourceName'; Type = 'text' },
            @{ Header = 'Type'; Property = 'ResourceType'; Type = 'text' },
            @{ Header = 'Resource Group'; Property = 'ResourceGroup'; Type = 'text' },
            @{ Header = 'Subscription'; Property = 'Subscription'; Type = 'text' },
            @{ Header = 'State'; Property = 'State'; Type = 'state' }))
    Add-Html "<p class=`"detail-note`">$($Tables.CurrentNoCost.Count) resource(s) in total (first $MaxDetailRows shown). Full list: 06-Current-Resources-No-MTD-Cost.csv.</p>"

    Add-Html '<h3>Cost by service</h3>'
    Add-Html (ConvertTo-HtmlTable -Rows @($Tables.ServiceTotals | Select-Object -First $MaxDetailRows) -Columns @(
            @{ Header = 'Service'; Property = 'Service'; Type = 'text' },
            @{ Header = 'Subscription'; Property = 'Subscription'; Type = 'text' },
            @{ Header = 'Currency'; Property = 'Currency'; Type = 'text' },
            @{ Header = 'MTD Cost'; Property = 'Cost'; Type = 'money' },
            @{ Header = 'Active'; Property = 'Active'; Type = 'money' },
            @{ Header = 'Historical / Deleted'; Property = 'Historical'; Type = 'money' },
            @{ Header = 'Unmapped'; Property = 'Unmapped'; Type = 'money' }))

    Add-Html '<h3>Cost by resource group</h3>'
    Add-Html (ConvertTo-HtmlTable -Rows @($Tables.ResourceGroupTotals | Select-Object -First $MaxDetailRows) -Columns @(
            @{ Header = 'Resource Group'; Property = 'ResourceGroup'; Type = 'text' },
            @{ Header = 'Subscription'; Property = 'Subscription'; Type = 'text' },
            @{ Header = 'Currency'; Property = 'Currency'; Type = 'text' },
            @{ Header = 'MTD Cost'; Property = 'Cost'; Type = 'money' },
            @{ Header = 'Active'; Property = 'Active'; Type = 'money' },
            @{ Header = 'Historical / Deleted'; Property = 'Historical'; Type = 'money' },
            @{ Header = 'Unmapped'; Property = 'Unmapped'; Type = 'money' }))

    # ---- cost by tag --------------------------------------------------------------------------------------------------
    Add-Html '<h3>Cost by tag</h3>'
    $TagColsAll = @(
        @{ Header = 'Tag'; Property = 'TagName'; Type = 'text' },
        @{ Header = 'Tag Value'; Property = 'TagValue'; Type = 'text' },
        @{ Header = 'Currency'; Property = 'Currency'; Type = 'text' },
        @{ Header = 'MTD Cost'; Property = 'Cost'; Type = 'money' },
        @{ Header = '% of Total'; Property = 'PctOfTotal'; Type = 'pct' },
        @{ Header = 'Active'; Property = 'Active'; Type = 'money' },
        @{ Header = 'Historical / Deleted'; Property = 'Historical'; Type = 'money' },
        @{ Header = 'Unmapped'; Property = 'Unmapped'; Type = 'money' },
        @{ Header = 'Cost Lines'; Property = 'Resources'; Type = 'number' })
    $RequiredTagCosts = @($Tables.TagCosts | Where-Object { $_.Required -eq 'Yes' })
    Add-Html (ConvertTo-HtmlTable -Rows @($RequiredTagCosts | Select-Object -First ($MaxDetailRows * 2)) -Columns $TagColsAll -EmptyMessage 'No cost was recorded, so there is no cost by tag.')
    Add-Html '<p class="detail-note">Required governance tags are shown with an explicit "(Not tagged)" row, so the rows for any one tag add up to the full month-to-date cost. Tags come from live Azure resources; for deleted resources, the tags recorded on the bill are used.</p>'
    $AllOtherTags = @($Tables.TagCosts | Where-Object { $_.Required -eq 'No' })
    $OtherTagCosts = @($AllOtherTags | Where-Object { $_.Cost -ne 0 } | Sort-Object -Property @{ Expression = { [decimal]$_.Cost }; Descending = $true } | Select-Object -First $MaxDetailRows)
    if ($OtherTagCosts.Count -gt 0) {
        Add-Html '<h3>Cost by other tags found on billed resources</h3>'
        Add-Html (ConvertTo-HtmlTable -Rows $OtherTagCosts -Columns $TagColsAll)
        Add-Html '<p class="detail-note">A resource with several tags appears under each of them, so rows for different tags must not be added together. Full list: 13-Cost-By-Tag.csv.</p>'
        if (($AllOtherTags.Count - $OtherTagCosts.Count) -gt 0) { Add-Html "<p class=`"detail-note`">$($AllOtherTags.Count - $OtherTagCosts.Count) further tag value(s) appear only on zero-cost resources and are listed in the CSV.</p>" }
    }
    Add-Html '</section>'

    # ---- final calculations ------------------------------------------------------------------------------------------
    Add-Html '<section id="calculations"><h2>Final calculations and reconciliation</h2>'
    $KeyFigures = @($Profiles | ForEach-Object {
            $Pf = $_
            [PSCustomObject]@{
                Currency = $Pf.Currency; Total = $Pf.Total; Active = $Pf.Active; Historical = $Pf.Historical; Unmapped = $Pf.Unmapped
                ElapsedDays = $Pf.ElapsedDays
                RunRateText = $(if ($null -ne $Pf.RunRate) { "$(Format-Amount $Pf.Active) x $DaysInMonth / $($Pf.ElapsedDays) + $(Format-Amount $Pf.Historical) + $(Format-Amount $Pf.Unmapped) = $(Format-Amount $Pf.RunRate)" } else { 'Not calculated (see run-rate note)' })
            }
        })
    Add-Html (ConvertTo-HtmlTable -Rows $KeyFigures -EmptyMessage 'No cost recorded.' -Columns @(
            @{ Header = 'Currency'; Property = 'Currency'; Type = 'text' },
            @{ Header = 'MTD Actual Cost'; Property = 'Total'; Type = 'money' },
            @{ Header = 'Active'; Property = 'Active'; Type = 'money' },
            @{ Header = 'Historical / Deleted'; Property = 'Historical'; Type = 'money' },
            @{ Header = 'Unmapped'; Property = 'Unmapped'; Type = 'money' },
            @{ Header = 'Days Billed'; Property = 'ElapsedDays'; Type = 'number' },
            @{ Header = 'Indicative Run Rate = Active x days in month / days billed + Historical + Unmapped'; Property = 'RunRateText'; Type = 'text' }))
    Add-Html '<h3>Tie-out checks</h3>'
    $CalcRows = @($Calculations | ForEach-Object {
            $IsCount = [string]::IsNullOrEmpty($_.Currency)
            [PSCustomObject]@{ Check = $_.Check; Currency = $_.Currency
                Calculated = $(if ($IsCount) { Format-Number $_.Calculated '#,##0' } else { Format-Amount $_.Calculated })
                Expected = $(if ($IsCount) { Format-Number $_.Expected '#,##0' } else { Format-Amount $_.Expected })
                Difference = $(if ($IsCount) { Format-Number $_.Difference '#,##0' } else { Format-Amount $_.Difference })
                State = $(if ($_.Result -eq 'Pass') { 'Current' } else { 'Historical' }); ResultText = $_.Result }
        })
    Add-Html (ConvertTo-HtmlTable -Rows $CalcRows -Columns @(
            @{ Header = 'Check'; Property = 'Check'; Type = 'text' },
            @{ Header = 'Currency'; Property = 'Currency'; Type = 'text' },
            @{ Header = 'Calculated'; Property = 'Calculated'; Type = 'numtext' },
            @{ Header = 'Expected'; Property = 'Expected'; Type = 'numtext' },
            @{ Header = 'Difference'; Property = 'Difference'; Type = 'numtext' },
            @{ Header = 'Result'; Property = 'ResultText'; Type = 'text' }))
    Add-Html "<p class=`"detail-note`">$(@($Calculations | Where-Object { $_.Result -eq 'Pass' }).Count) of $($Calculations.Count) checks passed. Every headline figure is recomputed from a different angle; if any check failed, no report would have been produced. Full list: 14-Final-Calculations.csv.</p></section>"

    # ---- 11. appendix: methodology and reconciliation (technical detail lives here, not on the first screen) ---------
    $MatchCounts = @{}
    foreach ($Row in $Tables.ResourceCosts) { $MatchCounts[[string]$Row.MatchMethod] = 1 + [int]$MatchCounts[[string]$Row.MatchMethod] }
    $FromCache = @($Collected.SubStatus | Where-Object { $_.CostSource -eq 'Cache' })
    $CacheText = if ($FromCache.Count -eq 0) { 'All cost data was generated fresh by Azure for this run.' } else { "$($FromCache.Count) of $($Collected.SubStatus.Count) subscription(s) reused a local cost-details cache younger than $CacheHours hour(s); the rest were generated fresh by Azure." }

    Add-Html '<section id="appendix"><h2>Appendix - methodology and reconciliation</h2>'
    Add-Html '<details class="appendix"><summary>How the numbers were produced</summary><ul>'
    Add-Html '<li><strong>Cost source.</strong> Azure Cost Management asynchronous cost-details reports (actual cost, current month) were requested per subscription, polled at the interval Azure specified, downloaded and analyzed locally. The synchronous query interface was not used.</li>'
    Add-Html "<li><strong>Cache.</strong> $(ConvertTo-HtmlText $CacheText)</li>"
    Add-Html '<li><strong>Coverage.</strong> Every enabled subscription in the tenant was required to complete; if any had failed, no consolidated report would have been produced.</li>'
    if ($Collected.NotEnabledCount -gt 0) { Add-Html "<li><strong>Out of scope.</strong> $($Collected.NotEnabledCount) subscription(s) in this tenant are not in the Enabled state and were not assessed.</li>" }
    Add-Html '<li><strong>Current versus historical.</strong> Billing lines were reconciled to the live Azure Resource Manager inventory by normalized resource ID, then by subscription + resource group + name (resource type must agree). A billed resource is Historical / Deleted only when it has a full resource ID in an assessed subscription that is absent from the live inventory. Zero cost never changes the state. Charges without a resource identity, and non-usage lines such as purchases, refunds and adjustments, are Unmapped.</li>'
    Add-Html "<li><strong>Reconciliation results.</strong> Resource-level matches - by resource ID: $([int]$MatchCounts['ResourceId']); by parent resource: $([int]$MatchCounts['ParentResource']); by subscription + group + name: $([int]$MatchCounts['Sub+RG+Name']); not matched: $([int]$MatchCounts['None']).</li>"
    Add-Html "<li><strong>Deletion checks.</strong> Every resource that looked deleted was looked up directly by its exact ID: $($script:Counters.DeletionConfirmed) confirmed deleted, $($script:Counters.DirectLookupMatches) found still existing (treated as Current), $($script:Counters.DeletionUnverified) could not be verified and stay flagged 'Not verified'.</li>"
    Add-Html "<li><strong>Volume.</strong> $($script:Counters.CostRows) cost line(s) processed; $($script:Counters.OutOfMonthRows) dated outside the current month.</li>"
    Add-Html '<li><strong>Run rate.</strong> The Indicative Month-End Run Rate extrapolates ACTIVE spend linearly from the days billed so far and holds historical and unmapped spend flat. It is suppressed when historical/deleted spend distorts the baseline. It is not the Azure Cost Management forecast.</li>'
    Add-Html '<li><strong>Privacy.</strong> Tenant, subscription and billing-account identifiers are intentionally omitted from this report. Supporting CSV files retain subscription and resource identifiers for traceability; handle them accordingly.</li>'
    Add-Html '</ul></details>'

    Add-Html '<details class="appendix"><summary>Supporting files</summary><ul>'
    foreach ($FileName in @('01-Cost-By-Resource.csv', '02-Cost-By-Subscription.csv', '03-Cost-By-Service.csv', '04-Cost-By-Resource-Group.csv', '05-Current-Resources.csv', '06-Current-Resources-No-MTD-Cost.csv', '07-Historical-Deleted-Resource-Cost.csv', '08-Cost-By-Currency.csv', '09-Raw-Cost-Details-Normalized.csv', '10-Executive-Summary.csv', '11-Executive-Actions.csv', '12-Governance-Readiness.csv', '13-Cost-By-Tag.csv', '14-Final-Calculations.csv', '15-Untagged-Cost.csv', '16-Tag-Quality-Findings.csv', 'Executive-Summary.json')) {
        Add-Html "<li>$(ConvertTo-HtmlText $FileName)</li>"
    }
    Add-Html '</ul></details>'
    Add-Html "<footer>Azure FinOps Executive Assessment v$ScriptVersion. Figures are Azure-reported month-to-date actual cost; nothing in this report was estimated other than the clearly labelled indicative run rate.</footer>"
    Add-Html '</section></div>'
    Add-Html '<script>function savePdf(){window.print();}window.addEventListener("beforeprint",function(){document.querySelectorAll("details").forEach(function(d){d.setAttribute("open","");});});</script>'
    Add-Html '</body></html>'
}
#endregion

#region ---------------------------------------------------------------- Exports (CSV 01-12 + JSON)
function Export-Deliverables {
    param($Collected, $Tables, [object[]]$Profiles, $Governance, $Headline, [object[]]$Actions, [object[]]$StatusItems, [string]$CommitmentText, [object[]]$Calculations, $TagPlan)

    $Dir = $Collected.ReportDir
    function Save-Csv {
        param([string]$Name, [object[]]$Rows, [string[]]$Header)
        $Path = Join-Path $Dir $Name
        if (@($Rows).Count -gt 0) { @($Rows) | ForEach-Object { Protect-CsvRow $_ } | Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding utf8BOM }
        else { ($Header -join ',') | Set-Content -LiteralPath $Path -Encoding utf8BOM }   # header-only file, never a missing file
    }

    Save-Csv '01-Cost-By-Resource.csv' $Tables.ResourceCosts @('Subscription', 'SubscriptionId', 'ResourceName', 'ResourceGroup', 'ResourceType', 'Location', 'ResourceState', 'Category', 'MatchMethod', 'Cost', 'Currency', 'CostRows', 'PrimaryService', 'PrimaryServiceFamily', 'FullyTagged', 'ResourceId', 'LiveId')
    Save-Csv '02-Cost-By-Subscription.csv' $Tables.SubscriptionTotals @('Subscription', 'Status', 'Currency', 'Cost', 'Active', 'Historical', 'Unmapped', 'CurrentResources', 'CostLines')
    Save-Csv '03-Cost-By-Service.csv' $Tables.ServiceTotals @('Subscription', 'Service', 'Currency', 'Cost', 'Active', 'Historical', 'Unmapped')
    Save-Csv '04-Cost-By-Resource-Group.csv' $Tables.ResourceGroupTotals @('Subscription', 'ResourceGroup', 'Currency', 'Cost', 'Active', 'Historical', 'Unmapped')
    Save-Csv '05-Current-Resources.csv' $Tables.CurrentResources @('Subscription', 'SubscriptionId', 'ResourceName', 'ResourceGroup', 'ResourceType', 'Location', 'State', 'Category', 'MtdCost', 'Currency', 'FullyTagged', 'ResourceId')
    Save-Csv '06-Current-Resources-No-MTD-Cost.csv' $Tables.CurrentNoCost @('Subscription', 'SubscriptionId', 'ResourceName', 'ResourceGroup', 'ResourceType', 'Location', 'State', 'Category', 'MtdCost', 'Currency', 'FullyTagged', 'ResourceId')
    Save-Csv '07-Historical-Deleted-Resource-Cost.csv' $Tables.HistoricalRows @('Subscription', 'SubscriptionId', 'ResourceName', 'ResourceGroup', 'ResourceType', 'Location', 'ResourceState', 'Category', 'MatchMethod', 'Cost', 'Currency', 'CostRows', 'PrimaryService', 'PrimaryServiceFamily', 'FullyTagged', 'ResourceId', 'LiveId')

    $CurrencyRows = @($Profiles | ForEach-Object {
            $Pf = $_
            [PSCustomObject]@{
                Currency = $Pf.Currency; MtdActualCost = $Pf.Total
                ActiveSpend = $Pf.Active; ActivePct = $Pf.ActivePct
                HistoricalSpend = $Pf.Historical; HistoricalPct = $Pf.HistoricalPct
                UnmappedSpend = $Pf.Unmapped; UnmappedPct = $Pf.UnmappedPct
                IndicativeMonthEndRunRate = $(if ($null -ne $Pf.RunRate) { $Pf.RunRate } else { 'Not calculated' })
                RunRateNote = $Pf.RunRateNote
                Note = 'No currency conversion performed'
            }
        })
    Save-Csv '08-Cost-By-Currency.csv' $CurrencyRows @('Currency', 'MtdActualCost', 'ActiveSpend', 'ActivePct', 'HistoricalSpend', 'HistoricalPct', 'UnmappedSpend', 'UnmappedPct', 'IndicativeMonthEndRunRate', 'RunRateNote', 'Note')

    # 09 was streamed to disk during processing.

    $SummaryRows = [System.Collections.Generic.List[object]]::new()
    foreach ($P in $Profiles) {
        $SummaryRows.Add([PSCustomObject]@{
                Currency = $P.Currency; MtdActualCost = $P.Total; ActiveSpend = $P.Active; HistoricalSpend = $P.Historical; UnmappedSpend = $P.Unmapped
                ActivePct = $P.ActivePct; HistoricalPct = $P.HistoricalPct; UnmappedPct = $P.UnmappedPct
                IndicativeMonthEndRunRate = $(if ($null -ne $P.RunRate) { $P.RunRate } else { 'Not calculated' })
                RunRateNote = $P.RunRateNote
                TopResource = $(if ($P.TopResource) { $P.TopResource.ResourceName } else { '' })
                TopService = $P.TopServiceName
                CommitmentAnalysisEligible = $P.CommitmentEligible
                EnabledSubscriptions = $Collected.Subscriptions.Count; CurrentArmResources = $Collected.LiveList.Count
                FullyTaggedPct = $Governance.FullyTaggedPct; GovernanceReadiness = $Governance.Maturity
                Headline = $(if ($Profiles.Count -eq 1) { $Headline.Headline } else { (@($Headline.PerCurrency | Where-Object { $_.Currency -eq $P.Currency })[0]).Text })
                KeyConsideration = Get-KeyConsideration $P $Governance
            })
    }
    Save-Csv '10-Executive-Summary.csv' @($SummaryRows) @('Currency', 'MtdActualCost', 'ActiveSpend', 'HistoricalSpend', 'UnmappedSpend', 'ActivePct', 'HistoricalPct', 'UnmappedPct', 'IndicativeMonthEndRunRate', 'RunRateNote', 'TopResource', 'TopService', 'CommitmentAnalysisEligible', 'EnabledSubscriptions', 'CurrentArmResources', 'FullyTaggedPct', 'GovernanceReadiness', 'Headline', 'KeyConsideration')

    Save-Csv '11-Executive-Actions.csv' @($Actions | ForEach-Object { [PSCustomObject]@{ Priority = $_.Priority; Action = $_.Action; Detail = $_.Detail } }) @('Priority', 'Action', 'Detail')

    $GovRows = [System.Collections.Generic.List[object]]::new()
    foreach ($T in $Governance.Tags) {
        $GovRows.Add([PSCustomObject]@{ Measure = "$($T.Tag) coverage"; Scope = 'All live resources'; Count = $T.Tagged; Total = $Governance.TotalResources; Percent = $T.CoveragePct })
        $GovRows.Add([PSCustomObject]@{ Measure = "$($T.Tag) coverage"; Scope = 'Top-level resources'; Count = $T.TopLevelTagged; Total = $Governance.TopLevelResources; Percent = $T.TopLevelCoveragePct })
    }
    $GovRows.Add([PSCustomObject]@{ Measure = 'Fully tagged (all required tags)'; Scope = 'All live resources'; Count = $Governance.FullyTagged; Total = $Governance.TotalResources; Percent = $Governance.FullyTaggedPct })
    $GovRows.Add([PSCustomObject]@{ Measure = 'Fully tagged (all required tags)'; Scope = 'Top-level resources'; Count = $Governance.TopLevelFullyTagged; Total = $Governance.TopLevelResources; Percent = $Governance.TopLevelFullyTaggedPct })
    $GovRows.Add([PSCustomObject]@{ Measure = "Readiness stage: $($Governance.Maturity)"; Scope = 'Tagging-based indicator'; Count = ''; Total = ''; Percent = '' })
    Save-Csv '12-Governance-Readiness.csv' @($GovRows) @('Measure', 'Scope', 'Count', 'Total', 'Percent')

    Save-Csv '13-Cost-By-Tag.csv' $Tables.TagCosts @('TagName', 'TagValue', 'Currency', 'Required', 'Cost', 'Active', 'Historical', 'Unmapped', 'Resources', 'PctOfTotal')
    Save-Csv '15-Untagged-Cost.csv' $TagPlan.UntaggedRows @('ResourceName', 'ResourceType', 'ResourceGroup', 'Subscription', 'ResourceState', 'Cost', 'Currency', 'MissingTags')
    Save-Csv '16-Tag-Quality-Findings.csv' $TagPlan.Quality @('Area', 'Tag', 'Finding', 'BestPractice')
    Save-Csv '14-Final-Calculations.csv' $Calculations @('Check', 'Currency', 'Calculated', 'Expected', 'Difference', 'Result')

    # ---- JSON summary: machine-readable, contains NO tenant / subscription / billing identifiers ---------------------
    $NotAssessed = [ordered]@{
        Budgets                          = 'Not assessed'
        OfficialAzureForecast            = 'Not available from this assessment'
        CostAnomalies                    = 'Not assessed'
        CommitmentUtilizationAndSavings  = 'Not assessed'
    }
    $Json = [ordered]@{
        SchemaVersion   = '1.0'
        ScriptVersion   = $ScriptVersion
        GeneratedUtc    = $GeneratedAtUtc.ToString('yyyy-MM-ddTHH:mm:ssZ', $Invariant)
        ReportingPeriod = [ordered]@{ Month = $MonthKey; BillingDataThroughUtc = $script:MaxDateKey; Basis = 'Month-to-date actual cost' }
        Company         = $script:CompanyName
        Status          = @($StatusItems | ForEach-Object { [ordered]@{ Label = $_.Label; Value = $_.Value; Level = $_.Level } })
        Scope           = [ordered]@{
            EnabledSubscriptionsAssessed = $Collected.Subscriptions.Count
            CurrentArmResources          = $Collected.LiveList.Count
            CurrentResourcesWithNoMtdCost = $Tables.CurrentNoCost.Count
            CostLinesProcessed           = $script:Counters.CostRows
        }
        Headline        = $Headline.Headline
        Currencies      = @($Profiles | ForEach-Object {
                [ordered]@{
                    Currency                  = $_.Currency
                    MtdActualCost             = $_.Total
                    ActiveSpend               = $_.Active
                    HistoricalDeletedSpend    = $_.Historical
                    UnmappedSpend             = $_.Unmapped
                    ActivePct                 = $_.ActivePct
                    HistoricalDeletedPct      = $_.HistoricalPct
                    UnmappedPct               = $_.UnmappedPct
                    IndicativeMonthEndRunRate = $_.RunRate
                    RunRateNote               = $_.RunRateNote
                    TopResource               = $(if ($_.TopResource) { [ordered]@{ Name = $_.TopResource.ResourceName; Type = $_.TopResource.ResourceType; State = $_.TopResource.ResourceState; Cost = $_.TopResource.Cost } } else { $null })
                    TopService                = $_.TopServiceName
                    CommitmentAnalysisEligible = $_.CommitmentEligible
                    CommitmentReasons         = @($_.CommitmentReasons)
                }
            })
        Governance      = [ordered]@{
            RequiredTags   = @($Governance.RequiredTagNames)
            TagCoverage    = @($Governance.Tags | ForEach-Object { [ordered]@{ Tag = $_.Tag; Tagged = $_.Tagged; CoveragePct = $_.CoveragePct } })
            FullyTagged    = $Governance.FullyTagged
            FullyTaggedPct = $Governance.FullyTaggedPct
            ReadinessStage = $Governance.Maturity
            Opportunity    = $Governance.Opportunity
        }
        CostByRequiredTag = @($Tables.TagCosts | Where-Object { $_.Required -eq 'Yes' } | ForEach-Object { [ordered]@{ Tag = $_.TagName; Value = $_.TagValue; Currency = $_.Currency; Cost = $_.Cost; PctOfTotal = $_.PctOfTotal } })
        FinalCalculations = @($Calculations | ForEach-Object { [ordered]@{ Check = $_.Check; Currency = $_.Currency; Calculated = $_.Calculated; Expected = $_.Expected; Result = $_.Result } })
        TaggingPlan     = [ordered]@{ AnyTagsFound = $TagPlan.AnyTagsFound; Situation = $TagPlan.Situation; Recommendations = @($TagPlan.Items); QualityFindings = @($TagPlan.Quality | ForEach-Object { [ordered]@{ Area = $_.Area; Tag = $_.Tag; Finding = $_.Finding; BestPractice = $_.BestPractice } }) }
        Actions         = @($Actions | ForEach-Object { [ordered]@{ Priority = $_.Priority; Action = $_.Action; Detail = $_.Detail } })
        CommitmentStatement = $CommitmentText
        NotAssessed     = $NotAssessed
        AccountingNote  = 'Not an accounting classification. Capital versus operating treatment must follow organizational accounting policy.'
        CurrencyPolicy  = 'Amounts are in the billing currency returned by Azure. No conversion is performed.'
    }
    $Json | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $Dir 'Executive-Summary.json') -Encoding utf8
}
#endregion

#region ---------------------------------------------------------------- Orchestration
try {
    $Collected = Invoke-FinOpsAssessment
    $Tables = New-ReportTables -Collected $Collected

    Write-Banner 'Building executive analysis'
    $Profiles = @($Tables.CurrencyCodes | ForEach-Object {
            New-CurrencyProfile -Currency $_ -ResourceCosts $Tables.ResourceCosts -ServiceTotals $Tables.ServiceTotals -DataThroughKey $script:MaxDateKey
        })
    $Governance = Get-GovernanceReadiness -LiveResources @($Collected.LiveList) -RequiredTagNames $RequiredTags
    $Headline = New-ExecutiveHeadline -Profiles $Profiles -Governance $Governance -LiveResourceCount $Collected.LiveList.Count -SubscriptionCount $Collected.Subscriptions.Count
    $UnmappedItems = 0
    foreach ($P in $Profiles) { $UnmappedItems += [int]$P.UnmappedItemCount }
    $Actions = @(New-ExecutiveActions -Profiles $Profiles -Governance $Governance -UnmappedItems $UnmappedItems)
    $CommitmentText = Get-CommitmentStatement $Profiles
    $TagPlan = New-TaggingPlan -Tables $Tables -Profiles $Profiles -Governance $Governance -LiveResources @($Collected.LiveList)
    $Calculations = @(New-FinalCalculations -Collected $Collected -Tables $Tables -Profiles $Profiles)

    # Status badges are computed from what actually happened in this run.
    $EnabledCount = $Collected.Subscriptions.Count
    $AssessedCount = @($Collected.SubStatus | Where-Object { $_.CostAssessed -and $script:AssessedSubIds.ContainsKey($_.Id) }).Count
    $CacheCount = @($Collected.SubStatus | Where-Object { $_.CostSource -eq 'Cache' }).Count
    $CostVerified = ($AssessedCount -eq $EnabledCount)
    $StatusItems = @(
        [PSCustomObject]@{ Label = 'Cost Data'; Value = $(if ($CostVerified) { 'Verified' } else { 'Incomplete' }); Level = $(if ($CostVerified) { 'ok' } else { 'warn' })
            Detail = "Azure cost-details reports processed for $AssessedCount of $EnabledCount subscription(s)" + $(if ($CacheCount -gt 0) { "; $CacheCount reused a recent local cache" } else { '' }) }
        [PSCustomObject]@{ Label = 'Subscription Coverage'; Value = $(if ($AssessedCount -eq $EnabledCount) { 'Complete' } else { 'Partial' }); Level = $(if ($AssessedCount -eq $EnabledCount) { 'ok' } else { 'warn' })
            Detail = "$AssessedCount of $EnabledCount enabled subscription(s) assessed" }
        [PSCustomObject]@{ Label = 'Current Resource Inventory'; Value = $(if (-not $Tables.IntegrityOk) { 'Review needed' } elseif ($script:Counters.DeletionUnverified -gt 0) { 'Reconciled - deletions not all verified' } else { 'Reconciled' }); Level = $(if ($Tables.IntegrityOk -and $script:Counters.DeletionUnverified -eq 0) { 'ok' } else { 'warn' })
            Detail = "$($Collected.LiveList.Count) live resource(s) enumerated and reconciled to billing lines; $($script:Counters.DeletionConfirmed) deletion(s) confirmed by direct lookup, $($script:Counters.DeletionUnverified) unverified" }
        [PSCustomObject]@{ Label = 'Currency'; Value = $(if ($Profiles.Count -gt 1) { 'Validated (multiple, kept separate)' } else { 'Validated' }); Level = 'ok'
            Detail = 'Billing currency taken from Azure on every non-zero cost line; currencies are never combined' }
        [PSCustomObject]@{ Label = 'Report Completeness'; Value = $(if ($Tables.IntegrityOk -and $CostVerified) { 'Complete' } else { 'Incomplete' }); Level = $(if ($Tables.IntegrityOk -and $CostVerified) { 'ok' } else { 'warn' })
            Detail = 'Totals agree across resource, service and resource-group views' }
    )

    Write-ExecutiveHtml -Collected $Collected -Tables $Tables -Profiles $Profiles -Governance $Governance -Headline $Headline -Actions $Actions -StatusItems $StatusItems -CommitmentText $CommitmentText -Calculations $Calculations -TagPlan $TagPlan
    $HtmlFile = Join-Path $Collected.ReportDir "$(Get-SafeName $script:CompanyName)-Azure-FinOps-Executive-Assessment-$MonthKey.html"
    Set-Content -LiteralPath $HtmlFile -Value $script:Html.ToString() -Encoding utf8

    Export-Deliverables -Collected $Collected -Tables $Tables -Profiles $Profiles -Governance $Governance -Headline $Headline -Actions $Actions -StatusItems $StatusItems -CommitmentText $CommitmentText -Calculations $Calculations -TagPlan $TagPlan

    Write-Banner 'ASSESSMENT COMPLETE' 'Green'
    foreach ($P in $Profiles) {
        Write-Host ("  {0}: MTD {1} | Active {2} | Historical/Deleted {3} | Unmapped {4}" -f $P.Currency, (Format-Amount $P.Total), (Format-Amount $P.Active), (Format-Amount $P.Historical), (Format-Amount $P.Unmapped))
    }
    Write-Host "  Report folder : $($Collected.ReportDir)"
    Write-Host "  HTML report   : $HtmlFile"
    if (-not $NoOpen) {
        try { Invoke-Item -LiteralPath $HtmlFile } catch { Write-Note 'Could not open the report automatically; open the HTML file manually.' }
    }}
catch {
    Write-Host ''
    Write-Host 'ASSESSMENT ABORTED - no report was produced, so no partial or misleading figures exist.' -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}
#endregion