<#
.SYNOPSIS
    Copilot hook: once a session has changed CustomHUD, its agent cannot finish a turn until
    scripts/audit.ps1 passes on exactly what it leaves behind.

.DESCRIPTION
    Register it user-wide, so it fires whichever folder a session opened: a repository's
    .github/hooks only load when the session starts inside that repository. In
    %USERPROFILE%\.copilot\hooks\customhud-audit.json, with <repo> this repository's path:

        { "version": 1, "hooks": {
            "sessionStart": [ { "type": "command", "timeoutSec": 30,
                "powershell": "& '<repo>\\scripts\\audit-hook.ps1' -Event sessionStart" } ],
            "agentStop":    [ { "type": "command", "timeoutSec": 120,
                "powershell": "& '<repo>\\scripts\\audit-hook.ps1' -Event agentStop" } ] } }

    sessionStart records the repository's fingerprint, HEAD and changed files. At the end of each
    agent turn:
      - nothing changed since the session started: the agent finishes;
      - no changed file is this session's: the agent finishes. The session's transcript, which
        also logs its subagents' tool calls, makes a file its own when one of its edit tools wrote
        it, or when the file (for a rename or a delete, its folder) was written while one of its
        shell commands ran that named this repository or ran inside it, or changed since the last
        stop with its old timestamps kept and such a command ran since that stop (a command that
        only runs audit.ps1 or this hook counts as none). Files it changed before its last passing
        turn no longer count. Without a readable transcript or a recorded HEAD, every change counts.
        Timestamps decide, so a file this session wrote that another conversation rewrote later,
        or a deleted file whose folder was written later, counts as theirs;
      - build/audit/receipt.json holds a full pass of exactly this state: the agent finishes;
      - otherwise the quick audit runs, and a failure becomes the agent's next prompt;
      - C#, Panorama or translations changed since the last full pass: one more prompt asks
        for the full audit (build, dependency check, compile).
    An identical prompt repeats at most twice. Any error in this hook lets the agent finish,
    because a broken hook must never trap a session. State and log live in
    %LOCALAPPDATA%\CustomHUD\audit-hook.

.PARAMETER Event
    sessionStart, agentStop, or subagentStop for a custom agent's own scoped Stop hook.
#>
param([ValidateSet('sessionStart', 'agentStop', 'subagentStop')] [string] $Event = 'agentStop')

# The hook's shell may be Windows PowerShell 5.1, under which the audit's generators write mojibake.
if ($PSVersionTable.PSVersion.Major -lt 7 -and (Get-Command pwsh -ErrorAction SilentlyContinue)) {
    $stdin = ''
    if ([Console]::IsInputRedirected) { $stdin = [Console]::In.ReadToEnd() }
    $answer = $stdin | pwsh -NoProfile -NonInteractive -File $PSCommandPath -Event $Event
    [Console]::Out.Write((@($answer) -join "`n"))
    return
}

$ErrorActionPreference = 'Stop'
$started  = Get-Date
# Taken before the repository is read, so a write during this stop is not dated before its pass.
$stopAt   = $started.ToUniversalTime().Ticks
$Grace    = 2 * [TimeSpan]::TicksPerSecond
$audit    = Join-Path $PSScriptRoot 'audit.ps1'
$repo     = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$stateDir = Join-Path $env:LOCALAPPDATA 'CustomHUD\audit-hook'
$log      = Join-Path $stateDir 'hook.log'

function Write-Log([string] $Text) {
    try {
        if ((Test-Path -LiteralPath $log) -and (Get-Item -LiteralPath $log).Length -gt 1MB) { Remove-Item -LiteralPath $log -Force }
        Add-Content -LiteralPath $log -Value ('{0:u} {1,-12} {2,-10} {3} ({4:N1}s)' -f (Get-Date), $Event, $script:session, $Text, ((Get-Date) - $started).TotalSeconds)
    }
    catch { }
}

# stdout carries exactly one JSON object: the runtime parses all of it as the hook's answer.
function Send($Output, [string] $Why) {
    Write-Log $Why
    [Console]::Out.Write((ConvertTo-Json -InputObject $Output -Compress -Depth 4))
}

function Save-State {
    [IO.File]::WriteAllText($script:statePath, (ConvertTo-Json -InputObject $script:state -Compress -Depth 8), (New-Object System.Text.UTF8Encoding $false))
}

# Two spellings of one path are one file on Windows, so one key; -Latest keeps the later time.
function Merge-Paths($Table, [switch] $Latest) {
    if ($Table -isnot [Collections.IDictionary]) { return $Table }
    $out = @{}
    foreach ($k in @($Table.Keys)) {
        if (-not $out.ContainsKey($k) -or ($Latest -and [long] $Table[$k] -gt [long] $out[$k])) { $out[$k] = $Table[$k] }
    }
    return $out
}

function Read-State {
    if (-not (Test-Path -LiteralPath $script:statePath)) { return $null }
    $json = Get-Content -LiteralPath $script:statePath -Raw
    $state = @{}
    if ($PSVersionTable.PSVersion.Major -lt 6) {
        foreach ($p in ($json | ConvertFrom-Json).PSObject.Properties) { $state[$p.Name] = $p.Value }
        return $state
    }
    # A plain ConvertFrom-Json throws on keys that differ only in case, which older states can hold.
    $read = $json | ConvertFrom-Json -AsHashtable
    if ($read -is [Collections.IDictionary]) { foreach ($k in @($read.Keys)) { $state[$k] = $read[$k] } }
    if ($state['tx'] -is [Collections.IDictionary]) { $state['tx']['writes'] = Merge-Paths $state['tx']['writes'] -Latest }
    if ($state['prev'] -is [Collections.IDictionary]) { $state['prev']['sigs'] = Merge-Paths $state['prev']['sigs'] }
    return $state
}

function Get-Key([string] $Text) {
    $sha = [Security.Cryptography.SHA256]::Create()
    return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))) -replace '-', '').Substring(0, 16)
}

# The user-wide hook and a custom agent's own Stop hook can fire for one stop: the second
# reuses the first's answer instead of auditing again and spending the block budget twice.
function Answer($Output, [string] $Why) {
    $script:state['last'] = @{ at = (Get-Date).ToUniversalTime().Ticks; all = $script:fingerprints['all']; output = (ConvertTo-Json -InputObject $Output -Compress -Depth 4) }
    Save-State
    Send $Output $Why
}

function Block([string] $Reason, [string] $Why) {
    $key = Get-Key $Reason
    $count = 1
    if ($script:state['blockKey'] -eq $key) { $count = [int] $script:state['blockCount'] + 1 }
    $script:state['blockKey'] = $key
    $script:state['blockCount'] = $count
    if ($count -gt 2) { Answer @{} "released after two identical blocks: $Why"; return }
    Answer @{ decision = 'block'; reason = $Reason } "blocked ($count): $Why"
}

function Pass([string] $Why) {
    $script:state['blockKey'] = ''
    $script:state['blockCount'] = 0
    Answer @{} $Why
}

$ShellTools = '^(powershell|bash|shell|run_in_terminal|send_to_terminal|run_task|create_and_run_task|write_powershell|write_bash)$'
$WriteTools = '^(edit|create|str_replace_editor|apply_patch|multi_edit|write|create_file|edit_file|replace_string_in_file|multi_replace_string_in_file|insert_edit_into_file|vscode_renameSymbol)$'
# The audit writes only gitignored build output, so a command that just runs it (or this hook) authors nothing.
$AuditRun = '(?<![\w.-])scripts\\audit(-hook)?\.ps1(?![\w.-])'
$ReadTail = '^(select-object|select|out-string|out-host|out-null|format-\w+|where-object|measure-object|sort-object)(?![\w-])'
$Navigate = '^(cd|sl|chdir|set-location|push-location|pushd|pop-location|popd)(?![\w-])'

function Get-Head {
    $head = git --no-optional-locks -C $repo rev-parse HEAD 2>$null
    if ($LASTEXITCODE -eq 0) { return ([string] $head).Trim() }
    return ''
}

function Format-Files($Files) {
    $list = @($Files)
    if (-not $list.Count) { return 'none' }
    $text = ($list | Select-Object -First 8) -join ', '
    if ($list.Count -gt 8) { $text += " (+$($list.Count - 8) more)" }
    return $text
}

function Get-RepoFile([string] $Path, [string] $Cwd) {
    try { $full = [IO.Path]::GetFullPath($(if ($Cwd -and -not [IO.Path]::IsPathRooted($Path)) { Join-Path $Cwd $Path } else { $Path })) } catch { return }
    if ($full.StartsWith($repo + '\', [StringComparison]::OrdinalIgnoreCase)) { return $full.Substring($repo.Length + 1).Replace('\', '/') }
}

function Add-ArgPaths([Text.Json.JsonElement] $El, [Collections.Generic.List[string]] $Out, [int] $Depth = 0) {
    if ($Depth -gt 4) { return }
    $patch = '(?m)^\*\*\* (?:(?:Add|Update|Delete) File|Move to): (.+?)\s*$'
    if ($El.ValueKind -eq 'Array') { foreach ($v in $El.EnumerateArray()) { Add-ArgPaths $v $Out ($Depth + 1) } }
    elseif ($El.ValueKind -eq 'String') { foreach ($m in [regex]::Matches($El.GetString(), $patch)) { $Out.Add($m.Groups[1].Value) } }
    elseif ($El.ValueKind -eq 'Object') {
        foreach ($p in $El.EnumerateObject()) {
            if ($p.Value.ValueKind -ne 'String') { Add-ArgPaths $p.Value $Out ($Depth + 1) }
            elseif ($p.Name -in 'path', 'filePath', 'file_path') { $Out.Add($p.Value.GetString()) }
            elseif ($p.Name -eq 'uri' -and $p.Value.GetString().StartsWith('file:')) { try { $Out.Add(([Uri] $p.Value.GetString()).LocalPath -replace '^/(?=[A-Za-z]:)', '') } catch { } }
            elseif ($p.Name -in 'input', 'patch') { foreach ($m in [regex]::Matches($p.Value.GetString(), $patch)) { $Out.Add($m.Groups[1].Value) } }
        }
    }
}

function Test-RepoCommand([string] $Text, [bool] $CwdInRepo) {
    $cmd = $Text.ToLowerInvariant().Replace('/', '\').Replace('\\', '\')
    $parts = @($cmd -split '\r?\n|;|&&|\|\|' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $audits = @($parts | Where-Object {
        $pipe = @($_ -split '\|' | ForEach-Object { $_.Trim() })
        $pipe[0] -match $AuditRun -and -not @($pipe | Select-Object -Skip 1 | Where-Object { $_ -notmatch $ReadTail }).Count
    })
    if ($audits.Count -and -not @($parts | Where-Object { $audits -notcontains $_ -and $_ -notmatch $Navigate }).Count) { return $false }
    # Covers the full path too, and keeps a sibling such as CustomHUD.wiki out.
    $leaf = '(?<![\w.-])' + [regex]::Escape((Split-Path $repo -Leaf).ToLowerInvariant()) + '(?![\w.-])'
    return $CwdInRepo -or $cmd -match $leaf
}

# $Agent '' closes the root agent's commands, $null every agent's.
function Close-Windows($Ctx, [long] $At, $Agent) {
    foreach ($w in $Ctx.Windows) { if ([long] $w.e -eq [long]::MaxValue -and ($null -eq $Agent -or [string] $w.a -eq $Agent)) { $w.e = $At } }
    foreach ($id in @($Ctx.Tx.pending.Keys)) {
        $p = $Ctx.Tx.pending[$id]
        if ($p.k -eq 's' -and ($null -eq $Agent -or [string] $p.a -eq $Agent)) {
            $Ctx.Windows.Add(@{ s = [long] $p.s; e = $At; a = [string] $p.a })
            $Ctx.Tx.pending.Remove($id)
        }
    }
}

function Read-ToolLine([string] $Line, $Ctx) {
    $tx = $Ctx.Tx
    $start = $Line.IndexOf('"type":"tool.execution_start"', [StringComparison]::Ordinal) -ge 0
    if (-not $start -and $Line.IndexOf('"type":"tool.execution_complete"', [StringComparison]::Ordinal) -lt 0) { return }
    $id = [regex]::Match($Line, '"toolCallId":"([^"]+)"').Groups[1].Value
    if (-not $id) { return }
    $kind = ''
    if ($start) {
        $name = [regex]::Match($Line, '"toolName":"([^"]+)"').Groups[1].Value
        if (-not $name) { return }
        $kind = if ($name -match $WriteTools) { 'w' } elseif ($name -match $ShellTools) { 's' } else { '' }
        # Other tools only prove the format is known.
        if (-not $kind -and $tx.known) { return }
    }
    elseif (-not $tx.pending.ContainsKey($id)) { return }
    $doc = [Text.Json.JsonDocument]::Parse($Line)
    try {
        $root = $doc.RootElement
        $data = $root.GetProperty('data')
        $ts = [DateTimeOffset]::Parse($root.GetProperty('timestamp').GetString(), [Globalization.CultureInfo]::InvariantCulture).UtcTicks
        $el = [Text.Json.JsonElement]::new()
        if ($start) {
            if ($kind) {
                $agent = if ($root.TryGetProperty('agentId', [ref] $el) -and $el.ValueKind -eq 'String') { $el.GetString() } else { '' }
                if (-not $data.TryGetProperty('arguments', [ref] $el)) { return }
                if ($kind -eq 'w') {
                    $paths = [Collections.Generic.List[string]]::new()
                    Add-ArgPaths $el $paths
                    if (-not $paths.Count) { return }
                    $files = @(foreach ($p in $paths) { Get-RepoFile $p $Ctx.Cwd })
                    if ($files.Count) { $tx.pending[$id] = @{ k = 'w'; f = $files } }
                }
                else {
                    if ($el.ValueKind -ne 'Object') { return }
                    $cmd = @(foreach ($p in $el.EnumerateObject()) { if ($p.Name -in 'command', 'input', 'cmd' -and $p.Value.ValueKind -eq 'String') { $p.Value.GetString() } }) -join "`n"
                    if (-not $cmd) { return }
                    if (Test-RepoCommand $cmd $Ctx.InRepo) { $tx.pending[$id] = @{ k = 's'; s = $ts; a = $agent } }
                }
            }
            $tx.known = $true
            return
        }
        $p = $tx.pending[$id]
        $tx.pending.Remove($id)
        if ($p.k -eq 'w') {
            if ($data.TryGetProperty('success', [ref] $el) -and $el.ValueKind -eq 'True') { foreach ($f in $p.f) { $tx.writes[$f] = $ts } }
            return
        }
        # Copilot CLI sets shellExecution.exitCode only on a finished command; VS Code completions carry no result.
        $exit = [Text.Json.JsonElement]::new()
        $closed = -not $data.TryGetProperty('result', [ref] $el) -or ($data.TryGetProperty('shellExecution', [ref] $el) -and $el.ValueKind -eq 'Object' -and $el.TryGetProperty('exitCode', [ref] $exit) -and $exit.ValueKind -eq 'Number')
        $Ctx.Windows.Add(@{ s = [long] $p.s; e = $(if ($closed) { $ts } else { [long]::MaxValue }); a = [string] $p.a })
    }
    finally { $doc.Dispose() }
}

# Reads only the bytes added since the last stop: a transcript can be far too big to reread in the hook's timeout.
function Update-Transcript($Ctx, [string] $Path, [long] $Since) {
    $tx = $Ctx.Tx
    $fs = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
    try {
        if ([long] $tx.offset -gt $fs.Length) { $tx.offset = 0 }
        $fs.Position = [long] $tx.offset
        $chunk = [byte[]]::new(16MB)
        $carry = [IO.MemoryStream]::new()
        while (($n = $fs.Read($chunk, 0, $chunk.Length)) -gt 0) {
            $carry.Write($chunk, 0, $n)
            $bytes = $carry.GetBuffer()
            $len = [int] $carry.Length
            $end = [Array]::LastIndexOf($bytes, [byte] 10, $len - 1)
            if ($end -lt 0) { continue }
            foreach ($line in [Text.Encoding]::UTF8.GetString($bytes, 0, $end + 1).Split("`n")) {
                if ($line.IndexOf('"type":"tool.execution_', [StringComparison]::Ordinal) -ge 0) { try { Read-ToolLine $line $Ctx } catch { }; continue }
                # A stop hook, abort or subagent's end closes that agent's commands (no agentId = root); a start, resume or shutdown closes all.
                $every = $line.Contains('"type":"session.shutdown"') -or $line.Contains('"type":"session.resume"') -or $line.Contains('"type":"session.start"')
                if ($every -or $line.Contains('"type":"abort"') -or $line.Contains('"type":"subagent.completed"') -or $line.Contains('"type":"subagent.failed"') -or
                    ($line.Contains('"type":"hook.start"') -and $line.Contains('"hookType":"agentStop"'))) {
                    $agent = if ($every) { $null } else { [regex]::Match($line, '"agentId":"([^"]+)"').Groups[1].Value }
                    $at = [regex]::Match($line, '"timestamp":"([^"]+)"').Groups[1].Value
                    if ($at) { try { Close-Windows $Ctx ([DateTimeOffset]::Parse($at, [Globalization.CultureInfo]::InvariantCulture).UtcTicks) $agent } catch { } }
                }
            }
            $tx.offset = [long] $tx.offset + $end + 1
            $rest = [byte[]]::new($len - $end - 1)
            [Array]::Copy($bytes, $end + 1, $rest, 0, $rest.Length)
            $carry.SetLength(0)
            $carry.Write($rest, 0, $rest.Length)
        }
    }
    finally { $fs.Dispose() }
    Close-Windows $Ctx ([DateTime]::UtcNow.Ticks) ''
    $tx.windows = @($Ctx.Windows | Where-Object { [long] $_.e -ge $Since - $Grace })
}

function Test-InWindow($Wins, [long] $At) {
    foreach ($w in $Wins) { if ($At + $Grace -ge [long] $w.s -and $At - $Grace -le [long] $w.e) { return $true } }
    return $false
}

function Get-Changed {
    $changed = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $renamed = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $status = (@(git --no-optional-locks -C $repo -c core.quotepath=off status --porcelain -z -uall 2>$null) -join "`n") -split "`0"
    if ($LASTEXITCODE -ne 0) { return }
    for ($i = 0; $i -lt $status.Count; $i++) {
        if ($status[$i].Length -lt 4) { continue }
        [void] $changed.Add($status[$i].Substring(3))
        if ($status[$i][0] -eq 'R') { [void] $renamed.Add($status[$i].Substring(3)) }
        if ($status[$i][0] -in 'R', 'C') { $i++ }
    }
    return @{ Files = $changed; Renamed = $renamed }
}

# Hashes, or length:time past 300 files; they date a write that kept old timestamps (Copy-Item onto a file).
function Get-Sigs($Files) {
    $sigs = @{}
    foreach ($f in $Files) {
        $item = Get-Item -LiteralPath (Join-Path $repo $f) -Force -ErrorAction SilentlyContinue
        $sigs[$f] = if (-not $item -or $item.PSIsContainer) { 'missing' }
                    elseif ($Files.Count -gt 300 -or $item.Length -gt 1MB) { "$($item.Length):$($item.LastWriteTimeUtc.Ticks)" }
                    else {
                        $hash = Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256 -ErrorAction SilentlyContinue
                        if ($hash) { $hash.Hash } else { 'unreadable' }
                    }
    }
    return $sigs
}

function New-State {
    $state = @{ baseline = $script:fingerprints['all']; head = Get-Head; blockKey = ''; blockCount = 0 }
    $now = Get-Changed
    if ($now) { $state['prev'] = @{ at = $stopAt; capped = $now.Files.Count -gt 1000; sigs = Get-Sigs @($now.Files | Sort-Object | Select-Object -First 1000) } }
    return $state
}

# The changed files this session wrote since its last passing turn; $null when its transcript can't tell.
function Get-OwnFiles($Payload) {
    $path = @($Payload.transcriptPath, $Payload.transcript_path, (Join-Path $env:USERPROFILE ".copilot\session-state\$($script:session)\events.jsonl")) |
        Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) } | Select-Object -First 1
    if (-not $path) { Write-Log 'no session transcript, so every change counts'; return }
    if (-not $script:state['head']) { Write-Log 'no HEAD recorded at session start, so every change counts'; return }
    $since = [long] $script:state['audited']
    $tx = @{}
    if ($script:state['tx'] -is [Collections.IDictionary]) { $tx = $script:state['tx'] }
    if ($tx.path -ne $path) { $tx = @{ path = [string] $path; offset = 0L; known = $false } }
    foreach ($k in 'writes', 'pending') { if (-not $tx[$k]) { $tx[$k] = @{} } }
    $cwd = [string] $Payload.cwd
    $here = if ($cwd) { [IO.Path]::GetFullPath($cwd).TrimEnd('\') } else { '' }
    $ctx = @{ Tx = $tx; Cwd = $cwd; InRepo = ($here -ieq $repo -or $here.StartsWith($repo + '\', [StringComparison]::OrdinalIgnoreCase)); Windows = [Collections.Generic.List[object]]::new() }
    foreach ($w in @($tx.windows)) { if ($w) { $ctx.Windows.Add($w) } }
    $clock = [Diagnostics.Stopwatch]::StartNew()
    Update-Transcript $ctx $path $since
    $script:state['tx'] = $tx
    if (-not $tx.known) { Write-Log "transcript not recognised, so every change counts: $path"; return }
    if ($clock.Elapsed.TotalSeconds -gt 5) { Write-Log ('read {0:N0} MB of transcript in {1:N1}s' -f ($tx.offset / 1MB), $clock.Elapsed.TotalSeconds) }

    $now = Get-Changed
    if (-not $now) { Write-Log 'git status failed, so every change counts'; return }
    $changed = $now.Files
    $head = Get-Head
    if ($head -and $script:state['head'] -ne $head) {
        foreach ($f in @(git --no-optional-locks -C $repo -c core.quotepath=off diff --name-only $script:state['head'] $head 2>$null)) { if ($f) { [void] $changed.Add($f) } }
    }
    # The fingerprint moved, yet git shows nothing: an ignored or timestamp-only change can't be attributed.
    if (-not $changed.Count) { Write-Log 'fingerprint changed with no changed file in git, so every change counts'; return }

    $mine = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($f in @($tx.writes.Keys)) { if ($changed.Contains($f) -and [long] $tx.writes[$f] -gt $since) { [void] $mine.Add($f) } }
    $wins = @(@($tx.windows) + @(foreach ($p in $tx.pending.Values) { if ($p.k -eq 's') { @{ s = [long] $p.s; e = [long]::MaxValue } } }) | Where-Object { $_ })
    $list = @($changed | Sort-Object | Select-Object -First 1000)
    $sigs = Get-Sigs $list
    $prev = $null
    if ($script:state['prev'] -is [Collections.IDictionary]) { $prev = $script:state['prev'] }
    $from = if ($prev) { [long] $prev.at } else { 0L }
    $known = if ($prev -and -not $prev.capped -and $prev.sigs -is [Collections.IDictionary]) { $prev.sigs } else { $null }
    $ranSince = $false
    foreach ($w in $wins) { if ([long] $w.e -gt [Math]::Max($from, $since)) { $ranSince = $true; break } }
    if ($wins.Count) {
        foreach ($f in $list) {
            if ($mine.Contains($f)) { continue }
            $full = Join-Path $repo $f
            $times = [Collections.Generic.List[long]]::new()
            $item = Get-Item -LiteralPath $full -Force -ErrorAction SilentlyContinue
            if ($item) {
                # A rename keeps the file's times and changes its folder's.
                $times.Add($item.LastWriteTimeUtc.Ticks); $times.Add($item.CreationTimeUtc.Ticks)
                if ($now.Renamed.Contains($f)) { $times.Add((Get-Item -LiteralPath (Split-Path $full -Parent) -Force).LastWriteTimeUtc.Ticks) }
            }
            else {
                # A deleted file leaves only its folder's write time.
                $dir = Split-Path $full -Parent
                while ($dir.Length -gt $repo.Length -and -not (Test-Path -LiteralPath $dir)) { $dir = Split-Path $dir -Parent }
                $times.Add((Get-Item -LiteralPath $dir -Force).LastWriteTimeUtc.Ticks)
            }
            $hit = $false
            foreach ($at in $times) { if ($at -gt $since -and (Test-InWindow $wins $at)) { $hit = $true; break } }
            if (-not $hit -and $item -and $ranSince -and $null -ne $known) {
                # Absent from the last stop's signatures = unchanged then; hash, length:time and unreadable don't compare.
                $was = if ($known.Contains($f)) { [string] $known[$f] } else { '' }
                $cur = [string] $sigs[$f]
                $hit = $was -ne $cur -and 'unreadable' -notin @($was, $cur) -and ($was -eq '' -or ($was -match ':') -eq ($cur -match ':')) -and
                    $item.LastWriteTimeUtc.Ticks -le $from -and $item.CreationTimeUtc.Ticks -le $from
                # The next stop's signatures already hold the copy, so it stays this session's until its next pass.
                if ($hit) { $tx.writes[$f] = $stopAt }
            }
            if ($hit) { [void] $mine.Add($f) }
        }
    }
    $script:state['prev'] = @{ at = $stopAt; capped = $changed.Count -gt 1000; sigs = $sigs }
    if ($changed.Count -gt 1000 -and -not $mine.Count) { [void] $mine.Add('(over 1000 changed files, not checked)') }
    return @{ Changed = @($changed | Sort-Object); Mine = @($mine | Sort-Object) }
}

$script:session = 'manual'
$mutex = $null
try {
    $payload = $null
    if ([Console]::IsInputRedirected) {
        $raw = [Console]::In.ReadToEnd()
        if ($raw.Trim()) { $payload = ConvertFrom-Json $raw }
    }
    if ($payload) {
        if ($payload.sessionId) { $script:session = [string] $payload.sessionId }
        elseif ($payload.session_id) { $script:session = [string] $payload.session_id }
    }
    $safe = $script:session -replace '[^\w-]', '_'
    $mutex = New-Object Threading.Mutex($false, "Local\CustomHUD-audit-hook-$safe")
    try { [void] $mutex.WaitOne(150000) } catch [Threading.AbandonedMutexException] { }

    $sessions = Join-Path $stateDir 'sessions'
    New-Item -ItemType Directory -Force -Path $sessions | Out-Null
    $script:statePath = Join-Path $sessions ($safe + '.json')
    $script:state = Read-State
    $script:fingerprints = & $audit -Fingerprint

    if ($Event -eq 'sessionStart') {
        if (-not $script:state) {
            $script:state = New-State
            Save-State
        }
        Get-ChildItem -LiteralPath $sessions -File | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-14) } | Remove-Item -Force
        Send @{} 'baseline recorded'
        return
    }
    if (-not $script:state) {
        $script:state = New-State
        Save-State
        Send @{} 'no baseline for this session yet; recorded one'
        return
    }
    $last = $script:state['last']
    if ($last -and $last.all -eq $script:fingerprints['all'] -and ((Get-Date).ToUniversalTime().Ticks - [long] $last.at) -lt 100000000) {
        Write-Log 'same state as the run a moment ago; same answer'
        [Console]::Out.Write([string] $last.output)
        return
    }
    if ($script:state['baseline'] -eq $script:fingerprints['all']) { Pass 'CustomHUD unchanged this session'; return }

    $own = $null
    try { $own = Get-OwnFiles $payload }
    catch { Write-Log "attribution failed, so every change counts: $($_.Exception.Message)" }
    if ($own -and -not $own.Mine.Count) { Pass ('CustomHUD changed only by other conversations: ' + (Format-Files $own.Changed)); return }
    $ownLine = if ($own) { 'Files this session changed: ' + (Format-Files $own.Mine) } else { 'This session has no readable transcript, so every change in CustomHUD counts as its own.' }
    if ($own) { Write-Log ('changed by this session: ' + (Format-Files $own.Mine)) }

    $receipt = $null
    $receiptPath = Join-Path $repo 'build\audit\receipt.json'
    if (Test-Path -LiteralPath $receiptPath) { $receipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json }
    if ($receipt -and $receipt.full -and $receipt.full.all -eq $script:fingerprints['all']) {
        $script:state['audited'] = $stopAt
        Pass 'a full pass covers this state'
        return
    }

    $json = Join-Path $stateDir ('quick-' + [guid]::NewGuid().ToString('N') + '.json')
    try {
        & $audit -Quick -JsonPath $json *> $null
        $result = Get-Content -LiteralPath $json -Raw | ConvertFrom-Json
    }
    finally { Remove-Item -LiteralPath $json -Force -ErrorAction SilentlyContinue }

    $command = "pwsh -NoProfile -File `"$audit`""
    if (-not $result.pass) {
        $errors = @($result.findings | Where-Object { $_.Level -eq 'error' })
        $lines = @(foreach ($f in ($errors | Select-Object -First 25)) {
            $where = if ($f.Line) { "$($f.File):$($f.Line)" } else { $f.File }
            "  $($f.Check)  $where  $($f.Message)"
        })
        if ($errors.Count -gt 25) { $lines += "  ...and $($errors.Count - 25) more" }
        $rules = @(foreach ($p in $result.rules.PSObject.Properties) { "  $($p.Name): $($p.Value)" })
        $reason = @(
            "[CustomHUD audit hook] This session changed CustomHUD and the quick audit fails with $($errors.Count) errors:"
            $lines
            ''
            $ownLine
            ''
            'The rules behind them:'
            $rules
            ''
            "Fix them, rerun $command until it prints PASS, and only then finish."
            'If a finding is wrong, say so in your reply instead of working around it.'
        ) -join "`n"
        Block $reason "quick audit: $($errors.Count) errors"
        return
    }

    $stale = @('cs', 'panorama', 'i18n' | Where-Object { -not $receipt -or -not $receipt.full -or $receipt.full.$_ -ne $script:fingerprints[$_] })
    if ($stale.Count) {
        $reason = @(
            "[CustomHUD audit hook] This session changed CustomHUD ($($stale -join ', ')) since the last full audit, and the quick audit alone passes."
            $ownLine
            "Run $command"
            'It publishes the plugin as CI does, runs SoftDependencyCheck and the wiki check, and compiles the changed Panorama files into the customhud addon.'
            'Fix whatever it reports, then finish. If it cannot run here, say so in your final message.'
        ) -join "`n"
        Block $reason ('full audit needed: ' + ($stale -join ', '))
        return
    }
    $script:state['audited'] = $stopAt
    Pass 'quick audit passed and the full pass is current'
}
catch {
    Write-Log ('hook error, letting the agent finish: ' + $_.Exception.Message)
    [Console]::Out.Write('{}')
}
finally {
    if ($mutex) { try { $mutex.ReleaseMutex() } catch { }; $mutex.Dispose() }
}
