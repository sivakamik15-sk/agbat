# ============================================================================
#  Banner Alert - bulk test file generator (UAT)
#
#  Reads TWO sheets that you export from UAT:
#     policies.csv   the UAT policy numbers          (column PolicyNumber__c)
#     content.csv    the banner messages you want to test  (column Content__c)
#  and writes a folder on your Desktop with N rule files, one rule per file,
#  each with only the three keys: message, description, policyRecords.
#
#  It NEVER invents a policy number. It only deploys nothing - you do that.
#
#  Edit the SETTINGS below if you need to, save, then run the .bat file.
# ============================================================================
param(
    [string]$InputFolder = $PSScriptRoot,
    [string]$OutputRoot  = [Environment]::GetFolderPath('Desktop')
)

# ============================== SETTINGS ====================================

$PolicyFile  = 'policies.csv'
$ContentFile = 'content.csv'
$OutputName  = 'Tester Bulk Data Load Banner Alert'

$Prefix          = 'CTX_POLICY_'
$FirstFileNumber = 801            # files are CTX_POLICY_801, 802, ... easy to find and delete
$FileCount       = 38
$MaxPerFile      = 500            # at most this many policies in one file

$ThreeBannerPolicies = 10         # this many policies are put in 3 files -> they show 3 banners
$TwoBannerPolicies   = 10         # this many policies are put in 2 files -> they show 2 banners
$UnlistedReserve     = 5          # this many policies are kept OUT of every file -> must show nothing

# Which message each file gets:
#   fill      = files use your content sheet rows one by one; when the rows run out, the rest get a generated test message
#   alternate = odd files use a message from your content sheet, even files a generated test message
#   all       = every file uses your content sheet (cycled)
#   none      = every file uses a generated test message
$ContentMode = 'fill'

# ----------------------------------------------------------------------------
$ErrorActionPreference = 'Stop'

function Write-Step { param($m) Write-Host ('') ; Write-Host ('>>> ' + $m) -ForegroundColor Cyan }
function Write-Ok   { param($m) Write-Host ('    OK  ' + $m) -ForegroundColor Green }
function Write-Warn { param($m) Write-Host ('    !!  ' + $m) -ForegroundColor Yellow }
function Stop-Now   { param($m) Write-Host ('    XX  ' + $m) -ForegroundColor Red; exit 1 }

# the values of one column; uses the named column if present, otherwise the first real column
function Get-ColumnValues {
    param($Rows, [string[]]$Names)
    if ($Rows.Count -eq 0) { return @() }
    $props = @($Rows[0].PSObject.Properties.Name)
    $col = $null
    foreach ($n in $Names) { if ($props -contains $n) { $col = $n; break } }
    if ($col -eq $null) {
        foreach ($p in $props) { if ($p -ne '_' -and $p -ne '') { $col = $p; break } }
    }
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($r in $Rows) { $out.Add([string]$r.$col) }
    return $out.ToArray()
}

# a safe JSON string: quotes, backslashes, line breaks and control characters are escaped
function ConvertTo-JsonString {
    param([string]$Text)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    foreach ($ch in $Text.ToCharArray()) {
        $code = [int]$ch
        if     ($code -eq 34) { [void]$sb.Append('\"') }
        elseif ($code -eq 92) { [void]$sb.Append([string][char]92 + [string][char]92) }
        elseif ($code -eq 10) { [void]$sb.Append('\n') }
        elseif ($code -eq 13) { [void]$sb.Append('\r') }
        elseif ($code -eq 9)  { [void]$sb.Append('\t') }
        elseif ($code -lt 32) { [void]$sb.Append(('\u{0:x4}' -f $code)) }
        else                  { [void]$sb.Append($ch) }
    }
    [void]$sb.Append('"')
    return $sb.ToString()
}

# UTF-8 without a byte order mark, which is what Apex expects
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
function Save-Text {
    param([string]$Path, [string]$Text)
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    [System.IO.File]::WriteAllText($Path, $Text, $utf8NoBom)
}

# ============================== READ THE SHEETS =============================
Write-Step 'Reading the two sheets'
$polPath = Join-Path $InputFolder $PolicyFile
$conPath = Join-Path $InputFolder $ContentFile
if (-not (Test-Path $polPath)) { Stop-Now ("Missing $PolicyFile in $InputFolder. Export the UAT policy numbers to it.") }
if (-not (Test-Path $conPath)) { Stop-Now ("Missing $ContentFile in $InputFolder. Put your banner messages in it.") }

$polRows = @(Import-Csv -Path $polPath -Encoding UTF8)
$conRows = @(Import-Csv -Path $conPath -Encoding UTF8)

$seen = New-Object 'System.Collections.Generic.HashSet[string]'
$policies = New-Object System.Collections.Generic.List[string]
foreach ($v in (Get-ColumnValues $polRows @('PolicyNumber__c','PolicyNumber','Policy Number'))) {
    $p = $v.Trim()
    if ($p -ne '' -and $seen.Add($p.ToUpper())) { $policies.Add($p) }
}
$messages = New-Object System.Collections.Generic.List[string]
foreach ($v in (Get-ColumnValues $conRows @('Content__c','Message','Content'))) {
    if ($v.Trim() -ne '') { $messages.Add($v.Trim()) }
}
$descriptions = @()
if ($conRows.Count -gt 0 -and (@($conRows[0].PSObject.Properties.Name) -contains 'Description')) {
    $descriptions = @(Get-ColumnValues $conRows @('Description'))
}
Write-Ok ("$($policies.Count) distinct policy numbers, $($messages.Count) messages")

$needed = $ThreeBannerPolicies + $TwoBannerPolicies + $UnlistedReserve + $FileCount
if ($policies.Count -lt $needed) { Stop-Now ("Need at least $needed policy numbers, found $($policies.Count).") }
if ($ContentMode -ne 'none' -and $messages.Count -eq 0) { Stop-Now 'content sheet has no messages' }

# ============================== SPLIT THE POLICIES ==========================
$idx = 0
$three = @($policies[$idx..($idx + $ThreeBannerPolicies - 1)]); $idx += $ThreeBannerPolicies
$two   = @($policies[$idx..($idx + $TwoBannerPolicies - 1)]);   $idx += $TwoBannerPolicies
$unlisted = @($policies[$idx..($idx + $UnlistedReserve - 1)]);  $idx += $UnlistedReserve
$pool  = @($policies[$idx..($policies.Count - 1)])

# room kept free in each file for the overlap policies
$room = $ThreeBannerPolicies + $TwoBannerPolicies
$chunk = [Math]::Min($MaxPerFile - $room, [Math]::Floor($pool.Count / $FileCount))
if ($chunk -lt 1) { Stop-Now 'not enough policy numbers for that many files' }

$fileLists = @()
for ($i = 0; $i -lt $FileCount; $i++) {
    $fileLists += ,(New-Object System.Collections.Generic.List[string])
    for ($j = 0; $j -lt $chunk; $j++) { $fileLists[$i].Add($pool[$i * $chunk + $j]) }
}
# overlap: 3 neighbouring files for the "three" group, 2 for the "two" group
for ($k = 0; $k -lt $three.Count; $k++) {
    $s = $k % $FileCount
    foreach ($o in 0..2) { $fileLists[($s + $o) % $FileCount].Add($three[$k]) }
}
for ($k = 0; $k -lt $two.Count; $k++) {
    $s = ($k * 3 + 1) % $FileCount
    foreach ($o in 0..1) { $fileLists[($s + $o) % $FileCount].Add($two[$k]) }
}

# ============================== WRITE THE FILES =============================
Write-Step 'Writing the rule files'
$out = Join-Path $OutputRoot $OutputName
$resDir = Join-Path $out 'staticresources'
if (Test-Path $out) { Remove-Item -Recurse -Force $out }
New-Item -ItemType Directory -Force -Path $resDir | Out-Null

$metaXml = '<?xml version="1.0" encoding="UTF-8"?>' + "`r`n" +
 '<StaticResource xmlns="http://soap.sforce.com/2006/04/metadata">' + "`r`n" +
 '    <cacheControl>Public</cacheControl>' + "`r`n" +
 '    <contentType>application/json</contentType>' + "`r`n" +
 '</StaticResource>' + "`r`n"

$plan = New-Object System.Collections.Generic.List[string]
$msgCursor = 0
for ($i = 0; $i -lt $FileCount; $i++) {
    $num  = $FirstFileNumber + $i
    $name = $Prefix + $num
    $useSheet = switch ($ContentMode) { 'all' { $true } 'none' { $false } 'fill' { $i -lt $messages.Count } default { ($i % 2) -eq 0 } }
    if ($useSheet) {
        $row = $msgCursor % $messages.Count
        $msg = $messages[$row]
        $desc = if ($descriptions.Count -gt $row -and $descriptions[$row].Trim() -ne '') { $descriptions[$row].Trim() } else { "TEST - message $($row + 1) from the content sheet" }
        $msgCursor++
        $kind = "content sheet row $($row + 1)"
    } else {
        $msg  = "test policy for this rule ($name)"
        $desc = "TEST - generated rule $name"
        $kind = 'generated test message'
    }
    $list = $fileLists[$i]
    $quoted = @($list | ForEach-Object { ConvertTo-JsonString $_ })
    $json = "{`n  " + '"message": ' + (ConvertTo-JsonString $msg) + ",`n  " +
            '"description": ' + (ConvertTo-JsonString $desc) + ",`n  " +
            '"policyRecords": [' + ($quoted -join ', ') + "]`n}`n"
    Save-Text (Join-Path $resDir ($name + '.json')) $json
    Save-Text (Join-Path $resDir ($name + '.resource-meta.xml')) $metaXml
    $plan.Add(("{0}  {1,4} policies  {2}  e.g. open {3}" -f $name, $list.Count, $kind, $list[0]))
}
Write-Ok "$FileCount rule files written to $resDir"

# ============================== TEST PLAN ===================================
$tp = New-Object System.Collections.Generic.List[string]
$tp.Add('BULK BANNER TEST PLAN'); $tp.Add('')
$tp.Add("Files: $Prefix$FirstFileNumber to $Prefix$($FirstFileNumber + $FileCount - 1)"); $tp.Add('')
$tp.Add("Policies that must show THREE banners:")
foreach ($p in $three) { $tp.Add("   $p") }
$tp.Add(''); $tp.Add("Policies that must show TWO banners:")
foreach ($p in $two) { $tp.Add("   $p") }
$tp.Add(''); $tp.Add("Policies in NO file (must show NO banner):")
foreach ($p in $unlisted) { $tp.Add("   $p") }
$tp.Add(''); $tp.Add('One policy per file (must show that file''s banner):')
foreach ($l in $plan) { $tp.Add("   $l") }
Save-Text (Join-Path $out 'test-plan.txt') (($tp -join "`r`n") + "`r`n")
Write-Ok 'test-plan.txt written'

Write-Step 'Done - nothing was deployed'
Write-Host "    Folder: $out"
Write-Host '    Deploy yourself when ready, e.g.:'
Write-Host "      sf project deploy start --source-dir `"$resDir`" --target-org uat --ignore-conflicts"
