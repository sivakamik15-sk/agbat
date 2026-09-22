# ============================================================================
#  Contextual Banner Alert - write the two config files
#
#  Writes PolicyBannerConfig.json and ContactBannerConfig.json into the
#  project's staticresources folder.
#
#  IT DOES NOT DEPLOY. The deploy command is printed at the end for you
#  to run yourself, after you have checked the files.
#
#  Existing files are backed up to *.bak before being overwritten.
#
#  HOW TO USE
#    1. Fill in the SETTINGS block below with real values from the org
#    2. Save this file
#    3. Double-click write-config.bat
#    4. Run the deploy command it prints
# ============================================================================

# ============================== SETTINGS ====================================

$ProjectPath = 'C:\Temp\contextualBanner'
$OrgAlias    = 'dev4cc'          # only used in the printed deploy command


# ------------------------------- POLICY -------------------------------------
# File: PolicyBannerConfig.json     Object: PolicyMaster__c
# Matching on PolicyNumber__c

# Rule 1 - a SET of policies sharing one message
$PolicySet        = @('LL013645400')
$PolicySetMsg     = 'GROUP MESSAGE - this policy belongs to the affected group.'
$PolicySetVariant = 'warning'                   # warning | error | info
$IncludePolicySet = $true

# Rule 2 - a SINGLE policy with its own message
$PolicySingle        = @('REPLACE_SINGLE_POLICY')
$PolicySingleMsg     = 'SINGLE MESSAGE - this message is only for one policy.'
$PolicySingleVariant = 'error'
$IncludePolicySingle = $false                   # set $true once you have a value

# Rule 3 - DERIVED from a related-record condition
#   Resolve the condition with a query, then paste the resulting
#   policy numbers here. SourceQuery is documentation only.
$PolicyDerived        = @('REPLACE_POLICY_1', 'REPLACE_POLICY_2')
$PolicyDerivedMsg     = 'RELATED TEST - this policy has a contact in the affected postcode.'
$PolicyDerivedVariant = 'info'
$PolicyDerivedSource  = "SELECT Policy__r.PolicyNumber__c FROM PolicyContact__c WHERE Contact__r.MailingPostalCode LIKE 'REPLACE_POSTCODE%'"
$IncludePolicyDerived = $true


# ------------------------------- CONTACT ------------------------------------
# File: ContactBannerConfig.json    Object: Contact

# Rule 1 - a SET of agents sharing one message
$ContactField     = 'LSW_Life_Agent_Number__c'
$AgentSet         = @('66666')
$AgentSetMsg      = 'GROUP MESSAGE - this agent belongs to the affected group.'
$AgentSetVariant  = 'warning'
$IncludeAgentSet  = $true

# Rule 2 - a SINGLE agent with its own message
$AgentSingle        = @('REPLACE_SINGLE_AGENT')
$AgentSingleMsg     = 'SINGLE MESSAGE - this message is only for one agent.'
$AgentSingleVariant = 'error'
$IncludeAgentSingle = $false

# Rule 3 - DERIVED from a related-record condition
#   Matches on the Contact record Id, which getRecord always provides.
$ContactDerived        = @('REPLACE_CONTACT_ID_1', 'REPLACE_CONTACT_ID_2')
$ContactDerivedMsg     = 'RELATED TEST - this client holds one of the affected policies.'
$ContactDerivedVariant = 'error'
$ContactDerivedSource  = "SELECT Contact__c FROM PolicyContact__c WHERE Policy__r.PolicyNumber__c = 'REPLACE_POLICY_NUMBER'"
$IncludeContactDerived = $false                 # set $true once you have Ids

# ============================================================================
# ===================  nothing below here needs editing  =====================
# ============================================================================

$ErrorActionPreference = 'Stop'
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Write-Step { param($m) Write-Host "`n>>> $m" -ForegroundColor Cyan }
function Write-Ok   { param($m) Write-Host "    OK  $m" -ForegroundColor Green }
function Write-Warn { param($m) Write-Host "    !!  $m" -ForegroundColor Yellow }
function Write-Err  { param($m) Write-Host "    XX  $m" -ForegroundColor Red }

function To-JsonArray {
    param([string[]]$Values)
    if (-not $Values -or $Values.Count -eq 0) { return '[]' }
    $quoted = $Values | ForEach-Object {
        '"' + ($_ -replace '\\', '\\' -replace '"', '\"') + '"'
    }
    return '[' + ($quoted -join ', ') + ']'
}

function Esc {
    param([string]$Text)
    return ($Text -replace '\\', '\\' -replace '"', '\"')
}

# --------------------------------------------------------------- 1. checks

Write-Step 'Checking the project'

if (-not (Test-Path (Join-Path $ProjectPath 'sfdx-project.json'))) {
    Write-Err "No SFDX project at $ProjectPath"
    Write-Host '    Fix the $ProjectPath setting at the top of this script.' -ForegroundColor Red
    exit 1
}
Write-Ok $ProjectPath

$srDir = Join-Path $ProjectPath 'force-app\main\default\staticresources'
if (-not (Test-Path $srDir)) {
    New-Item -ItemType Directory -Force -Path $srDir | Out-Null
    Write-Ok 'created staticresources folder'
}

# ------------------------------------------------- 2. refuse placeholders

Write-Step 'Checking for unreplaced placeholders'

$toCheck = @()
if ($IncludePolicySet)     { $toCheck += $PolicySet }
if ($IncludePolicySingle)  { $toCheck += $PolicySingle }
if ($IncludePolicyDerived) { $toCheck += $PolicyDerived }
if ($IncludeAgentSet)      { $toCheck += $AgentSet }
if ($IncludeAgentSingle)   { $toCheck += $AgentSingle }
if ($IncludeContactDerived){ $toCheck += $ContactDerived }

$bad = $toCheck | Where-Object { $_ -like 'REPLACE_*' -or $_ -like 'POLICY_?' -or $_ -like 'AGENT_?' }

if ($bad) {
    Write-Err 'these values are still placeholders:'
    $bad | Select-Object -Unique | ForEach-Object { Write-Host "        $_" -ForegroundColor Red }
    Write-Host ''
    Write-Host '    NOTHING WAS WRITTEN. Replace them with real values from the org,' -ForegroundColor Red
    Write-Host '    or set the matching $Include... switch to $false to leave that rule out.' -ForegroundColor Red
    exit 1
}
Write-Ok 'no placeholders in the enabled rules'

# ------------------------------------------------------- 3. build policy

Write-Step 'Building PolicyBannerConfig.json'

$policyRules = @()

if ($IncludePolicySet) {
    $policyRules += @"
    {
      "Id": "SET_OF_POLICIES",
      "Variant": "$PolicySetVariant",
      "Message": "$(Esc $PolicySetMsg)",
      "PolicyRecords": $(To-JsonArray $PolicySet)
    }
"@
    Write-Ok "SET_OF_POLICIES - $($PolicySet.Count) values"
}

if ($IncludePolicySingle) {
    $policyRules += @"
    {
      "Id": "SINGLE_POLICY",
      "Variant": "$PolicySingleVariant",
      "Message": "$(Esc $PolicySingleMsg)",
      "PolicyRecords": $(To-JsonArray $PolicySingle)
    }
"@
    Write-Ok "SINGLE_POLICY - $($PolicySingle.Count) values"
}

if ($IncludePolicyDerived) {
    $policyRules += @"
    {
      "Id": "RELATED_POSTCODE_DERIVED",
      "Variant": "$PolicyDerivedVariant",
      "Derived": true,
      "SourceQuery": "$(Esc $PolicyDerivedSource)",
      "Message": "$(Esc $PolicyDerivedMsg)",
      "PolicyRecords": $(To-JsonArray $PolicyDerived)
    }
"@
    Write-Ok "RELATED_POSTCODE_DERIVED - $($PolicyDerived.Count) values"
}

$policyJson = "{`r`n  `"Version`": 1,`r`n  `"Rules`": [`r`n" `
            + ($policyRules -join ",`r`n") `
            + "`r`n  ]`r`n}`r`n"

# ------------------------------------------------------ 4. build contact

Write-Step 'Building ContactBannerConfig.json'

$contactRules = @()

if ($IncludeAgentSet) {
    $contactRules += @"
    {
      "Id": "SET_OF_AGENTS",
      "Variant": "$AgentSetVariant",
      "Message": "$(Esc $AgentSetMsg)",
      "Conditions": [
        {
          "Field": "$ContactField",
          "Operator": "IN",
          "Values": $(To-JsonArray $AgentSet)
        }
      ]
    }
"@
    Write-Ok "SET_OF_AGENTS - $($AgentSet.Count) values"
}

if ($IncludeAgentSingle) {
    $contactRules += @"
    {
      "Id": "SINGLE_AGENT",
      "Variant": "$AgentSingleVariant",
      "Message": "$(Esc $AgentSingleMsg)",
      "Conditions": [
        {
          "Field": "$ContactField",
          "Operator": "IN",
          "Values": $(To-JsonArray $AgentSingle)
        }
      ]
    }
"@
    Write-Ok "SINGLE_AGENT - $($AgentSingle.Count) values"
}

if ($IncludeContactDerived) {
    $contactRules += @"
    {
      "Id": "RELATED_POLICY_DERIVED",
      "Variant": "$ContactDerivedVariant",
      "Derived": true,
      "SourceQuery": "$(Esc $ContactDerivedSource)",
      "Message": "$(Esc $ContactDerivedMsg)",
      "Conditions": [
        {
          "Field": "Id",
          "Operator": "IN",
          "Values": $(To-JsonArray $ContactDerived)
        }
      ]
    }
"@
    Write-Ok "RELATED_POLICY_DERIVED - $($ContactDerived.Count) values"
}

$contactJson = "{`r`n  `"Version`": 1,`r`n  `"Rules`": [`r`n" `
             + ($contactRules -join ",`r`n") `
             + "`r`n  ]`r`n}`r`n"

# ----------------------------------------------- 5. back up and write

Write-Step 'Backing up and writing'

foreach ($pair in @(
    @{ Name = 'PolicyBannerConfig.json';  Content = $policyJson  },
    @{ Name = 'ContactBannerConfig.json'; Content = $contactJson }
)) {
    $path = Join-Path $srDir $pair.Name

    if (Test-Path $path) {
        Copy-Item $path "$path.bak" -Force
        Write-Ok "backed up $($pair.Name) -> $($pair.Name).bak"
    }

    [System.IO.File]::WriteAllText($path, $pair.Content, $utf8NoBom)
    Write-Ok "wrote $($pair.Name)"
}

# make sure the meta files exist
$resourceMeta = @'
<?xml version="1.0" encoding="UTF-8"?>
<StaticResource xmlns="http://soap.sforce.com/2006/04/metadata">
    <cacheControl>Public</cacheControl>
    <contentType>application/json</contentType>
</StaticResource>
'@

foreach ($n in @('PolicyBannerConfig', 'ContactBannerConfig')) {
    $metaPath = Join-Path $srDir "$n.resource-meta.xml"
    if (-not (Test-Path $metaPath)) {
        [System.IO.File]::WriteAllText($metaPath, $resourceMeta, $utf8NoBom)
        Write-Ok "created $n.resource-meta.xml"
    }
}

# ------------------------------------------------------- 6. validate

Write-Step 'Validating the JSON'

$allValid = $true
foreach ($n in @('PolicyBannerConfig', 'ContactBannerConfig')) {
    $p = Join-Path $srDir "$n.json"
    try {
        $parsed = Get-Content $p -Raw | ConvertFrom-Json
        Write-Ok "$n.json parses - $($parsed.Rules.Count) rules"
    } catch {
        Write-Err "$n.json is NOT valid JSON: $_"
        $allValid = $false
    }
}
if (-not $allValid) { exit 1 }

# ------------------------------------------------------- 7. show them

Write-Step 'PolicyBannerConfig.json'
Write-Host $policyJson -ForegroundColor DarkGray

Write-Step 'ContactBannerConfig.json'
Write-Host $contactJson -ForegroundColor DarkGray

# ---------------------------------------------------- 8. what to do next

Write-Host @"

============================================================
  FILES WRITTEN - NOTHING HAS BEEN DEPLOYED
============================================================

  $srDir
      PolicyBannerConfig.json
      ContactBannerConfig.json
  (previous versions saved as .bak)

------------------------------------------------------------
  NEXT - run these yourself
------------------------------------------------------------

  1. Deploy

       cd $ProjectPath
       sf project deploy start --source-dir force-app/main/default/staticresources --target-org $OrgAlias --ignore-conflicts

  2. If the CLI crashes with "Missing message metadata.transfer:Finalizing",
     the deploy still went through. Check it with:

       sf project deploy report --use-most-recent --target-org $OrgAlias

  3. VERIFY IN THE ORG before testing any record

       Setup -> Static Resources -> PolicyBannerConfig  -> View file
       Setup -> Static Resources -> ContactBannerConfig -> View file

     Confirm your real values are there. If you still see old values,
     the deploy did not take effect and there is no point checking a record.

  4. Test with a hard refresh on every page

       Ctrl+Shift+R

============================================================
"@ -ForegroundColor White
