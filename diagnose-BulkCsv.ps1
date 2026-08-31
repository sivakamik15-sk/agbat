<#
    check-AgentSales.ps1 - one-click diagnosis of the AgentSalesUpsert failure

        InvalidBatch : Field name not found : 399700

    Just run it. No arguments, no paths to type. It knows where everything is.

    WHAT IT LOOKS AT, and why each one matters

      1. C:\NLG\Source Data\AgentSales\Agentsalesdatasalesforce.csv
         The file you are trying to load now.

      2. C:\NLG\Load Result\AgentSalesUpsert_input.csv
         The file the loader actually SENT to Salesforce, after the SDL header
         rewrite. If 1 is clean and 2 is not, the defect was introduced by the
         prepare step, not by the extract. Nothing else distinguishes those two
         cases.

      3. The newest copy of the same filename under C:\NLG\Archive
         Your bat archives the source CSV when a job SUCCEEDS, so this is the
         file from the run that worked. Comparing it against 1 is what answers
         "why did it fail this time when it ran fine last time".

    HOW IT FINDS WHAT COMMA-COUNTING CANNOT
    "Field name not found : 399700" means the server's CSV parser lost the row
    boundaries and read a data value where a column name belonged. 399700 sits
    at B2506 - deep in the body, not in the header. A line-by-line comma count
    cannot see this, because the three causes are exactly the three things that
    break the line/record relationship:

        - an unbalanced double quote: from there on, newlines are swallowed
          into one field and every later row boundary is wrong
        - a record with more or fewer fields than the header
        - a line break embedded inside a quoted field

    So this walks the bytes with the same quoting state machine the server
    uses, and reports RECORDS rather than lines. That is also why the loader's
    row-count guard passed 10000/10000 and still let a broken file through: the
    LINE count was right, the RECORD count was not, and nothing was checking it.

    IT NEVER WRITES TO THE CSVs. Read-only. The only file it creates is its own
    report, so you can paste the results without retyping:

        C:\NLG\Log\AgentSales-csv-check.txt

    BEFORE YOU RUN IT: close the CSV in Excel, and do not save it. Excel had it
    open; an Excel round-trip re-quotes fields and reformats numbers, and is a
    common way this damage gets introduced.
#>

# ---------------- paths (edit only if your layout differs) ------------------
$ROOT = 'C:\NLG'
if ($env:NLG_ROOT) { $ROOT = $env:NLG_ROOT }        # honoured for testing

$SOURCE   = Join-Path $ROOT 'Source Data\AgentSales\Agentsalesdatasalesforce.csv'
$PREPARED = Join-Path $ROOT 'Load Result\AgentSalesUpsert_input.csv'
$ARCHIVE  = Join-Path $ROOT 'Archive'
$LOGDIR   = Join-Path $ROOT 'Log'
$REPORT   = Join-Path $LOGDIR 'AgentSales-csv-check.txt'
$EXTID    = 'ProducerID'                             # column holding the agent id
$MAXREPORT = 20

$ErrorActionPreference = 'Stop'

# ---------------- output helper --------------------------------------------
$lines = New-Object 'System.Collections.Generic.List[string]'
function Say([string] $t = '', [string] $colour = '') {
    $lines.Add($t)
    if ($colour) { Write-Host $t -ForegroundColor $colour } else { Write-Host $t }
}

# ---------------- the parser ------------------------------------------------
# Same quoting rules the Bulk API uses. Returns one object per RECORD, so a
# record spanning physical lines is visible instead of silently miscounted.
function Read-Records([string] $text) {
    $recs = New-Object 'System.Collections.Generic.List[object]'
    $fields = 1; $inQ = $false; $line = 1; $start = 1; $spans = 0
    $first = New-Object Text.StringBuilder
    $capture = $true
    $i = 0; $n = $text.Length
    while ($i -lt $n) {
        $c = $text[$i]
        if ($inQ) {
            if ($c -eq '"') {
                if (($i + 1) -lt $n -and $text[$i + 1] -eq '"') { $i++ } else { $inQ = $false }
            }
            elseif ($c -eq "`n") { $line++; $spans++ }
        }
        else {
            if     ($c -eq '"')  { $inQ = $true }
            elseif ($c -eq ',')  { $fields++; $capture = $false }
            elseif ($c -eq "`r") { }
            elseif ($c -eq "`n") {
                $recs.Add([pscustomobject]@{ StartLine=$start; Fields=$fields; Spans=$spans; First=$first.ToString() })
                $line++; $start = $line; $fields = 1; $spans = 0
                $first = New-Object Text.StringBuilder; $capture = $true
            }
            elseif ($capture) { [void]$first.Append($c) }
        }
        $i++
    }
    if ($fields -gt 1 -or $first.Length -gt 0) {
        $recs.Add([pscustomobject]@{ StartLine=$start; Fields=$fields; Spans=$spans; First=$first.ToString() })
    }
    return @{ Records = $recs; Unterminated = $inQ }
}

function Analyse([string] $path) {
    $bytes = [IO.File]::ReadAllBytes($path)
    $bom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $crlf = 0; $lf = 0; $ctrl = 0; $ctrlZ = 0; $firstCtrl = -1
    for ($i = 0; $i -lt $bytes.Length; $i++) {
        $b = $bytes[$i]
        if ($b -eq 10) { if ($i -gt 0 -and $bytes[$i-1] -eq 13) { $crlf++ } else { $lf++ } }
        elseif ($b -eq 0x1A) { $ctrlZ++; if ($firstCtrl -lt 0) { $firstCtrl = $i } }
        elseif (($b -le 0x08) -or ($b -eq 0x0B) -or ($b -eq 0x0C) -or ($b -ge 0x0E -and $b -le 0x1F)) {
            $ctrl++; if ($firstCtrl -lt 0) { $firstCtrl = $i }
        }
    }
    $reader = [IO.StreamReader]::new($path, $true)   # consumes the BOM
    $text = $reader.ReadToEnd(); $reader.Close()
    $p = Read-Records $text
    return [pscustomobject]@{
        Path=$path; Bytes=$bytes.Length; Bom=$bom; Crlf=$crlf; Lf=$lf
        Ctrl=$ctrl; CtrlZ=$ctrlZ; FirstCtrl=$firstCtrl
        Quotes=($text.ToCharArray() | Where-Object { $_ -eq '"' }).Count
        Unterminated=$p.Unterminated; Records=$p.Records
        Header=(($text -split "`r?`n")[0])
    }
}

# Reports on one file. Returns the list of problem names found.
function Report([string] $label, [string] $path) {
    Say ''
    Say "=============================================================="
    Say "  $label"
    Say "  $path"
    Say "=============================================================="
    if (-not (Test-Path -LiteralPath $path)) {
        Say '  NOT FOUND - skipped.' 'Yellow'
        return @()
    }
    $a = Analyse $path
    if ($a.Records.Count -eq 0) { Say '  File is empty.' 'Red'; return @('EMPTY') }

    $expected = $a.Records[0].Fields
    $data = $a.Records | Select-Object -Skip 1

    Say ("  bytes             : {0:N0}" -f $a.Bytes)
    Say "  BOM               : $(if ($a.Bom) { 'yes (harmless, the loader strips it)' } else { 'no' })"
    Say "  line endings      : CRLF $($a.Crlf), bare LF $($a.Lf)$(if ($a.Crlf -gt 0 -and $a.Lf -gt 0) { '   <-- MIXED' })"
    Say "  header fields     : $expected"
    Say ("  data RECORDS      : {0:N0}" -f $data.Count)
    Say "  double quotes     : $($a.Quotes)"
    Say "  header            : $($a.Header)"

    $problems = @()

    if ($a.Unterminated) {
        $problems += 'UNBALANCED QUOTE'
        Say ''
        Say '  *** UNBALANCED DOUBLE QUOTE - the file ends inside a quoted field. ***' 'Red'
        Say '      Every newline after the opening quote is swallowed into one field,' 'Red'
        Say '      so every row boundary past it is wrong. This is the single most' 'Red'
        Say '      likely cause of "Field name not found : <a data value>".' 'Red'
    }

    $bad = @($data | Where-Object { $_.Fields -ne $expected })
    if ($bad.Count -gt 0) {
        $problems += 'FIELD COUNT'
        Say ''
        Say "  *** $($bad.Count) record(s) do not have $expected fields. ***" 'Red'
        Say '      Bulk API cannot line these up with the header.' 'Red'
        $bad | Select-Object -First $MAXREPORT | ForEach-Object {
            Say ("      line {0,-8} {1,3} fields (expected {2})   starts: {3}" -f $_.StartLine, $_.Fields, $expected, $_.First)
        }
        if ($bad.Count -gt $MAXREPORT) { Say "      ... and $($bad.Count - $MAXREPORT) more" 'Red' }
    }

    $span = @($data | Where-Object { $_.Spans -gt 0 })
    if ($span.Count -gt 0) {
        $problems += 'EMBEDDED NEWLINE'
        Say ''
        Say "  *** $($span.Count) record(s) span more than one physical line. ***" 'Yellow'
        Say '      A value contains a line break. Legal CSV, but it makes the' 'Yellow'
        Say '      loader row-count guard disagree with the server.' 'Yellow'
        $span | Select-Object -First $MAXREPORT | ForEach-Object {
            Say ("      starts line {0,-8} spans {1} extra line(s)   starts: {2}" -f $_.StartLine, $_.Spans, $_.First)
        }
    }

    if ($a.CtrlZ -gt 0) {
        $problems += 'CTRL-Z'
        Say ''
        Say "  *** $($a.CtrlZ) x 0x1A (Ctrl-Z) byte(s), first at offset $($a.FirstCtrl). ***" 'Red'
        Say '      This is what truncated a 100,000-row file to 65,535 rows before.' 'Red'
    }
    if ($a.Ctrl -gt 0) {
        $problems += 'CONTROL CHARS'
        Say ''
        Say "  *** $($a.Ctrl) other control character(s), first at offset $($a.FirstCtrl). ***" 'Red'
    }

    # duplicates in the upsert key
    $cols = $a.Header -split ','
    $idx = [Array]::FindIndex($cols, [Predicate[string]] { $args[0].Trim() -ieq $EXTID })
    if ($idx -ge 0 -and $problems.Count -eq 0) {
        try {
            $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            $dupe = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            $blank = 0
            Import-Csv -LiteralPath $path | ForEach-Object {
                $v = "$($_.$EXTID)".Trim()
                if (-not $v) { $blank++ } elseif (-not $seen.Add($v)) { [void]$dupe.Add($v) }
            }
            Say ''
            Say "  '$EXTID' : $($seen.Count) distinct, $($dupe.Count) duplicated, $blank blank"
            if ($dupe.Count -gt 0) {
                Say '      On upsert the LAST row for a duplicated key silently wins.' 'Yellow'
                $dupe | Select-Object -First 10 | ForEach-Object { Say "      $_" }
            }
        } catch { Say "  (duplicate check skipped: $($_.Exception.Message))" 'Yellow' }
    }

    if ($problems.Count -eq 0) { Say ''; Say '  No structural defect in this file.' 'Green' }
    return $problems
}

# ---------------- run -------------------------------------------------------
Clear-Host
Say ''
Say '  check-AgentSales.ps1 - why did AgentSalesUpsert fail?'
Say "  run at $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')   root: $ROOT"

$pSource   = Report 'FILE 1 of 3 - the source CSV you are loading now' $SOURCE
$pPrepared = Report 'FILE 2 of 3 - what the loader actually SENT to Salesforce' $PREPARED

# newest archived copy of the same filename = the run that succeeded
$arch = $null
if (Test-Path -LiteralPath $ARCHIVE) {
    $arch = Get-ChildItem -LiteralPath $ARCHIVE -Recurse -Filter 'Agentsalesdatasalesforce.csv' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
}
$pArch = @()
if ($arch) { $pArch = Report 'FILE 3 of 3 - the archived copy from the run that WORKED' $arch.FullName }
else {
    Say ''
    Say '=============================================================='
    Say '  FILE 3 of 3 - archived copy'
    Say '=============================================================='
    Say "  No Agentsalesdatasalesforce.csv found anywhere under $ARCHIVE." 'Yellow'
    Say '  The bat archives the source only when a job SUCCEEDS, so if there is' 'Yellow'
    Say '  no copy here then AgentSalesUpsert has never completed. In that case' 'Yellow'
    Say '  this is not a regression - the file was always malformed and we are' 'Yellow'
    Say '  catching it for the first time.' 'Yellow'
}

# ---------------- side by side ---------------------------------------------
if ($arch -and (Test-Path -LiteralPath $SOURCE)) {
    $a = Analyse $SOURCE
    $b = Analyse $arch.FullName
    Say ''
    Say '=============================================================='
    Say '  NOW vs THE RUN THAT WORKED'
    Say '=============================================================='
    Say ("  {0,-20} {1,18} {2,18}" -f '', 'LOADING NOW', 'WORKED BEFORE')
    Say ("  {0,-20} {1,18:N0} {2,18:N0}" -f 'bytes',         $a.Bytes, $b.Bytes)
    Say ("  {0,-20} {1,18:N0} {2,18:N0}" -f 'data records',  ($a.Records.Count - 1), ($b.Records.Count - 1))
    Say ("  {0,-20} {1,18} {2,18}"       -f 'header fields', $a.Records[0].Fields, $b.Records[0].Fields)
    Say ("  {0,-20} {1,18} {2,18}"       -f 'double quotes', $a.Quotes, $b.Quotes)
    Say ("  {0,-20} {1,18} {2,18}"       -f 'bare LF',       $a.Lf, $b.Lf)
    Say ("  {0,-20} {1,18} {2,18}"       -f 'control chars', ($a.Ctrl + $a.CtrlZ), ($b.Ctrl + $b.CtrlZ))
    Say ''
    if ($a.Header -ne $b.Header) {
        Say '  *** THE HEADERS DIFFER. ***' 'Red'
        Say "      now    : $($a.Header)" 'Red'
        Say "      before : $($b.Header)" 'Red'
    } else { Say '  Headers are identical.' 'Green' }
    if ($a.Bytes -ne $b.Bytes) {
        Say ''
        Say '  Byte sizes differ - these are NOT the same file. That is what changed' 'Yellow'
        Say '  between the run that worked and this one.' 'Yellow'
    }
}

# ---------------- verdict ---------------------------------------------------
Say ''
Say '=============================================================='
Say '  VERDICT'
Say '=============================================================='
if ($pSource.Count -gt 0) {
    Say "  The SOURCE CSV is malformed: $($pSource -join ', ')" 'Red'
    Say ''
    Say '  That is the root cause. The server reported a data value as a field' 'Red'
    Say '  name because the parser lost the row boundaries at the record(s)' 'Red'
    Say '  listed under FILE 1 above.' 'Red'
    Say ''
    Say '  FIX: repair those record(s) in the source CSV, then:' 'Cyan'
    Say '       run-AgencyAgentLoad.bat AgentSalesUpsert' 'Cyan'
    Say ''
    Say '  If an archived copy exists and is clean, the fastest fix is to put it' 'Cyan'
    Say '  back and re-export whatever changed since.' 'Cyan'
    Say ''
    Say '  Do NOT repair it by opening in Excel and saving - an Excel round-trip' 'Yellow'
    Say '  re-quotes fields and reformats numbers, and is a common way this' 'Yellow'
    Say '  damage is introduced.' 'Yellow'
}
elseif ($pPrepared.Count -gt 0) {
    Say "  The source CSV is clean, but the PREPARED file is malformed: $($pPrepared -join ', ')" 'Red'
    Say ''
    Say '  So the defect is introduced by the loader prepare step, not by the' 'Red'
    Say '  extract. That points at the header rewrite / body copy in the bat.' 'Red'
    Say '  Send this report - the fix belongs in the script, not the data.' 'Red'
}
else {
    Say '  No structural defect found in either file.' 'Green'
    Say ''
    Say '  So it is NOT csv structure. Two possibilities remain:' 'Cyan'
    Say '    1. a column name in the prepared header is not a real field on' 'Cyan'
    Say '       Contact - check every right-hand value in AgentSalesMapping.sdl' 'Cyan'
    Say '       against:  sf sobject describe -s Contact -o dev3cc' 'Cyan'
    Say '       Annualized_Premium_MTD__c was already flagged as UNVERIFIED.' 'Cyan'
    Say '    2. the SDL was not applied - but your log says "SDL mappings: 10",' 'Cyan'
    Say '       so this one is already ruled out.' 'Cyan'
    Say ''
    Say '  Possibility 1 is the likely answer. Bulk API reports only the FIRST' 'Cyan'
    Say '  bad field name per run, so check all ten at once.' 'Cyan'
}

# ---------------- save ------------------------------------------------------
Say ''
try {
    if (-not (Test-Path -LiteralPath $LOGDIR)) { New-Item -ItemType Directory -Path $LOGDIR -Force | Out-Null }
    [IO.File]::WriteAllLines($REPORT, $lines, [Text.UTF8Encoding]::new($false))
    Write-Host "  Report saved: $REPORT" -ForegroundColor Green
    Write-Host '  Open it and paste the contents back for the fix.' -ForegroundColor Green
} catch {
    Write-Host "  Could not save the report: $($_.Exception.Message)" -ForegroundColor Yellow
}
Write-Host ''
[void](Read-Host 'Press Enter to close')
