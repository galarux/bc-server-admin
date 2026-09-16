# Reads/writes CustomSettings.config, manages backups and builds exports.

$script:BcsaConfigCache = @{}
$script:BcsaSettingsMeta = $null
$script:BcsaBackupPattern = '^CustomSettings_(\d{8})_(\d{6})_(\d{3})_([a-z-]+)\.config$'

function Get-BcsaSettingsMeta {
    if (-not $script:BcsaSettingsMeta) {
        $path = Join-Path $PSScriptRoot '..\web\data\settings-meta.json'
        $script:BcsaSettingsMeta = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    return $script:BcsaSettingsMeta
}

function Get-BcsaSettingCategory {
    param([string] $Key)
    foreach ($category in (Get-BcsaSettingsMeta).categories) {
        foreach ($pattern in @($category.patterns)) {
            if ($Key -match $pattern) { return $category }
        }
    }
    return ((Get-BcsaSettingsMeta).categories | Where-Object { $_.id -eq 'other' } | Select-Object -First 1)
}

function Import-BcsaXmlDocument {
    param([string] $Path)
    $doc = New-Object System.Xml.XmlDocument
    $doc.PreserveWhitespace = $true
    $doc.XmlResolver = $null
    $doc.Load($Path)
    return $doc
}

function Get-BcsaAppSettingsNode {
    param([System.Xml.XmlDocument] $Document)
    if ($Document.DocumentElement.LocalName -eq 'appSettings') { return $Document.DocumentElement }
    $node = $Document.SelectSingleNode('//appSettings')
    if (-not $node) { throw 'The configuration file has no <appSettings> element.' }
    return $node
}

function Format-BcsaComment {
    # Removes the common indentation of an XML comment and trims blank edges.
    param([string] $Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($line in ($Text -split "\r?\n")) { $lines.Add($line.TrimEnd()) }
    while ($lines.Count -gt 0 -and $lines[0].Trim() -eq '') { $lines.RemoveAt(0) }
    while ($lines.Count -gt 0 -and $lines[$lines.Count - 1].Trim() -eq '') { $lines.RemoveAt($lines.Count - 1) }
    $indent = [int]::MaxValue
    foreach ($line in $lines) {
        if ($line.Trim() -eq '') { continue }
        $leading = $line.Length - $line.TrimStart().Length
        if ($leading -lt $indent) { $indent = $leading }
    }
    if ($indent -eq [int]::MaxValue) { $indent = 0 }
    $out = foreach ($line in $lines) { if ($line.Length -ge $indent) { $line.Substring($indent) } else { $line.Trim() } }
    return (@($out) -join "`n")
}

function Get-BcsaFileStamp {
    param([string] $Path)
    $item = Get-Item -LiteralPath $Path -ErrorAction Stop
    return ('{0}-{1}' -f $item.LastWriteTimeUtc.Ticks, $item.Length)
}

function Read-BcsaCustomSettings {
    <# Returns @{ path; stamp; settings = @( @{ key; value; description; secret } ) } (cached per file version). #>
    param([Parameter(Mandatory = $true)] [string] $Path)

    $stamp = Get-BcsaFileStamp -Path $Path
    $cached = $script:BcsaConfigCache[$Path]
    if ($cached -and $cached.stamp -eq $stamp) { return $cached }

    $root = Get-BcsaAppSettingsNode (Import-BcsaXmlDocument -Path $Path)
    $settings = [System.Collections.Generic.List[object]]::new()
    $comment = $null
    foreach ($node in $root.ChildNodes) {
        switch ([string]$node.NodeType) {
            'Comment' { $comment = $node.Value }
            'Whitespace' { }
            'SignificantWhitespace' { }
            'Element' {
                if ($node.LocalName -eq 'add') {
                    $key = $node.GetAttribute('key')
                    $settings.Add([pscustomobject]@{
                            key         = $key
                            value       = $node.GetAttribute('value')
                            description = (Format-BcsaComment $comment)
                            secret      = (Test-BcsaSecretKey $key)
                        })
                }
                $comment = $null
            }
            default { $comment = $null }
        }
    }

    $entry = @{ path = $Path; stamp = $stamp; settings = $settings.ToArray() }
    $script:BcsaConfigCache[$Path] = $entry
    return $entry
}

function Save-BcsaXmlDocument {
    # Writes in place (keeps file ACLs) and preserves the original BOM choice.
    param([System.Xml.XmlDocument] $Document, [string] $Path)
    $original = [IO.File]::ReadAllBytes($Path)
    $hasBom = $original.Length -ge 3 -and $original[0] -eq 0xEF -and $original[1] -eq 0xBB -and $original[2] -eq 0xBF

    $settings = New-Object System.Xml.XmlWriterSettings
    $settings.Encoding = New-Object System.Text.UTF8Encoding($hasBom)
    $settings.Indent = $false
    $settings.OmitXmlDeclaration = -not ($Document.FirstChild -is [System.Xml.XmlDeclaration])

    $stream = New-Object System.IO.MemoryStream
    $writer = [System.Xml.XmlWriter]::Create($stream, $settings)
    try { $Document.Save($writer) } finally { $writer.Dispose() }
    [IO.File]::WriteAllBytes($Path, $stream.ToArray())
    $script:BcsaConfigCache.Remove($Path)
}

function Set-BcsaCustomSettingsFile {
    <# Direct XML edit, used when the BC management module is not available (and by demo mode). #>
    param(
        [Parameter(Mandatory = $true)] [string] $Path,
        [Parameter(Mandatory = $true)] [object[]] $Changes
    )
    $doc = Import-BcsaXmlDocument -Path $Path
    $root = Get-BcsaAppSettingsNode $doc
    $nodes = @{}
    foreach ($node in $root.ChildNodes) {
        if ($node.NodeType -eq [System.Xml.XmlNodeType]::Element -and $node.LocalName -eq 'add') { $nodes[$node.GetAttribute('key')] = $node }
    }
    $results = @()
    foreach ($change in $Changes) {
        $key = [string]$change.key
        if ($nodes.ContainsKey($key)) {
            $nodes[$key].SetAttribute('value', [string]$change.value)
            $results += [ordered]@{ key = $key; ok = $true; error = $null; memory = $null }
        } else {
            $results += [ordered]@{ key = $key; ok = $false; error = 'Unknown setting'; memory = $null }
        }
    }
    Save-BcsaXmlDocument -Document $doc -Path $Path
    return $results
}

function Get-BcsaBackupDirectory {
    param([string] $InstanceName)
    return (Join-Path $script:Bcsa.BackupRoot (Get-BcsaSafeFileName $InstanceName))
}

function New-BcsaBackup {
    param($Instance, [ValidatePattern('^[a-z-]+$')] [string] $Reason = 'manual')
    if (-not $Instance.configPath) { Stop-BcsaRequest 409 'config_not_found' 'CustomSettings.config was not found for this instance.' }
    $dir = Get-BcsaBackupDirectory -InstanceName $Instance.name
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $name = 'CustomSettings_{0}_{1}.config' -f (Get-Date -Format 'yyyyMMdd_HHmmss_fff'), $Reason
    $target = Join-Path $dir $name
    Copy-Item -LiteralPath $Instance.configPath -Destination $target -Force

    # Keep the newest 100 backups per instance.
    Get-ChildItem -LiteralPath $dir -File | Where-Object { $_.Name -match $script:BcsaBackupPattern } |
        Sort-Object Name -Descending | Select-Object -Skip 100 | Remove-Item -Force -ErrorAction SilentlyContinue

    return [ordered]@{ name = $name; path = $target }
}

function Get-BcsaBackup {
    param($Instance)
    $dir = Get-BcsaBackupDirectory -InstanceName $Instance.name
    $items = @()
    if (Test-Path -LiteralPath $dir) {
        foreach ($file in (Get-ChildItem -LiteralPath $dir -File | Sort-Object Name -Descending)) {
            if ($file.Name -notmatch $script:BcsaBackupPattern) { continue }
            $created = [datetime]::ParseExact("$($Matches[1])$($Matches[2])$($Matches[3])", 'yyyyMMddHHmmssfff', [Globalization.CultureInfo]::InvariantCulture)
            $items += [ordered]@{ name = $file.Name; size = $file.Length; created = $created.ToString('o'); reason = $Matches[4] }
        }
    }
    return [ordered]@{ directory = $dir; items = @($items) }
}

function Restore-BcsaBackup {
    param($Instance, [string] $Name)
    if ($Name -notmatch $script:BcsaBackupPattern) { Stop-BcsaRequest 400 'invalid_backup' 'Invalid backup name.' }
    $source = Join-Path (Get-BcsaBackupDirectory -InstanceName $Instance.name) $Name
    if (-not (Test-Path -LiteralPath $source)) { Stop-BcsaRequest 404 'backup_not_found' 'Backup not found.' }
    try { Import-BcsaXmlDocument -Path $source | Out-Null } catch { Stop-BcsaRequest 422 'invalid_backup' "The backup is not valid XML: $($_.Exception.Message)" }
    $safety = New-BcsaBackup -Instance $Instance -Reason 'before-restore'
    [IO.File]::WriteAllBytes($Instance.configPath, [IO.File]::ReadAllBytes($source))
    $script:BcsaConfigCache.Remove($Instance.configPath)
    return [ordered]@{ restored = $Name; backup = $safety.name }
}

function Export-BcsaConfiguration {
    <# Returns @{ content; contentType; fileName } for Html, Csv or Json. Secrets are redacted unless -IncludeSecrets. #>
    param(
        [Parameter(Mandatory = $true)] $Instance,
        [ValidateSet('Html', 'Csv', 'Json')] [string] $Format = 'Html',
        [switch] $IncludeSecrets,
        [ValidateSet('en', 'es')] [string] $Language = 'en'
    )
    if (-not $Instance.configPath) { Stop-BcsaRequest 409 'config_not_found' 'CustomSettings.config was not found for this instance.' }
    $redacted = '********'
    $rows = foreach ($setting in (Read-BcsaCustomSettings -Path $Instance.configPath).settings) {
        $value = $setting.value
        if ($setting.secret -and -not $IncludeSecrets -and $value) { $value = $redacted }
        $category = Get-BcsaSettingCategory -Key $setting.key
        [pscustomobject]@{
            category    = $category.label.$Language
            categoryId  = $category.id
            key         = $setting.key
            value       = $value
            description = $setting.description
        }
    }
    $rows = @($rows)
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $baseName = '{0}-config-{1}' -f (Get-BcsaSafeFileName $Instance.name), $stamp

    switch ($Format) {
        'Json' {
            $content = ConvertTo-Json -Depth 5 -InputObject ([ordered]@{
                    instance    = $Instance.name
                    version     = $Instance.version
                    computer    = $script:Bcsa.ComputerName
                    generatedAt = (Get-Date).ToString('o')
                    settings    = @($rows | ForEach-Object { [ordered]@{ category = $_.categoryId; key = $_.key; value = $_.value; description = $_.description } })
                })
            return @{ content = $content; contentType = 'application/json; charset=utf-8'; fileName = "$baseName.json" }
        }
        'Csv' {
            $content = ($rows | Select-Object category, key, value, description | ConvertTo-Csv -NoTypeInformation) -join "`r`n"
            return @{ content = $content; contentType = 'text/csv; charset=utf-8'; fileName = "$baseName.csv" }
        }
        default {
            return @{ content = (ConvertTo-BcsaHtmlReport -Instance $Instance -Rows $rows -Language $Language); contentType = 'text/html; charset=utf-8'; fileName = "$baseName.html" }
        }
    }
}

function ConvertTo-BcsaHtmlReport {
    param($Instance, [object[]] $Rows, [string] $Language)
    $enc = { param($s) [System.Net.WebUtility]::HtmlEncode([string]$s) }
    $text = @{
        en = @{ search = 'Search setting or value...'; settings = 'settings'; generated = 'Generated'; by = 'Generated by' }
        es = @{ search = 'Buscar ajuste o valor...'; settings = 'ajustes'; generated = 'Generado'; by = 'Generado con' }
    }[$Language]

    $sections = New-Object System.Text.StringBuilder
    foreach ($group in ($Rows | Group-Object categoryId)) {
        $label = $group.Group[0].category
        [void]$sections.Append("<section><h2>$(& $enc $label) <span class=""n"">($($group.Count))</span></h2><table><tbody>")
        foreach ($row in $group.Group) {
            $valueClass = if ([string]::IsNullOrEmpty($row.value)) { 'v empty' } else { 'v' }
            [void]$sections.Append("<tr><td class=""k"" title=""$(& $enc $row.description)"">$(& $enc $row.key)</td><td class=""$valueClass"">$(& $enc $row.value)</td></tr>")
        }
        [void]$sections.Append('</tbody></table></section>')
    }

    $title = '{0} - Business Central {1}' -f $Instance.name, $Instance.version
    $meta = '{0} &middot; {1} {2}' -f (& $enc $script:Bcsa.ComputerName), $text.generated, (Get-Date -Format 'yyyy-MM-dd HH:mm')

    return @"
<!DOCTYPE html>
<html lang="$Language">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>$(& $enc $title)</title>
<style>
:root { --bg:#f3f5f8; --card:#fff; --text:#1d2433; --muted:#667085; --line:#dde2ea; --head:#1f4e78; --val:#0b7a3b; --hover:#eaf2fb; }
@media (prefers-color-scheme: dark) { :root { --bg:#12161d; --card:#1a2029; --text:#e4e8ef; --muted:#98a2b3; --line:#2c3441; --head:#2a5d8f; --val:#5fd08f; --hover:#223044; } }
* { box-sizing: border-box; }
body { margin:0; padding:24px 16px; background:var(--bg); color:var(--text); font:13px/1.45 "Segoe UI", system-ui, sans-serif; }
.wrap { max-width:1400px; margin:auto; }
h1 { margin:0; font-size:22px; font-weight:600; }
.meta { color:var(--muted); margin:4px 0 18px; }
.toolbar { position:sticky; top:0; background:var(--bg); padding:8px 0 12px; z-index:2; display:flex; gap:12px; align-items:center; }
#q { width:420px; max-width:100%; padding:8px 12px; border:1px solid var(--line); border-radius:6px; background:var(--card); color:var(--text); font:inherit; }
#count { color:var(--muted); font-size:12px; }
section { background:var(--card); border:1px solid var(--line); border-radius:8px; margin-bottom:14px; overflow:hidden; }
h2 { margin:0; padding:8px 12px; font-size:13px; font-weight:600; background:var(--head); color:#fff; }
h2 .n { font-weight:400; opacity:.8; }
table { width:100%; border-collapse:collapse; table-layout:fixed; }
td { padding:5px 12px; border-top:1px solid var(--line); vertical-align:top; word-break:break-word; font-family:Consolas, "Cascadia Mono", monospace; }
td.k { width:45%; font-weight:600; }
td.v { color:var(--val); }
td.empty::after { content:"-"; color:var(--muted); }
tr:hover td { background:var(--hover); }
footer { color:var(--muted); font-size:12px; margin-top:18px; }
</style>
</head>
<body>
<div class="wrap">
<h1>$(& $enc $title)</h1>
<div class="meta">$meta</div>
<div class="toolbar"><input id="q" type="search" placeholder="$(& $enc $text.search)" autofocus><span id="count"></span></div>
$($sections.ToString())
<footer>$($text.by) bc-server-admin $script:BcsaVersion</footer>
</div>
<script>
(function () {
  var q = document.getElementById('q'), count = document.getElementById('count');
  function apply() {
    var f = q.value.toLowerCase(), total = 0;
    document.querySelectorAll('section').forEach(function (s) {
      var visible = 0;
      s.querySelectorAll('tbody tr').forEach(function (r) {
        var show = r.textContent.toLowerCase().indexOf(f) >= 0;
        r.style.display = show ? '' : 'none';
        if (show) visible++;
      });
      s.style.display = visible ? '' : 'none';
      total += visible;
    });
    count.textContent = total + ' $($text.settings)';
  }
  q.addEventListener('input', apply);
  apply();
})();
</script>
</body>
</html>
"@
}
