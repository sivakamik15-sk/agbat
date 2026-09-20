# ============================================================================
#  Contextual Banner Alert - project scaffolding script
#
#  Creates the SFDX project, folders, static resources and LWC in one run.
#  Run it by double-clicking setup.bat in the same folder.
#
#  EDIT THE FOUR SETTINGS BELOW before running, then leave everything else.
# ============================================================================

# ---------------------------- SETTINGS --------------------------------------

$ProjectRoot     = 'C:\Temp'            # where the project folder is created
$ProjectName     = 'contextualBanner'   # the project folder name
$PolicyNumber    = 'LS002876200'        # a REAL PolicyNumber__c from your org
$ContactLastName = 'testAgent'          # a REAL Contact LastName from your org

# ----------------------------------------------------------------------------

$ErrorActionPreference = 'Stop'
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Write-Step { param($m) Write-Host "`n>>> $m" -ForegroundColor Cyan }
function Write-Ok   { param($m) Write-Host "    OK  $m" -ForegroundColor Green }
function Write-Warn { param($m) Write-Host "    !!  $m" -ForegroundColor Yellow }

function Save-File {
    param($Path, $Content)
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
    Write-Ok (Split-Path -Leaf $Path)
}

# ---------------------------------------------------------------- 1. checks

Write-Step 'Checking the Salesforce CLI'

$sf = Get-Command sf -ErrorAction SilentlyContinue
if (-not $sf) {
    Write-Host "`n    The Salesforce CLI ('sf') was not found on this machine." -ForegroundColor Red
    Write-Host "    Install it, then run this script again.`n" -ForegroundColor Red
    exit 1
}
Write-Ok "found at $($sf.Source)"

# ------------------------------------------------------------- 2. project

$projectPath = Join-Path $ProjectRoot $ProjectName

Write-Step "Creating the project at $projectPath"

if (-not (Test-Path $ProjectRoot)) {
    New-Item -ItemType Directory -Force -Path $ProjectRoot | Out-Null
    Write-Ok "created $ProjectRoot"
}

if (Test-Path (Join-Path $projectPath 'sfdx-project.json')) {
    Write-Warn 'project already exists - skipping generation, files will be added to it'
} else {
    Push-Location $ProjectRoot
    try {
        sf project generate --name $ProjectName | Out-Null
        Write-Ok 'project generated'
    } catch {
        Write-Host "`n    Project generation failed: $_`n" -ForegroundColor Red
        Pop-Location
        exit 1
    }
    Pop-Location
}

$defaultDir = Join-Path $projectPath 'force-app\main\default'
$srDir      = Join-Path $defaultDir 'staticresources'
$lwcDir     = Join-Path $defaultDir 'lwc\contextualBannerAlert'

# ----------------------------------------------------- 3. static resources

Write-Step 'Writing the static resources'

$policyJson = @"
{
  "Version": 1,
  "Rules": [
    {
      "Id": "TEST_POLICY_RULE",
      "Variant": "warning",
      "Message": "TEST BANNER - this policy matched a rule in the config file.",
      "PolicyRecords": ["$PolicyNumber"]
    }
  ]
}
"@

$contactJson = @"
{
  "Version": 1,
  "Rules": [
    {
      "Id": "TEST_CONTACT_RULE",
      "Variant": "info",
      "Message": "TEST BANNER - this contact matched a rule in the config file.",
      "Conditions": [
        {
          "Field": "LastName",
          "Operator": "IN",
          "Values": ["$ContactLastName"]
        }
      ]
    }
  ]
}
"@

$resourceMeta = @'
<?xml version="1.0" encoding="UTF-8"?>
<StaticResource xmlns="http://soap.sforce.com/2006/04/metadata">
    <cacheControl>Public</cacheControl>
    <contentType>application/json</contentType>
</StaticResource>
'@

Save-File (Join-Path $srDir 'PolicyBannerConfig.json')                $policyJson
Save-File (Join-Path $srDir 'PolicyBannerConfig.resource-meta.xml')   $resourceMeta
Save-File (Join-Path $srDir 'ContactBannerConfig.json')               $contactJson
Save-File (Join-Path $srDir 'ContactBannerConfig.resource-meta.xml')  $resourceMeta

# ------------------------------------------------------------------ 4. LWC

Write-Step 'Writing the Lightning Web Component'

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
                variant: variant,
                iconName: 'utility:' + variant,
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
            <lightning-icon icon-name={m.iconName} variant={m.variant}
                            size="small" style="margin-right:2%;"></lightning-icon>
            <lightning-formatted-rich-text value={m.text}></lightning-formatted-rich-text>
        </div>
    </template>
</template>
'@

$lwcMeta = @'
<?xml version="1.0" encoding="UTF-8"?>
<LightningComponentBundle xmlns="http://soap.sforce.com/2006/04/metadata">
    <apiVersion>62.0</apiVersion>
    <isExposed>true</isExposed>
    <targets>
        <target>lightning__RecordPage</target>
    </targets>
    <targetConfigs>
        <targetConfig targets="lightning__RecordPage">
            <objects>
                <object>PolicyMaster__c</object>
                <object>Contact</object>
            </objects>
        </targetConfig>
    </targetConfigs>
</LightningComponentBundle>
'@

Save-File (Join-Path $lwcDir 'contextualBannerAlert.js')           $lwcJs
Save-File (Join-Path $lwcDir 'contextualBannerAlert.html')         $lwcHtml
Save-File (Join-Path $lwcDir 'contextualBannerAlert.js-meta.xml')  $lwcMeta

# ------------------------------------------------------------- 5. summary

Write-Step 'Verifying'

$expected = @(
    (Join-Path $srDir  'PolicyBannerConfig.json'),
    (Join-Path $srDir  'PolicyBannerConfig.resource-meta.xml'),
    (Join-Path $srDir  'ContactBannerConfig.json'),
    (Join-Path $srDir  'ContactBannerConfig.resource-meta.xml'),
    (Join-Path $lwcDir 'contextualBannerAlert.js'),
    (Join-Path $lwcDir 'contextualBannerAlert.html'),
    (Join-Path $lwcDir 'contextualBannerAlert.js-meta.xml')
)

$missing = $expected | Where-Object { -not (Test-Path $_) }

if ($missing) {
    Write-Host "`n    These files are missing:" -ForegroundColor Red
    $missing | ForEach-Object { Write-Host "      $_" -ForegroundColor Red }
    exit 1
}

Write-Ok "all 7 files created"

Write-Host @"

============================================================
  DONE - project ready at:
  $projectPath

  Test values baked into the config files:
    PolicyNumber__c : $PolicyNumber
    Contact LastName: $ContactLastName

  If either of those is not a real value in your org, edit
  the JSON files before deploying or no banner will appear.
============================================================

NEXT STEPS - run these commands one at a time:

  1. Move into the project
       cd $projectPath

  2. Connect to the org  (sandbox shown - drop the URL flag for production)
       sf org login web --alias devorg --instance-url https://test.salesforce.com

  3. Deploy the static resources FIRST
       sf project deploy start --source-dir force-app/main/default/staticresources --target-org devorg

  4. Then deploy the component
       sf project deploy start --source-dir force-app/main/default/lwc/contextualBannerAlert --target-org devorg

  5. Add it to the page
       Open a policy record  ->  gear icon  ->  Edit Page
       Drag "Contextual Banner Alert" to the top
       Save  ->  Activation  ->  Assign as Org Default
       Repeat on a Contact record page

  6. Test
       Open the policy record - the test banner should appear.
       If it does not, press F12 and look in the Console for
       lines starting "Contextual banner".

  7. Open the project in VS Code if you want to edit anything
       code $projectPath

============================================================
"@ -ForegroundColor White
