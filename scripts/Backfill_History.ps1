<#
.SYNOPSIS
    Storage Portal — History Backfill Aracı
    Mevcut CSV dosyalarından eksik _history/ snapshot'larını retroaktif olarak üretir.

.DESCRIPTION
    StorageReport.ps1 belirli bir süre çalışmamışsa _history/ klasörü boş olabilir.
    Bu araç mevcut (güncel) CSV'leri baz alarak belirtilen tarihlere ait snapshot
    dosyaları oluşturur — böylece trend.html ve anomaly.html hemen çalışmaya başlar.

    DRY RUN varsayılan: -Commit parametresi olmadan hiçbir dosya yazılmaz.

.PARAMETER BaseDir
    Storage CSV'lerinin bulunduğu kök dizin.
    Varsayılan: C:\Scripts\Storage

.PARAMETER Days
    Kaç günlük backfill yapılacak. Varsayılan: 7

.PARAMETER Commit
    Bu switch olmadan sadece rapor çıkar, dosya yazmaz (güvenli varsayılan).

.EXAMPLE
    # Önce test et:
    .\Backfill_History.ps1 -Days 14

    # Sonra yaz:
    .\Backfill_History.ps1 -Days 14 -Commit
#>

[CmdletBinding()]
param(
    [string]$BaseDir = 'C:\Scripts\Storage',
    [int]$Days       = 7,
    [switch]$Commit
)

$ErrorActionPreference = 'Continue'

function Write-Log {
    param([string]$Msg, [string]$Color = 'White')
    Write-Host "  $Msg" -ForegroundColor $Color
}

# CSV'ler ve history klasörleri
$targets = @(
    @{ Src='Hw\Dorado_Dashboard.csv';   Dir='Hw\_history';    Base='Dorado_Dashboard' },
    @{ Src='Hw\Dorado_Host.csv';        Dir='Hw\_history';    Base='Dorado_Host' },
    @{ Src='Hw\Dorado_HyperMetro.csv';  Dir='Hw\_history';    Base='Dorado_HyperMetro' },
    @{ Src='Pmax\PmaxPoolDash.csv';     Dir='Pmax\_history';  Base='PmaxPoolDash' },
    @{ Src='Pmax\PmaxPoolHost.csv';     Dir='Pmax\_history';  Base='PmaxPoolHost' },
    @{ Src='Pmax\PmaxLunGroups.csv';    Dir='Pmax\_history';  Base='PmaxLunGroups' },
    @{ Src='Pure\Pure_Dashboard.csv';   Dir='Pure\_history';  Base='Pure_Dashboard' },
    @{ Src='Pure\Pure_Host.csv';        Dir='Pure\_history';  Base='Pure_Host' },
    @{ Src='Pure\FB_Dashboard.csv';     Dir='Pure\_history';  Base='FB_Dashboard' },
    @{ Src='Pure\FB_Buckets.csv';       Dir='Pure\_history';  Base='FB_Buckets' },
    @{ Src='NetApp\NetApp_Dashboard.csv';Dir='NetApp\_history';Base='NetApp_Dashboard'},
    @{ Src='Ecs\ECS_Dashboard.csv';     Dir='Ecs\_history';   Base='ECS_Dashboard' },
    @{ Src='Ecs\ECS_Buckets.csv';       Dir='Ecs\_history';   Base='ECS_Buckets' },
    @{ Src='San\SAN_Director_Dashboard.csv';Dir='San\_history';Base='SAN_Director_Dashboard' },
    @{ Src='San\SAN_Fabric_Hosts.csv';  Dir='San\_history';   Base='SAN_Fabric_Hosts' }
)

$today = Get-Date
$dates = 1..$Days | ForEach-Object {
    $today.AddDays(-$_).ToString('yyyy-MM-dd')
}

Write-Host ""
Write-Host "  Storage Portal — History Backfill" -ForegroundColor Cyan
Write-Host "  BaseDir : $BaseDir" -ForegroundColor Gray
Write-Host "  Days    : $Days ($($dates[-1]) → $($dates[0]))" -ForegroundColor Gray
Write-Host "  Mode    : $(if($Commit){'YAZMA (Commit)'}else{'DRY RUN (sadece rapor)'})" -ForegroundColor $(if($Commit){'Yellow'}else{'Green'})
Write-Host ""

$written = 0
$skipped = 0
$missing = 0

foreach ($t in $targets) {
    $srcPath = Join-Path $BaseDir $t.Src
    $histDir = Join-Path $BaseDir $t.Dir

    if (-not (Test-Path $srcPath)) {
        Write-Log "ATLA: $($t.Src) bulunamadı" DarkGray
        $missing++
        continue
    }

    $srcDate = (Get-Item $srcPath).LastWriteTime.ToString('yyyy-MM-dd')
    Write-Log "$($t.Base) (kaynak: $srcDate)" Cyan

    foreach ($date in $dates) {
        $snapName = "$($t.Base)_${date}.csv"
        $snapPath = Join-Path $histDir $snapName

        if (Test-Path $snapPath) {
            Write-Log "  ✓ mevcut: $snapName" DarkGray
            $skipped++
            continue
        }

        if ($Commit) {
            if (-not (Test-Path $histDir)) {
                New-Item -ItemType Directory -Path $histDir -Force | Out-Null
            }
            try {
                Copy-Item -Path $srcPath -Destination $snapPath -Force
                Write-Log "  + yazıldı: $snapName" Green
                $written++
            } catch {
                Write-Log "  ✗ HATA: $snapName — $($_.Exception.Message)" Red
            }
        } else {
            Write-Log "  [DRY] yazılacak: $snapName" Yellow
            $written++
        }
    }
}

Write-Host ""
Write-Host "  Özet: $written $(if($Commit){'yazıldı'}else{'yazılacak (dry-run)'}) · $skipped mevcut · $missing kaynak yok" -ForegroundColor $(if($written -gt 0){'Green'}else{'Gray'})
if (-not $Commit -and $written -gt 0) {
    Write-Host "  Yazmak için: .\Backfill_History.ps1 -Days $Days -Commit" -ForegroundColor Yellow
}
Write-Host ""
