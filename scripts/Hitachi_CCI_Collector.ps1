<#
.SYNOPSIS
    Hitachi HORCM Multi-Instance Pool Capacity Collector
    PROD ve DR Hitachi storage sistemlerinden pool kapasitesini toplar,
    CSV olarak yazar ve SMB ortak alanına kopyalar.

.DESCRIPTION
    Bu script HORCM instance'larını doğrudan başlatır/durdurur ve
    raidcom ile pool kapasitelerini toplar. Çıktı, hitachi.html'in
    beklediği CSV şemasına uyar:
      Kabinet, Lokasyon, Pool, Total (TB), Used (TB), Free (TB), Doluluk (%)

    ⚠️  Permission Hatası Hakkında (Start-Process -Verb RunAs)
    ----------------------------------------------------------
    Eski yaklaşım Start-Process -Verb RunAs kullanıyordu. Bu,
    zamanlanmış görev/headless ortamda UAC popup açmaya çalışır
    ve "permission denied" hatası verir.

    Bu script horcmstart/raidcom/horcmshutdown'ı DOĞRUDAN çağırır
    (& operatörü ile). Yeterli yetkiyle çalışan görev (Görev
    Zamanlayıcısı → "En yüksek ayrıcalıklarla çalıştır") yapılandırması
    gereklidir — ayrı UAC elevasyonu gerekmez.

    Çalıştırma yöntemi:
      - PROD sunucusunda zamanlanmış görev (admin hakları)
      - DR sunucusunda zamanlanmış görev  (admin hakları)
      - Her ikisi de SMB ortak alanına Hitachi_PROD.csv / Hitachi_DR.csv yazar

.PARAMETER Lokasyon
    'PROD' veya 'DR' — CSV'nin Lokasyon kolonuna yazılır.

.PARAMETER Instances
    HORCM instance numaraları (virgülle ayrılmış veya dizi).
    Varsayılan: @('134','115')

.PARAMETER OutputDir
    Yerel çıktı klasörü. Varsayılan: C:\Scripts\Storage\Hitachi

.PARAMETER RemoteDir
    SMB ortak alan hedef klasörü. Boş bırakılırsa kopyalama atlanır.
    Örnek: \\btprdsrc01\source_drive\genel\StorageScriptOutput\Hitachi

.PARAMETER HorcmDir
    horcmstart.exe / horcmshutdown.exe klasörü.
    Varsayılan: C:\HORCM\etc

.PARAMETER RaidcomPath
    raidcom.exe tam yolu. Varsayılan: C:\HORCM\usr\bin\raidcom.exe

.PARAMETER StartupWaitSec
    HORCM instance başladıktan sonra bekleme süresi (saniye).
    Varsayılan: 5

.PARAMETER NoPublish
    SMB ortak alanına kopyalamayı atla.

.PARAMETER DryRun
    CSV yazmadan sadece konsola çıkar. Test için kullanın.

.EXAMPLE
    # PROD sunucusunda — iki instance, SMB kopyalama ile:
    .\Hitachi_CCI_Collector.ps1 -Lokasyon PROD `
        -Instances @('134','115') `
        -RemoteDir '\\btprdsrc01\source_drive\genel\StorageScriptOutput\Hitachi'

    # DR sunucusunda:
    .\Hitachi_CCI_Collector.ps1 -Lokasyon DR `
        -Instances @('134','115') `
        -RemoteDir '\\btprdsrc01\source_drive\genel\StorageScriptOutput\Hitachi'

    # Sadece yerel, kopyalama yok:
    .\Hitachi_CCI_Collector.ps1 -Lokasyon PROD -NoPublish

    # Test modu:
    .\Hitachi_CCI_Collector.ps1 -Lokasyon PROD -DryRun
#>

[CmdletBinding()]
param(
    [ValidateSet('PROD','DR')]
    [string]$Lokasyon       = 'PROD',

    [string[]]$Instances    = @('134','115'),

    [string]$OutputDir      = 'C:\Scripts\Storage\Hitachi',

    [string]$RemoteDir      = '',

    [string]$HorcmDir       = 'C:\HORCM\etc',

    [string]$RaidcomPath    = 'C:\HORCM\usr\bin\raidcom.exe',

    [int]$StartupWaitSec    = 5,

    [switch]$NoPublish,

    [switch]$DryRun
)

$ErrorActionPreference = 'Continue'
$script:StartTime = Get-Date

# ── Sabitler ──────────────────────────────────────────────────────────────────
$TB = [double]1099511627776   # 1 TB in bytes (kullanılmıyor ama referans)

# ── Loglama ───────────────────────────────────────────────────────────────────
function Write-Log {
    param([string]$Msg, [string]$Color = 'White')
    $ts = Get-Date -Format 'HH:mm:ss'
    Write-Host "[$ts] $Msg" -ForegroundColor $Color
}

function Write-Step {
    param([string]$Msg, [string]$Color = 'Gray')
    Write-Host "  $Msg" -ForegroundColor $Color
}

# ── CSV Güvenliği: Excel formula injection önleme ──────────────────────────────
# Storage host adlarında = veya + ile başlayan string'ler Excel formülü olarak
# yorumlanabilir. Tek tırnak prefix bunu engeller.
function Protect-CsvCell {
    param($Value)
    if ($null -eq $Value) { return $Value }
    $s = [string]$Value
    if ($s.Length -gt 0 -and ($s[0] -eq '=' -or $s[0] -eq '+' -or
        $s[0] -eq '-' -or $s[0] -eq '@' -or $s[0] -eq "`t" -or $s[0] -eq "`r")) {
        return "'$s"
    }
    return $Value
}

# ── PS 5.1 uyumlu null-coalescing ─────────────────────────────────────────────
function Coalesce {
    param($Value, $Default = '')
    if ($null -eq $Value) { return $Default }
    if ($Value -is [string] -and $Value -eq '') { return $Default }
    return $Value
}

# ── Sayı parse (Türkçe Windows: ondalık = virgül) ─────────────────────────────
function Parse-Double {
    param([string]$Value, [double]$Default = 0)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $Default }
    $clean = $Value.Trim() -replace '[^\d\.\,\-]',''
    if ($clean -match '[\.,]') {
        $clean = $clean -replace '\.(?=.*[\.,])','  '   # binlik nokta temizle
        $clean = $clean -replace '\s',''
        $clean = $clean -replace ',','.'                  # Türkçe virgülü noktaya
    }
    $result = 0.0
    if ([double]::TryParse($clean,
        [System.Globalization.NumberStyles]::Any,
        [System.Globalization.CultureInfo]::InvariantCulture,
        [ref]$result)) {
        return $result
    }
    return $Default
}

# ── Write-CSVAndPublish: Storage_report.ps1 ile aynı imza ─────────────────────
# Yerel CSV yaz + SMB kopyala. Boş veri varsa dosya yazmaz.
# ConvertTo-Csv + WriteAllText: BOM'suz UTF-8, CRLF sonlandırıcı.
function Write-CSVAndPublish {
    param(
        [array]$Data,
        [string]$LocalPath,
        [string]$RemotePath,
        [switch]$NoPublish
    )

    if (-not $Data -or $Data.Count -eq 0) {
        Write-Step "(boş veri - dosya yazılmadı)" DarkGray
        return
    }

    $dataArray = @($Data)

    # Protect-CsvCell uygula (string property'lere)
    $finalData = $dataArray | ForEach-Object {
        $o = [ordered]@{}
        foreach ($prop in $_.PSObject.Properties) {
            $val = $prop.Value
            if ($null -eq $val) { $val = '' }
            elseif ($val -is [string]) { $val = Protect-CsvCell $val }
            $o[$prop.Name] = $val
        }
        [PSCustomObject]$o
    }

    try {
        $dir = Split-Path $LocalPath -Parent
        if (-not (Test-Path $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        $csvContent = $finalData | ConvertTo-Csv -NoTypeInformation
        [System.IO.File]::WriteAllText(
            $LocalPath,
            ($csvContent -join "`r`n"),
            [System.Text.UTF8Encoding]::new($false)   # UTF-8 BOM'suz
        )
        $sz = [math]::Round((Get-Item $LocalPath).Length / 1KB, 1)
        Write-Step "lokal: $LocalPath ($sz KB · $($finalData.Count) satır)" Green
    } catch {
        Write-Step "HATA: CSV yazılamadı: $($_.Exception.Message)" Red

        # Fallback: satır satır manuel yaz
        try {
            $simpleCsv = @()
            $headers = $finalData[0].PSObject.Properties.Name
            $simpleCsv += ($headers | ForEach-Object { '"' + ($_ -replace '"','""') + '"' }) -join ','
            foreach ($row in $finalData) {
                $line = ($row.PSObject.Properties | ForEach-Object {
                    $val = if ($null -eq $_.Value) { '' } else { [string]$_.Value }
                    $val = $val -replace '"','""'
                    '"' + $val + '"'
                }) -join ','
                $simpleCsv += $line
            }
            [System.IO.File]::WriteAllLines($LocalPath, $simpleCsv, [System.Text.UTF8Encoding]::new($false))
            Write-Step "lokal (fallback): $LocalPath" Yellow
        } catch {
            Write-Step "FATAL: $($_.Exception.Message)" Red
            return
        }
    }

    if ($NoPublish) { return }
    if (-not $RemotePath) { return }

    try {
        $remoteDir = Split-Path $RemotePath -Parent
        if (-not (Test-Path $remoteDir)) {
            New-Item -ItemType Directory -Path $remoteDir -Force -ErrorAction Stop | Out-Null
        }
        Copy-Item -Path $LocalPath -Destination $RemotePath -Force -ErrorAction Stop
        Write-Step "remote: $RemotePath" Green
    } catch {
        Write-Step "remote UYARI: $($_.Exception.Message)" DarkYellow
    }
}

# ── raidcom çağırıcı (doğrudan, UAC olmadan) ─────────────────────────────────
# ⚠️  Eski kod: Start-Process -Verb RunAs → UAC popup → headless ortamda HATA
# Yeni yaklaşım: & (call operator) ile doğrudan çağır.
# Ön koşul: Script bir admin/HORCM yetkili kullanıcı olarak çalışıyor olmalı.
# Görev Zamanlayıcısı'nda: "En yüksek ayrıcalıklarla çalıştır" seçeneği = yeterli.
function Invoke-Raidcom {
    param([string]$Instance, [string]$Arguments)
    Write-Verbose "  raidcom -I $Instance $Arguments"
    try {
        $out = & $RaidcomPath -I $Instance $Arguments.Split(' ') 2>&1
        return $out
    } catch {
        Write-Log "  raidcom HATA (instance $Instance): $($_.Exception.Message)" Yellow
        return $null
    }
}

# HORCM instance başlat — doğrudan, runas olmadan
function Start-HorcmInstance {
    param([string]$Instance)
    $horcmStart = Join-Path $HorcmDir 'horcmstart.exe'
    if (-not (Test-Path $horcmStart)) {
        Write-Log "  horcmstart.exe bulunamadı: $horcmStart" Red
        return $false
    }
    Write-Step "HORCM $Instance başlatılıyor..." Gray
    try {
        # Doğrudan çağır — Start-Process -Verb RunAs YOK
        $proc = Start-Process -FilePath $horcmStart -ArgumentList $Instance `
                              -PassThru -WindowStyle Hidden -ErrorAction Stop
        $proc.WaitForExit(10000) | Out-Null   # max 10 sn bekle
        Write-Step "HORCM $Instance başlatıldı (PID: $($proc.Id))" DarkGray
        Start-Sleep -Seconds $StartupWaitSec
        return $true
    } catch {
        Write-Log "  HORCM $Instance başlatma HATASI: $($_.Exception.Message)" Red
        Write-Log "  → Script admin yetkisiyle çalışıyor mu? Görev Zamanlayıcısı'nda" Red
        Write-Log "    'En yüksek ayrıcalıklarla çalıştır' seçeneğini aktif edin." Yellow
        return $false
    }
}

# HORCM instance durdur
function Stop-HorcmInstance {
    param([string]$Instance)
    $horcmShut = Join-Path $HorcmDir 'horcmshutdown.exe'
    if (-not (Test-Path $horcmShut)) {
        Write-Step "horcmshutdown.exe bulunamadı, instance durdurulmadı." Yellow
        return
    }
    try {
        $proc = Start-Process -FilePath $horcmShut -ArgumentList $Instance `
                              -PassThru -WindowStyle Hidden -ErrorAction Stop
        $proc.WaitForExit(10000) | Out-Null
        Write-Step "HORCM $Instance durduruldu." DarkGray
    } catch {
        Write-Step "HORCM $Instance durdurma uyarısı: $($_.Exception.Message)" DarkYellow
    }
}

# ── Pool verisi topla (tek instance için) ─────────────────────────────────────
function Get-PoolData {
    param([string]$Instance, [string]$KabinetAdi)

    $rows = [System.Collections.Generic.List[PSCustomObject]]::new()

    # Önce dp_pool dene (standart Dynamic Provisioning)
    $poolOut = Invoke-Raidcom -Instance $Instance -Arguments 'get dp_pool'

    if ($poolOut -and $poolOut.Count -gt 0) {
        Write-Step "dp_pool çıktısı alındı ($($poolOut.Count) satır)" DarkGray
        $headers = $null
        foreach ($line in $poolOut) {
            $line = $line.Trim()
            if (-not $line -or $line -match '^#') { continue }

            if ($line -match '^PID\s+POLS') {
                $headers = $line -split '\s+'
                continue
            }
            if (-not $headers) { continue }

            $parts = $line -split '\s+'
            if ($parts.Count -lt 5) { continue }

            # raidcom get dp_pool kolon düzeni:
            # 0=PID  1=POLS  2=U(%)  3=AV_CAP(MB)  4=TP_CAP(MB)
            # 5=W(%) 6=H(%)  7=Num   8=LDEV#        9=TL_CAP(MB)
            $pid_num  = $parts[0]
            $usedPct  = Parse-Double ($parts[2] -replace '[^0-9.]','') / 100.0
            $tpCapMB  = Parse-Double ($parts[4] -replace '[^0-9.]','')
            $tlCapMB  = if ($parts.Count -gt 9) {
                            Parse-Double ($parts[9] -replace '[^0-9.]','')
                        } else { $tpCapMB }
            if ($tlCapMB -le 0) { $tlCapMB = $tpCapMB }
            if ($tlCapMB -le 0) { continue }

            $totTB  = [math]::Round($tlCapMB / 1024 / 1024, 4)
            $usedTB = [math]::Round($totTB * $usedPct, 4)
            $freeTB = [math]::Round([math]::Max(0, $totTB - $usedTB), 4)
            $pct    = [math]::Round($usedPct * 100, 1)

            $rows.Add([PSCustomObject][ordered]@{
                'Kabinet'     = $KabinetAdi
                'Lokasyon'    = $Lokasyon
                'Pool'        = "DP-Pool-$pid_num"
                'Total (TB)'  = $totTB
                'Used (TB)'   = $usedTB
                'Free (TB)'   = $freeTB
                'Doluluk (%)' = $pct
                'Pool ID'     = $pid_num
                'Toplanan'    = (Get-Date -Format 'yyyy-MM-dd HH:mm')
            })
            Write-Step "  Pool $pid_num : $totTB TB · $usedTB TB kullanıldı · $pct%" DarkGray
        }
    }

    # Fallback: raidcom get pool -key opt
    if ($rows.Count -eq 0) {
        Write-Step "dp_pool boş — get pool -key opt deneniyor..." Yellow
        $poolOut2 = Invoke-Raidcom -Instance $Instance -Arguments 'get pool -key opt'
        if ($poolOut2) {
            $hdrFound = $false
            foreach ($line in $poolOut2) {
                $line = $line.Trim()
                if (-not $line -or $line -match '^#') { continue }
                if ($line -match '^Pool\s+ID') { $hdrFound = $true; continue }
                if (-not $hdrFound) { continue }
                $parts = $line -split '\s+'
                if ($parts.Count -lt 4) { continue }

                $pid_num = $parts[0]
                $usedMB  = Parse-Double ($parts[2] -replace '[^0-9.]','')
                $totMB   = Parse-Double ($parts[3] -replace '[^0-9.]','')
                if ($totMB -le 0) { continue }

                $totTB  = [math]::Round($totMB / 1024 / 1024, 4)
                $usedTB = [math]::Round($usedMB / 1024 / 1024, 4)
                $freeTB = [math]::Round([math]::Max(0, $totTB - $usedTB), 4)
                $pct    = [math]::Round(($usedMB / $totMB) * 100, 1)

                $rows.Add([PSCustomObject][ordered]@{
                    'Kabinet'     = $KabinetAdi
                    'Lokasyon'    = $Lokasyon
                    'Pool'        = "Pool-$pid_num"
                    'Total (TB)'  = $totTB
                    'Used (TB)'   = $usedTB
                    'Free (TB)'   = $freeTB
                    'Doluluk (%)' = $pct
                    'Pool ID'     = $pid_num
                    'Toplanan'    = (Get-Date -Format 'yyyy-MM-dd HH:mm')
                })
            }
        }
    }

    return ,$rows.ToArray()
}

# ── Storage serial numarası al ────────────────────────────────────────────────
function Get-StorageSerial {
    param([string]$Instance)
    $sysOut = Invoke-Raidcom -Instance $Instance -Arguments 'get system'
    if ($sysOut) {
        $serialLine = $sysOut | Where-Object { $_ -match 'Serial#\s*:\s*(\d+)' }
        if ($serialLine -and $serialLine -match 'Serial#\s*:\s*(\d+)') {
            return $Matches[1]
        }
    }
    return $null
}

# ═══════════════════════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════════════════════

Write-Log "Hitachi CCI Collector başlatıldı" Cyan
Write-Log "  Lokasyon  : $Lokasyon" Gray
Write-Log "  Instance'lar: $($Instances -join ', ')" Gray
Write-Log "  HORCM dir : $HorcmDir" Gray
Write-Log "  raidcom   : $RaidcomPath" Gray
Write-Log "  Çıktı dir : $OutputDir" Gray
if ($RemoteDir) { Write-Log "  Remote dir: $RemoteDir" Gray }
if ($DryRun)    { Write-Log "  *** DRY RUN — dosya yazılmayacak ***" Yellow }

# raidcom kontrolü
if (-not (Test-Path $RaidcomPath)) {
    Write-Log "HATA: raidcom bulunamadı: $RaidcomPath" Red
    Write-Log "  -RaidcomPath parametresiyle doğru yolu belirtin." Red
    exit 1
}

# Çıktı klasörü oluştur
if (-not (Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}

# Tüm instance'lardan pool verisi topla
$allRows = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($instance in $Instances) {
    Write-Log "" White
    Write-Log "═══ Instance $instance işleniyor ════════════════════════════" Cyan

    # 1. HORCM başlat
    $started = Start-HorcmInstance -Instance $instance

    if (-not $started) {
        # Instance başlatılamadı — mevcut çalışan instance ile devam etmeyi dene
        Write-Step "Instance başlatılamadı, varolan bağlantı deneniyor..." Yellow
    }

    # 2. Serial numarasını al → kabinet adı
    $serial = Get-StorageSerial -Instance $instance
    $kabinetAdi = if ($serial) { "VSP-$serial" } else { "Hitachi-$Lokasyon-$instance" }
    Write-Step "Kabinet: $kabinetAdi" Gray

    # 3. Pool verisi topla
    $instanceRows = Get-PoolData -Instance $instance -KabinetAdi $kabinetAdi
    Write-Step "$($instanceRows.Count) pool satırı toplandı" $(if ($instanceRows.Count -gt 0) { 'Green' } else { 'Yellow' })

    foreach ($r in $instanceRows) { $allRows.Add($r) }

    # 4. HORCM durdur (başlatıldıysa)
    if ($started) {
        Stop-HorcmInstance -Instance $instance
    }
}

Write-Log "" White
Write-Log "Toplam $($allRows.Count) pool satırı toplandı" $(if ($allRows.Count -gt 0) { 'Green' } else { 'Yellow' })

# DryRun çıkışı
if ($DryRun) {
    Write-Log "DRY RUN — dosya yazılmıyor:" Yellow
    $allRows | Format-Table -AutoSize
    exit 0
}

# Veri yoksa uyar ama çık (boş CSV yazma — hitachi.html "0 kayıt" olarak gösterir)
if ($allRows.Count -eq 0) {
    Write-Log "UYARI: Yazılacak pool verisi bulunamadı." Yellow
    Write-Log "  HORCM instance'ları çalışıyor mu? raidcom erişim yetkisi var mı?" Yellow
    exit 0
}

# ── CSV yaz ve yayınla ────────────────────────────────────────────────────────
# hitachi.html iki dosya bekliyor: Hitachi_PROD.csv veya Hitachi_DR.csv
$fileName   = "Hitachi_${Lokasyon}.csv"
$localPath  = Join-Path $OutputDir $fileName
$remotePath = if ($RemoteDir) { Join-Path $RemoteDir $fileName } else { '' }

Write-Log "CSV yazılıyor: $localPath" Gray
Write-CSVAndPublish `
    -Data       $allRows.ToArray() `
    -LocalPath  $localPath `
    -RemotePath $remotePath `
    -NoPublish:$NoPublish

# ── Özet ──────────────────────────────────────────────────────────────────────
$dur = [math]::Round(((Get-Date) - $script:StartTime).TotalSeconds, 1)
Write-Log "" White
Write-Log "══════════════════════════════════════════════════════" Cyan
Write-Log "Tamamlandı: $($allRows.Count) pool · ${dur}s" Cyan
Write-Log "Çıktı: $localPath" Cyan
if ($remotePath -and -not $NoPublish) {
    Write-Log "Remote: $remotePath" Cyan
}
Write-Log "══════════════════════════════════════════════════════" Cyan
