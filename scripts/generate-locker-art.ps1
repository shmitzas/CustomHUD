<#
.SYNOPSIS
    Generates locker_art.vcss, the game's map and rank art for menu_locker by image key;
    with -Maps server_maps.vcss, CustomHUD's own map pictures; or with -Server a server's
    server_maps_custom.vcss, the map pictures of its own addon.

.DESCRIPTION
    Like econ_thumbs.vcss, each image is a class named 'econ-' plus the first 12
    hex digits of the SHA-256 of its lower-cased key, so a plugin points at one
    with the same `image=` directive (FrameComposer.ThumbToken must match):

        map/<name>         a stock map: its 360p screenshot on a slot's thumb
                           panel (.lk-thumb) and its logo on the logo panel (.lk-logo)
        map/<key>          a picture from -Pictures, <key>.png, on the thumb panel alone
        rank/skillgroupN   CS2's competitive emblem, N = 0..18, and every number
                           of each replacement set in $CustomIconSets
        rank/wingmanN      the wingman emblem, N = 0..18
        rank/levelN        the 1..10 level badges this addon ships

    Map rules name the panel because one key draws two pictures. The header
    comment lists the maps, which LockerProfiles.StockMaps must match: a key
    the label fallback (ImageLabels) gives a listed map without art would leave
    a blank card instead of the typographic one.

    A picture's file name is its key, lower-case: a map name (de_dust2) or a Workshop
    id (3070923343), as MapChooser's and MixScrims' integrations send them
    (Directive.IsMapName, Directive.IsWorkshopId). Its rule points at
    panorama/images/custom_game/customhud/maps/<key>.png in whichever addon ships it.
    PNG only: no other raster is proven in game.

    Default mode writes locker_art.vcss for CustomHUD's addon: the game's art from the
    listing. Only paths are written; every image resolves from the player's own CS2
    install, or this addon.

    -Maps and -Server need no listing and write the pictures' rules alone. The map layouts
    include locker_art.vcss, then server_maps.vcss (-Maps), then server_maps_custom.vcss
    (-Server), so the later rule wins a tie: a picture for a map the game has replaces its
    screenshot and keeps its logo. CustomHUD's addon ships an empty server_maps_custom.vcss,
    which a server's own addon replaces with its -Server sheet and its pictures.

.PARAMETER Listing
    A listing of pak01_dir.vpk paths (Source2Viewer-CLI --vpk_list output, or one
    path per line) covering panorama/images/map_icons/ and
    panorama/images/icons/skillgroups/. When omitted, -Source2Viewer produces one.
    Not read with -Maps or -Server.

.PARAMETER Pictures
    The folder of <key>.png map pictures, read with -Maps and -Server. Defaults to the
    addon's resources/panorama/images/custom_game/customhud/maps; a missing folder holds none.

.PARAMETER Maps
    Write the addon's server_maps.vcss, CustomHUD's own map pictures, instead of
    locker_art.vcss: the header alone while there are none.

.PARAMETER Server
    Write a server's sheet of map pictures instead of locker_art.vcss.

.PARAMETER Output
    The sheet to write: the addon's locker_art.vcss, with -Maps its server_maps.vcss, or
    with -Server server_maps_custom.vcss in the current folder.

.EXAMPLE
    .\scripts\generate-locker-art.ps1 -Listing .\vpk_paths.txt
    .\scripts\generate-locker-art.ps1 -Source2Viewer C:\tools\Source2Viewer-CLI.exe
    .\scripts\generate-locker-art.ps1 -Maps
    .\scripts\generate-locker-art.ps1 -Server -Pictures C:\myhud\panorama\images\custom_game\customhud\maps -Output C:\myhud\panorama\styles\custom_game\customhud\server_maps_custom.vcss
#>
[CmdletBinding()]
param(
    [string] $Listing       = $null,
    [string] $Source2Viewer = $null,
    [string] $Cs2Root       = 'C:\Program Files (x86)\Steam\steamapps\common\Counter-Strike Global Offensive',
    [string] $Pictures      = $null,
    [switch] $Maps,
    [switch] $Server,
    [string] $Output        = $null
)

$ErrorActionPreference = 'Stop'
if ($Maps -and $Server) { throw 'Pass -Maps for CustomHUD''s own sheet or -Server for a server''s, not both.' }

$styles = Join-Path $PSScriptRoot '..\resources\panorama\styles\custom_game\customhud'
$images = Join-Path $PSScriptRoot '..\resources\panorama\images\custom_game\customhud'
if (-not $Pictures) { $Pictures = Join-Path $images 'maps' }
$Pictures = [IO.Path]::GetFullPath($Pictures, (Get-Location).ProviderPath)
if (-not $Output) {
    $Output = if ($Server) { 'server_maps_custom.vcss' } elseif ($Maps) { Join-Path $styles 'server_maps.vcss' } else { Join-Path $styles 'locker_art.vcss' }
}
$Output = [IO.Path]::GetFullPath($Output, (Get-Location).ProviderPath)

# Key -> URL, ordinal by key. Any file but a PNG, or any subfolder, fails by name rather than go missing, or ship with
# no rule to draw it when watch-panorama.ps1 compiles it (a .svg, another raster). Only the files an OS leaves pass.
$found = New-Object 'System.Collections.Generic.SortedDictionary[string,string]' ([StringComparer]::Ordinal)
if (($Maps -or $Server) -and (Test-Path -LiteralPath $Pictures -PathType Container)) {
    foreach ($dir in Get-ChildItem -LiteralPath $Pictures -Directory) { throw "'$($dir.FullName)': keep every picture directly in the pictures folder, with no subfolders." }
    foreach ($file in Get-ChildItem -LiteralPath $Pictures -File) {
        if ($file.Name -in 'desktop.ini', 'thumbs.db', '.ds_store') { continue }
        if ($file.Extension -ne '.png') { throw "'$($file.FullName)': the pictures folder holds PNG pictures only, the one format proven in CS2. Save it as a .png, or move it out." }
        if ($file.Name -cnotmatch '^([a-z0-9]+_[a-z0-9_]+|[0-9]+)\.png$') {
            throw "'$($file.FullName)': name a picture after its map as MapChooser or MixScrims gives it, lower-case: <map name>.png (de_dust2.png) or <Workshop id>.png (3070923343.png)."
        }
        $found[$Matches[1]] = "s2r://panorama/images/custom_game/customhud/maps/$($Matches[1]).png"
    }
}
if ($Server -and $found.Count -eq 0) { throw "No <key>.png pictures in '$Pictures'. Pass -Pictures <your pictures folder>." }

$owners = @{}
function Get-Token([string] $Key) {
    $lower = $Key.ToLowerInvariant()
    $hash = [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($lower))
    $token = [Convert]::ToHexString($hash).Substring(0, 12).ToLowerInvariant()
    if ($owners.ContainsKey($token) -and $owners[$token] -ne $lower) {
        throw "Image token collision: '$($owners[$token])' and '$lower' both hash to $token."
    }
    $owners[$token] = $lower
    return $token
}

$sb = New-Object System.Text.StringBuilder
function Add-Rule([string] $Selector, [string] $Url) {
    [void] $sb.Append($Selector).Append(' { background-image: url( "').Append($Url).AppendLine('" ); }')
}

function Save-Sheet {
    New-Item -ItemType Directory -Force -Path (Split-Path $Output -Parent) | Out-Null
    [IO.File]::WriteAllText($Output, $sb.ToString(), (New-Object System.Text.UTF8Encoding $false))
}

if ($Maps -or $Server) {
    if ($Server) {
        [void] $sb.AppendLine('/* CustomHUD server sheet, generated by CustomHUD''s scripts/generate-locker-art.ps1 -Server. Do not edit. */')
        [void] $sb.AppendLine('/* This server''s map pictures, by image key: map/<key>. Its own addon ships this file over CustomHUD''s empty placeholder of the same name. */')
    }
    else {
        [void] $sb.AppendLine('/* Generated by scripts/generate-locker-art.ps1 -Maps. Do not edit. */')
        [void] $sb.AppendLine('/* CustomHUD''s own map pictures, by image key: map/<key>. A server''s own addon ships its pictures in server_maps_custom.vcss. */')
    }
    if ($found.Count) { [void] $sb.AppendLine("/* pictures: $($found.Keys -join ' ') */").AppendLine('') }
    foreach ($key in $found.Keys) { Add-Rule ".lk-thumb.econ-$(Get-Token "map/$key")" $found[$key] }
    Save-Sheet
    Write-Host ("{0} pictures -> {1}" -f $found.Count, $Output)
    return
}

if (-not $Listing) {
    if (-not $Source2Viewer -or -not (Test-Path $Source2Viewer)) {
        throw 'Pass -Listing, or -Source2Viewer pointing at Source2Viewer-CLI.exe.'
    }
    $vpk = Join-Path $Cs2Root 'game\csgo\pak01_dir.vpk'
    if (-not (Test-Path $vpk)) { throw "VPK not found at '$vpk'. Pass -Cs2Root." }
    $Listing = Join-Path ([IO.Path]::GetTempPath()) 'customhud_art_listing.txt'
    & $Source2Viewer -i $vpk --vpk_list -f 'panorama/images/' | Set-Content -Path $Listing -Encoding UTF8
    if ($LASTEXITCODE -ne 0) { throw "Source2Viewer-CLI exited with $LASTEXITCODE." }
}

$shots = New-Object 'System.Collections.Generic.SortedSet[string]' ([StringComparer]::Ordinal)
$logos = New-Object 'System.Collections.Generic.SortedSet[string]' ([StringComparer]::Ordinal)
$groups = New-Object 'System.Collections.Generic.SortedSet[string]' ([StringComparer]::Ordinal)
foreach ($line in [IO.File]::ReadLines((Resolve-Path $Listing).Path)) {
    $path = ($line -split '\s+', 2)[0].Replace('\', '/')
    if ($path -match '^panorama/images/map_icons/screenshots/360p/([a-z0-9_]+)_png\.vtex_c$') { [void] $shots.Add($Matches[1]) }
    elseif ($path -match '^panorama/images/map_icons/map_icon_([a-z0-9_]+)\.vsvg_c$') { [void] $logos.Add($Matches[1]) }
    elseif ($path -match '^panorama/images/icons/skillgroups/((skillgroup|wingman)\d{1,2})\.vsvg_c$') { [void] $groups.Add($Matches[1]) }
}

# Lobby and Rush art are not maps a server votes on.
$stock = @($shots | Where-Object { $logos.Contains($_) -and $_ -notmatch '^(lobby_|rush_)' })
if ($stock.Count -eq 0) { throw "No map art found in '$Listing'." }
if ($groups.Count -eq 0) { throw "No skill-group emblems found in '$Listing'." }
$levels = @(1..10 | Where-Object { Test-Path (Join-Path $images "faceit_lvl$_.svg") })

# Replacement rank icon sets for Ranks' Custom mode: another Workshop addon ships each as
# panorama/images/icons/skillgroups/skillgroup<number>, which the player's game draws for that
# number. A class per number is all CustomHUD adds. RankArt.CustomIconSets holds the same table.
$CustomIconSets = @(
    # The set Ranks' and K4-LevelRanks' docs use as their example: 100 badges (Workshop 3340561607).
    @{ First = 26283401; Last = 26283500 }
)

[void] $sb.AppendLine('/* Generated by scripts/generate-locker-art.ps1. Do not edit. */')
[void] $sb.AppendLine('/* Paths only: every image resolves from the player''s own CS2 install, or this addon. */')
[void] $sb.AppendLine("/* maps: $($stock -join ' ') */")
[void] $sb.AppendLine('')
foreach ($map in $stock) {
    $token = Get-Token "map/$map"
    Add-Rule ".lk-thumb.econ-$token" "s2r://panorama/images/map_icons/screenshots/360p/${map}_png.vtex"
    Add-Rule ".lk-logo.econ-$token" "s2r://panorama/images/map_icons/map_icon_$map.vsvg"
}
[void] $sb.AppendLine('')
foreach ($group in $groups) {
    $token = Get-Token "rank/$group"
    [void] $sb.Append('.econ-').Append($token).Append(' { background-image: url( "s2r://panorama/images/icons/skillgroups/').Append($group).AppendLine('.vsvg" ); }')
}
[void] $sb.AppendLine("/* replacement rank icons: $(($CustomIconSets | ForEach-Object { "$($_.First)-$($_.Last)" }) -join ' ') */")
foreach ($set in $CustomIconSets) {
    for ($number = $set.First; $number -le $set.Last; $number++) {
        $token = Get-Token "rank/skillgroup$number"
        [void] $sb.Append('.econ-').Append($token).Append(' { background-image: url( "s2r://panorama/images/icons/skillgroups/skillgroup').Append($number).AppendLine('.vsvg" ); }')
    }
}
foreach ($level in $levels) {
    $token = Get-Token "rank/level$level"
    [void] $sb.Append('.econ-').Append($token).Append(' { background-image: url( "s2r://panorama/images/custom_game/customhud/faceit_lvl').Append($level).AppendLine('.vsvg" ); }')
}

Save-Sheet
Write-Host ("{0} maps, {1} emblems, {2} replacement icons, {3} levels -> {4}" -f $stock.Count, $groups.Count,
    ($CustomIconSets | ForEach-Object { $_.Last - $_.First + 1 } | Measure-Object -Sum).Sum, $levels.Count, $Output)
