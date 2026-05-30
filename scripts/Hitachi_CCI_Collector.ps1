<#
.SYNOPSIS
    Hitachi VSP Pool Capacity Collector — CCI (raidcom) tabanlı
    PROD ve DR Hitachi storage sistemlerinden pool kapasitesini toplar,
    CSV olarak yazar ve FTP ile ortak alana kopyalar.

.DESCRIPTION
    Bu script, Hitachi PROD veya DR sunucusunda yerel olarak çalışır.
    raidcom komutlarını kullanarak pool bilgilerini alır ve
    StorageReport.ps1'in beklediği CSV şemasını üretir:
      Kabinet, Lokasyon, Pool, Total (TB), Used (TB), Free (TB), Doluluk (%)

    Çalıştırma yöntemi:
      - PROD sunucusunda zamanlanmış görev → Hitachi_PROD.csv üretir
      - DR sunucusunda zamanlanmış görev  → Hitachi_DR.csv üretir
      - Her ikisi de FTP/SMB ile ortak /Hitachi/ klasörüne kopyalanır

.PARAMETER Lokasyon
    'PROD' veya 'DR' — CSV'nin Lokasyon kolonuna yazılır.
    hitachi.html bu değeri PROD/DR filtresi için kullanır.

.PARAMETER OutputPath
    Üretilecek CSV dosyasının tam yolu.
    Varsayılan: C:\Scripts\Storage\Hitachi\Hitachi_PROD.csv (Lokasyon=PROD)
               C:\Scripts\Storage\Hitachi\Hitachi_DR.csv   (Lokasyon=DR)

.PARAMETER RemotePath
    FTP/SMB ortak alan hedefi. Boş bırakılırsa kopyalama atlanır.
    Örnek: \\btprdsrc01\source_drive\genel\StorageScriptOutput\Hitachi\Hitachi_PROD.csv

.PARAMETER RaidcomPath
    raidcom.exe tam yolu. Varsayılan: C:\HORCM\usr\bin\raidcom.exe

.PARAMETER HorcmInstance
    HORCM instance numarası (raidcom -I parametresi). Varsayılan: 0

.PARAMETER SerialNumber
    Hedef storage serial numarası. Boş bırakılırsa otomatik algılanır.

.PARAMETER DryRun
    CSV yazmadan sadece konsola çıkar. Test için kullanın.

.EXAMPLE
    # PROD sunucusunda çalıştır:
    .\Hitachi_CCI_Collector.ps1 -Lokasyon PROD -RemotePath \\server\share\Hitachi\Hitachi_PROD.csv

    # DR sunucusunda çalıştır:
    .\Hitachi_CCI_Collector.ps1 -Lokasyon DR -RemotePath \\server\share\Hitachi\Hitachi_DR.csv

    # Test modu (dosya yazmaz):
    .\Hitachi_CCI_Collector.ps1 -Lokasyon PROD -DryRun
#>

[CmdletBinding()]
param(
    [ValidateSet('PROD','DR')]
    [string]$Lokasyon    = 'PROD',

    [string]$OutputPath  = '',

    [string]$RemotePath  = '',

    [string]$RaidcomPath = 'C:\HORCM\usr\bin\raidcom.exe',

    [int]$HorcmInstance  = 0,

    [string]$SerialNumber = '',

    [switch]$DryRun
)

$ErrorActionPreference = 'Continue'
$StartTime = Get-Date

# ── Sabitler ────────────────────────────────────────────────────────────────
$GB = [double]1073741824
$TB = [double]1099511627776

# ── Çıktı yolu varsayılanı ──────────────────────────────────────────────────
if (-not $OutputPath) {
    $dir = 'C:\Scripts\Storage\Hitachi'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $OutputPath = Join-Path $dir "Hitachi_${Lokasyon}.csv"
}

# ── Yardımcılar ─────────────────────────────────────────────────────────────
function Write-Log {
    param([string]$Msg, [string]$Color = 'White')
    $ts = Get-Date -Format 'HH:mm:ss'
    Write-Host "[$ts] $Msg" -ForegroundColor $Color
}

function Invoke-Raidcom {
    param([string]$Args)
    $cmd = "$RaidcomPath -I $HorcmInstance $Args"
    Write-Verbose "  raidcom: $cmd"
    try {
        $out = & $RaidcomPath -I $HorcmInstance $Args.Split(' ') 2>&1
        return $out
    } catch {
        Write-Log "  raidcom HATA: $($_.Exception.Message)" Yellow
        return $null
    }
}

function Bytes-ToTB([double]$bytes) {
    return [math]::Round($bytes / $TB, 4)
}

# ── raidcom erişim kontrolü ──────────────────────────────────────────────────
if (-not (Test-Path $RaidcomPath)) {
    Write-Log "HATA: raidcom bulunamadı: $RaidcomPath" Red
    Write-Log "  Lütfen -RaidcomPath parametresiyle doğru yolu belirtin." Red
    exit 1
}

Write-Log "Hitachi CCI Collector başlatıldı" Cyan
Write-Log "  Lokasyon : $Lokasyon" Gray
Write-Log "  raidcom  : $RaidcomPath  (instance: $HorcmInstance)" Gray
Write-Log "  Çıktı    : $OutputPath" Gray

# ── Storage sistemi bilgisi ─────────────────────────────────────────────────
Write-Log "Storage sistemi sorgulanıyor..." Gray

$serialRaw = $SerialNumber
if (-not $serialRaw) {
    $sysOut = Invoke-Raidcom 'get system'
    if ($sysOut) {
        # Örnek çıktı: "Serial#   : 123456"
        $serialLine = $sysOut | Where-Object { $_ -match 'Serial#\s*:\s*(\d+)' }
        if ($serialLine -and $serialLine -match 'Serial#\s*:\s*(\d+)') {
            $serialRaw = $Matches[1]
        }
    }
}
$KabinetAdi = if ($serialRaw) { "VSP-$serialRaw" } else { "Hitachi-$Lokasyon" }
Write-Log "  Kabinet  : $KabinetAdi" Gray

# ── Pool listesi ─────────────────────────────────────────────────────────────
Write-Log "Pool kapasiteleri alınıyor..." Gray

# raidcom get dp_pool çıktı formatı:
# PID  POLS U(%) AV_CAP(MB)  TP_CAP(MB) W(%) H(%) Num LDEV# TL_CAP(MB) BF SDV(MB)
# 0    POLN 42   102400      204800     N    N    10 0    204800      N  0
$poolOut = Invoke-Raidcom 'get dp_pool'

$rows = [System.Collections.Generic.List[PSCustomObject]]::new()

if (-not $poolOut -or $poolOut.Count -eq 0) {
    Write-Log "  UYARI: Pool verisi alınamadı. HORCM çalışıyor mu?" Yellow
} else {
    # İlk satır header, geri kalanlar veri
    $headers = $null
    foreach ($line in $poolOut) {
        $line = $line.Trim()
        if (-not $line -or $line -match '^#') { continue }

        # Header satırını yakala
        if ($line -match '^PID\s+POLS') {
            $headers = $line -split '\s+'
            continue
        }
        if (-not $headers) { continue }

        $parts = $line -split '\s+'
        if ($parts.Count -lt 5) { continue }

        # Kolon indexleri (raidcom get dp_pool çıktısına göre):
        # 0=PID, 1=POLS, 2=U%, 3=AV_CAP(MB), 4=TP_CAP(MB)
        $pid_num = $parts[0]
        $usedPct = [double]($parts[2] -replace '[^0-9.]', '') / 100.0
        $avCapMB = [double]($parts[3] -replace '[^0-9.]', '')   # Boş/free
        $tpCapMB = [double]($parts[4] -replace '[^0-9.]', '')   # Total provisioned

        # TL_CAP (indeks 9): physical total capacity
        $tlCapMB = if ($parts.Count -gt 9) { [double]($parts[9] -replace '[^0-9.]', '') } else { $tpCapMB }

        if ($tlCapMB -le 0) { $tlCapMB = $tpCapMB }

        $totTB  = [math]::Round($tlCapMB / 1024 / 1024, 4)
        $usedTB = [math]::Round($totTB * $usedPct, 4)
        $freeTB = [math]::Round([math]::Max(0, $totTB - $usedTB), 4)
        $pct    = [math]::Round($usedPct * 100, 1)

        $row = [PSCustomObject][ordered]@{
            'Kabinet'      = $KabinetAdi
            'Lokasyon'     = $Lokasyon
            'Pool'         = "DP-Pool-$pid_num"
            'Total (TB)'   = $totTB
            'Used (TB)'    = $usedTB
            'Free (TB)'    = $freeTB
            'Doluluk (%)'  = $pct
            'Pool ID'      = $pid_num
            'Toplanan'     = (Get-Date -Format 'yyyy-MM-dd HH:mm')
        }
        $rows.Add($row)
        Write-Log "  Pool $pid_num : $totTB TB total · $usedTB TB used · $pct%" DarkGray
    }
}

# ── Fallback: raidcom get pool (alternatif komut) ───────────────────────────
if ($rows.Count -eq 0) {
    Write-Log "  dp_pool boş — raidcom get pool deneniyor..." Yellow
    $poolOut2 = Invoke-Raidcom 'get pool -key opt'
    if ($poolOut2) {
        $hdrFound = $false
        foreach ($line in $poolOut2) {
            $line = $line.Trim()
            if (-not $line -or $line -match '^#') { continue }
            if ($line -match '^Pool\s+ID') { $hdrFound = $true; continue }
            if (-not $hdrFound) { continue }
            $parts = $line -split '\s+'
            if ($parts.Count -lt 4) { continue }

            # Format: PoolID PoolNm UsedCap(MB) TotalCap(MB) ...
            $pid_num = $parts[0]
            $usedMB  = [double]($parts[2] -replace '[^0-9.]','')
            $totMB   = [double]($parts[3] -replace '[^0-9.]','')
            if ($totMB -le 0) { continue }

            $totTB  = [math]::Round($totMB / 1024 / 1024, 4)
            $usedTB = [math]::Round($usedMB / 1024 / 1024, 4)
            $freeTB = [math]::Round([math]::Max(0, $totTB - $usedTB), 4)
            $pct    = [math]::Round(($usedMB / $totMB) * 100, 1)

            $rows.Add([PSCustomObject][ordered]@{
                'Kabinet'      = $KabinetAdi
                'Lokasyon'     = $Lokasyon
                'Pool'         = "Pool-$pid_num"
                'Total (TB)'   = $totTB
                'Used (TB)'    = $usedTB
                'Free (TB)'    = $freeTB
                'Doluluk (%)'  = $pct
                'Pool ID'      = $pid_num
                'Toplanan'     = (Get-Date -Format 'yyyy-MM-dd HH:mm')
            })
        }
    }
}

Write-Log "$($rows.Count) pool satırı toplandı" $(if ($rows.Count -gt 0) { 'Green' } else { 'Yellow' })

# ── DryRun çıkışı ────────────────────────────────────────────────────────────
if ($DryRun) {
    Write-Log "DRY RUN — dosya yazılmıyor" Yellow
    $rows | Format-Table -AutoSize
    exit 0
}

# ── CSV yaz ──────────────────────────────────────────────────────────────────
if ($rows.Count -eq 0) {
    Write-Log "UYARI: Yazılacak veri yok. CSV oluşturulmadı." Yellow
    exit 0
}

try {
    $csvContent = $rows | ConvertTo-Csv -NoTypeInformation
    [System.IO.File]::WriteAllText(
        $OutputPath,
        ($csvContent -join "`r`n"),
        [System.Text.UTF8Encoding]::new($false)   # UTF-8 BOM'suz
    )
    $sz = [math]::Round((Get-Item $OutputPath).Length / 1KB, 1)
    Write-Log "CSV yazıldı: $OutputPath ($sz KB · $($rows.Count) satır)" Green
} catch {
    Write-Log "HATA: CSV yazılamadı: $($_.Exception.Message)" Red
    exit 1
}

# ── Uzak kopyalama ────────────────────────────────────────────────────────────
if ($RemotePath) {
    try {
        $remoteDir = Split-Path $RemotePath -Parent
        if (-not (Test-Path $remoteDir)) {
            New-Item -ItemType Directory -Path $remoteDir -Force | Out-Null
        }
        Copy-Item -Path $OutputPath -Destination $RemotePath -Force -ErrorAction Stop
        Write-Log "Uzak kopyalandı: $RemotePath" Green
    } catch {
        Write-Log "UYARI: Uzak kopyalama başarısız: $($_.Exception.Message)" Yellow
    }
}

# ── Özet ─────────────────────────────────────────────────────────────────────
$dur = [math]::Round(((Get-Date) - $StartTime).TotalSeconds, 1)
Write-Log "Tamamlandı: $($rows.Count) pool · ${dur}s" Cyan
Write-Log "Sonraki adım: Çıktıyı portal'ın Hitachi klasörüne kopyalayın." DarkGray
