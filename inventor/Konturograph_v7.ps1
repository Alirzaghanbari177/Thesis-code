#Requires -Version 5.1
<#
.SYNOPSIS
  Builds the Konturograph v7 parts (and assembly) in the RUNNING Autodesk Inventor 2025 via COM.

  - Bolzenhalter_Flach_28Loch_v7.ipt  flat bolt holder, 310x310x100, 28x D20x50 blind holes,
                                      60 deg dovetail groove on X=310 face (through all along Y)
  - Bolzen_Seitenschale_v1.ipt        side tray 120x150x50 with pocket, 6 small holes and
                                      dovetail tongue on X=0 face
  - Konturograph_Baugruppe_v7.iam     block grounded at origin, tray at (310, 0, 50) mm

  Inventor API lengths are cm; every mm value below goes through MM().
  Each extrusion is checked (volume change for cuts, volume + bounding box for joins). If a result
  is wrong, the feature is deleted (sketch kept) and rebuilt with the opposite extent direction.

.USAGE
  Run in Windows PowerShell 5.1 (NOT PowerShell 7), as the same user and elevation as Inventor:
    powershell.exe -ExecutionPolicy Bypass -File .\Konturograph_v7.ps1
    powershell.exe -ExecutionPolicy Bypass -File .\Konturograph_v7.ps1 -SkipAssembly
#>
param(
    [string]$OutDir = 'D:\AAM\Konturograph',
    [switch]$SkipAssembly
)

$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion.Major -ge 6) {
    throw 'Run this with Windows PowerShell 5.1 (powershell.exe). PowerShell 7 has no Marshal.GetActiveObject.'
}

# ---------------------------------------------------------------- Inventor enum values
$kPartDocumentObject     = 12290
$kAssemblyDocumentObject = 12291
$kMetricSystemOfMeasure  = 8963
$kJoinOperation          = 20481
$kCutOperation           = 20482
$kPositiveExtent         = 20993
$kNegativeExtent         = 20994
$kSymmetricExtent        = 20995
$kUpToDateHealth         = 11777

# ---------------------------------------------------------------- connect
try {
    $inv = [Runtime.InteropServices.Marshal]::GetActiveObject('Inventor.Application')
} catch {
    throw "Could not attach to a running Inventor. Is Inventor open, and is PowerShell running with the same elevation (both admin or both non-admin)? $($_.Exception.Message)"
}
$tg = $inv.TransientGeometry
Write-Host "Connected to Inventor $($inv.SoftwareVersion.DisplayVersion)"

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$logPath = Join-Path $OutDir 'Konturograph_v7_build.log'
try { Start-Transcript -Path $logPath -Force | Out-Null } catch { }

$pathBlock = Join-Path $OutDir 'Bolzenhalter_Flach_28Loch_v7.ipt'
$pathTray  = Join-Path $OutDir 'Bolzen_Seitenschale_v1.ipt'
$pathAsm   = Join-Path $OutDir 'Konturograph_Baugruppe_v7.iam'

# Refuse to run if a target file is open in Inventor (SaveAs would fail / we would clobber edits).
foreach ($d in @($inv.Documents)) {
    foreach ($p in @($pathBlock, $pathTray, $pathAsm)) {
        if ($d.FullFileName -ieq $p) { throw "$p is open in Inventor. Close it and run again." }
    }
}

# ---------------------------------------------------------------- helpers
function MM([double]$v) { $v / 10.0 }   # mm -> cm

function Test-Near([double]$a, [double]$b, [double]$relTol = 0.01, [double]$absTol = 0.01) {
    [Math]::Abs($a - $b) -le [Math]::Max($absTol, $relTol * [Math]::Abs($b))
}

function New-PartDoc {
    $tpl = $inv.FileManager.GetTemplateFile($kPartDocumentObject, $kMetricSystemOfMeasure)
    Write-Host "  template: $tpl"
    $inv.Documents.Add($kPartDocumentObject, $tpl, $true)
}

function Get-Volume($doc) {   # cm^3, summed over all solid bodies
    $doc.Update()
    $v = 0.0
    $bodies = @($doc.ComponentDefinition.SurfaceBodies)
    try {
        foreach ($b in $bodies) { $v += [double]$b.Volume(0.00001) }
    } catch {
        $v = [double]$doc.ComponentDefinition.MassProperties.Volume
    }
    return $v
}

function Get-Range($doc) {     # cm, union of all body range boxes
    $r = $null
    foreach ($b in @($doc.ComponentDefinition.SurfaceBodies)) {
        $mn = $b.RangeBox.MinPoint; $mx = $b.RangeBox.MaxPoint
        if ($null -eq $r) {
            $r = [ordered]@{ MinX = $mn.X; MinY = $mn.Y; MinZ = $mn.Z; MaxX = $mx.X; MaxY = $mx.Y; MaxZ = $mx.Z }
        } else {
            $r.MinX = [Math]::Min($r.MinX, $mn.X); $r.MinY = [Math]::Min($r.MinY, $mn.Y); $r.MinZ = [Math]::Min($r.MinZ, $mn.Z)
            $r.MaxX = [Math]::Max($r.MaxX, $mx.X); $r.MaxY = [Math]::Max($r.MaxY, $mx.Y); $r.MaxZ = [Math]::Max($r.MaxZ, $mx.Z)
        }
    }
    if ($null -eq $r) { return $null }
    [pscustomobject]$r
}

function Format-RangeMM($r) {
    if ($null -eq $r) { return '(no body)' }
    'X {0:N2}..{1:N2}  Y {2:N2}..{3:N2}  Z {4:N2}..{5:N2} mm' -f ($r.MinX * 10), ($r.MaxX * 10), ($r.MinY * 10), ($r.MaxY * 10), ($r.MinZ * 10), ($r.MaxZ * 10)
}

function Test-Range($r, $minX, $maxX, $minY, $maxY, $minZ, $maxZ, [double]$tolMM = 0.5) {
    # expected values in mm
    if ($null -eq $r) { return $false }
    $t = MM $tolMM
    (Test-Near $r.MinX (MM $minX) 0 $t) -and (Test-Near $r.MaxX (MM $maxX) 0 $t) -and
    (Test-Near $r.MinY (MM $minY) 0 $t) -and (Test-Near $r.MaxY (MM $maxY) 0 $t) -and
    (Test-Near $r.MinZ (MM $minZ) 0 $t) -and (Test-Near $r.MaxZ (MM $maxZ) 0 $t)
}

# Model point (mm) -> 2D point in the sketch's own coordinate system. Avoids guessing how each
# origin plane's sketch axes map to model axes.
function SP($sk, [double]$x, [double]$y, [double]$z) {
    $sk.ModelToSketchSpace($tg.CreatePoint((MM $x), (MM $y), (MM $z)))
}

function Add-ClosedPolygon($sk, [object[]]$pts2d) {
    $sps = @()
    foreach ($p in $pts2d) { $sps += $sk.SketchPoints.Add($p, $false) }
    for ($i = 0; $i -lt $sps.Count; $i++) {
        [void]$sk.SketchLines.AddByTwoPoints($sps[$i], $sps[($i + 1) % $sps.Count])
    }
}

# Builds an extrusion, checks it, and flips the extent direction if the check fails.
#   $Check : scriptblock param($v0, $v1, $doc) -> $true if the result is right
function Add-CheckedExtrude {
    param(
        $Doc, $Sketch, [int]$Operation, [double]$DistanceCm, [string]$Name,
        [scriptblock]$Check, [switch]$ThroughAllSymmetric
    )
    $cd   = $Doc.ComponentDefinition
    $efs  = $cd.Features.ExtrudeFeatures
    $v0   = Get-Volume $Doc
    $dirs = if ($ThroughAllSymmetric) { @($kSymmetricExtent) } else { @($kPositiveExtent, $kNegativeExtent) }
    $feat = $null

    foreach ($dir in $dirs) {
        $dirName = @{ $kPositiveExtent = 'positive'; $kNegativeExtent = 'negative'; $kSymmetricExtent = 'symmetric' }[$dir]
        try {
            $prof = $Sketch.Profiles.AddForSolid()
            $def  = $efs.CreateExtrudeDefinition($prof, $Operation)
            if ($ThroughAllSymmetric) { $def.SetThroughAllExtent($dir) }
            else                      { $def.SetDistanceExtent($DistanceCm, $dir) }
            $feat = $efs.Add($def)
        } catch {
            Write-Host ("  [{0}] {1} direction could not be built ({2}), flipping" -f $Name, $dirName, $_.Exception.Message)
            $feat = $null
            continue
        }
        $v1 = Get-Volume $Doc
        if (& $Check $v0 $v1 $Doc) {
            $feat.Name = $Name
            Write-Host ("  [{0}] OK, {1} direction: V {2:N3} -> {3:N3} cm3 (dV {4:+0.000;-0.000}), {5}" -f `
                $Name, $dirName, $v0, $v1, ($v1 - $v0), (Format-RangeMM (Get-Range $Doc)))
            return $feat
        }
        Write-Host ("  [{0}] {1} direction gave the wrong result (dV {2:+0.000;-0.000} cm3, {3}), flipping" -f `
            $Name, $dirName, ($v1 - $v0), (Format-RangeMM (Get-Range $Doc)))
        $feat.Delete($true, $false, $false)   # keep the sketch
        $feat = $null
    }
    throw "Extrusion '$Name' did not give the expected result in any direction."
}

function Save-Doc($doc, [string]$path) {
    if (Test-Path $path) {
        $bak = '{0}.bak_{1}' -f $path, (Get-Date -Format 'yyyyMMdd_HHmmss')
        Move-Item -LiteralPath $path -Destination $bak
        Write-Host "  existing file moved to $bak"
    }
    $old = $inv.SilentOperation
    $inv.SilentOperation = $true
    try { $doc.SaveAs($path, $false) } finally { $inv.SilentOperation = $old }
    Write-Host "  saved $path"
}

function Set-PartNumber($doc, [string]$pn, [string]$desc) {
    $dtp = $doc.PropertySets.Item('Design Tracking Properties')
    $dtp.Item('Part Number').Value = $pn
    if ($desc) { $dtp.Item('Description').Value = $desc }
}

# ================================================================= PART 1: Bolzenhalter
Write-Host "`n=== Part 1: Bolzenhalter_Flach_28Loch_v7 ==="
$doc1 = New-PartDoc
$cd1  = $doc1.ComponentDefinition
$wpYZ = $cd1.WorkPlanes.Item(1); $wpXZ = $cd1.WorkPlanes.Item(2); $wpXY = $cd1.WorkPlanes.Item(3)

# 1a  base block 310 x 310 x 100
$sk = $cd1.Sketches.Add($wpXY); $sk.Name = 'Skizze_Grundkoerper'
Add-ClosedPolygon $sk @((SP $sk 0 0 0), (SP $sk 310 0 0), (SP $sk 310 310 0), (SP $sk 0 310 0))
[void](Add-CheckedExtrude -Doc $doc1 -Sketch $sk -Operation $kJoinOperation -DistanceCm (MM 100) `
    -Name 'Grundkoerper_310x310x100' -Check {
        param($v0, $v1, $d)
        (Test-Near $v1 9610.0 0.001) -and (Test-Range (Get-Range $d) 0 310 0 310 0 100)
    })

# 1b  28 blind holes D20 x 50 from top (Z=100), 4 rows (Y) x 7 (X)
$wpTop = $cd1.WorkPlanes.AddByPlaneAndOffset($wpXY, (MM 100))
$wpTop.Name = 'AE_Oberseite_Z100'; $wpTop.Visible = $false
$sk = $cd1.Sketches.Add($wpTop); $sk.Name = 'Skizze_Bohrungen_28x'
for ($j = 0; $j -lt 4; $j++) {
    for ($i = 0; $i -lt 7; $i++) {
        $x = 27.5 + $i * 42.5; $y = 27.5 + $j * 85.0
        [void]$sk.SketchCircles.AddByCenterRadius((SP $sk $x $y 100), (MM 10))
    }
}
$holesVol = 28 * [Math]::PI * 1.0 * 1.0 * 5.0          # cm^3 = 439.823
[void](Add-CheckedExtrude -Doc $doc1 -Sketch $sk -Operation $kCutOperation -DistanceCm (MM 50) `
    -Name 'Bohrungen_28x_D20_T50' -Check {
        param($v0, $v1, $d)
        (Test-Near ($v0 - $v1) $holesVol 0.005) -and (Test-Range (Get-Range $d) 0 310 0 310 0 100)
    })

# 1c  dovetail groove on X=310, 60 deg (flanks 30 deg to face normal), centred Z=75, through all along Y
$t6 = 6.0 * [Math]::Tan([Math]::PI / 6.0)              # 3.4641 mm
$sk = $cd1.Sketches.Add($wpXZ); $sk.Name = 'Skizze_Schwalbenschwanznut'
Add-ClosedPolygon $sk @((SP $sk 310 0 67), (SP $sk 304 0 (67 - $t6)), (SP $sk 304 0 (83 + $t6)), (SP $sk 310 0 83))
$grooveVol = ((16.0 + (16.0 + 2 * $t6)) / 2.0 * 6.0 * 310.0) / 1000.0   # cm^3 = 36.203
[void](Add-CheckedExtrude -Doc $doc1 -Sketch $sk -Operation $kCutOperation -ThroughAllSymmetric `
    -Name 'Schwalbenschwanznut_60Grad_X310' -Check {
        param($v0, $v1, $d)
        Test-Near ($v0 - $v1) $grooveVol 0.005
    })

Set-PartNumber $doc1 'Bolzenhalter_Flach_28Loch_v7' 'Bolzenhalter flach, 28 Bohrungen D20x50, Schwalbenschwanznut 60 Grad'
Save-Doc $doc1 $pathBlock
$doc1.Close($true)

# ================================================================= PART 2: Seitenschale
Write-Host "`n=== Part 2: Bolzen_Seitenschale_v1 ==="
$doc2 = New-PartDoc
$cd2  = $doc2.ComponentDefinition
$wpXZ = $cd2.WorkPlanes.Item(2); $wpXY = $cd2.WorkPlanes.Item(3)

# 2a  box 120 x 150 x 50
$sk = $cd2.Sketches.Add($wpXY); $sk.Name = 'Skizze_Grundkoerper'
Add-ClosedPolygon $sk @((SP $sk 0 0 0), (SP $sk 120 0 0), (SP $sk 120 150 0), (SP $sk 0 150 0))
[void](Add-CheckedExtrude -Doc $doc2 -Sketch $sk -Operation $kJoinOperation -DistanceCm (MM 50) `
    -Name 'Grundkoerper_120x150x50' -Check {
        param($v0, $v1, $d)
        (Test-Near $v1 900.0 0.001) -and (Test-Range (Get-Range $d) 0 120 0 150 0 50)
    })

$wpTop = $cd2.WorkPlanes.AddByPlaneAndOffset($wpXY, (MM 50))
$wpTop.Name = 'AE_Oberseite_Z50'; $wpTop.Visible = $false

# 2b  compartment pocket X 4..116, Y 64..146, 35 deep from top
$sk = $cd2.Sketches.Add($wpTop); $sk.Name = 'Skizze_Tasche'
Add-ClosedPolygon $sk @((SP $sk 4 64 50), (SP $sk 116 64 50), (SP $sk 116 146 50), (SP $sk 4 146 50))
$pocketVol = 11.2 * 8.2 * 3.5                           # cm^3 = 321.44
[void](Add-CheckedExtrude -Doc $doc2 -Sketch $sk -Operation $kCutOperation -DistanceCm (MM 35) `
    -Name 'Tasche_112x82_T35' -Check {
        param($v0, $v1, $d)
        (Test-Near ($v0 - $v1) $pocketVol 0.005) -and (Test-Range (Get-Range $d) 0 120 0 150 0 50)
    })

# 2c  six small blind holes, 12 deep from top
$smallHoles = @(
    @(25, 43, 1.5), @(60, 43, 1.0), @(95, 43, 2.5),
    @(25, 17, 3.0), @(60, 17, 2.5), @(95, 17, 1.5)
)
$sk = $cd2.Sketches.Add($wpTop); $sk.Name = 'Skizze_Bohrungen_6x_klein'
$smallVol = 0.0
foreach ($h in $smallHoles) {
    [void]$sk.SketchCircles.AddByCenterRadius((SP $sk $h[0] $h[1] 50), (MM ($h[2] / 2.0)))
    $smallVol += [Math]::PI * [Math]::Pow((MM ($h[2] / 2.0)), 2) * (MM 12)
}                                                        # cm^3 = 0.2545
[void](Add-CheckedExtrude -Doc $doc2 -Sketch $sk -Operation $kCutOperation -DistanceCm (MM 12) `
    -Name 'Bohrungen_6x_D1-D3_T12' -Check {
        param($v0, $v1, $d)
        (Test-Near ($v0 - $v1) $smallVol 0.05 0.005) -and (Test-Range (Get-Range $d) 0 120 0 150 0 50)
    })

# 2d  dovetail tongue on X=0, full length Y 0..150 (profile exactly as specified)
$sk = $cd2.Sketches.Add($wpXZ); $sk.Name = 'Skizze_Schwalbenschwanz_Feder'
Add-ClosedPolygon $sk @((SP $sk 0 0 17.2), (SP $sk -5.8 0 14.051), (SP $sk -5.8 0 35.949), (SP $sk 0 0 32.8))
$tongueVol = ((15.6 + (35.949 - 14.051)) / 2.0 * 5.8 * 150.0) / 1000.0   # cm^3 = 16.312
[void](Add-CheckedExtrude -Doc $doc2 -Sketch $sk -Operation $kJoinOperation -DistanceCm (MM 150) `
    -Name 'Schwalbenschwanz_Feder_X0' -Check {
        param($v0, $v1, $d)
        (@($d.ComponentDefinition.SurfaceBodies).Count -eq 1) -and
        (Test-Near ($v1 - $v0) $tongueVol 0.005) -and
        (Test-Range (Get-Range $d) -5.8 120 0 150 0 50)
    })

Set-PartNumber $doc2 'Bolzen_Seitenschale_v1' 'Seitenschale mit Schwalbenschwanz-Feder (0.2 mm Spiel je Seite)'
Save-Doc $doc2 $pathTray
$doc2.Close($true)

# ================================================================= reopen + verify parts
Write-Host "`n=== Verification (files reopened from disk) ==="
$report = @()
foreach ($item in @(
        @{ Path = $pathBlock; Expected = 9610.0 - $holesVol - $grooveVol },
        @{ Path = $pathTray;  Expected = 900.0 - $pocketVol - $smallVol + $tongueVol })) {
    $d = $inv.Documents.Open($item.Path, $true)
    $v = Get-Volume $d
    $bad = @()
    foreach ($f in @($d.ComponentDefinition.Features)) {
        if ($f.HealthStatus -ne $kUpToDateHealth) { $bad += "$($f.Name) (health $($f.HealthStatus))" }
    }
    $report += [pscustomobject]@{
        File        = $item.Path
        PartNumber  = $d.PropertySets.Item('Design Tracking Properties').Item('Part Number').Value
        'Volume_cm3'   = [Math]::Round($v, 3)
        'Expected_cm3' = [Math]::Round($item.Expected, 3)
        VolumeOK    = (Test-Near $v $item.Expected 0.001)
        Bodies      = @($d.ComponentDefinition.SurfaceBodies).Count
        Range       = Format-RangeMM (Get-Range $d)
        Features    = (@($d.ComponentDefinition.Features) | ForEach-Object { $_.Name }) -join ', '
        FeatureErrors = if ($bad.Count) { $bad -join '; ' } else { 'none' }
    }
}

# ================================================================= optional assembly
if (-not $SkipAssembly) {
    Write-Host "`n=== Assembly: Konturograph_Baugruppe_v7 ==="
    $tplA = $inv.FileManager.GetTemplateFile($kAssemblyDocumentObject, $kMetricSystemOfMeasure)
    $asm  = $inv.Documents.Add($kAssemblyDocumentObject, $tplA, $true)
    $occs = $asm.ComponentDefinition.Occurrences

    $occ1 = $occs.Add($pathBlock, $tg.CreateMatrix())
    $occ1.Grounded = $true

    $m2 = $tg.CreateMatrix()
    $m2.SetTranslation($tg.CreateVector((MM 310), (MM 0), (MM 50)))
    $occ2 = $occs.Add($pathTray, $m2)

    try {
        $c1 = $inv.TransientObjects.CreateObjectCollection(); $c1.Add($occ1)
        $c2 = $inv.TransientObjects.CreateObjectCollection(); $c2.Add($occ2)
        $ir = $asm.ComponentDefinition.AnalyzeInterference($c1, $c2)
        Write-Host "  interference block <-> tray: $($ir.Count) region(s) (expected 0)"
    } catch { Write-Host "  interference check skipped: $($_.Exception.Message)" }

    $asm.PropertySets.Item('Design Tracking Properties').Item('Part Number').Value = 'Konturograph_Baugruppe_v7'
    Save-Doc $asm $pathAsm
    $asm.Close($true)

    $asm = $inv.Documents.Open($pathAsm, $true)
    foreach ($o in @($asm.ComponentDefinition.Occurrences)) {
        $tr = $o.Transformation.Translation
        Write-Host ("  {0}: offset ({1:N1}, {2:N1}, {3:N1}) mm, grounded={4}" -f $o.Name, ($tr.X * 10), ($tr.Y * 10), ($tr.Z * 10), $o.Grounded)
    }
}

Write-Host "`n=== Result ==="
$report | Format-List
Write-Host "Log: $logPath"
try { Stop-Transcript | Out-Null } catch { }
