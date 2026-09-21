# ============================================================================
#  Contextual Banner Alert - update script
#
#  1. Rewrites PolicyBannerConfig.json and ContactBannerConfig.json with the
#     "set of records" + "single record" test rules.
#  2. Refreshes the LWC with the latest code (includes the icon-variant fix).
#  3. Validates the JSON.
#  4. Optionally deploys.
#
#  EDIT THE SETTINGS BLOCK BELOW, save, then run update.bat.
# ============================================================================

# ============================== SETTINGS ====================================

# --- where the project lives -------------------------------------------------
$ProjectPath = 'C:\Temp\contextualBanner'

# --- org alias used for deployment ------------------------------------------
$OrgAlias = 'dev4cc'

# --- deploy automatically after writing the files? --------------------------
$DeployAfterWrite = $true

# --- also refresh the LWC code, not just the config? ------------------------
$UpdateComponent = $true


# ============================ POLICY RULES ==================================

# A SET of policies that should all show the SAME message
$PolicySet = @(
    'POLICY_A',
    'POLICY_B',
    'POLICY_C'
)
$PolicySetMessage = 'GROUP MESSAGE - this policy belongs to the affected group.'
$PolicySetVariant = 'warning'          # warning | error | info

# A SINGLE policy with its OWN separate message
$PolicySingle = @(
    'POLICY_D'
)
$PolicySingleMessage = 'SINGLE MESSAGE - this message is only for policy D.'
$PolicySingleVariant = 'error'


# =========================== CONTACT RULES ==================================

# Which contact field to match on
$ContactField = 'LSW_Life_Agent_Number__c'

# A SET of agents that should all show the SAME message
$AgentSet = @(
    'AGENT_1',
    'AGENT_2',
    'AGENT_3'
)
$AgentSetMessage = 'GROUP MESSAGE - this agent belongs to the affected group.'
$AgentSetVariant = 'warning'

# A SINGLE agent with its OWN separate message
$AgentSingle = @(
    'AGENT_4'
)
$AgentSingleMessage = 'SINGLE MESSAGE - this message is only for agent 4.'
$AgentSingleVariant = 'error'

# ============================================================================
# ===================  nothing below here needs editing  =====================
# ============================================================================

$ErrorActionPreference = 'Stop'
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Write-Step { param($m) Write-Host "`n>>> $m" -ForegroundColor Cyan }
function Write-Ok   { param($m) Write-Host "    OK  $m" -ForegroundColor Green }
function Write-Warn { param($m) Write-Host "    !!  $m" -ForegroundColor Yellow }
function Write-Err  { param($m) Write-Host "    XX  $m" -ForegroundColor Red }

function Save-File {
    param($Path, $Content)
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
    Write-Ok (Split-Path -Leaf $Path)
}

# renders a PowerShell array as a JSON array string
function To-JsonArray {
    param([string[]]$Values)
    if (-not $Values -or $Values.Count -eq 0) { return '[]' }
    $quoted = $Values | ForEach-Object { '"' + ($_ -replace '\\', '\\' -replace '"', '\"') + '"' }
    return '[' + ($quoted -join ', ') + ']'
}

function Escape-Json {
    param([string]$Text)
    return ($Text -replace '\\', '\\' -replace '"', '\"')
}

# ------------------------------------------------------------------- checks

Write-Step 'Checking the project'

if (-not (Test-Path (Join-Path $ProjectPath 'sfdx-project.json'))) {
    Write-Err "No SFDX project found at $ProjectPath"
    Write-Host "    Fix the `$ProjectPath setting at the top of this script." -ForegroundColor Red
    exit 1
}
Write-Ok "found $ProjectPath"

$srDir  = Join-Path $ProjectPath 'force-app\main\default\staticresources'
$lwcDir = Join-Path $ProjectPath 'force-app\main\default\lwc\contextualBannerAlert'

# --------------------------------------------------- warn about placeholders

$placeholders = @()
$PolicySet    | Where-Object { $_ -like 'POLICY_*' } | ForEach-Object { $placeholders += $_ }
$PolicySingle | Where-Object { $_ -like 'POLICY_*' } | ForEach-Object { $placeholders += $_ }
$AgentSet     | Where-Object { $_ -like 'AGENT_*'  } | ForEach-Object { $placeholders += $_ }
$AgentSingle  | Where-Object { $_ -like 'AGENT_*'  } | ForEach-Object { $placeholders += $_ }

if ($placeholders.Count -gt 0) {
    Write-Warn "these values are still placeholders: $($placeholders -join ', ')"
    Write-Warn 'no banner will appear for them - replace with real values from the org'
}

# --------------------------------------------------------- policy config

Write-Step 'Writing PolicyBannerConfig.json'

$policyJson = @"
{
  "Version": 1,
  "Rules": [
    {
      "Id": "SET_OF_POLICIES",
      "Variant": "$PolicySetVariant",
      "Message": "$(Escape-Json $PolicySetMessage)",
      "PolicyRecords": $(To-JsonArray $PolicySet)
    },
    {
      "Id": "SINGLE_POLICY",
      "Variant": "$PolicySingleVariant",
      "Message": "$(Escape-Json $PolicySingleMessage)",
      "PolicyRecords": $(To-JsonArray $PolicySingle)
    }
  ]
}
"@

Save-File (Join-Path $srDir 'PolicyBannerConfig.json') $policyJson

# -------------------------------------------------------- contact config

Write-Step 'Writing ContactBannerConfig.json'

$contactJson = @"
{
  "Version": 1,
  "Rules": [
    {
      "Id": "SET_OF_AGENTS",
      "Variant": "$AgentSetVariant",
      "Message": "$(Escape-Json $AgentSetMessage)",
      "Conditions": [
        {
          "Field": "$ContactField",
          "Operator": "IN",
          "Values": $(To-JsonArray $AgentSet)
        }
      ]
    },
    {
      "Id": "SINGLE_AGENT",
      "Variant": "$AgentSingleVariant",
      "Message": "$(Escape-Json $AgentSingleMessage)",
      "Conditions": [
        {
          "Field": "$ContactField",
          "Operator": "IN",
          "Values": $(To-JsonArray $AgentSingle)
        }
      ]
    }
  ]
}
"@

Save-File (Join-Path $srDir 'ContactBannerConfig.json') $contactJson

# ---------------------------------------------- make sure the meta files exist

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
        Save-File $metaPath $resourceMeta
    }
}

# ------------------------------------------------------------ validate JSON

Write-Step 'Validating the JSON'

$valid = $true
foreach ($n in @('PolicyBannerConfig', 'ContactBannerConfig')) {
    $p = Join-Path $srDir "$n.json"
    try {
        $parsed = Get-Content $p -Raw | ConvertFrom-Json
        Write-Ok "$n.json parses - $($parsed.Rules.Count) rules"
    } catch {
        Write-Err "$n.json is NOT valid JSON: $_"
        $valid = $false
    }
}
if (-not $valid) { exit 1 }

# -------------------------------------------------------------- component

if ($UpdateComponent) {

Write-Step 'Refreshing the component'

$lwcJs = @'
import { LightningElement, api, wire } from 'lwc';
import { getRecord } from 'lightning/uiRecordApi';

import POLICY_MESSAGES from '@salesforce/resourceUrl/PolicyBannerConfig';
import CONTACT_MESSAGES from '@salesforce/resourceUrl/ContactBannerConfig';

// Which config file to use for which object.
// Adding a third object = one entry here + one <object> in the meta file.
const FILES = {
    'PolicyMaster__c': POLICY_MESSAGES,
    'Contact': CONTACT_MESSAGES
};

// lightning-icon has no 'info' variant - use inverse on the dark info theme
const ICON_VARIANT = {
    warning: 'warning',
    error: 'error',
    info: 'inverse'
};

export default class ContextualBannerAlert extends LightningElement {
    @api recordId;
    @api objectApiName;      // set automatically by the platform on a record page

    rules = null;            // parsed from the static resource
    fieldList = [];          // derived from the rules - drives the @wire below
    recordData = null;       // this record, via Lightning Data Service
    messages = [];           // what the template renders

    // ---------------------------------------------- load the config file

    async connectedCallback() {
        const fileUrl = FILES[this.objectApiName];
        if (!fileUrl) {
            console.log('Contextual banner - no config file for ' + this.objectApiName);
            return;
        }

        try {
            const response = await fetch(fileUrl);
            if (!response.ok) {
                throw new Error('HTTP ' + response.status + ' loading config file');
            }

            const file = await response.json();
            this.rules = Array.isArray(file.Rules) ? file.Rules : [];
            console.log('Contextual banner - loaded ' + this.rules.length + ' rules');

            // Work out which fields to request, straight from the rules.
            // This is what makes the component configurable: a new rule using
            // a new field needs no code change.
            const needed = new Set();
            for (const rule of this.rules) {
                for (const c of this.conditionsFor(rule)) {
                    if (c.Field) { needed.add(this.objectApiName + '.' + c.Field); }
                }
            }
            this.fieldList = [...needed];
            console.log('Contextual banner - requesting fields', this.fieldList);

            this.evaluate();
        } catch (e) {
            // A bad file must never blank the page.
            console.error('Contextual banner - config file failed:',
                e && e.message ? e.message : e);
        }
    }

    // ------------------------------- read the record with no SOQL query

    @wire(getRecord, { recordId: '$recordId', fields: '$fieldList' })
    wiredRecord({ data, error }) {
        if (data) {
            this.recordData = data;
            this.evaluate();
        } else if (error) {
            console.error('Contextual banner - record read failed:',
                (error && error.body && error.body.message) ? error.body.message : error);
        }
    }

    // ------------------------------------- evaluate all rules in memory

    /**
     * Supports two shapes in the JSON:
     *   1. Shorthand:  "PolicyRecords": ["LS001", "LS002"]
     *   2. Full form:  "Conditions": [ { Field, Operator, Values } ]
     */
    conditionsFor(rule) {
        if (Array.isArray(rule.Conditions) && rule.Conditions.length) {
            return rule.Conditions;
        }
        if (Array.isArray(rule.PolicyRecords) && rule.PolicyRecords.length) {
            return [{
                Field: 'PolicyNumber__c',
                Operator: 'IN',
                Values: rule.PolicyRecords
            }];
        }
        return [];
    }

    evaluate() {
        if (!this.rules || !this.recordData) { return; }

        const matched = [];

        this.rules.forEach((rule, i) => {
            const conditions = this.conditionsFor(rule);
            if (!conditions.length) { return; }

            // every condition must pass (AND logic)
            const passes = conditions.every(c => this.test(this.readField(c.Field), c));
            if (!passes) { return; }

            const variant = rule.Variant || 'warning';
            matched.push({
                key: rule.Id || ('rule-' + i),
                text: rule.Message,
                iconName: 'utility:' + variant,
                iconVariant: ICON_VARIANT[variant] || 'bare',
                cssClass: 'slds-notify slds-notify_alert '
                        + 'slds-theme_alert-texture slds-theme_' + variant
            });
        });

        console.log('Contextual banner - matched ' + matched.length + ' rules');
        this.messages = matched;
    }

    readField(field) {
        if (!this.recordData || !this.recordData.fields) { return null; }
        const f = this.recordData.fields[field];
        return f ? f.value : null;
    }

    /**
     * Mirrors SOQL behaviour:
     *   - comparisons are case-insensitive
     *   - null IN (...) is false
     *   - null != 'x' is TRUE
     */
    test(actual, c) {
        const op = (c.Operator || 'IN').toUpperCase();
        const values = (c.Values || []).map(v => String(v).trim().toUpperCase());

        if (op === 'IS_TRUE') { return actual === true; }
        if (op === 'IS_FALSE') { return actual === false; }

        if (actual === null || actual === undefined) {
            return op === 'NOT_IN' || op === 'NOT_EQUALS';
        }

        const a = String(actual).trim().toUpperCase();

        switch (op) {
            case 'IN':
            case 'EQUALS':      return values.includes(a);
            case 'NOT_IN':
            case 'NOT_EQUALS':  return !values.includes(a);
            case 'STARTS_WITH': return values.some(v => a.startsWith(v));
            case 'CONTAINS':    return values.some(v => a.includes(v));
            default:            return false;
        }
    }
}
'@

$lwcHtml = @'
<template>
    <template for:each={messages} for:item="m">
        <div key={m.key} class={m.cssClass} role="alert"
             style="text-align:left; justify-content:left;">
            <lightning-icon icon-name={m.iconName} variant={m.iconVariant}
                            size="small" style="margin-right:2%;"></lightning-icon>
            <lightning-formatted-rich-text value={m.text}></lightning-formatted-rich-text>
        </div>
    </template>
</template>
'@

    Save-File (Join-Path $lwcDir 'contextualBannerAlert.js')   $lwcJs
    Save-File (Join-Path $lwcDir 'contextualBannerAlert.html') $lwcHtml
}

# ----------------------------------------------------------------- deploy

if ($DeployAfterWrite) {

    Write-Step "Deploying to $OrgAlias"

    Push-Location $ProjectPath
    try {
        Write-Host '    static resources...' -ForegroundColor Gray
        sf project deploy start --source-dir force-app/main/default/staticresources --target-org $OrgAlias --ignore-conflicts --async

        if ($UpdateComponent) {
            Write-Host '    component...' -ForegroundColor Gray
            sf project deploy start --source-dir force-app/main/default/lwc/contextualBannerAlert --target-org $OrgAlias --ignore-conflicts --async
        }

        Write-Host ''
        Write-Warn 'deploys were submitted asynchronously - check the result with:'
        Write-Host "      sf project deploy report --use-most-recent --target-org $OrgAlias" -ForegroundColor White
    } catch {
        Write-Err "deploy command failed: $_"
        Write-Warn 'the files are written - you can deploy manually'
    }
    Pop-Location

} else {
    Write-Step 'Skipping deployment (DeployAfterWrite is false)'
    Write-Host "      cd $ProjectPath" -ForegroundColor White
    Write-Host "      sf project deploy start --source-dir force-app/main/default/staticresources --target-org $OrgAlias --ignore-conflicts" -ForegroundColor White
}

# ---------------------------------------------------------- test matrix

$setList     = $PolicySet -join ', '
$singleList  = $PolicySingle -join ', '
$agentList   = $AgentSet -join ', '
$agentSingle = $AgentSingle -join ', '

Write-Host @"

============================================================
  TEST MATRIX - open each record and check the banner
============================================================

POLICY pages
  $setList
      -> expect: $PolicySetMessage

  $singleList
      -> expect: $PolicySingleMessage

  any other policy
      -> expect: NO banner at all

CONTACT pages   (matching on $ContactField)
  $agentList
      -> expect: $AgentSetMessage

  $agentSingle
      -> expect: $AgentSingleMessage

  any other contact
      -> expect: NO banner at all

------------------------------------------------------------
  Press Ctrl+Shift+R on each page - the browser caches
  static resources and a normal refresh may show stale data.

  If a banner is wrong, press F12 and look in the Console
  for lines starting "Contextual banner".
============================================================
"@ -ForegroundColor White
