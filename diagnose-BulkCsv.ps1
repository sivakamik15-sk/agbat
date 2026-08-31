<#
    diagnose-BulkCsv.ps1 - find out why Bulk API 2.0 rejected a CSV.

    WHY THIS EXISTS
    Bulk API 2.0 reports a rejected load as

        InvalidBatch : Field name not found : 399700

    and 399700 is not a field name at all - it is a data value from somewhere in
    the body. That error means the server's CSV parser LOST SYNC with the row
    boundaries, so a value ended up where a column name was expected. The
    message names the value it tripped over, never the row it came from, which
    makes it useless for locating the defect.

    Counting commas per line does not find it either, because the three things
    that cause it are exactly the three things a naive line-by-line comma count
    cannot see:

        1. a row with more or fewer fields than the header
        2. an unbalanced double quote - from there on, newlines are swallowed
           into one field and every following row boundary is wrong
        3. an embedded line break inside a quoted field

    So this script walks the file character by character with the same quoting
    state machine the server uses. That is the only way to see records as the
    server sees them, and it is why this finds the row that a comma count
    misses.

    WHAT IT CHECKS
      - BOM, byte size, line-ending style (CRLF / LF / mixed)
      - header field count, and every record whose field count differs
      - unbalanced quote, with the line it starts on
      - records that span more than one physical line
      - control characters, 0x1A (Ctrl-Z) called out separately because it is
        what silently truncated a 100,000-row file to 65,535 once before
      - duplicate values in the external-id column, which upsert resolves by
        letting the LAST row win, silently
      - optional: diff against a known-good copy (e.g. the archived file from
        the run that worked)

    USAGE
      .\diagnose-BulkCsv.ps1
          asks for the CSV path

      .\diagnose-BulkCsv.ps1 -Csv 'C:\NLG\Source Data\AgentSales\Agentsalesdatasalesforce.csv'

      # compare against the copy that loaded successfully
      .\diagnose-BulkCsv.ps1 -Csv '...\Agentsalesdatasalesforce.csv' `
                             -Against 'C:\NLG\Archive\Archive_0830 ...\Agentsalesdatasalesforce.csv'

      # also report duplicates in the upsert key
      .\diagnose-BulkCsv.ps1 -Csv '...\file.csv' -ExtIdColumn ProducerID

    Read-only. It never writes to or modifies the CSV.
#>

[CmdletBinding()]
param(
    [string] $Csv,
    [string] $Against,
    [string] $ExtIdColumn,
    [int]    $MaxReport = 20
)

$ErrorActionPreference = 'Stop'
$interactive = -not $Csv

function Clean-Path([string] $p) {
    if ($null -eq $p) { return '' }
    return $p.Trim().Trim('"').Trim("'").Trim()
}

function Stop-Script([int] $code) {
    if ($interactive) { Write-Host ''; [void](Read-Host 'Press Enter to close') }
    exit $code
}

# --- the parser -------------------------------------------------------------
# Walks the text with the same quoting rules the Bulk API uses, and returns one
# object per RECORD (not per line) so a record that spans lines is visible.
function Read-Records([string] $text) {
    $recs   = New-Object 'System.Collections.Generic.List[object]'
    $fields = 1
    $inQ    = $false
    $line   = 1
    $start  = 1
    $spans  = 0
    $firstField = New-Object Text.StringBuilder
    $capture = $true
    $i = 0
    $n = $text.Length

    while ($i -lt $n) {
        $c = $text[$i]
        if ($inQ) {
            if ($c -eq '"') {
                if (($i + 1) -lt $n -and $text[$i + 1] -eq '"') { $i++ }   # escaped ""
                else { $inQ = $false }
            }
            elseif ($c -eq "`n") { $line++; $spans++ }
        }
        else {
            switch ($c) {
                '"'    { $inQ = $true }
                ','    { $fields++; $capture = $false }
                "`r"   { }
                "`n"   {
                    $recs.Add([pscustomobject]@{
                        StartLine = $start; Fields = $fields; SpannedLines = $spans
                        FirstField = $firstField.ToString()
                    })
                    $line++; $start = $line; $fields = 1; $spans = 0
                    $firstField = New-Object Text.StringBuilder
                    $capture = $true
                }
                default { if ($capture) { [void]$firstField.Append($c) } }
            }
        }
        $i++
    }
    # trailing record with no final newline
    if ($fields -gt 1 -or $firstField.Length -gt 0) {
        $recs.Add([pscustomobject]@{
            StartLine = $start; Fields = $fields; SpannedLines = $spans
            FirstField = $firstField.ToString()
        })
    }
    return @{ Records = $recs; UnterminatedQuote = $inQ }
}

function Analyse([string] $path) {
    $bytes = [IO.File]::ReadAllBytes($path)
    $bom   = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)

    $crlf = 0; $lf = 0
    for ($i = 0; $i -lt $bytes.Length; $i++) {
        if ($bytes[$i] -eq 10) { if ($i -gt 0 -and $bytes[$i-1] -eq 13) { $crlf++ } else { $lf++ } }
    }

    $ctrl = 0; $ctrlZ = 0; $ctrlAt = @()
    for ($i = 0; $i -lt $bytes.Length; $i++) {
        $b = $bytes[$i]
        if ($b -eq 0x1A) { $ctrlZ++; if ($ctrlAt.Count -lt 5) { $ctrlAt += $i } }
        elseif (($b -le 0x08) -or ($b -eq 0x0B) -or ($b -eq 0x0C) -or ($b -ge 0x0E -and $b -le 0x1F)) {
            $ctrl++; if ($ctrlAt.Count -lt 5) { $ctrlAt += $i }
        }
    }

    # StreamReader consumes the BOM so header names compare cleanly
    $reader = [IO.StreamReader]::new($path, $true)
    $text   = $reader.ReadToEnd()
    $reader.Close()

    $parsed = Read-Records $text
    $quotes = ($text.ToCharArray() | Where-Object { $_ -eq '"' }).Count

    return [pscustomobject]@{
        Path = $path; Bytes = $bytes.Length; Bom = $bom
        Crlf = $crlf; Lf = $lf; Ctrl = $ctrl; CtrlZ = $ctrlZ; CtrlAt = $ctrlAt
        Quotes = $quotes; Unterminated = $parsed.UnterminatedQuote
        Records = $parsed.Records
        Text = $text
    }
}

# --- input ------------------------------------------------------------------
Write-Host ''
Write-Host '  diagnose-BulkCsv.ps1 - why did Bulk API reject this CSV?'
Write-Host '  --------------------------------------------------------'

if ($interactive) {
    Write-Host ''
    $Csv = Clean-Path (Read-Host '  CSV path')
}
$Csv = Clean-Path $Csv
if (-not (Test-Path -LiteralPath $Csv)) { Write-Host "  Not found: $Csv" -ForegroundColor Red; Stop-Script 2 }
$Csv = (Resolve-Path -LiteralPath $Csv).Path

$a = Analyse $Csv
if ($a.Records.Count -eq 0) { Write-Host '  File has no records.' -ForegroundColor Red; Stop-Script 2 }

$header   = $a.Records[0]
$expected = $header.Fields
$data     = $a.Records | Select-Object -Skip 1

$headerLine = ($a.Text -split "`r?`n")[0]
$cols = $headerLine -split ','

Write-Host ''
Write-Host "  file            : $Csv"
Write-Host "  bytes           : $($a.Bytes)"
Write-Host "  BOM             : $(if ($a.Bom) { 'yes (harmless - the loader strips it)' } else { 'no' })"
Write-Host "  line endings    : CRLF $($a.Crlf), bare LF $($a.Lf)$(if ($a.Crlf -gt 0 -and $a.Lf -gt 0) { '   <-- MIXED' })"
Write-Host "  header fields   : $expected"
Write-Host "  data records    : $($data.Count)"
Write-Host "  double quotes   : $($a.Quotes)"
Write-Host ''

# --- findings ---------------------------------------------------------------
$problems = @()

if ($a.Unterminated) {
    $problems += 'UNBALANCED QUOTE'
    Write-Host '  *** UNBALANCED DOUBLE QUOTE - the file ends inside a quoted field. ***' -ForegroundColor Red
    Write-Host '      From the opening quote onward every newline is swallowed into one' -ForegroundColor Red
    Write-Host '      field, so every row boundary after it is wrong. This is the most' -ForegroundColor Red
    Write-Host '      common cause of "Field name not found : <a data value>".' -ForegroundColor Red
    Write-Host ''
}

$bad = @($data | Where-Object { $_.Fields -ne $expected })
if ($bad.Count -gt 0) {
    $problems += 'FIELD COUNT'
    Write-Host "  *** $($bad.Count) record(s) do not have $expected fields. ***" -ForegroundColor Red
    Write-Host '      Bulk API cannot line these up with the header.' -ForegroundColor Red
    $bad | Select-Object -First $MaxReport | ForEach-Object {
        "      line {0,-8} {1,3} fields (expected {2})   first field: {3}" -f $_.StartLine, $_.Fields, $expected, $_.FirstField
    }
    if ($bad.Count -gt $MaxReport) { Write-Host "      ... and $($bad.Count - $MaxReport) more" -ForegroundColor Red }
    Write-Host ''
}

$spanning = @($data | Where-Object { $_.SpannedLines -gt 0 })
if ($spanning.Count -gt 0) {
    $problems += 'EMBEDDED NEWLINE'
    Write-Host "  *** $($spanning.Count) record(s) span more than one physical line. ***" -ForegroundColor Yellow
    Write-Host '      Legal CSV, but it means a value contains a line break - and it makes' -ForegroundColor Yellow
    Write-Host '      the loader row-count guard disagree with the server.' -ForegroundColor Yellow
    $spanning | Select-Object -First $MaxReport | ForEach-Object {
        "      starts line {0,-8} spans {1} extra line(s)   first field: {2}" -f $_.StartLine, $_.SpannedLines, $_.FirstField
    }
    Write-Host ''
}

if ($a.CtrlZ -gt 0) {
    $problems += 'CTRL-Z'
    Write-Host "  *** $($a.CtrlZ) x 0x1A (Ctrl-Z) byte(s), first at offset $($a.CtrlAt[0]). ***" -ForegroundColor Red
    Write-Host '      This is what truncated a 100,000-row file to 65,535 rows before.' -ForegroundColor Red
    Write-Host ''
}
if ($a.Ctrl -gt 0) {
    $problems += 'CONTROL CHARS'
    Write-Host "  *** $($a.Ctrl) other control character(s), first at offset $($a.CtrlAt[0]). ***" -ForegroundColor Red
    Write-Host ''
}

if ($ExtIdColumn) {
    $idx = [Array]::FindIndex($cols, [Predicate[string]] { $args[0].Trim() -ieq $ExtIdColumn.Trim() })
    if ($idx -lt 0) {
        Write-Host "  -ExtIdColumn '$ExtIdColumn' is not in the header. Columns:" -ForegroundColor Yellow
        for ($j = 0; $j -lt $cols.Count; $j++) { Write-Host ("    {0,3}  {1}" -f ($j + 1), $cols[$j]) }
    }
    else {
        $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $dupe = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $blank = 0
        Import-Csv -LiteralPath $Csv | ForEach-Object {
            $v = "$($_.$ExtIdColumn)".Trim()
            if (-not $v) { $blank++ } elseif (-not $seen.Add($v)) { [void]$dupe.Add($v) }
        }
        Write-Host "  external id '$ExtIdColumn': $($seen.Count) distinct, $($dupe.Count) duplicated, $blank blank"
        if ($dupe.Count -gt 0) {
            Write-Host '      On upsert the LAST row for a duplicated key silently wins.' -ForegroundColor Yellow
            $dupe | Select-Object -First 10 | ForEach-Object { "      $_" }
        }
        Write-Host ''
    }
}

# --- compare against a known-good copy --------------------------------------
if ($Against) {
    $Against = Clean-Path $Against
    if (-not (Test-Path -LiteralPath $Against)) {
        Write-Host "  -Against not found: $Against" -ForegroundColor Yellow
    }
    else {
        $b = Analyse ((Resolve-Path -LiteralPath $Against).Path)
        $bHeader = ($b.Text -split "`r?`n")[0]
        Write-Host '  ---- compared with the known-good copy ----'
        "  {0,-18} {1,20} {2,20}" -f '', 'THIS FILE', 'KNOWN GOOD'
        "  {0,-18} {1,20} {2,20}" -f 'bytes',        $a.Bytes,          $b.Bytes
        "  {0,-18} {1,20} {2,20}" -f 'data records', $data.Count,       ($b.Records.Count - 1)
        "  {0,-18} {1,20} {2,20}" -f 'header fields',$expected,         $b.Records[0].Fields
        "  {0,-18} {1,20} {2,20}" -f 'double quotes',$a.Quotes,         $b.Quotes
        "  {0,-18} {1,20} {2,20}" -f 'bare LF',      $a.Lf,             $b.Lf
        "  {0,-18} {1,20} {2,20}" -f 'control chars',($a.Ctrl+$a.CtrlZ),($b.Ctrl+$b.CtrlZ)
        Write-Host ''
        if ($headerLine -ne $bHeader) {
            Write-Host '  *** THE HEADERS DIFFER. ***' -ForegroundColor Red
            Write-Host "      this file : $headerLine" -ForegroundColor Red
            Write-Host "      known good: $bHeader" -ForegroundColor Red
        }
        else { Write-Host '  headers are identical.' -ForegroundColor Green }
        Write-Host ''
    }
}

# --- verdict ----------------------------------------------------------------
Write-Host '  ================ VERDICT ================'
if ($problems.Count -eq 0) {
    Write-Host '  No structural defect found. Records all have the same field count,' -ForegroundColor Green
    Write-Host '  quotes are balanced, no control characters.' -ForegroundColor Green
    Write-Host ''
    Write-Host '  If Bulk API still rejects it, the problem is NOT csv structure:' -ForegroundColor Cyan
    Write-Host '    - a column name in the header is not a real field on the object' -ForegroundColor Cyan
    Write-Host '      (check the SDL right-hand side against sf sobject describe), or' -ForegroundColor Cyan
    Write-Host '    - the SDL was not applied, so raw legacy headers went out. The log' -ForegroundColor Cyan
    Write-Host '      line "SDL mappings: 0" is the tell; it should equal the column count.' -ForegroundColor Cyan
}
else {
    Write-Host "  Structural defect(s): $($problems -join ', ')" -ForegroundColor Red
    Write-Host ''
    Write-Host '  This is why the server reported a DATA VALUE as a field name: the' -ForegroundColor Red
    Write-Host '  parser lost the row boundaries and read a value where it expected a' -ForegroundColor Red
    Write-Host '  column. Fix the record(s) listed above and reload.' -ForegroundColor Red
    Write-Host ''
    Write-Host '  Do NOT fix it by opening the file in Excel and saving - an Excel' -ForegroundColor Yellow
    Write-Host '  round-trip re-quotes fields and reformats numbers, which is a common' -ForegroundColor Yellow
    Write-Host '  way this kind of damage gets introduced in the first place.' -ForegroundColor Yellow
}
Write-Host ''
Stop-Script $(if ($problems.Count -eq 0) { 0 } else { 1 })
