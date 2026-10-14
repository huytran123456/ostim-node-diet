# OStimNodeDiet.ps1 - shrink the Pandora-built 0_Master.hkx without losing animations (2026-10-15)
#
# Every OStim pack animation state is built as  State -> ModifierGenerator -> (BSIsActiveModifier
# setting bAnimationDriven, ClipGenerator). That wrapper pair is identical for all animations of a
# pack. This script re-points the pointers so that ONE wrapper wraps the whole pack state machine and
# every animation state points straight at its clip. Same in-game effect (bAnimationDriven is on while
# any animation of the pack plays), ~2 behavior nodes fewer per animation, which keeps the graph under
# Havok's 65,536 node-id limit (int16 ids wrap and collide above that -> OStim crash SkyrimSE+0AF724B).
#
# Only the packfile's global fixup table is edited (pointer targets); file size does not change.
# A backup is written next to the file as 0_Master.hkx.original. Rollback: run the behavior engine again, or -Rollback.
param(
    [string]$Path,          # 0_Master.hkx; a file picker opens when omitted
    [switch]$DryRun,        # analyse and verify only, write nothing
    [switch]$Rollback       # restore 0_Master.hkx.original
)
$ErrorActionPreference = 'Stop'
$logFile = Join-Path $PSScriptRoot 'OStimNodeDiet.log'
function Say($m) { Write-Host $m; Add-Content -Path $logFile -Value ("[{0:yyyy-MM-dd HH:mm:ss}] {1}" -f (Get-Date), $m) }

if (-not $Path) {
    Add-Type -AssemblyName System.Windows.Forms
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Title = 'Select the 0_Master.hkx built by your behavior engine (meshes\actors\character\behaviors)'
    $dlg.Filter = '0_Master.hkx|0_Master.hkx|Havok behavior (*.hkx)|*.hkx'
    if ($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { Write-Host 'Cancelled.'; exit 1 }
    $Path = $dlg.FileName
}
if (-not (Test-Path -LiteralPath $Path)) { Say "File not found: $Path"; exit 1 }

if ($Rollback) {
    $backup = "$Path.original"
    if (-not (Test-Path -LiteralPath $backup)) { Say "No backup found ($backup). Run your behavior engine again to get the original file."; exit 1 }
    if ((Get-Item -LiteralPath $backup).Length -ne (Get-Item -LiteralPath $Path).Length) {
        Say "Backup does not match the current file (behavior engine was run again since?). Not restoring - run your behavior engine again instead."; exit 1
    }
    Copy-Item -LiteralPath $backup -Destination $Path -Force
    Say "Restored the original file from $backup"
    exit 0
}
$b = [IO.File]::ReadAllBytes($Path)
function I32([int]$o) { [BitConverter]::ToInt32($b, $o) }
function CStr([int]$o) { $e = $o; while ($b[$e] -ne 0) { $e++ }; [Text.Encoding]::ASCII.GetString($b, $o, $e - $o) }

# ---------- parse packfile ----------
if ((I32 0) -ne 0x57E0E057 -or $b[0x10] -ne 8) { Say "Not a 64-bit Havok packfile: $Path"; exit 1 }
$nsec = I32 0x14
$secs = @{}
for ($i = 0; $i -lt $nsec; $i++) {
    $h = 0x40 + $i * 0x30
    $secs[(CStr $h)] = [pscustomobject]@{ Index = $i; Start = (I32 ($h + 20)); Local = (I32 ($h + 24)); Global = (I32 ($h + 28)); Virtual = (I32 ($h + 32)); Exports = (I32 ($h + 36)) }
}
$cn = $secs['__classnames__']; $ds = $secs['__data__']; $D = $ds.Start
$local = New-Object 'System.Collections.Generic.Dictionary[int,int]'
for ($o = $D + $ds.Local; $o -lt $D + $ds.Global; $o += 8) { $s = I32 $o; if ($s -ge 0) { $local[$s] = I32 ($o + 4) } }
$gDst = New-Object 'System.Collections.Generic.Dictionary[int,int]'   # src -> dst
$gPos = New-Object 'System.Collections.Generic.Dictionary[int,int]'   # src -> file offset of the dst field
for ($o = $D + $ds.Global; $o -lt $D + $ds.Virtual; $o += 12) {
    $s = I32 $o; if ($s -lt 0) { continue }
    if ((I32 ($o + 4)) -ne $ds.Index) { continue }
    $gDst[$s] = I32 ($o + 8); $gPos[$s] = $o + 8
}
$offs = New-Object 'System.Collections.Generic.List[int]'
$cls = New-Object 'System.Collections.Generic.Dictionary[int,string]'
for ($o = $D + $ds.Virtual; $o -lt $D + $ds.Exports; $o += 12) {
    $s = I32 $o; if ($s -lt 0) { continue }
    $cls[$s] = CStr ($cn.Start + (I32 ($o + 8))); $offs.Add($s)
}
$offs.Sort(); $offArr = $offs.ToArray()
function Owner([int]$src) { $i = [Array]::BinarySearch($offArr, $src); if ($i -lt 0) { $i = (-bnot $i) - 1 }; if ($i -lt 0) { return -1 }; $offArr[$i] }
function G([int]$src) { if ($gDst.ContainsKey($src)) { $gDst[$src] } else { -1 } }
function C([int]$off) { if ($off -ge 0 -and $cls.ContainsKey($off)) { $cls[$off] } else { '' } }
function Nm([int]$off) { if ($local.ContainsKey($off + 0x38)) { CStr ($D + $local[$off + 0x38]) } else { '' } }
Say "Loaded $Path ($($b.Length) bytes, $($cls.Count) objects, $($gDst.Count) pointers)"

# ---------- reachability (what Havok will give node ids to) ----------
$isNode = { param($c) $c -match 'Generator$|^hkbStateMachine$|TransitionEffect$|Modifier$|ModifierList$|^hkbBehaviorGraph$' }
function CountReachable($dst) {
    $adj = @{}
    foreach ($kv in $dst.GetEnumerator()) { $own = Owner $kv.Key; if ($own -lt 0) { continue }; if (-not $adj.ContainsKey($own)) { $adj[$own] = New-Object 'System.Collections.Generic.List[int]' }; $adj[$own].Add($kv.Value) }
    $seen = New-Object 'System.Collections.Generic.HashSet[int]'
    $q = New-Object 'System.Collections.Generic.Queue[int]'
    foreach ($o in $offArr) { if ($cls[$o] -eq 'hkbBehaviorGraph') { [void]$seen.Add($o); $q.Enqueue($o) } }
    while ($q.Count) { $o = $q.Dequeue(); if ($adj.ContainsKey($o)) { foreach ($t in $adj[$o]) { if ($seen.Add($t)) { $q.Enqueue($t) } } } }
    $n = 0; foreach ($o in $seen) { if (& $isNode $cls[$o]) { $n++ } }
    $n
}

# ---------- find bAnimationDriven variable index ----------
$sd = $offArr | Where-Object { $cls[$_] -eq 'hkbBehaviorGraphStringData' } | Select-Object -First 1
$vb = $local[$sd + 48]; $vn = I32 ($D + $sd + 56); $animDriven = -1
for ($i = 0; $i -lt $vn; $i++) { if ((CStr ($D + $local[$vb + 8 * $i])) -eq 'bAnimationDriven') { $animDriven = $i; break } }
if ($animDriven -lt 0) { Say "bAnimationDriven variable not found - aborting"; exit 1 }

# reference counts of every target, and owner state(s) of every generator
$refs = New-Object 'System.Collections.Generic.Dictionary[int,int]'
foreach ($v in $gDst.Values) { if ($refs.ContainsKey($v)) { $refs[$v]++ } else { $refs[$v] = 1 } }
$ownerState = @{}
foreach ($o in $offArr) { if ($cls[$o] -eq 'hkbStateMachineStateInfo') { $g = G ($o + 0x58); if ($g -ge 0) { if (-not $ownerState.ContainsKey($g)) { $ownerState[$g] = @() }; $ownerState[$g] += $o } } }

function IsAnimDrivenModifier([int]$x) {
    $bs = G ($x + 0x10); if ((C $bs) -ne 'hkbVariableBindingSet') { return $false }
    if (-not $local.ContainsKey($bs + 0x10)) { return $false }
    if ((I32 ($D + $bs + 0x18)) -ne 1) { return $false }
    $e = $local[$bs + 0x10]
    if (-not $local.ContainsKey($e)) { return $false }
    ((CStr ($D + $local[$e])) -eq 'bIsActive0') -and ((I32 ($D + $e + 28)) -eq $animDriven)
}

# ---------- plan ----------
$before = CountReachable $gDst
$plan = New-Object 'System.Collections.Generic.List[object]'   # (src, newDst)
$packs = 0; $anims = 0; $skipped = @()
foreach ($p in $offArr) {
    if ($cls[$p] -ne 'hkbStateMachine') { continue }
    if ((G ($p + 0xA0)) -lt 0) { continue }                          # must own wildcard transitions
    if (-not $local.ContainsKey($p + 0x90)) { continue }
    $buf = $local[$p + 0x90]; $n = I32 ($D + $p + 0x98)
    if ($n -lt 1) { continue }
    $cand = @(); $ok = $true
    for ($i = 0; $i -lt $n; $i++) {
        $s = G ($buf + 8 * $i); $m = G ($s + 0x58)
        if ((C $s) -ne 'hkbStateMachineStateInfo' -or (C $m) -ne 'hkbModifierGenerator') { $ok = $false; break }
        $x = G ($m + 0x48); $clip = G ($m + 0x50)
        if ((C $x) -ne 'BSIsActiveModifier' -or (C $clip) -ne 'hkbClipGenerator') { $ok = $false; break }
        if ($refs[$m] -ne 1 -or $refs[$x] -ne 1 -or $refs[$clip] -ne 1 -or -not (IsAnimDrivenModifier $x)) { $ok = $false; break }
        $cand += , @($s, $m, $clip)
    }
    if (-not $ok) { continue }
    $owners = @($ownerState[$p])
    if ($owners.Count -ne 1) { $skipped += (Nm $p); continue }
    $s0 = $owners[0]; $m0 = $cand[0][1]
    $plan.Add(@(($m0 + 0x50), $p))        # wrapper now wraps the whole pack
    $plan.Add(@(($s0 + 0x58), $m0))       # pack state -> wrapper
    foreach ($c in $cand) { $plan.Add(@(($c[0] + 0x58), $c[2])) }   # animation state -> clip
    $packs++; $anims += $cand.Count
}
if ($skipped.Count) { Say ("Skipped (unusual structure): " + ($skipped -join ', ')) }
if ($packs -eq 0) { Say "Nothing to do - file already optimized (or no OStim packs found). Nodes reachable: $before"; exit 0 }

# ---------- apply in memory + verify ----------
$newDst = New-Object 'System.Collections.Generic.Dictionary[int,int]' ($gDst)
foreach ($e in $plan) { if (-not $gPos.ContainsKey($e[0])) { Say "Internal error: no fixup at $($e[0]) - aborting, file untouched"; exit 1 }; $newDst[$e[0]] = $e[1] }
$after = CountReachable $newDst
$expected = $before - 2 * $anims + 2 * $packs
Say ("Packs: {0}, animation states: {1}. Reachable nodes: {2} -> {3} (expected {4})" -f $packs, $anims, $before, $after, $expected)
if ($after -ne $expected) { Say "Verification FAILED (node count mismatch) - aborting, file untouched"; exit 1 }
foreach ($e in $plan) { $t = C $e[1]; if ($t -notin 'hkbStateMachine', 'hkbModifierGenerator', 'hkbClipGenerator') { Say "Verification FAILED (bad target $t) - aborting"; exit 1 } }
if ($DryRun) { Say "Dry run - nothing written."; exit 0 }

# ---------- write ----------
$backup = "$Path.original"
Copy-Item -LiteralPath $Path -Destination $backup -Force
foreach ($e in $plan) { [BitConverter]::GetBytes([int]$e[1]).CopyTo($b, $gPos[$e[0]]) }
$tmp = "$Path.tmp"
[IO.File]::WriteAllBytes($tmp, $b)
Move-Item -LiteralPath $tmp -Destination $Path -Force
Say "Done. Backup: $backup"
Say ("0_Master now has {0} behavior nodes. Havok's limit (65,536) counts 0_Master plus all other character behaviors (vanilla + FNIS)." -f $after)
