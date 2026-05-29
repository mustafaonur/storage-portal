<#
.SYNOPSIS
    Storage Portal - Unified Reporting Script
    Huawei OceanStor/Dorado + Dell EMC PowerMax/VMAX + Brocade SAN raporlama

.DESCRIPTION
    Tum kabinetleri ve SAN director'lari tarayip CSV cikti uretir.
    Sifreler $PSScriptRoot\Credentials\ altindaki .cred dosyalarindan okunur (DPAPI).

    Once Setup-Credentials.ps1'i bir kez calistirin.

    Cikti dosyalari:
      C:\Scripts\Storage\Hw\   -> Dorado_Dashboard.csv, Dorado_Host.csv, Dorado_Lun.csv, Dorado_PortGroup.csv
      C:\Scripts\Storage\Pmax\ -> PmaxPoolDash.csv, PmaxPoolHost.csv, PmaxLunGroups.csv, PmaxPortGroup.csv
      C:\Scripts\Storage\San\  -> SAN_Director_Dashboard.csv, SAN_Director_Ports.csv,
                                  SAN_Fabric_Hosts.csv, SAN_Host_LastSeen.csv

.PARAMETER OnlyHuawei
    Sadece Huawei kabinetlerini tara
.PARAMETER OnlyPowerMax
    Sadece PowerMax kabinetlerini tara
.PARAMETER OnlySAN
    Sadece Brocade SAN director'larini tara
.PARAMETER OnlySwitch
    Sadece belirtilen tek switch'i tara
.PARAMETER NoPublish
    SMB share'a kopyalamayi atla
.PARAMETER SANTimeout
    Plink komut timeout'u saniye

.EXAMPLE
    .\StorageReport.ps1
    .\StorageReport.ps1 -OnlySAN -OnlySwitch 'AI18FC187' -NoPublish
    .\StorageReport.ps1 -OnlyHuawei -NoPublish
#>

[CmdletBinding()]
param(
    [switch]$OnlyHuawei,
    [switch]$OnlyPowerMax,
    [switch]$OnlyPure,
    [switch]$OnlyPureFB,
    [switch]$OnlyNetApp,
    [switch]$OnlyECS,
    [switch]$OnlySAN,
    [string]$OnlySwitch   = $null,
    [switch]$NoPublish,
    [switch]$PlinkOnly,    # ECS icin REST API'yi atla, sadece plink kullan
    [int]$SANTimeout      = 20,
    [switch]$TestMode      # Pester icin: sadece fonksiyonlari yukle, ana akisi calistirma
)

$ErrorActionPreference = 'Continue'
$script:StartTime = Get-Date

# ============================================================
# 0. ORTAM & CONFIG
# ============================================================

Add-Type -AssemblyName System.Security -ErrorAction SilentlyContinue

# Boyut sabitleri (PS 5.1 ve 7.x uyumlu)
$script:KB = [double]1024
$script:MB = [double]1024 * 1024
$script:GB = [double]1024 * 1024 * 1024
$script:TB = [double]1024 * 1024 * 1024 * 1024

# PowerShell 5.1 uyumlu null-coalescing yerine.
# PS7'deki '??' operatoru 5.1'de yok; bunun yerine Coalesce kullanilir.
# Bos string ve $null'i ayni sekilde 'yok' kabul eder (orijinal ?? davranisi).
function Coalesce {
    param($Value, $Default = '')
    if ($null -eq $Value) { return $Default }
    if ($Value -is [string] -and $Value -eq '') { return $Default }
    return $Value
}

# Guvenli ic-ozellik erisimi ($obj.a?.b yerine). $obj veya ara seviye
# $null ise patlamaz, $null doner.
function Get-Prop {
    param($Object, [string]$Path)
    $cur = $Object
    foreach ($p in $Path.Split('.')) {
        if ($null -eq $cur) { return $null }
        $cur = $cur.$p
    }
    return $cur
}

# Hata durumunda TUM vendor'lar icin ortak dashboard satiri.
# Tutarlilik: sayisal alanlar 0, durum 'HATA', metin alanlari '-'.
# Boylece kabinet CSV/dashboard'da KAYBOLMAZ ve kolonlar bos string
# yerine tutarli deger tasir (birlestirmede/gorsel patlama olmaz).
function New-ErrorDashRow {
    param(
        [string]$Lokasyon,
        [string]$Kabinet,
        [string]$IP,
        [string]$Hata = ''
    )
    [PSCustomObject]@{
        Lokasyon          = $Lokasyon
        Kabinet           = $Kabinet
        IP                = $IP
        'Total (TB)'      = 'HATA'
        'Used (TB)'       = 0
        'Subscribed (TB)' = 0
        'Free (TB)'       = 0
        'Doluluk (%)'     = 0
        'Data Reduction'  = '-'
        'Host Sayisi'     = 0
        'OS Dagilimi'     = '-'
        Versiyon          = '-'
        Durum             = if ($Hata) { "HATA: $Hata" } else { 'HATA' }
    }
}

# Transient hatalara karsi retry sarmalayicisi (exponential backoff + jitter).
# Storage REST API'lerinde ag/throttle hatalari yaygin. 3 deneme arasi
# 1s -> 2s -> 4s + 0-500ms jitter.
# Kullanim: $resp = Invoke-RestWithRetry { Invoke-RestMethod ... }
# Auth/401 gibi kalici hatalarda retry yapilmaz (anlamsiz).
function Invoke-RestWithRetry {
    param(
        [Parameter(Mandatory=$true)][scriptblock]$ScriptBlock,
        [int]$MaxAttempts = 3,
        [int]$InitialDelayMs = 1000
    )
    $attempt = 0
    $delay = $InitialDelayMs
    while ($true) {
        $attempt++
        try {
            return & $ScriptBlock
        } catch {
            $status = $null
            try { $status = $_.Exception.Response.StatusCode.value__ } catch {}
            # Kalici hatalar: 401 (auth), 403 (yetki), 404 (yok) - retry anlamsiz
            $permanent = ($status -eq 401 -or $status -eq 403 -or $status -eq 404)
            if ($permanent -or $attempt -ge $MaxAttempts) {
                throw
            }
            # Transient: 500/502/503/504/timeout/network - retry
            $jitter = Get-Random -Minimum 0 -Maximum 500
            Start-Sleep -Milliseconds ($delay + $jitter)
            $delay *= 2
            Write-Verbose "[Retry $attempt/$MaxAttempts] $($_.Exception.Message) - $delay ms sonra tekrar"
        }
    }
}

# CSV Formula Injection koruması.
# Excel/LibreOffice: hucre =, +, -, @ ile baslarsa formul olarak yorumlanir
# (=cmd|...|, =HYPERLINK(...) gibi saldirilar mumkun). Storage host adlari
# normalde temizdir ama sosyal-muhendislik vektoru olabilir.
# Cozum: zararsiz tek-tirnak prefix ('=cmd) - Excel formul olarak calistirmaz.
function Protect-CsvCell {
    param($Value)
    if ($null -eq $Value) { return $Value }
    $s = [string]$Value
    if ($s.Length -gt 0 -and ($s[0] -eq '=' -or $s[0] -eq '+' -or $s[0] -eq '-' -or $s[0] -eq '@' -or $s[0] -eq "`t" -or $s[0] -eq "`r")) {
        return "'$s"
    }
    return $Value
}

# Dizinin tum string hucrelerini sanitize et (Export-Csv oncesi).
# Sayilar/null'lara dokunmaz, sadece tehlikeli karakterle baslayan string'ler.
function Protect-CsvData {
    param([object[]]$Data)
    if (-not $Data) { return @() }
    $out = New-Object System.Collections.ArrayList
    foreach ($row in $Data) {
        if ($null -eq $row) { continue }
        $safe = [ordered]@{}
        foreach ($prop in $row.PSObject.Properties) {
            if ($prop.Value -is [string]) {
                $safe[$prop.Name] = Protect-CsvCell $prop.Value
            } else {
                $safe[$prop.Name] = $prop.Value
            }
        }
        [void]$out.Add([PSCustomObject]$safe)
    }
    return ,$out.ToArray()
}

# Culture-safe double parse (Türkçe Windows: ondalık = virgül → hata kaynağı)
function Parse-Double {
    param([string]$Value, [double]$Default = 0)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $Default }
    $clean = $Value.Trim() -replace '[^\d\.\,\-]',''
    # Hem virgül hem nokta varsa: son olanı ondalık ayırıcı say
    if ($clean -match '[\.,]') {
        $clean = $clean -replace '\.(?=.*[\.,])','' # binlik nokta temizle
        $clean = $clean -replace ',','.'             # Türkçe virgülü noktaya çevir
    }
    $result = 0.0
    if ([double]::TryParse($clean,
        [System.Globalization.NumberStyles]::Any,
        [System.Globalization.CultureInfo]::InvariantCulture,
        [ref]$result)) { return $result }
    return $Default
}

# Merkezi WWN formatter: herhangi formattaki hex'i aa:bb:cc:dd:ee:ff:00:11 formatına çevirir
function Format-StorageWWN {
    param([string]$Raw)
    if (-not $Raw) { return $null }
    # Sadece hex karakterlerini al
    $hex = ($Raw -replace '[^0-9a-fA-F]','').ToLower()
    # 16 karakter = 1 WWN
    if ($hex.Length -lt 16) { return $null }
    $hex = $hex.Substring(0, 16)
    return ($hex -split '(.{2})' | Where-Object { $_ }) -join ':'
}

# Pipe-ayrılmış WWN listesini genişlet (32-hex birleşik format dahil)
function Expand-WwnList {
    param([string]$Raw)
    $result = [System.Collections.Generic.List[string]]::new()
    if (-not $Raw) { return $result }
    foreach ($chunk in ($Raw -split '\|')) {
        $hex = ($chunk.Trim() -replace '[^0-9a-fA-F]','').ToLower()
        if ($hex.Length -eq 0) { continue }
        for ($i = 0; $i + 16 -le $hex.Length; $i += 16) {
            $w = Format-StorageWWN $hex.Substring($i, 16)
            if ($w) { $result.Add($w) }
        }
    }
    return $result
}

function Get-ScriptRoot {
    if ($PSScriptRoot)                 { return $PSScriptRoot }
    if ($MyInvocation.MyCommand.Path)  { return Split-Path -Parent $MyInvocation.MyCommand.Path }
    if ($PSCommandPath)                { return Split-Path -Parent $PSCommandPath }
    return (Get-Location).Path
}

$ScriptRoot = Get-ScriptRoot
$CredDir    = Join-Path $ScriptRoot 'Credentials'
if (-not (Test-Path $CredDir)) {
    Write-Host "HATA: Credentials klasoru yok: $CredDir" -ForegroundColor Red
    Write-Host "Once Setup-Credentials.ps1'i calistirin." -ForegroundColor Yellow
    exit 1
}

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
[System.Net.WebRequest]::DefaultWebProxy = New-Object System.Net.WebProxy

if (-not ([System.Management.Automation.PSTypeName]'SSLBypass').Type) {
    Add-Type -TypeDefinition @"
        using System.Net;
        using System.Net.Security;
        using System.Security.Cryptography.X509Certificates;
        public class SSLBypass {
            public static void Enable() {
                ServicePointManager.ServerCertificateValidationCallback =
                    delegate(object s, X509Certificate c, X509Chain ch, SslPolicyErrors e) { return true; };
            }
        }
"@
}
[SSLBypass]::Enable()

# Yollar
$LocalBase  = 'C:\Scripts\Storage'
$RemoteBase = '\\btprdsrc01\source_drive\genel\StorageScriptOutput'

$LocalHw      = Join-Path $LocalBase 'Hw'
$LocalPmax    = Join-Path $LocalBase 'Pmax'
$LocalSan     = Join-Path $LocalBase 'San'
$LocalPure    = Join-Path $LocalBase 'Pure'
$LocalNetApp  = Join-Path $LocalBase 'NetApp'
$LocalEcs     = Join-Path $LocalBase 'Ecs'
$RemoteHw     = Join-Path $RemoteBase 'Hw'
$RemotePmax   = Join-Path $RemoteBase 'Pmax'
$RemoteSan    = Join-Path $RemoteBase 'San'
$RemotePure   = Join-Path $RemoteBase 'Pure'
$RemoteNetApp = Join-Path $RemoteBase 'NetApp'
$RemoteEcs    = Join-Path $RemoteBase 'Ecs'

@($LocalBase, $LocalHw, $LocalPmax, $LocalSan, $LocalPure, $LocalNetApp, $LocalEcs) | ForEach-Object {
    if (-not (Test-Path $_)) { New-Item -ItemType Directory -Path $_ -Force | Out-Null }
}

$PlinkPath = 'C:\PLINK\plink.exe'

# ============================================================
# ECS CONFIG (Dell EMC Elastic Cloud Storage)
# ============================================================
$EcsIstanbul = @{
    ManagementIP = '10.81.39.224'
    Nodes        = @('10.81.39.140','10.81.39.141','10.81.39.142','10.81.39.143',
                     '10.81.39.144','10.81.39.145','10.81.39.146','10.81.39.224',
                     '10.81.39.225','10.81.39.226','10.81.39.227','10.81.39.228',
                     '10.81.39.229','10.81.39.230')
    Lokasyon     = 'Istanbul'
}
$EcsAnkara = @{
    ManagementIP = '10.25.165.201'
    Nodes        = @('10.25.165.201','10.25.165.202','10.25.165.203','10.25.165.204',
                     '10.25.165.205','10.25.165.206','10.25.165.207','10.25.165.208',
                     '10.25.165.209','10.25.165.210','10.25.165.211','10.25.165.212',
                     '10.25.165.213','10.25.165.214','10.25.165.228','10.25.165.229')
    Lokasyon     = 'Ankara'
}
$EcsRestPort    = 4443
$EcsTestPorts   = @(9096, 9098)
$EcsTestSampleN = 5

# ============================================================
# SAN SWITCH LISTESI (Brocade 20 Director)
# ============================================================
$AllSwitches = @(
    @{ Name='AI18FC187';  IP='10.81.165.187'; Lokasyon='Istanbul';    Fabric='A' }
    @{ Name='AI25FC190';  IP='10.81.165.190'; Lokasyon='Istanbul';    Fabric='B' }
    @{ Name='EO17FC184';  IP='10.81.165.184'; Lokasyon='Istanbul';    Fabric='A' }
    @{ Name='EO24FC193';  IP='10.81.165.193'; Lokasyon='Istanbul';    Fabric='B' }
    @{ Name='CN39FC196';  IP='10.81.165.196'; Lokasyon='Istanbul';    Fabric='A' }
    @{ Name='CO39FC206';  IP='10.81.165.206'; Lokasyon='Istanbul';    Fabric='B' }
    @{ Name='CO39FC37';   IP='10.81.165.37';  Lokasyon='Istanbul';    Fabric='A' }
    @{ Name='CN39FC209';  IP='10.81.165.209'; Lokasyon='Istanbul';    Fabric='B' }
    @{ Name='DR707FC215'; IP='10.25.167.215'; Lokasyon='Ankara';      Fabric='A' }
    @{ Name='DR712FC218'; IP='10.25.167.218'; Lokasyon='Ankara';      Fabric='B' }
    @{ Name='DR406FC221'; IP='10.25.167.221'; Lokasyon='Ankara';      Fabric='A' }
    @{ Name='DR412FC224'; IP='10.25.167.224'; Lokasyon='Ankara';      Fabric='B' }
    @{ Name='DR815FC188'; IP='10.25.167.188'; Lokasyon='Ankara';      Fabric='A' }
    @{ Name='DR810FC191'; IP='10.25.167.191'; Lokasyon='Ankara';      Fabric='B' }
    @{ Name='DR712FC194'; IP='10.25.167.194'; Lokasyon='Ankara';      Fabric='A' }
    @{ Name='DR707FC197'; IP='10.25.167.197'; Lokasyon='Ankara';      Fabric='B' }
    @{ Name='DL21KOS126'; IP='10.81.167.126'; Lokasyon='Kos';         Fabric='A' }
    @{ Name='DM21KOS129'; IP='10.81.167.129'; Lokasyon='Kos';         Fabric='B' }
    @{ Name='KKSAN01A1';  IP='10.85.7.61';    Lokasyon='KristalKule'; Fabric='A' }
    @{ Name='KKSAN02A2';  IP='10.85.7.62';    Lokasyon='KristalKule'; Fabric='B' }
)

# Log helper
function Write-Step($Msg, $Color = 'White') { Write-Host $Msg -ForegroundColor $Color }

# ============================================================
# ORTAK HELPER: Lokasyon TOPLAM + GENEL TOPLAM satirlari
# 5 vendor scan fonksiyonunda tekrar eden ~15 satirlik blok
# DR/Host/OS kolonlari opsiyonel (vendor'a gore degisir)
# ============================================================
function Add-LocationTotals {
    param(
        [Parameter(Mandatory)] $RaporDash,   # [ref] degil; ArrayList/array - geri donulur
        [Parameter(Mandatory)] [hashtable]$LocTotals,
        [switch]$WithSubscribed              # PowerMax/Pure FA icin Subscribed kolonu var
    )
    $rows = @()
    $genTotal = 0; $genUsed = 0; $genSubs = 0; $genFree = 0

    foreach ($loc in ($LocTotals.Keys | Sort-Object)) {
        $t    = $LocTotals[$loc]
        $tot  = if ($t.Total) { [double]$t.Total } else { 0 }
        $usd  = if ($t.Used)  { [double]$t.Used }  else { 0 }
        $sub  = if ($t.Subs)  { [double]$t.Subs }  else { 0 }
        $fre  = if ($t.Free)  { [double]$t.Free }  else { [math]::Round($tot - $usd, 2) }
        $pct  = if ($tot -gt 0) { [math]::Round($usd / $tot * 100, 2) } else { 0 }

        $row = [ordered]@{
            Lokasyon='---'; Kabinet="TOPLAM $($loc.ToUpper())"; IP=''
            'Total (TB)'=[math]::Round($tot,2); 'Used (TB)'=[math]::Round($usd,2)
        }
        if ($WithSubscribed) { $row['Subscribed (TB)'] = [math]::Round($sub,2) }
        $row['Free (TB)']      = [math]::Round($fre,2)
        $row['Doluluk (%)']    = $pct
        $row['Data Reduction'] = ''
        $row['Host Sayisi']    = ''
        $row['OS Dagilimi']    = ''
        $row['Versiyon']       = ''
        $rows += [PSCustomObject]$row
        $genTotal += $tot; $genUsed += $usd; $genSubs += $sub; $genFree += $fre
    }

    $genPct = if ($genTotal -gt 0) { [math]::Round($genUsed / $genTotal * 100, 2) } else { 0 }
    $grow = [ordered]@{
        Lokasyon='==='; Kabinet='GENEL TOPLAM'; IP=''
        'Total (TB)'=[math]::Round($genTotal,2); 'Used (TB)'=[math]::Round($genUsed,2)
    }
    if ($WithSubscribed) { $grow['Subscribed (TB)'] = [math]::Round($genSubs,2) }
    $grow['Free (TB)']      = [math]::Round($genFree,2)
    $grow['Doluluk (%)']    = $genPct
    $grow['Data Reduction'] = ''
    $grow['Host Sayisi']    = ''
    $grow['OS Dagilimi']    = ''
    $grow['Versiyon']       = ''
    $rows += [PSCustomObject]$grow
    return ,$rows
}

# ============================================================
# ALARM / MAIL — kritik kapasite bildirimi
# alert-config.json'dan okur. enabled=false ise HIC mail gitmez.
# Guvenli varsayilan: pasif. management.html'den ya da elle ac.
# ============================================================
function Send-CapacityAlert {
    param(
        [Parameter(Mandatory)] $VendorDashboards,  # @{ Huawei=@(...); PowerMax=@(...); ... }
        [string]$ConfigPath
    )

    if (-not $ConfigPath) { $ConfigPath = Join-Path $ScriptRoot 'alert-config.json' }

    if (-not (Test-Path $ConfigPath)) {
        Write-Step "  Alarm: alert-config.json yok, atlandi" DarkGray
        return
    }
    try {
        $cfg = Get-Content $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        Write-Step "  Alarm: config okunamadi ($($_.Exception.Message)), atlandi" DarkYellow
        return
    }

    if (-not $cfg.enabled) {
        Write-Step "  Alarm: PASIF (alert-config.json enabled=false). Mail gonderilmedi." DarkGray
        return
    }

    $kritikEsik = if ($cfg.thresholds.kritik) { [double]$cfg.thresholds.kritik } else { 85 }
    $uyariEsik  = if ($cfg.thresholds.uyari)  { [double]$cfg.thresholds.uyari }  else { 75 }
    $sadeceKritik = $cfg.options.sadeceKritikGonder -ne $false

    # Vendor filtresi: config'de vendors.X=false ise o vendor atlanir
    $vendorFilter = @{}
    if ($cfg.vendors) {
        foreach ($p in $cfg.vendors.PSObject.Properties) { $vendorFilter[$p.Name] = $p.Value }
    }

    $alarmlar = @()
    foreach ($vendorName in $VendorDashboards.Keys) {
        # Bu vendor alarm verecek mi?
        if ($vendorFilter.ContainsKey($vendorName) -and $vendorFilter[$vendorName] -eq $false) {
            Write-Step "  Alarm: $vendorName atlandi (config'de kapali)" DarkGray
            continue
        }
        foreach ($row in $VendorDashboards[$vendorName]) {
            if ($row.Kabinet -match '^(TOPLAM|GENEL TOPLAM|===|---)') { continue }
            $pctRaw = "$($row.'Doluluk (%)')" -replace '[^0-9\.,]',''
            if (-not $pctRaw) { continue }
            $pct = Parse-Double $pctRaw
            if ($pct -le 0) { continue }

            $seviye = if ($pct -ge $kritikEsik) { 'KRITIK' }
                      elseif ($pct -ge $uyariEsik) { 'UYARI' }
                      else { $null }
            if (-not $seviye) { continue }
            if ($sadeceKritik -and $seviye -ne 'KRITIK') { continue }

            $alarmlar += [PSCustomObject]@{
                Seviye   = $seviye
                Vendor   = $vendorName
                Lokasyon = $row.Lokasyon
                Kabinet  = $row.Kabinet
                IP       = $row.IP
                'Doluluk %' = $pct
                'Total TB'  = $row.'Total (TB)'
                'Used TB'   = $row.'Used (TB)'
                'Free TB'   = $row.'Free (TB)'
            }
        }
    }

    if ($alarmlar.Count -eq 0) {
        Write-Step "  Alarm: esik asan kabinet yok (kritik=%$kritikEsik, uyari=%$uyariEsik). Mail gerekmedi." Green
        return
    }

    $aliciList = @()
    foreach ($r in $cfg.recipients) {
        if ($r.active -eq $true -and $r.email) { $aliciList += $r.email }
    }
    if ($aliciList.Count -eq 0) {
        Write-Step "  Alarm: $($alarmlar.Count) esik asan kabinet VAR ama aktif alici yok. Mail gonderilmedi." DarkYellow
        return
    }

    $smtp = $cfg.smtp
    if (-not $smtp.server) {
        Write-Step "  Alarm: SMTP server tanimli degil. Mail gonderilmedi." DarkYellow
        Write-Step "  -> $($alarmlar.Count) kabinet: $(($alarmlar | ForEach-Object { $_.Kabinet }) -join ', ')" DarkYellow
        return
    }

    $tableStr = $alarmlar |
        Sort-Object @{E='Seviye';Desc=$true}, @{E='Doluluk %';Desc=$true} |
        Format-Table Seviye, Vendor, Lokasyon, Kabinet, IP, 'Doluluk %', 'Total TB', 'Used TB', 'Free TB' -AutoSize |
        Out-String

    $kritikSayi = ($alarmlar | Where-Object { $_.Seviye -eq 'KRITIK' }).Count
    $uyariSayi  = ($alarmlar | Where-Object { $_.Seviye -eq 'UYARI' }).Count
    $now = Get-Date -Format 'yyyy-MM-dd HH:mm'

    $body = "<p style='font-family:Segoe UI,Arial;font-size:13px'>" +
            "QNB Storage izleme - <b>$kritikSayi kritik</b>" +
            $(if ($uyariSayi -gt 0) { ", <b>$uyariSayi uyari</b>" } else { "" }) +
            " kabinet kapasite esigini asti.<br>Tarama zamani: $now</p>" +
            "<pre style='font-family:Consolas,Courier New;font-size:12px;background:#f4f4f4;padding:10px;border:1px solid #ddd'>" +
            $tableStr +
            "</pre>" +
            "<p style='font-family:Segoe UI,Arial;font-size:11px;color:#888'>" +
            "Esikler: kritik %$kritikEsik, uyari %$uyariEsik. Otomatik bildirim - Storage Portal.</p>"

    $subject = if ($smtp.subject) { "$($smtp.subject) [$now]" } else { "QNB Storage - $($alarmlar.Count) Kabinet Esik Asti" }

    try {
        $mailParams = @{
            From       = $smtp.from
            To         = $aliciList
            Subject    = $subject
            Body       = $body
            BodyAsHtml = $true
            SmtpServer = $smtp.server
            Port       = if ($smtp.port) { [int]$smtp.port } else { 25 }
            Encoding   = [System.Text.Encoding]::UTF8
        }
        if ($smtp.useSsl -eq $true) { $mailParams['UseSsl'] = $true }

        Send-MailMessage @mailParams -ErrorAction Stop
        Write-Step "  Alarm: MAIL GONDERILDI -> $($aliciList -join ', ')" Green
        Write-Step "  -> $kritikSayi kritik + $uyariSayi uyari kabinet bildirildi" Green
    } catch {
        Write-Step "  Alarm: MAIL GONDERILEMEDI: $($_.Exception.Message)" Red
        Write-Step "  -> Bildirilemeyen: $(($alarmlar | ForEach-Object { $_.Kabinet }) -join ', ')" DarkYellow
    }
}
function Write-Hdr($Msg) {
    Write-Host ""
    Write-Host ("=" * 60) -ForegroundColor DarkCyan
    Write-Host " $Msg" -ForegroundColor Cyan
    Write-Host ("=" * 60) -ForegroundColor DarkCyan
}

# Ham WWN string temizleyip gecerli 16-hex WWN listesi dondurur.
function Expand-Wwn {
    param([string]$raw)
    # Expand-WwnList kullanır ve kolonlu format döndürür
    $list = Expand-WwnList -Raw $raw
    return @($list)
}

# ============================================================
# 1. CREDENTIAL OKUMA
# ============================================================

function Get-CredFromFile {
    param(
        [string]$Type = '',
        [string]$Name = '',
        [string]$FilePath = ''
    )

    if (-not $FilePath) {
        if (-not $Type -or -not $Name) {
            throw "Get-CredFromFile: -FilePath veya (-Type + -Name) gerekli"
        }
        $FilePath = Join-Path $CredDir "${Type}_${Name}.cred"
    }

    if (-not (Test-Path $FilePath)) {
        throw "Credential dosyasi yok: $(Split-Path $FilePath -Leaf)  (Setup-Credentials.ps1 ile kaydedin)"
    }

    $b64       = [System.IO.File]::ReadAllText($FilePath).Trim()
    $encrypted = [Convert]::FromBase64String($b64)
    $decrypted = [System.Security.Cryptography.ProtectedData]::Unprotect(
        $encrypted, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser
    )
    $json = [System.Text.Encoding]::UTF8.GetString($decrypted)
    $obj  = $json | ConvertFrom-Json

    return @{ User = $obj.User; Password = $obj.Password }
}

# ============================================================
# 2. KABINET LISTELERI
# ============================================================

$HuaweiCabinets = @(
    @{ Name='HW007';      IP='10.81.164.37';  Lokasyon='Istanbul' }
    @{ Name='HW005';      IP='10.81.164.39';  Lokasyon='Istanbul' }
    @{ Name='HW004';      IP='10.81.165.96';  Lokasyon='Istanbul' }
    @{ Name='HW002';      IP='10.81.165.68';  Lokasyon='Istanbul' }
    @{ Name='HW005_DE39'; IP='10.81.164.190'; Lokasyon='Istanbul' }
    @{ Name='HW001_AT32'; IP='10.81.165.4';   Lokasyon='Istanbul' }
    @{ Name='HW005_AT37'; IP='10.81.165.143'; Lokasyon='Istanbul' }
    @{ Name='HW005_IBT';  IP='10.131.9.62';   Lokasyon='IBTech'   }
    @{ Name='HW001_ANK';  IP='10.25.166.137'; Lokasyon='Ankara';   DisplayName='HW001' }
    @{ Name='HW005_ANK';  IP='10.25.166.213'; Lokasyon='Ankara';   DisplayName='HW005' }
    @{ Name='HW001_SOL5'; IP='10.25.166.128'; Lokasyon='Ankara' }
    @{ Name='HW002_SOL5'; IP='10.25.166.130'; Lokasyon='Ankara' }
)

$PowerMaxCabinets = @(
    @{ Name='IST_PMAX'; IP='stoprdapp04' }
    @{ Name='ANK_PMAX'; IP='stodrcapp02' }
    @{ Name='KOS_PMAX'; IP='stoprdapp05' }
)

# Pure FlashArray - Token tabanli (kullanici yok, sadece API token)
# Token'lar Credentials\PureFA_<Name>.cred dosyalarinda DPAPI ile saklanir
$PureFACabinets = @(
    @{ Name='PURE_07B'; IP='10.81.167.91';  Lokasyon='Istanbul' }
    @{ Name='PURE_008'; IP='10.81.167.110'; Lokasyon='Istanbul' }
    @{ Name='PURE_005'; IP='10.81.167.101'; Lokasyon='Istanbul' }
)

# Pure FlashBlade - S3 Object + NFS/SMB File Storage
# SSH ile baglaniliyor (REST API token yerine SSH user/pass)
# Credential: Credentials\PureFB_<Name>.cred -> User=sshuser, Password=sshpass
$PureFBCabinets = @(
    @{ Name='FB_UOM'; IP='10.81.165.243'; Lokasyon='Istanbul'; SshOnly=$true }
    @{ Name='FB_ANK'; IP='10.25.167.185'; Lokasyon='Ankara';   SshOnly=$true }
)

# Pure FA personality -> OS map
$PurePersonalityMap = @{
    'windows'          = 'Windows'
    'hpux'             = 'HP-UX'
    'vms'              = 'OpenVMS'
    'aix'              = 'AIX'
    'esxi'             = 'VMware ESX'
    'oracle-vm-server' = 'Oracle VM'
    'hitachi-vsp'      = 'Hitachi VSP'
    'solaris'          = 'Solaris'
}

# NetApp ONTAP Cluster listesi (REST API: HTTPS port 443)
$NetAppClusters = @(
    @{ Name='UMR_CLS';        IP='10.81.165.236'; Lokasyon='Istanbul'; User='admin' }
    @{ Name='UOM_AFF_CLS_01'; IP='10.81.166.145'; Lokasyon='Istanbul'; User='admin' }
    @{ Name='UOM_AFF_CLS_02'; IP='10.81.166.150'; Lokasyon='Istanbul'; User='admin' }
    @{ Name='ANK_CLS';        IP='10.25.166.88';  Lokasyon='Ankara';   User='admin' }
    @{ Name='ANK_AFF_CLS_01'; IP='10.25.167.238'; Lokasyon='Ankara';   User='admin' }
    @{ Name='ANK_AFF_CLS_02'; IP='10.25.167.239'; Lokasyon='Ankara';   User='admin' }
)

# Huawei OS id -> isim
$HuaweiOsMap = @{
    '0'='Linux'; '1'='Windows'; '2'='Solaris'; '3'='HP-UX'; '4'='AIX'
    '5'='XenServer'; '6'='Mac OS'; '7'='VMware ESX'; '8'='Windows'
    '9'='Oracle VM'; '10'='OpenVMS'; '11'='Linux'; '22'='Linux'; '23'='Linux'; '24'='Linux'
}

# ============================================================
# OS RESOLVER V2 - Skorlama tabanli host OS tespiti
# ============================================================
# ============================================================
# RESOLVE-HOSTOS V2 — Skorlama tabanli OS tespiti
# ============================================================
# StorageReport.ps1'deki Resolve-HostOS'i drop-in degistirir.
#
# DEGISIM MANTIGI (eski sorunlar -> yeni cozumler):
#
# ESKI: "ilk eslesen kazanir" -> _DB[0-9] gibi genis pattern tum DB host'lari
# AIX gosteriyordu. FEAGTPRDDB03 Linux'tu ama AIX olarak raporlaniyordu.
#
# YENI: Skorlama tabanli. Sinyaller (en guvenilirden zayifa):
#   1. host_os_override.csv (manuel)              +1000  Certain
#   2. Storage personality explicit (aix/esxi/vmware) +90  High (kesin
#      storage admin secimi - default "linux" haric)
#   3. WWN OUI - kesin tek-OS olanlar (c0:50:76 = IBM Power = AIX)  +100
#   4. WWN OUI - VMware vmkernel (20:00:00:25:b5)  +100
#   5. WWN OUI - "AIX degil" hint (51:40:2e = HPE/Inspur x86)  +10
#      Bu durumda AIX genel pattern'leri ATLANIR.
#   6. PMAX flag blob (avoid_reset_broadcast vb.)  +60
#   7. Hostname pattern - spesifik (ESX[0-9], KFTPRDRAC) +50 (+80 ESX icin)
#   8. Personality "linux" (default deger - dusuk guven)  +30
#   9. Hostname pattern - genel (PRDDB, _DB)  +20
#
# Skor < 20 -> Unknown (CurrentOs varsa ona fallback).
#
# ONEMLI: 10:00:00:62 gibi cok yaygin Emulex OUI'leri ne Linux ne AIX'e
# kesin baglanmaz - hem AIX hem Linux host'larinda gorulur. Bu yuzden bu
# OUI'lere puan VERMIYORUZ, kararı personality + hostname'e birakiyoruz.
# ============================================================

# ---------- Override CSV cache ----------
$script:OsOverrideCache = $null
$script:OsOverrideCachePath = ''

function Get-HostOSOverride {
    param([string]$Path = '.\host_os_override.csv')
    if ($script:OsOverrideCache -and $script:OsOverrideCachePath -eq $Path) {
        return $script:OsOverrideCache
    }
    $map = @{}
    if (Test-Path $Path) {
        try {
            foreach ($r in (Import-Csv -Path $Path)) {
                $h = ($r.HostName -as [string])
                $o = ($r.OS -as [string])
                if ($h -and $o) { $map[$h.ToUpper().Trim()] = $o.Trim() }
            }
            Write-Verbose "[OS-Override] $($map.Count) host yuklendi: $Path"
        } catch {
            Write-Warning "[OS-Override] CSV okunamadi: $Path - $($_.Exception.Message)"
        }
    }
    $script:OsOverrideCache = $map
    $script:OsOverrideCachePath = $Path
    return $map
}

# Helper: source string'i guvenli append (PS5.1 uyumlu - ?? operatoru kullanmaz)
function Add-OSSource {
    param([hashtable]$Map, [string]$Key, [string]$Text)
    if (-not $Map.ContainsKey($Key) -or [string]::IsNullOrEmpty($Map[$Key])) {
        $Map[$Key] = $Text.TrimStart('+')
    } else {
        $Map[$Key] = $Map[$Key] + $Text
    }
}

# ---------- WWN OUI tablolari ----------
# SADECE tek-OS'a kesin baglanan OUI'ler. Genel/coklu kullanilan OUI'ler
# (10:00:00:62 = Emulex generic vb.) burada YOK - cunku hem AIX hem Linux
# host'lar bu OUI'yi kullanir (verinden teyit edildi).
$script:WWNOuiMap = @{
    'c050760'    = 'AIX'         # IBM Power Systems NPIV - kesin
    '20000025b5' = 'VMware ESX'  # Cisco UCS vmkernel WWN
    '2000002590' = 'VMware ESX'  # Cisco UCS vmkernel
    '200000144f' = 'Solaris'     # Sun/Oracle
}

# "AIX degil" hint - sadece AIX genel pattern'lerini atlamak icin
$script:WWNNotAIXOui = @('51402ec0', '5140', '50060b')

# Storage personality -> OS map (V2-ozel; StorageReport'taki global
# $PurePersonalityMap ile cakismasin diye ayri isim)
$script:OsPersonalityMap = @{
    'aix'              = 'AIX'
    'esxi'             = 'VMware ESX'
    'vmware'           = 'VMware ESX'
    'vmware esx'       = 'VMware ESX'     # Huawei display name
    'vmware esxi'      = 'VMware ESX'
    'hpux'             = 'HP-UX'
    'hp-ux'            = 'HP-UX'           # Huawei display name
    'hpux-vms'         = 'HP-UX'
    'vms'              = 'OpenVMS'
    'openvms'          = 'OpenVMS'         # Huawei
    'linux'            = 'Linux'
    'solaris'          = 'Solaris'
    'windows'          = 'Windows'
    'oracle-vm'        = 'Oracle VM'
    'oracle-vm-server' = 'Oracle VM'
    'oracle vm'        = 'Oracle VM'       # Huawei
    'xenserver'        = 'XenServer'
    'mac os'           = 'Other'
    'hitachi-vsp'      = 'Hitachi VSP'
}

# ---------- Hostname pattern'leri ----------
# SPESIFIK: yuksek guven (kategori adi pattern icinde)
$script:OsSpecificPatterns = @{
    'VMware ESX' = @(
        'ESX[0-9]', '^FEPRDVM[0-9]', '^FEDRCVM[0-9]',
        '^FBPRDESX[0-9]', '^FBDRCESX[0-9]',
        '^PRDESX[0-9]', '^DRCESX[0-9]', '^TSTESX[0-9]',
        '^FEPRDESX', '^FEDRCESX', '^FFPRDESX', '^FFDRCESX',
        '^SIMDRCESX', '^LSXDRCESX', '^LSXPRDESX',
        '^PSPRDESX', '^PSDRCESX', '^CBPRDESX', '^CBDRCESX',
        '^FBPRDVM[0-9]', '^FBDRCVM[0-9]',
        '^VDIPRDVM', '^VDIDRCVM', '^HYPV[0-9]', '^CLESX'
    )
    'Linux' = @(
        '^GPU[0-9]', '^CLW[A-Z]+GPU', '^KFK[0-9]', 'KAFKA[0-9]',
        '^SFDPRDRAC[0-9]', '^SFDDRCRAC[0-9]',
        '^LSXPRDRAC[0-9]', '^LSXDRCRAC[0-9]', '^LSXPRDLX', '^LSXDRCLX',
        '^STOPRDAPP[1-9][0-9]', '^STODRCAPP[0-9]', '^STOTSTAPP[0-9]',
        '^ALODRCKFK', '^ALOPRDKFK', '^DAPRDKFK', '^DADRCKFK',
        '^ELKPRD', '^ELKDRC', '^ELKTST',
        '^DOCKER', '^K8S', '^POSTGRES', '^MYSQL', '^MARIADB', '^ELASTIC',
        'LINUX', 'RHEL', 'UBUNTU', 'CENTOS',
        '^FEDWHPRD', '^FEGNLPRD',
        '^PGMPRDCAS', '^PGMPRDRAC[0-9]', '^PGMDRCCAS', '^PGMDRCRAC[0-9]',
        '^FEAGTPRDDB', '^FEAGTDRCDB', '^SCMPRDDB', '^SCMDRCDB',
        '^BDPPRDEDG', '^BDPDRCEDG', '^DAPRDCAS', '^DADRCCAS',
        '^BTPRDOPVIRT', '^BTDRCOPVIRT',
        '^BNXUCM', '^UCMPRD', '^UCMDRC'
    )
    'Windows' = @(
        '^CLN[0-9]', '^HST[0-9]', '^EXC[0-9]', '^HYPVPRD[0-9]',
        '^BNXEARPRD', '^BNXSESPRD', '^EARPRDCLN',
        '^BNXMSGPRDEXC', '^MSGSDRCEXC', '^ATMPRD', '^ATMDRC', '^KMP[0-9]',
        '^KKPRDDB[0-9]', '^KKDRCDB[0-9]',
        '^CCPRDCLN', '^CCDRCCLN', '^MBPRDCLN', '^MBDRCCLN',
        '^EPRPRDCLN', '^EPRDRCCLN',
        'WIN[0-9]', '^FILE[0-9]', '^FS[0-9]', '^DC[0-9]', '^AD[0-9]',
        '^SQL[0-9]', '^IIS[0-9]'
    )
    'AIX' = @(
        '^RAC[0-9]', '^MQ[0-9]',
        '^KFTPRDRAC', '^KFTDRCRAC',
        '^OCM[0-9]', '^CFR[0-9]',
        '^IDMPRDRAC', '^IDMDRCRAC',
        '^ATLPRDRAC', '^ATLDRCRAC', '^ATLTSTRAC',
        '^GENPRDRAC', '^GENDRCRAC', '^GENTSTRAC',
        '^ECMPRDRAC', '^ECMDRCRAC',
        '^ODPRDRAC', '^ODDRCRAC', '^ODTSTRAC',
        '^CBPRDRAC', '^CBDRCRAC', '^CBTSTRAC',
        '\bAIX\b'
    )
}

# GENEL: zayif sinyal - WWN/personality varsa onlar baskin
$script:OsGeneralPatterns = @{
    'AIX' = @(
        'PRDDB[0-9]', 'DRCDB[0-9]', 'TSTDB[0-9]', '_DB[0-9]',
        '^CB[A-Z]', '^GEN[A-Z]', '^EVA[A-Z]', '^TNG[A-Z]', '^KFT[A-Z]',
        '^OCM[A-Z]', '^CFR[A-Z]', '^SEA[A-Z]', '^IDM[A-Z]', '^VPS[A-Z]',
        '^HCE[A-Z]', '^ECM[A-Z]', '^IFM[A-Z]', '^SCE[A-Z]', '^KYS[A-Z]',
        '^CSPRD', '^CSDRC', '^CSTST', '^MSPRD', '^SFD[A-Z]',
        '^BTPRDMGT', '^BTDRCMGT',
        '^BNXGSC', '^BNXMCM', '^BNXSW', '^BNXMSG', '^BNXDTL', '^BNXEPS',
        '^SWPRD', '^SWDRC', '^SWTST', '^ATL[A-Z]',
        '^RES[0-9]', '^ARC[0-9]'
    )
    'VMware ESX' = @(
        '^VMWARE', 'VDIVM', 'EFKEP', 'LSXLX',
        '^BTPRDLX[0-9_]', '^BTDRCLX[0-9_]', '^CBPRDLX[0-9_]', '^CBDRCLX[0-9_]',
        '^IG_BTPRDLX', '^IG_BTDRCLX', '^IG_CBPRDLX', '^IG_CBDRCLX'
    )
    'Windows' = @(
        '^ESR', '^ALM', '^EPR', '^COM', '^MBE', '^YN', '^FRA', '^FRD',
        '^INBSES', '^IG_ATMPRD', '^IG_ATMDRC',
        '^TEST$', '^ANSIBLE'
    )
    'Linux' = @(
        '^EBS[0-9]', 'FRAP[0-9]', 'FBHWPOC', '^IG_FBHWPOC',
        '^BNXEDPRD', '^RAPRD',
        '^IG_STOPRDAPP', '^IG_STOTSTAPP',
        'HMRDC[0-9]', 'HMTST[0-9]', '^ML[0-9]',
        '^PGMTSTRAC', 'SGXLIN', 'LSXLSN',
        '^FRA[A-Z]+CLN', '^FF[A-Z]*PRDDB', '^FF[A-Z]*DRCDB',
        '^STOTSTAPP$', '^STOPRDAPP$', '^TNGPRDAPP', '^TNGDRCAPP',
        '^DA[A-Z]+KFK', '^ELK',
        '^INSTAPRDAPP', '^TRHPRDAPP'
    )
}

# ============================================================
function Resolve-HostOS {
    <#
    .SYNOPSIS
        Multi-signal scoring ile host OS tespiti.
    .DESCRIPTION
        Storage'in OS, WWN OUI, personality flag ve hostname pattern'lerinin
        toplam skoruyla en yuksek puanli OS'i secer.
    #>
    [CmdletBinding()]
    param(
        [string]$CurrentOs,
        [string]$HostName,
        [array] $WWNs = @(),
        [string]$FlagBlob = '',
        [string]$ExplicitPersonality = '',
        [string]$OverrideCsvPath = '.\host_os_override.csv',
        [switch]$DetailedOutput,
        [switch]$VerboseScoring
    )

    if (-not $HostName) {
        $fallback = if ($CurrentOs) { $CurrentOs } else { 'Unknown' }
        if ($DetailedOutput) {
            return @{ OS = $fallback; Score = 0; Source = 'NoHostname'; Confidence = 'None' }
        }
        return $fallback
    }

    $name      = $HostName.ToUpper().Trim()
    $nameClean = $name -replace '^[A-Z0-9_-]+:', ''
    # _IG1, _PHY gibi soneklerden de OS karari etkilenmesin: ana adi yakalama icin
    # ek temizleme yapmayalim - pattern eslesmesi zaten yeterli esnek

    # 1) OVERRIDE
    $override = Get-HostOSOverride -Path $OverrideCsvPath
    foreach ($key in @($name, $nameClean)) {
        if ($override.ContainsKey($key)) {
            if ($DetailedOutput) {
                return @{ OS = $override[$key]; Score = 1000; Source = 'Override'; Confidence = 'Certain' }
            }
            return $override[$key]
        }
    }

    $scores = [ordered]@{
        'AIX'        = 0
        'Linux'      = 0
        'Windows'    = 0
        'VMware ESX' = 0
        'HP-UX'      = 0
        'Solaris'    = 0
        'Other'      = 0
    }
    $sources = @{}
    $isNotAIX = $false

    # 2) WWN OUI - sadece tek-OS olanlar
    if ($WWNs -and $WWNs.Count -gt 0) {
        foreach ($wwn in $WWNs) {
            if (-not $wwn) { continue }
            $w = ($wwn.ToString() -replace '[^0-9a-f]','').ToLower()
            if ($w.Length -lt 8) { continue }

            $matched = $false
            foreach ($len in @(10, 8, 7, 6)) {
                if ($w.Length -ge $len) {
                    $prefix = $w.Substring(0, $len)
                    if ($script:WWNOuiMap.ContainsKey($prefix)) {
                        $os = $script:WWNOuiMap[$prefix]
                        $scores[$os] += 100
                        Add-OSSource $sources $os "+WWN($prefix`:100)"
                        $matched = $true
                        break
                    }
                }
            }
            if (-not $matched) {
                foreach ($notAixPrefix in $script:WWNNotAIXOui) {
                    if ($w.StartsWith($notAixPrefix)) {
                        $isNotAIX = $true
                        $scores['Linux']      += 10
                        $scores['VMware ESX'] += 10
                        Add-OSSource $sources 'Linux'      '+WWN-NonAIX(10)'
                        Add-OSSource $sources 'VMware ESX' '+WWN-NonAIX(10)'
                        break
                    }
                }
            }
        }
    }

    # 3) EXPLICIT PERSONALITY - storage admin'in secimi
    if ($ExplicitPersonality) {
        $p = $ExplicitPersonality.ToLower().Trim()
        if ($script:OsPersonalityMap.ContainsKey($p)) {
            $os = $script:OsPersonalityMap[$p]
            # Default "linux"un puanı dusuk; digerleri "elle secilmistir" -> yuksek
            $pts = if ($p -eq 'linux') { 30 } else { 90 }
            $scores[$os] += $pts
            Add-OSSource $sources $os "+Pers($p`:$pts)"
        }
    }

    # 4) PMAX FLAG BLOB
    if ($FlagBlob) {
        $b = $FlagBlob.ToLower()
        $hit = $null
        if     ($b -match '\baix\b')                  { $hit = 'AIX' }
        elseif ($b -match 'vmware|esx|esxi')          { $hit = 'VMware ESX' }
        elseif ($b -match '\bwindows\b|\bwin\b')      { $hit = 'Windows' }
        elseif ($b -match '\blinux\b')                { $hit = 'Linux' }
        elseif ($b -match 'hp[\-]?ux')                { $hit = 'HP-UX' }
        elseif ($b -match 'solaris')                  { $hit = 'Solaris' }
        if ($hit) {
            $scores[$hit] += 60
            Add-OSSource $sources $hit '+Flag(60)'
        }
        if ($b -match 'avoid_reset_broadcast.*enabled.*true' -and
            $b -match 'volume_set_addressing.*enabled.*true') {
            $scores['AIX'] += 60
            Add-OSSource $sources 'AIX' '+Flag-AIX-combo(60)'
        }
    }

    # 5) SPESIFIK PATTERN
    foreach ($os in $script:OsSpecificPatterns.Keys) {
        foreach ($pat in $script:OsSpecificPatterns[$os]) {
            if ($nameClean -match $pat) {
                $pts = if ($os -eq 'VMware ESX') { 80 } else { 50 }
                $scores[$os] += $pts
                Add-OSSource $sources $os "+Spec($pts)"
                break
            }
        }
    }

    # 6) GENEL PATTERN - WWN-NonAIX gorulduyse AIX'i atla
    foreach ($os in $script:OsGeneralPatterns.Keys) {
        if ($os -eq 'AIX' -and $isNotAIX) { continue }
        foreach ($pat in $script:OsGeneralPatterns[$os]) {
            if ($nameClean -match $pat) {
                $scores[$os] += 20
                Add-OSSource $sources $os '+Gen(20)'
                break
            }
        }
    }

    # KARAR
    $winner = $null
    $maxScore = 0
    foreach ($k in $scores.Keys) {
        if ($scores[$k] -gt $maxScore) {
            $maxScore = $scores[$k]
            $winner = $k
        }
    }

    # Tie-break: NonAIX flag + AIX baglıysa AIX'i ele
    if ($maxScore -gt 0) {
        $tied = @($scores.GetEnumerator() | Where-Object { $_.Value -eq $maxScore } | ForEach-Object { $_.Key })
        if ($tied.Count -gt 1 -and $isNotAIX -and ($tied -contains 'AIX')) {
            $remaining = @($tied | Where-Object { $_ -ne 'AIX' })
            if ($remaining.Count -gt 0) { $winner = $remaining[0] }
        }
    }

    $source = ''
    if ($maxScore -lt 20) {
        if ($CurrentOs -and $CurrentOs -ne 'Unknown' -and $CurrentOs -notmatch '^Generic') {
            $winner = $CurrentOs
            $maxScore = 10
            $source = 'Fallback(CurrentOs)'
        } else {
            $winner = 'Unknown'
            $source = 'NoSignal'
        }
    } else {
        $source = if ($sources.ContainsKey($winner)) { $sources[$winner] } else { '?' }
    }

    $confidence = switch ($true) {
        ($maxScore -ge 100) { 'High'   ; break }
        ($maxScore -ge 50)  { 'Medium' ; break }
        ($maxScore -ge 20)  { 'Low'    ; break }
        default             { 'None' }
    }

    if ($VerboseScoring) {
        Write-Host "[$HostName] -> $winner ($maxScore $confidence) | $source" -ForegroundColor Gray
        foreach ($k in $scores.Keys) {
            if ($scores[$k] -gt 0) {
                Write-Host "    $k = $($scores[$k])  ($($sources[$k]))" -ForegroundColor DarkGray
            }
        }
    }

    if ($DetailedOutput) {
        return @{ OS = $winner; Score = $maxScore; Source = $source; Confidence = $confidence }
    }
    return $winner
}


# ============================================================
# 3. HUAWEI TARAYICI
# ============================================================

function Invoke-HuaweiScan {
    param([array]$Cabinets)

    $Rapor_Dash       = @()
    $Rapor_Hosts      = @()
    $Rapor_LunGrps    = @()
    $Rapor_PortGroups = @()
    $Rapor_Snapshots  = @()
    $Rapor_NAS        = @()
    $Rapor_HyperMetro = @()
    $LocTotals        = @{}

    foreach ($Kabinet in $Cabinets) {
        $Lokasyon    = $Kabinet.Lokasyon
        $DisplayName = if ($Kabinet.DisplayName) { $Kabinet.DisplayName } else { $Kabinet.Name }

        Write-Step "  -> Baglaniyor: $Lokasyon / $DisplayName ($($Kabinet.IP))" Cyan

        $cred = $null
        try {
            $cred = Get-CredFromFile -Type 'Huawei' -Name $Kabinet.Name
        } catch {
            Write-Step "     HATA: $($_.Exception.Message)" Red
            $Rapor_Dash += New-ErrorDashRow -Lokasyon $Lokasyon -Kabinet $DisplayName -IP $Kabinet.IP -Hata $_.Exception.Message
            continue
        }

        $User = $cred.User
        $Pass = $cred.Password
        $cred = $null

        $BaseUrl = "https://$($Kabinet.IP):8088/deviceManager/rest"
        $Session = $null

        try {
            # ---- LOGIN ----
            $LoginBody = @{ username=$User; password=$Pass; scope=0 } | ConvertTo-Json
            $LoginResp = Invoke-RestMethod -Uri "$BaseUrl/xxxxx/sessions" -Method Post `
                -Body $LoginBody -ContentType 'application/json' `
                -SessionVariable Session -TimeoutSec 30 -ErrorAction Stop

            if (-not $LoginResp.data) { throw 'Cihaz cevap vermedi (empty data)' }

            $DevId   = $LoginResp.data.deviceid
            $Token   = $LoginResp.data.iBaseToken
            $Headers = @{ iBaseToken=$Token; 'Content-Type'='application/json' }

            # ---- SISTEM KAPASITESI ----
            $SysResp = Invoke-RestMethod -Uri "$BaseUrl/$DevId/system/" -Method Get -Headers $Headers `
                -WebSession $Session -TimeoutSec 30 -ErrorAction Stop
            if (-not $SysResp.data) { throw 'Kapasite verisi bos' }

            $D = $SysResp.data
            $SectorSize = if ($D.SECTORSIZE) { (Parse-Double "$($D.SECTORSIZE)" 512) } else { 512 }
            $RawTotal   = if ($D.STORAGEPOOLCAPACITY)     { (Parse-Double "$($D.STORAGEPOOLCAPACITY)") }     else { 0 }
            $RawUsed    = if ($D.USEDCAPACITY)            { (Parse-Double "$($D.USEDCAPACITY)") }            else { 0 }
            $RawSubs    = if ($D.mappedLunsCountCapacity) { (Parse-Double "$($D.mappedLunsCountCapacity)") } else { 0 }
            $Version    = if ($D.pointRelease)            { $D.pointRelease } else { '' }

            $TotalTB = [math]::Round(($RawTotal * $SectorSize) / $script:TB, 2)
            $UsedTB  = [math]::Round(($RawUsed  * $SectorSize) / $script:TB, 2)
            $SubsTB  = [math]::Round(($RawSubs  * $SectorSize) / $script:TB, 2)
            $FreeTB  = [math]::Round($TotalTB - $UsedTB, 2)
            $Pct     = if ($TotalTB -gt 0) { [math]::Round($UsedTB / $TotalTB * 100, 2) } else { 0 }

            # Lokasyon toplami
            if (-not $LocTotals.ContainsKey($Lokasyon)) {
                $LocTotals[$Lokasyon] = @{ Total=0; Used=0; Subs=0; Free=0 }
            }
            $LocTotals[$Lokasyon].Total += $TotalTB
            $LocTotals[$Lokasyon].Used  += $UsedTB
            $LocTotals[$Lokasyon].Subs  += $SubsTB
            $LocTotals[$Lokasyon].Free  += $FreeTB

            # ---- DATA REDUCTION RATIO ----
            $ReductionStr = '-'
            try {
                $PoolResp = Invoke-RestMethod -Uri "$BaseUrl/$DevId/storagepool" -Method Get `
                    -Headers $Headers -WebSession $Session -TimeoutSec 30 -ErrorAction Stop
                if ($PoolResp.data) {
                    $RatioList = @()
                    foreach ($pool in $PoolResp.data) {
                        $Raw = $pool.SPACEREDUCTIONRATE
                        $Num = 0; $Den = 0
                        if ($Raw -is [string] -and $Raw.StartsWith('{')) {
                            try { $obj = $Raw | ConvertFrom-Json; $Num=(Parse-Double "$($obj.numerator)"); $Den=(Parse-Double "$($obj.denominator)") } catch { Write-Verbose "[L516] PoolResp atlandi: $($_.Exception.Message)" }
                        } elseif ($Raw -is [PSCustomObject] -or $Raw -is [hashtable]) {
                            $Num = (Parse-Double "$($Raw.numerator)"); $Den = (Parse-Double "$($Raw.denominator)")
                        }
                        if ($Den -gt 0) {
                            $calc = [math]::Round($Num / $Den, 2)
                            $RatioList += "$($calc):1"
                        }
                    }
                    if ($RatioList.Count -gt 0) { $ReductionStr = $RatioList -join ' | ' }
                }
            } catch { Write-Step "     ! DR ratio alinamadi" DarkYellow }

            # ---- WWN MAP HAZIRLA (bulk fc_initiator) ----
            $WwnMap = @{}
            $fcRange = 0
            $fcFetched = 0
            do {
                $fcBatch = $null
                try {
                    $fcUrl = "$BaseUrl/$DevId/fc_initiator?range=[$fcRange-$($fcRange+99)]"
                    $fcResp = Invoke-RestMethod -Uri $fcUrl -Method Get -Headers $Headers `
                        -WebSession $Session -TimeoutSec 30 -ErrorAction Stop
                    $fcBatch = if ($fcResp.data) { @($fcResp.data) } else { @() }
                } catch { break }

                foreach ($ini in $fcBatch) {
                    $rawWwn = $null
                    if ($ini.ID) { $rawWwn = $ini.ID.ToString().Trim() }
                    $wwns = Expand-Wwn -raw $rawWwn
                    if ($wwns.Count -eq 0) { continue }

                    $parentId = $null
                    foreach ($fld in 'PARENTID','parentId','PARENTOBJID','parentObjId','HOSTID','hostId') {
                        if ($ini.$fld) {
                            $val = $ini.$fld.ToString().Trim()
                            if ($val -and $val -ne '0' -and $val -ne '') { $parentId = $val; break }
                        }
                    }

                    if ($parentId) {
                        if (-not $WwnMap.ContainsKey($parentId)) { $WwnMap[$parentId] = @() }
                        foreach ($wwn in $wwns) {
                            if ($wwn -notin $WwnMap[$parentId]) { $WwnMap[$parentId] += $wwn }
                        }
                    }
                }

                $fcFetched = $fcBatch.Count
                $fcRange += 100
            } while ($fcFetched -eq 100 -and $fcRange -lt 10000)

            # iSCSI initiator - pagination ile tum IQN'leri cek
            try {
                $isOffset = 0; $isPage = 100
                do {
                    $isResp = Invoke-RestMethod `
                        -Uri "$BaseUrl/$DevId/iscsi_initiator?range=[$isOffset-$($isOffset+$isPage)]" `
                        -Method Get -Headers $Headers -WebSession $Session `
                        -TimeoutSec 60 -ErrorAction SilentlyContinue
                    if (-not $isResp.data -or $isResp.data.Count -eq 0) { break }
                    foreach ($ini in @($isResp.data)) {
                        $iqn      = if ($ini.ID)       { $ini.ID }       elseif ($ini.NAME)     { $ini.NAME }     else { $null }
                        $parentId = if ($ini.PARENTID) { $ini.PARENTID.ToString() } else { $null }
                        if ($iqn -and $parentId) {
                            if (-not $WwnMap.ContainsKey($parentId)) { $WwnMap[$parentId] = @() }
                            $WwnMap[$parentId] += 'iqn:' + $iqn.ToString().Trim()
                        }
                    }
                    $isOffset += $isResp.data.Count
                    if ($isResp.data.Count -lt $isPage) { break }
                } while ($true)
            } catch { Write-Verbose "[L588] isResp atlandi: $($_.Exception.Message)" }

            # ---- LUN GROUP CACHE (her LUN Group icin kapasite + sayim cek) ----
            # NOT: bu cache hem ProvisionedTB hesaplamasinda hem LunGroup CSV'sinde kullanilacak
            $LunGroupCapMap = @{}    # lgId -> @{ Name, CapTB, LunCount }
            try {
                $LgResp = Invoke-RestMethod -Uri "$BaseUrl/$DevId/lungroup" -Method Get `
                    -Headers $Headers -WebSession $Session -TimeoutSec 30 -ErrorAction Stop
                if ($LgResp.data) {
                    foreach ($lg in $LgResp.data) {
                        $lgIdStr = $lg.ID.ToString()
                        $grpTb = 0; $cnt = 0
                        try {
                            $AssocUrl = "$BaseUrl/$DevId/lun/associate?ASSOCIATEOBJTYPE=256&ASSOCIATEOBJID=$lgIdStr"
                            $AssocResp = Invoke-RestMethod -Uri $AssocUrl -Method Get `
                                -Headers $Headers -WebSession $Session -TimeoutSec 60 -ErrorAction Stop
                            if ($AssocResp.data) {
                                $cnt = $AssocResp.data.Count
                                foreach ($lun in $AssocResp.data) {
                                    if ($lun.CAPACITY) {
                                        $grpTb += ((Parse-Double "$($lun.CAPACITY)") * $SectorSize) / $script:TB
                                    }
                                }
                            }
                        } catch { Write-Verbose "[L612] AssocResp atlandi: $($_.Exception.Message)" }
                        $LunGroupCapMap[$lgIdStr] = @{
                            Name     = $lg.NAME
                            CapTB    = [math]::Round($grpTb, 3)
                            LunCount = $cnt
                        }

                        # LunGroup CSV satiri
                        $Rapor_LunGrps += [PSCustomObject]@{
                            Lokasyon=$Lokasyon; Kabinet=$DisplayName
                            'Lun Group Name'=$lg.NAME
                            'Total Capacity (TB)'=[math]::Round($grpTb, 2)
                            'LUN Count'=$cnt
                        }
                    }
                }
            } catch { Write-Step "     ! LUN gruplari alinamadi" DarkYellow }

            # ---- MAPPING VIEW + HOST PROVISIONED KAPASITE ----
            # DOGRU MANTIK: Bir mapping view'daki LUN Group kapasitesi
            # o HostGroup'taki host sayisina bolunur (paylasimli kapasite)
            $HostProvMap = @{}        # hostId -> toplam TB
            try {
                $MvResp = Invoke-RestMethod -Uri "$BaseUrl/$DevId/mappingview?range=[0-999]" -Method Get `
                    -Headers $Headers -WebSession $Session -TimeoutSec 30 -ErrorAction SilentlyContinue

                if ($MvResp.data) {
                    foreach ($mv in @($MvResp.data)) {
                        $hgId = $null; $lgId = $null
                        foreach ($f in 'HOSTGROUP_ID','hostgroup_id','HOSTGROUPID','HostGroupId') {
                            if ($mv.$f) { $hgId = $mv.$f.ToString(); break }
                        }
                        foreach ($f in 'LUNGROUP_ID','lungroup_id','LUNGROUPID','LunGroupId') {
                            if ($mv.$f) { $lgId = $mv.$f.ToString(); break }
                        }
                        if (-not $hgId -or -not $lgId) { continue }

                        # LUN Group kapasitesi cache'den
                        $lgCapTb = 0
                        if ($LunGroupCapMap.ContainsKey($lgId)) { $lgCapTb = $LunGroupCapMap[$lgId].CapTB }
                        if ($lgCapTb -le 0) { continue }

                        # HostGroup'taki host listesi
                        $hostsInGroup = @()
                        try {
                            $HgHostUrl = "$BaseUrl/$DevId/host/associate?ASSOCIATEOBJTYPE=14&ASSOCIATEOBJID=$hgId"
                            $HgResp = Invoke-RestMethod -Uri $HgHostUrl -Method Get -Headers $Headers `
                                -WebSession $Session -TimeoutSec 15 -ErrorAction SilentlyContinue
                            if ($HgResp.data) {
                                foreach ($hh in @($HgResp.data)) {
                                    $hostsInGroup += $hh.ID.ToString()
                                }
                            }
                        } catch { Write-Verbose "[L665] HgResp atlandi: $($_.Exception.Message)" }

                        if ($hostsInGroup.Count -eq 0) { continue }

                        # Kapasite host sayisina bolunur (paylasimli)
                        # Birden fazla host varsa esit bolusur (cluster mantigi)
                        $perHostTb = [math]::Round($lgCapTb / $hostsInGroup.Count, 3)
                        foreach ($hhId in $hostsInGroup) {
                            if ($HostProvMap.ContainsKey($hhId)) {
                                $HostProvMap[$hhId] += $perHostTb
                            } else {
                                $HostProvMap[$hhId] = $perHostTb
                            }
                        }
                    }
                }
            } catch { Write-Verbose "[L681] HgResp atlandi: $($_.Exception.Message)" }

            # ---- HOST LISTESI ----
            $HostCount = 0; $OsStats = @{}; $OsString = '-'

            try {
                # Huawei varsayilan limit 100 - buyuk ortamda host eksik gelebilir
                # Pagination ile tum hostlari cek
                $allHosts = @()
                $hostOffset = 0; $hostPage = 100
                do {
                    $HostResp = Invoke-RestMethod `
                        -Uri "$BaseUrl/$DevId/host?range=[$hostOffset-$($hostOffset+$hostPage)]" `
                        -Method Get -Headers $Headers -WebSession $Session `
                        -TimeoutSec 30 -ErrorAction Stop
                    if ($HostResp.data -and $HostResp.data.Count -gt 0) {
                        $allHosts += $HostResp.data
                        $hostOffset += $HostResp.data.Count
                        if ($HostResp.data.Count -lt $hostPage) { break }
                    } else { break }
                } while ($true)
                $HostCount = $allHosts.Count

                if ($allHosts.Count -gt 0) {
                    foreach ($h in $allHosts) {
                        $OsId   = "$($h.OPERATIONSYSTEM)"
                        $OsBase = if ($HuaweiOsMap.ContainsKey($OsId)) { $HuaweiOsMap[$OsId] } else { "Generic($OsId)" }

                        $MapDur = 'Unmapped'
                        $isAdded = "$($h.ISADD2HOSTGROUP)".Trim().ToLower()
                        if ($isAdded -eq 'true' -or $isAdded -eq '1' -or $isAdded -eq 'yes') {
                            $MapDur = 'Mapped'
                        }
                        # Fallback: hostgroups varsa Mapped say
                        if ($MapDur -eq 'Unmapped' -and $h.HOSTGROUP_ID) {
                            $MapDur = 'Mapped'
                        }

                        $hostId = $h.ID.ToString()
                        $hostName = "$($h.NAME)".Trim()
                        $hostWwns = if ($WwnMap.ContainsKey($hostId)) { @($WwnMap[$hostId]) } else { @() }

                        # WWN fallback (gerekirse)
                        if ($hostWwns.Count -eq 0) {
                            try {
                                $assocUrl = "$BaseUrl/$DevId/host/associate/fc_initiator?ASSOCIATEOBJTYPE=21&ASSOCIATEOBJID=$hostId"
                                $aResp = Invoke-RestMethod -Uri $assocUrl -Method Get -Headers $Headers `
                                    -WebSession $Session -TimeoutSec 10 -ErrorAction SilentlyContinue
                                if ($aResp.data) {
                                    foreach ($ini in @($aResp.data)) {
                                        $rawW = if ($ini.ID) { $ini.ID.ToString().Trim() } else { $null }
                                        foreach ($w in (Expand-Wwn -raw $rawW)) { $hostWwns += $w }
                                    }
                                }
                            } catch { Write-Verbose "[L735] aResp atlandi: $($_.Exception.Message)" }
                        }

                        # OS resolve - skorlama tabanli (storage personality + WWN + pattern)
                        # $OsBase Huawei OPERATIONSYSTEM ID'den cevrilmis "AIX/Linux/VMware ESX" gibi.
                        # "Generic(X)" haric explicit personality olarak gecsin.
                        $personalityArg = if ($OsBase -and $OsBase -notmatch '^Generic') { $OsBase } else { '' }
                        $OsName = Resolve-HostOS -CurrentOs $OsBase -HostName $hostName -WWNs $hostWwns `
                                                 -ExplicitPersonality $personalityArg

                        if ($OsStats.ContainsKey($OsName)) { $OsStats[$OsName]++ } else { $OsStats[$OsName] = 1 }

                        $provTb = if ($HostProvMap.ContainsKey($hostId)) {
                            [math]::Round($HostProvMap[$hostId], 2)
                        } else { 0 }

                        $Rapor_Hosts += [PSCustomObject]@{
                            Lokasyon=$Lokasyon; Kabinet=$DisplayName
                            'Host Name'=$hostName; OS=$OsName; 'Map Durumu'=$MapDur
                            'Provisioned (TB)'=$provTb
                            'Host WWN'=($hostWwns -join ' | ')
                        }
                    }

                    $stat = @()
                    foreach ($k in $OsStats.Keys) { $stat += "${k}: $($OsStats[$k])" }
                    $OsString = $stat -join ' | '
                    Write-Step "     Host: $HostCount adet" DarkGray
                }   # if ($allHosts.Count -gt 0)
            } catch { Write-Step "     ! Host listesi alinamadi: $($_.Exception.Message)" DarkYellow }

            # ---- SNAPSHOT POLICY / SCHEDULE ----
            try {
                Write-Step "     + snapshot schedule..." DarkGray
                $schedRows = @()

                # Huawei Dorado'da endpoint isimleri versiyona gore degisir
                # Sirasıyla dene: snapshot_scheduler, schedule_task, remote_replication_task
                $snapEndpoints = @(
                    "snapshot_scheduler",
                    "schedule_task",
                    "snapshot_schedule"
                )
                $schedData = @()
                $schedTip  = 'LUN'
                foreach ($ep in $snapEndpoints) {
                    try {
                        $r = Invoke-RestMethod `
                            -Uri "$BaseUrl/$DevId/${ep}?range=[0-500]" `
                            -Method Get -Headers $Headers -WebSession $Session `
                            -TimeoutSec 60 -ErrorAction Stop
                        if ($r -and $r.data -and $r.data.Count -gt 0) {
                            $schedData = $r.data
                            Write-Step "     Snapshot endpoint: /$ep ($($schedData.Count) kural)" DarkGray
                            break
                        }
                    } catch { Write-Verbose "[L787] r atlandi: $($_.Exception.Message)" }
                }

                foreach ($sch in $schedData) {
                    $intervalSec = if ($sch.SCHEDINTERVAL)    { [int]$sch.SCHEDINTERVAL }    else { 0 }
                    $retainSec   = if ($sch.SCHEDULEKEEPCOUNT){ [int]$sch.SCHEDULEKEEPCOUNT } else { 0 }
                    $retainDays  = if ($sch.RETENTIONDURATION){ [math]::Round([int]$sch.RETENTIONDURATION / 86400, 1) } else { 0 }

                    $intervalStr = if     ($intervalSec -ge 86400) { "$([math]::Round($intervalSec/86400,1)) gun" }
                                   elseif ($intervalSec -ge 3600)  { "$([math]::Round($intervalSec/3600,1)) saat" }
                                   elseif ($intervalSec -gt 0)     { "$([math]::Round($intervalSec/60,0)) dakika" }
                                   else                             { '-' }

                    $retainStr   = if ($retainDays -gt 0)  { "$retainDays gun" }
                                   elseif ($retainSec -gt 0){ "$retainSec kopya" }
                                   else                     { '-' }

                    $objName  = if ($sch.PARENTNAME) { $sch.PARENTNAME } elseif ($sch.NAME) { $sch.NAME } else { '' }
                    $hostName = ''
                    # NOT: snapshot -> LUN -> LUN Group -> Host eslestirme zinciri
                    # Dorado'da ayri REST sorgulari gerektirir; $LunGroupCapMap
                    # su an sadece kapasite tutuyor (LunNames/HostName yok).
                    # Tanimsiz $LunGroupCache kullanimi kaldirildi (script patlamasin).
                    # Gercek eslestirme: Dorado ciktisi ile sonraki fazda.
                    if ($objName -and $script:HwSnapHostMap -and $script:HwSnapHostMap.ContainsKey($objName)) {
                        $hostName = $script:HwSnapHostMap[$objName]
                    }
                    $isActive = if ($sch.RUNNINGSTATUS -eq '1' -or $sch.ENABLED -eq 'true') { 'Aktif' } else { 'Pasif' }
                    $schedRows += [PSCustomObject]@{
                        Lokasyon=''; Kabinet=$DisplayName; 'Policy Adi'=$sch.NAME
                        'LUN / Obje'=$objName; 'Host'=$hostName
                        'Periyot'=$intervalStr; 'Saklama'=$retainStr; 'Durum'=$isActive; 'Tip'='LUN'
                    }
                }

                # 2. CG bazli snapshot scheduler
                $cgEndpoints = @("consistencygroup_snapshot_scheduler", "cg_snapshot_schedule")
                foreach ($ep in $cgEndpoints) {
                    try {
                        $cgr = Invoke-RestMethod `
                            -Uri "$BaseUrl/$DevId/${ep}?range=[0-200]" `
                            -Method Get -Headers $Headers -WebSession $Session `
                            -TimeoutSec 20 -ErrorAction Stop
                        if ($cgr -and $cgr.data -and $cgr.data.Count -gt 0) {
                            foreach ($sch in $cgr.data) {
                                $intervalSec = if ($sch.SCHEDINTERVAL)    { [int]$sch.SCHEDINTERVAL }    else { 0 }
                                $retainDays  = if ($sch.RETENTIONDURATION){ [math]::Round([int]$sch.RETENTIONDURATION / 86400, 1) } else { 0 }
                                $retainSec   = if ($sch.SCHEDULEKEEPCOUNT){ [int]$sch.SCHEDULEKEEPCOUNT } else { 0 }
                                $intervalStr = if ($intervalSec -ge 86400) { "$([math]::Round($intervalSec/86400,1)) gun" }
                                              elseif ($intervalSec -ge 3600)  { "$([math]::Round($intervalSec/3600,1)) saat" }
                                              elseif ($intervalSec -gt 0)     { "$([math]::Round($intervalSec/60,0)) dakika" }
                                              else { '-' }
                                $retainStr   = if ($retainDays -gt 0) { "$retainDays gun" } elseif ($retainSec -gt 0) { "$retainSec kopya" } else { '-' }
                                $isActive = if ($sch.RUNNINGSTATUS -eq '1' -or $sch.ENABLED -eq 'true') { 'Aktif' } else { 'Pasif' }
                                $schedRows += [PSCustomObject]@{
                                    Lokasyon=''; Kabinet=$DisplayName; 'Policy Adi'=$sch.NAME
                                    'LUN / Obje'=if ($sch.CGNAME) { $sch.CGNAME } else { $sch.PARENTNAME }
                                    'Host'=''; 'Periyot'=$intervalStr; 'Saklama'=$retainStr; 'Durum'=$isActive; 'Tip'='CG'
                                }
                            }
                            break
                        }
                    } catch { Write-Verbose "[L847] cgr atlandi: $($_.Exception.Message)" }
                }

                # Lokasyon doldur
                $schedRows | ForEach-Object { $_.Lokasyon = $Lokasyon }
                Write-Step "     Snapshot policy: $($schedRows.Count) kural" DarkGray
                $Rapor_Snapshots += $schedRows

            } catch { Write-Step "     ! Snapshot policy alinamadi: $($_.Exception.Message)" DarkYellow }

            # ---- NAS (Filesystem + CIFS) ----
            try {
                Write-Step "     + NAS filesystem listesi..." DarkGray
                $fsOffset = 0; $fsPageSize = 200; $nasRows = @()
                do {
                    $fsResp = Invoke-RestMethod `
                        -Uri "$BaseUrl/$DevId/filesystem?range=[$fsOffset-$($fsOffset+$fsPageSize)]" `
                        -Method Get -Headers $Headers -WebSession $Session -TimeoutSec 60 -ErrorAction Stop
                    if (-not $fsResp.data -or $fsResp.data.Count -eq 0) { break }
                    foreach ($fs in $fsResp.data) {
                        $allocTB = if ($fs.ALLOCTYPE -ne $null) { [math]::Round((Parse-Double "$($fs.CAPACITY)") * $SectorSize / $script:TB, 4) } else { 0 }
                        $usedTB  = if ($fs.USEDCAPACITY)        { [math]::Round((Parse-Double "$($fs.USEDCAPACITY)") * $SectorSize / $script:TB, 4) } else { 0 }
                        $nasRows += [PSCustomObject]@{
                            Lokasyon       = $Lokasyon
                            Kabinet        = $DisplayName
                            'Filesystem'   = $fs.NAME
                            'Pool'         = if ($fs.POOLNAME)   { $fs.POOLNAME }   else { '' }
                            'VSTORE'       = if ($fs.vstoreName) { $fs.vstoreName } else { '' }
                            'Kapasite (TB)'= $allocTB
                            'Kullanilan (TB)' = $usedTB
                            'NFS'          = if ($fs.ENABLENFSV3 -eq 'true' -or $fs.ENABLENFSV4 -eq 'true') { 'Evet' } else { 'Hayir' }
                            'CIFS'         = if ($fs.ENABLESMB   -eq 'true') { 'Evet' } else { 'Hayir' }
                            'Durum'        = if ($fs.HEALTHSTATUS -eq '1') { 'Normal' } else { 'Anormal' }
                        }
                    }
                    $fsOffset += $fsResp.data.Count
                    if ($fsResp.data.Count -lt $fsPageSize) { break }
                } while ($true)

                # CIFS paylaşımları — filesystem ile eşleştir
                try {
                    $cifsResp = Invoke-RestMethod -Uri "$BaseUrl/$DevId/CIFS_SHARE?range=[0-500]" `
                        -Method Get -Headers $Headers -WebSession $Session -TimeoutSec 30 -ErrorAction SilentlyContinue
                    if ($cifsResp.data) {
                        foreach ($c in $cifsResp.data) {
                            $fsName = if ($c.FILESYSTEMNAME) { $c.FILESYSTEMNAME } else { '' }
                            $existing = $nasRows | Where-Object { $_.Filesystem -eq $fsName } | Select-Object -First 1
                            if (-not $existing) {
                                $nasRows += [PSCustomObject]@{
                                    Lokasyon=''; Kabinet=$DisplayName; Filesystem=$fsName
                                    Pool=''; VSTORE=''; 'Kapasite (TB)'=0; 'Kullanilan (TB)'=0
                                    NFS='Hayir'; CIFS='Evet'; Durum='Normal'
                                }
                            }
                        }
                    }
                } catch { Write-Verbose "[L903] cifsResp atlandi: $($_.Exception.Message)" }

                Write-Step "     NAS Filesystem: $($nasRows.Count)" DarkGray
                $Rapor_NAS += $nasRows
            } catch { Write-Step "     ! NAS listesi alinamadi: $($_.Exception.Message)" DarkYellow }

            # ---- HYPERMETRO ----
            try {
                Write-Step "     + HyperMetro ciftleri..." DarkGray
                $hmResp = Invoke-RestMethod -Uri "$BaseUrl/$DevId/HyperMetroPair?range=[0-500]" `
                    -Method Get -Headers $Headers -WebSession $Session -TimeoutSec 60 -ErrorAction Stop
                if ($hmResp.data) {
                    foreach ($hm in $hmResp.data) {
                        $runStatus = switch ("$($hm.RUNNINGSTATUS)") {
                            '1'  {'Normal'}    '2'  {'Fault'}
                            '23' {'Paused'}    '33' {'Synchronizing'}
                            '34' {'Synchronized'} '35' {'NotSynchronized'}
                            '41' {'Standby'}   '47' {'Running'}
                            default { "[$($hm.RUNNINGSTATUS)]" }
                        }
                        $hmState = switch ("$($hm.HEALTHSTATUS)") {
                            '1' {'Normal'} '2' {'Fault'} default { "[$($hm.HEALTHSTATUS)]" }
                        }
                        $capacTB = if ($hm.CAPACITYBYTES) {
                            [math]::Round((Parse-Double "$($hm.CAPACITYBYTES)") / $script:TB, 3)
                        } elseif ($hm.CAPACITY) {
                            [math]::Round((Parse-Double "$($hm.CAPACITY)") * $SectorSize / $script:TB, 3)
                        } else { 0 }

                        $Rapor_HyperMetro += [PSCustomObject]@{
                            Lokasyon        = $Lokasyon
                            Kabinet         = $DisplayName
                            ID              = $hm.ID
                            'Yerel LUN'     = if ($hm.LOCALOBJNAME)  { $hm.LOCALOBJNAME }  else { $hm.LOCALOBJID }
                            'Uzak LUN'      = if ($hm.REMOTEOBJNAME) { $hm.REMOTEOBJNAME } else { $hm.REMOTEOBJID }
                            'Uzak Kabinet'  = if ($hm.REMOTEDEVICENAME) { $hm.REMOTEDEVICENAME } else { '' }
                            'Domain'        = if ($hm.DOMAINNAME)    { $hm.DOMAINNAME }    else { '' }
                            'Durum'         = $runStatus
                            'Saglik'        = $hmState
                            'Kapasite (TB)' = $capacTB
                            'Sync Ilerleme' = if ($hm.PROGRESS)      { "$($hm.PROGRESS)%" } else { '' }
                        }
                    }
                    Write-Step "     HyperMetro: $($hmResp.data.Count) cift" DarkGray
                }
            } catch { Write-Step "     ! HyperMetro listesi alinamadi: $($_.Exception.Message)" DarkYellow }

            # ---- PORT GROUP ----
            try {
                $PgResp = Invoke-RestMethod -Uri "$BaseUrl/$DevId/portgroup" -Method Get `
                    -Headers $Headers -WebSession $Session -TimeoutSec 30 -ErrorAction Stop
                if ($PgResp.data) {
                    foreach ($pg in $PgResp.data) {
                        $pgName = $pg.NAME
                        $pgId   = $pg.ID
                        $portWwns = @()

                        try {
                            $FcAssoc = "$BaseUrl/$DevId/fc_port/associate?ASSOCIATEOBJTYPE=257&ASSOCIATEOBJID=$pgId"
                            $FcResp = Invoke-RestMethod -Uri $FcAssoc -Method Get `
                                -Headers $Headers -WebSession $Session -TimeoutSec 30 -ErrorAction SilentlyContinue
                            if ($FcResp.data) {
                                foreach ($fp in @($FcResp.data)) {
                                    $w = $null
                                    if ($fp.WWN) { $w = $fp.WWN.ToString().ToLower() }
                                    elseif ($fp.ID) { $w = $fp.ID.ToString().ToLower() }
                                    if ($w) {
                                        $clean = $w.Replace(':','').Replace('-','').Trim()
                                        if ($clean -match '^[0-9a-f]{16}$') {
                                            $portWwns += ($clean -split '(..)' | Where-Object { $_ }) -join ':'
                                        }
                                    }
                                }
                            }
                        } catch { Write-Verbose "[L977] FcResp atlandi: $($_.Exception.Message)" }

                        $stdAlias = "${DisplayName}_${pgName}" -replace '\s+','_'

                        if ($portWwns.Count -gt 0) {
                            foreach ($pw in $portWwns) {
                                $Rapor_PortGroups += [PSCustomObject]@{
                                    Lokasyon=$Lokasyon; Kabinet=$DisplayName
                                    PortGroup=$pgName; Alias=$stdAlias
                                    PortWWN=$pw; PortCount=$portWwns.Count
                                }
                            }
                        } else {
                            $Rapor_PortGroups += [PSCustomObject]@{
                                Lokasyon=$Lokasyon; Kabinet=$DisplayName
                                PortGroup=$pgName; Alias=$stdAlias
                                PortWWN=''; PortCount=0
                            }
                        }
                    }
                }
            } catch { Write-Verbose "[L998] islem atlandi: $($_.Exception.Message)" }

            # ---- DASHBOARD SATIRI ----
            $Rapor_Dash += [PSCustomObject]@{
                Lokasyon=$Lokasyon; Kabinet=$DisplayName; IP=$Kabinet.IP
                'Total (TB)'=$TotalTB; 'Used (TB)'=$UsedTB; 'Subscribed (TB)'=$SubsTB
                'Free (TB)'=$FreeTB; 'Doluluk (%)'=$Pct
                'Data Reduction'=$ReductionStr
                'Host Sayisi'=$HostCount; 'OS Dagilimi'=$OsString
                Versiyon=$Version
            }

            Write-Step "     OK: $TotalTB TB | DR: $ReductionStr | host: $HostCount | Prov hesaplandi: $($HostProvMap.Keys.Count)" Green

            # ---- LOGOUT ----
            try {
                Invoke-RestMethod -Uri "$BaseUrl/$DevId/sessions/$Token" -Method Delete `
                    -Headers $Headers -WebSession $Session -TimeoutSec 10 -ErrorAction SilentlyContinue | Out-Null
            } catch { Write-Verbose "[L1016] logout atlandi: $($_.Exception.Message)" }

        } catch {
            Write-Step "     HATA: $($_.Exception.Message)" Red
            $Rapor_Dash += New-ErrorDashRow -Lokasyon $Lokasyon -Kabinet $DisplayName -IP $Kabinet.IP -Hata $_.Exception.Message
        } finally {
            $Pass = $null
            [System.GC]::Collect()
        }
    }

    # ---- TOPLAM SATIRLARI (ortak helper) ----
    $Rapor_Dash += Add-LocationTotals -RaporDash $Rapor_Dash -LocTotals $LocTotals

    return @{
        Dashboard   = $Rapor_Dash
        Hosts       = $Rapor_Hosts
        LunGroups   = $Rapor_LunGrps
        PortGroups  = $Rapor_PortGroups
        Snapshots   = $Rapor_Snapshots
        NAS         = $Rapor_NAS
        HyperMetro  = $Rapor_HyperMetro
    }
}

# ============================================================
# 4. POWERMAX TARAYICI
# ============================================================

function Invoke-PowerMaxScan {
    param([array]$Cabinets)

    $U4P_Version = '100'
    $Rapor_Dash       = @()
    $Rapor_Hosts      = @()
    $Rapor_LunGroups  = @()
    $Rapor_PortGroups = @()
    $Rapor_SnapPolicy = @()
    $ProcessedArrays  = @()
    $LocTotals = @{}

    foreach ($Uni in $Cabinets) {
        Write-Step "  -> Baglaniyor: $($Uni.Name) ($($Uni.IP))" Cyan

        $cred = $null
        try {
            $cred = Get-CredFromFile -Type 'PowerMax' -Name $Uni.Name
        } catch {
            Write-Step "     HATA: $($_.Exception.Message)" Red
            $loc = switch -Regex ($Uni.Name) { 'IST' {'Istanbul'} 'ANK' {'Ankara'} 'KOS' {'Kos'} default {$Uni.Name} }
            $Rapor_Dash += New-ErrorDashRow -Lokasyon $loc -Kabinet $Uni.Name -IP $Uni.IP -Hata $_.Exception.Message
            continue
        }

        $User = $cred.User
        $Pass = $cred.Password
        $cred = $null
        $Auth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${User}:${Pass}"))
        $BaseUrl = "https://$($Uni.IP):8443/univmax/restapi/$U4P_Version"
        $Headers = @{ Authorization="Basic $Auth"; 'Content-Type'='application/json'; Accept='application/json' }

        try {
            $SymResp = Invoke-RestMethod -Uri "$BaseUrl/system/symmetrix" -Method Get -Headers $Headers `
                -TimeoutSec 30 -ErrorAction Stop
            $SymIDs = if ($SymResp.symmetrixId) { @($SymResp.symmetrixId) } else { @($SymResp) }

            foreach ($SymIDRaw in $SymIDs) {
                $SymID = $SymIDRaw.ToString().Trim()
                if ($ProcessedArrays -contains $SymID) { continue }

                $Lokasyon = switch -Regex ($Uni.Name) {
                    'IST' { 'Istanbul' }
                    'ANK' { 'Ankara' }
                    'KOS' { 'Kos' }
                    default { $Uni.Name }
                }
                if ($SymID -match '630$' -or $SymID -match '631$') { $Lokasyon = 'Kos' }

                Write-Step "     Array: $SymID ($Lokasyon)" Green

                # ---- SISTEM EFFICIENCY & FIZIKSEL KAPASITE ----
                $SysTotalGB = 0; $SysUsedGB = 0; $DRR_Val = 1.0; $FoundDRR = '1.0:1'
                try {
                    $SloData = Invoke-RestMethod -Uri "$BaseUrl/sloprovisioning/symmetrix/$SymID" `
                        -Method Get -Headers $Headers -TimeoutSec 30 -ErrorAction Stop
                    if ($SloData.physicalCapacity) {
                        $SysTotalGB = (Parse-Double "$($SloData.physicalCapacity.total_capacity_gb)")
                        $SysUsedGB  = (Parse-Double "$($SloData.physicalCapacity.used_capacity_gb)")
                    }
                    $Eff = $SloData.system_efficiency
                    if ($Eff.data_reduction_ratio_to_one) {
                        $DRR_Val = Parse-Double "$($Eff.data_reduction_ratio_to_one)"
                    } elseif ($Eff.overall_efficiency_ratio_to_one) {
                        $DRR_Val = Parse-Double "$($Eff.overall_efficiency_ratio_to_one)"
                    }
                    $FoundDRR = "${DRR_Val}:1"
                } catch { Write-Verbose "[L1132] sloprovisioning atlandi: $($_.Exception.Message)" }

                $TotalTB = if ($SysTotalGB -gt 0) { [math]::Round($SysTotalGB / 1024, 2) } else { 0 }
                $UsedTB  = if ($SysUsedGB  -gt 0) { [math]::Round($SysUsedGB  / 1024, 2) } else { 0 }
                $FreeTB  = [math]::Round($TotalTB - $UsedTB, 2)
                $Pct     = if ($TotalTB -gt 0) { [math]::Round($UsedTB / $TotalTB * 100, 2) } else { 0 }

                # Subscribed + Storage Group cap map
                $SubsTB = 0
                $sgCapMap = @{}
                try {
                    $SgResp = Invoke-RestMethod -Uri "$BaseUrl/sloprovisioning/symmetrix/$SymID/storagegroup" `
                        -Method Get -Headers $Headers -TimeoutSec 30 -ErrorAction SilentlyContinue
                    $sgIds = if ($SgResp.storageGroupId) { @($SgResp.storageGroupId) } else { @() }
                    foreach ($sgId in $sgIds) {
                        try {
                            $sg = Invoke-RestMethod -Uri "$BaseUrl/sloprovisioning/symmetrix/$SymID/storagegroup/$sgId" `
                                -Method Get -Headers $Headers -TimeoutSec 15 -ErrorAction Stop
                            $capTB = if ($sg.cap_gb) { [math]::Round((Parse-Double "$($sg.cap_gb)") / 1024, 2) } else { 0 }
                            $cnt   = if ($sg.num_of_vols) { [int]$sg.num_of_vols } else { 0 }
                            $SubsTB += $capTB
                            $sgCapMap[$sgId] = @{ CapTB=$capTB; LunCount=$cnt; HostCount=0 }
                        } catch { Write-Verbose "[L1154] sloprovisioning atlandi: $($_.Exception.Message)" }
                    }
                    $SubsTB = [math]::Round($SubsTB, 2)
                } catch { Write-Verbose "[L1157] sloprovisioning atlandi: $($_.Exception.Message)" }

                # ---- MASKING VIEW + HOST ----
                $HostCount = 0; $OsStats = @{}; $OsString = '-'

                # MV listesi
                $mvList = @()
                try {
                    $MvResp = Invoke-RestMethod -Uri "$BaseUrl/sloprovisioning/symmetrix/$SymID/maskingview" `
                        -Method Get -Headers $Headers -TimeoutSec 30 -ErrorAction Stop
                    $mvList = if ($MvResp.maskingViewId) { @($MvResp.maskingViewId) } else { @() }
                } catch { Write-Step "     ! MaskingView listesi alinamadi" DarkYellow }

                # SG -> HostGroup uyeligi (paylasimli kapasite icin)
                # Onceden tum mv'leri tara, her SG'ye kac host bagli oldugunu say
                $mvDetails = @()
                foreach ($mvID in $mvList) {
                    try {
                        $mv = Invoke-RestMethod -Uri "$BaseUrl/sloprovisioning/symmetrix/$SymID/maskingview/$mvID" `
                            -Method Get -Headers $Headers -TimeoutSec 15 -ErrorAction Stop
                        if ($mv.hostId -and $mv.storageGroupId) {
                            $mvDetails += @{
                                MvId  = $mvID
                                HostId= $mv.hostId
                                SgId  = $mv.storageGroupId
                            }
                            # SG host sayisini arttir
                            if ($sgCapMap.ContainsKey($mv.storageGroupId)) {
                                $sgCapMap[$mv.storageGroupId].HostCount++
                            }
                        } elseif ($mv.hostGroupId -and $mv.storageGroupId) {
                            # Host Group bazli mv: icindeki hostlari cek
                            try {
                                $hg = Invoke-RestMethod -Uri "$BaseUrl/sloprovisioning/symmetrix/$SymID/hostgroup/$($mv.hostGroupId)" `
                                    -Method Get -Headers $Headers -TimeoutSec 20 -ErrorAction Stop
                                if ($hg.host) {
                                    foreach ($hMember in @($hg.host)) {
                                        $hName = if ($hMember -is [string]) { $hMember } else { $hMember.hostId }
                                        if (-not $hName) { continue }
                                        $mvDetails += @{
                                            MvId   = $mvID
                                            HostId = $hName
                                            SgId   = $mv.storageGroupId
                                        }
                                        if ($sgCapMap.ContainsKey($mv.storageGroupId)) {
                                            $sgCapMap[$mv.storageGroupId].HostCount++
                                        }
                                    }
                                }
                            } catch { Write-Verbose "[L1206] sloprovisioning atlandi: $($_.Exception.Message)" }
                        }
                    } catch { Write-Verbose "[L1208] sloprovisioning atlandi: $($_.Exception.Message)" }
                }

                $uniqueHosts = @{}    # hostKey -> @{ Name, OS, WWN, ProvTB, MaskingViews, SGs }

                foreach ($mvd in $mvDetails) {
                    $hostId = $mvd.HostId
                    $hostKey= $hostId.ToLower()
                    $sgId   = $mvd.SgId
                    $mvID   = $mvd.MvId

                    # Bu SG'nin paylasimli kapasitesi (host sayisina bolunmus)
                    $mvSgCapShared = 0
                    if ($sgCapMap.ContainsKey($sgId)) {
                        $sgInfo = $sgCapMap[$sgId]
                        $shareDivisor = if ($sgInfo.HostCount -gt 0) { $sgInfo.HostCount } else { 1 }
                        $mvSgCapShared = [math]::Round($sgInfo.CapTB / $shareDivisor, 3)
                    }

                    if (-not $uniqueHosts.ContainsKey($hostKey)) {
                        $hostOs   = 'Unknown'
                        $wwnList  = @()
                        $flagStr  = ''

                        try {
                            $h = Invoke-RestMethod -Uri "$BaseUrl/sloprovisioning/symmetrix/$SymID/host/$hostId" `
                                -Method Get -Headers $Headers -TimeoutSec 20 -ErrorAction Stop
                            if ($h.initiator) {
                                $wwnList = @($h.initiator | ForEach-Object {
                                    $_.ToString().ToLower().Replace(':','')
                                } | Where-Object { $_ -match '^[0-9a-f]{16}$' })
                            }
                            $flagStr = (("$($h.enabled_flags)") + ' ' +
                                        ("$($h.disabled_flags)") + ' ' +
                                        ("$($h.host_flags | Out-String)") + ' ' +
                                        ("$($h.type)")).ToLower()
                        } catch { Write-Verbose "[L1244] sloprovisioning atlandi: $($_.Exception.Message)" }

                        $hostOs = Resolve-HostOS -CurrentOs 'Unknown' -HostName $hostId -WWNs $wwnList -FlagBlob $flagStr

                        $uniqueHosts[$hostKey] = @{
                            Name   = $hostId
                            OS     = $hostOs
                            WWN    = $wwnList
                            ProvTB = $mvSgCapShared
                            MVs    = @($mvID)
                            SGs    = @($sgId)
                        }
                    } else {
                        $uniqueHosts[$hostKey].ProvTB += $mvSgCapShared
                        $uniqueHosts[$hostKey].MVs   += $mvID
                        $uniqueHosts[$hostKey].SGs   += $sgId
                    }
                }

                # Rapor_Hosts'a yaz (her host icin tek satir)
                foreach ($info in $uniqueHosts.Values) {
                    $Rapor_Hosts += [PSCustomObject]@{
                        Lokasyon=$Lokasyon; 'Array ID'=$SymID
                        'Host Name'=$info.Name; OS=$info.OS
                        'Provisioned (TB)'=[math]::Round($info.ProvTB, 2)
                        'Host WWN'=($info.WWN -join ' | ')
                        'Masking View'=(($info.MVs | Select-Object -Unique) -join '; ')
                        'Storage Group'=(($info.SGs | Select-Object -Unique) -join '; ')
                    }

                    if ($OsStats.ContainsKey($info.OS)) { $OsStats[$info.OS]++ } else { $OsStats[$info.OS] = 1 }
                }

                $HostCount = $uniqueHosts.Count
                if ($OsStats.Count -gt 0) {
                    $sl = @(); foreach ($k in $OsStats.Keys) { $sl += "${k}: $($OsStats[$k])" }
                    $OsString = $sl -join ' | '
                }

                # Storage Group -> Host map. Snapshot policy'leri SG seviyesinde atanir;
                # portalda host bazli gormek icin SG'ye bagli host'lari burada sakliyoruz.
                $sgHostMap = @{}
                foreach ($info in $uniqueHosts.Values) {
                    foreach ($sgNameForHost in @($info.SGs | Select-Object -Unique)) {
                        if (-not $sgNameForHost) { continue }
                        if (-not $sgHostMap.ContainsKey($sgNameForHost)) { $sgHostMap[$sgNameForHost] = @() }
                        $sgHostMap[$sgNameForHost] += $info.Name
                    }
                }
                foreach ($sgKey in @($sgHostMap.Keys)) {
                    $sgHostMap[$sgKey] = @($sgHostMap[$sgKey] | Where-Object { $_ } | Select-Object -Unique | Sort-Object)
                }

                # Storage Group -> LUN Group CSV
                foreach ($sgId in $sgCapMap.Keys) {
                    $Rapor_LunGroups += [PSCustomObject]@{
                        Lokasyon=$Lokasyon; Kabinet=$SymID
                        'Lun Group Name'=$sgId
                        'Total Capacity (TB)'=$sgCapMap[$sgId].CapTB
                        'LUN Count'=$sgCapMap[$sgId].LunCount
                    }
                }

                # ---- PORT GROUP ----
                try {
                    $PgListResp = Invoke-RestMethod -Uri "$BaseUrl/sloprovisioning/symmetrix/$SymID/portgroup" `
                        -Method Get -Headers $Headers -TimeoutSec 30 -ErrorAction Stop
                    $pgIds = if ($PgListResp.portGroupId) { @($PgListResp.portGroupId) } else { @() }

                    $portWwnCache = @{}

                    foreach ($pgId in $pgIds) {
                        try {
                            $pgDetail = Invoke-RestMethod -Uri "$BaseUrl/sloprovisioning/symmetrix/$SymID/portgroup/$pgId" `
                                -Method Get -Headers $Headers -TimeoutSec 15 -ErrorAction Stop

                            $pgPorts = @()
                            if ($pgDetail.symmetrixPortKey) {
                                foreach ($pk in @($pgDetail.symmetrixPortKey)) {
                                    $dirId  = $pk.directorId
                                    $portId = $pk.portId
                                    if (-not $dirId -or -not $portId) { continue }
                                    $cacheKey = "$dirId/$portId"

                                    $wwn = $portWwnCache[$cacheKey]
                                    if (-not $wwn) {
                                        try {
                                            $portInfo = Invoke-RestMethod -Uri "$BaseUrl/sloprovisioning/symmetrix/$SymID/director/$dirId/port/$portId" `
                                                -Method Get -Headers $Headers -TimeoutSec 20 -ErrorAction Stop
                                            if ($portInfo.symmetrixPort.identifier) {
                                                $raw = $portInfo.symmetrixPort.identifier.ToString().ToLower().Replace(':','').Replace('-','').Trim()
                                                if ($raw -match '^[0-9a-f]{16}$') {
                                                    $wwn = ($raw -split '(..)' | Where-Object { $_ }) -join ':'
                                                    $portWwnCache[$cacheKey] = $wwn
                                                }
                                            }
                                        } catch { Write-Verbose "[L1326] sloprovisioning atlandi: $($_.Exception.Message)" }
                                    }
                                    if ($wwn) { $pgPorts += $wwn }
                                }
                            }

                            $stdAlias = "${SymID}_${pgId}" -replace '\s+','_'

                            if ($pgPorts.Count -gt 0) {
                                foreach ($pw in $pgPorts) {
                                    $Rapor_PortGroups += [PSCustomObject]@{
                                        Lokasyon=$Lokasyon; Kabinet=$SymID
                                        PortGroup=$pgId; Alias=$stdAlias
                                        PortWWN=$pw; PortCount=$pgPorts.Count
                                    }
                                }
                            } else {
                                $Rapor_PortGroups += [PSCustomObject]@{
                                    Lokasyon=$Lokasyon; Kabinet=$SymID
                                    PortGroup=$pgId; Alias=$stdAlias
                                    PortWWN=''; PortCount=0
                                }
                            }
                        } catch { Write-Verbose "[L1349] islem atlandi: $($_.Exception.Message)" }
                    }
                } catch { Write-Verbose "[L1351] islem atlandi: $($_.Exception.Message)" }

                # Lokasyon toplami
                if (-not $LocTotals.ContainsKey($Lokasyon)) {
                    $LocTotals[$Lokasyon] = @{ Total=0; Used=0; Subs=0; Free=0 }
                }
                $LocTotals[$Lokasyon].Total += $TotalTB
                $LocTotals[$Lokasyon].Used  += $UsedTB
                $LocTotals[$Lokasyon].Subs  += $SubsTB
                $LocTotals[$Lokasyon].Free  += $FreeTB

                $Rapor_Dash += [PSCustomObject]@{
                    Lokasyon=$Lokasyon; Kabinet=$SymID; IP=$Uni.IP
                    'Total (TB)'=$TotalTB; 'Used (TB)'=$UsedTB; 'Subscribed (TB)'=$SubsTB
                    'Free (TB)'=$FreeTB; 'Doluluk (%)'=$Pct
                    'Data Reduction'=$FoundDRR
                    'Host Sayisi'=$HostCount; 'OS Dagilimi'=$OsString
                    Versiyon=''
                }

                $ProcessedArrays += $SymID

                # ---- SNAPSHOT POLICY ----
                try {
                    Write-Step "     + snapshot policy..." DarkGray

                    # Unisphere versiyonuna gore endpoint degisir
                    # v9.2+: /replication/symmetrix/{id}/snapshotpolicy
                    # Eski: /84/replication/symmetrix/{id}/snapshotpolicy
                    $spListResp = $null
                    $spEndpoints = @(
                        "$BaseUrl/replication/symmetrix/$SymID/snapshotpolicy",
                        "$BaseUrl/84/replication/symmetrix/$SymID/snapshotpolicy",
                        "$BaseUrl/91/replication/symmetrix/$SymID/snapshotpolicy",
                        "$BaseUrl/92/replication/symmetrix/$SymID/snapshotpolicy"
                    )
                    foreach ($ep in $spEndpoints) {
                        try {
                            $spListResp = Invoke-RestMethod -Uri $ep `
                                -Method Get -Headers $Headers -TimeoutSec 20 -ErrorAction Stop
                            if ($spListResp) { Write-Step "     PMAX Snap endpoint OK: $ep" DarkGray; break }
                        } catch { Write-Verbose "[L1392] spListResp atlandi: $($_.Exception.Message)" }
                    }

                    $policyNames = if ($spListResp -and $spListResp.name) { @($spListResp.name) }
                                   elseif ($spListResp -and $spListResp.snapshotPolicies) { @($spListResp.snapshotPolicies) }
                                   elseif ($spListResp -and $spListResp.snapshotPolicyName) { @($spListResp.snapshotPolicyName) }
                                   else { @() }

                    $snapCountCache = @{} # "SG::Policy" -> current policy snapshot count

                    foreach ($pName in $policyNames) {
                        try {
                            $sp = $null
                            $spDetailEndpoints = @(
                                "$BaseUrl/replication/symmetrix/$SymID/snapshotpolicy/$pName",
                                "$BaseUrl/84/replication/symmetrix/$SymID/snapshotpolicy/$pName",
                                "$BaseUrl/91/replication/symmetrix/$SymID/snapshotpolicy/$pName",
                                "$BaseUrl/92/replication/symmetrix/$SymID/snapshotpolicy/$pName"
                            )
                            foreach ($spEp in $spDetailEndpoints) {
                                try {
                                    $sp = Invoke-RestMethod -Uri $spEp -Method Get -Headers $Headers -TimeoutSec 15 -ErrorAction Stop
                                    if ($sp) { break }
                                } catch { Write-Verbose "[PMAX SnapshotPolicy detail] $spEp atlandi: $($_.Exception.Message)" }
                            }
                            if (-not $sp) { continue }

                            $intMin  = if ($sp.intervalMinutes) { [int]$sp.intervalMinutes }
                                       elseif ($sp.interval_mins) { [int]$sp.interval_mins }
                                       elseif ($sp.interval) { [int]$sp.interval }
                                       else { 0 }
                            $offMin  = if ($sp.offsetMinutes) { [int]$sp.offsetMinutes }
                                       elseif ($sp.offset_mins) { [int]$sp.offset_mins }
                                       elseif ($sp.offset) { [int]$sp.offset }
                                       else { 0 }
                            $retSnap = if ($sp.numberOfFlashCopies) { [int]$sp.numberOfFlashCopies }
                                       elseif ($sp.maxCount) { [int]$sp.maxCount }
                                       elseif ($sp.max_count) { [int]$sp.max_count }
                                       elseif ($sp.snapshotsToKeep) { [int]$sp.snapshotsToKeep }
                                       else { 0 }
                            $retDays = if ($sp.secureForDays) { [int]$sp.secureForDays }
                                       elseif ($sp.retentionDays) { [int]$sp.retentionDays }
                                       else { 0 }

                            $intervalStr = if ($intMin -ge 1440) { "$([math]::Round($intMin/1440,1)) gun" }
                                           elseif ($intMin -ge 60) { "$([math]::Round($intMin/60,1)) saat" }
                                           elseif ($intMin -gt 0)  { "$intMin dakika" }
                                           else { '-' }
                            $offsetStr   = if ($offMin -ge 1440) { "$([math]::Round($offMin/1440,1)) gun" }
                                           elseif ($offMin -ge 60) { "$([math]::Round($offMin/60,1)) saat" }
                                           elseif ($offMin -gt 0)  { "$offMin dakika" }
                                           else { '-' }
                            $retainStr   = if ($retDays -gt 0) { "$retDays gun" } elseif ($retSnap -gt 0) { "$retSnap kopya" } else { '-' }
                            $policyType  = if ($sp.policyType) { $sp.policyType }
                                           elseif ($sp.type) { $sp.type }
                                           elseif ($sp.cloudProvider) { 'Cloud' }
                                           else { 'Local' }
                            $compliance  = if ($sp.complianceStatus) { $sp.complianceStatus }
                                           elseif ($sp.compliance) { $sp.compliance }
                                           elseif ($sp.compliance_state) { $sp.compliance_state }
                                           else { '-' }

                            $sgNames = @()
                            if ($sp.symmetrixSnapshotPolicyStorageGroupAssociation) {
                                $sgNames = @($sp.symmetrixSnapshotPolicyStorageGroupAssociation | ForEach-Object { $_.storageGroupName })
                            }
                            if ($sp.storageGroupName) { $sgNames += @($sp.storageGroupName) }
                            if ($sp.storageGroups)    { $sgNames += @($sp.storageGroups | ForEach-Object { if ($_ -is [string]) { $_ } else { $_.storageGroupName } }) }
                            $sgNames = @($sgNames | Where-Object { $_ } | Select-Object -Unique)
                            $isActive = if ($sp.suspended -eq $false -or $sp.policyState -eq 'Active') { 'Aktif' } else { 'Pasif' }

                            if ($sgNames.Count -eq 0) {
                                $Rapor_SnapPolicy += [PSCustomObject]@{
                                    Host='—'; Kabinet=$SymID; PolicyName=$pName
                                    StorageGroup='—'; Schedule=$intervalStr; Offset=$offsetStr
                                    Retention=$retainStr; TotalSnapshots=$retSnap; SnapshotsTaken=0; SnapshotsRemaining=$retSnap
                                    Compliance=$compliance; Status=$isActive; PolicyType=$policyType
                                }
                            } else {
                                foreach ($sgName in $sgNames) {
                                    $cacheKey = "$sgName`::$pName"
                                    $curSnapCount = 0
                                    if ($snapCountCache.ContainsKey($cacheKey)) {
                                        $curSnapCount = $snapCountCache[$cacheKey]
                                    } else {
                                        try {
                                            $snapResp = $null
                                            $snapEndpoints = @(
                                                "$BaseUrl/replication/symmetrix/$SymID/storagegroup/$sgName/snapshot",
                                                "$BaseUrl/84/replication/symmetrix/$SymID/storagegroup/$sgName/snapshot",
                                                "$BaseUrl/91/replication/symmetrix/$SymID/storagegroup/$sgName/snapshot",
                                                "$BaseUrl/92/replication/symmetrix/$SymID/storagegroup/$sgName/snapshot"
                                            )
                                            foreach ($snapEp in $snapEndpoints) {
                                                try {
                                                    $snapResp = Invoke-RestMethod -Uri $snapEp -Method Get -Headers $Headers -TimeoutSec 15 -ErrorAction Stop
                                                    if ($snapResp) { break }
                                                } catch { Write-Verbose "[PMAX Snapshot list] $snapEp atlandi: $($_.Exception.Message)" }
                                            }
                                            $snapItems = @()
                                            if ($snapResp.snapshot) { $snapItems = @($snapResp.snapshot) }
                                            elseif ($snapResp.snapshots) { $snapItems = @($snapResp.snapshots) }
                                            elseif ($snapResp.name) { $snapItems = @($snapResp.name) }
                                            elseif ($snapResp.snapshotName) { $snapItems = @($snapResp.snapshotName) }
                                            foreach ($sn in $snapItems) {
                                                $snName = if ($sn -is [string]) { $sn }
                                                          elseif ($sn.name) { $sn.name }
                                                          elseif ($sn.snapshotName) { $sn.snapshotName }
                                                          elseif ($sn.snapshot_name) { $sn.snapshot_name }
                                                          else { '' }
                                                if ($snName -eq $pName) { $curSnapCount++ }
                                            }
                                        } catch { Write-Verbose "[PMAX Snapshot count] $sgName/$pName atlandi: $($_.Exception.Message)" }
                                        $snapCountCache[$cacheKey] = $curSnapCount
                                    }

                                    $remaining = if ($retSnap -gt 0) { [math]::Max(0, $retSnap - $curSnapCount) } else { 0 }
                                    $hostsForSg = if ($sgHostMap.ContainsKey($sgName)) { @($sgHostMap[$sgName]) } else { @('—') }
                                    foreach ($hostName in $hostsForSg) {
                                        $Rapor_SnapPolicy += [PSCustomObject]@{
                                            Host=$hostName; Kabinet=$SymID; PolicyName=$pName
                                            StorageGroup=$sgName; Schedule=$intervalStr; Offset=$offsetStr
                                            Retention=$retainStr; TotalSnapshots=$retSnap; SnapshotsTaken=$curSnapCount; SnapshotsRemaining=$remaining
                                            Compliance=$compliance; Status=$isActive; PolicyType=$policyType
                                        }
                                    }
                                }
                            }
                        } catch { Write-Verbose "[L1434] islem atlandi: $($_.Exception.Message)" }
                    }
                    Write-Step "     Snapshot policy: $($policyNames.Count) adet" DarkGray
                } catch { Write-Step "     ! PMAX Snapshot policy alinamadi: $($_.Exception.Message)" DarkYellow }
            }
        } catch {
            Write-Step "     HATA: $($_.Exception.Message)" Red
        } finally {
            $Pass = $null
            $Auth = $null
            [System.GC]::Collect()
        }
    }

    # ---- TOPLAM SATIRLARI (ortak helper) ----
    $Rapor_Dash += Add-LocationTotals -RaporDash $Rapor_Dash -LocTotals $LocTotals -WithSubscribed

    return @{
        Dashboard  = $Rapor_Dash
        Hosts      = $Rapor_Hosts
        LunGroups  = $Rapor_LunGroups
        PortGroups = $Rapor_PortGroups
        SnapPolicy = $Rapor_SnapPolicy
    }
}

# ============================================================
# 4b. PURE FLASHARRAY TARAYICI
# ============================================================
# Pure REST API kullanir (api/2.36 - login/logout, /arrays, /hosts, /volumes)
# Auth: api-token -> session token (x-auth-token)
# Credential: Credentials\PureFA_<Name>.cred icinde JSON: { User=<bos>, Password=<api-token> }

function Invoke-PureScan {
    param([array]$Cabinets)

    $Rapor_Dash    = @()
    $Rapor_Hosts   = @()
    $Rapor_Volumes = @()
    $LocTotals     = @{}

    foreach ($Pure in $Cabinets) {
        $Lokasyon = if ($Pure.Lokasyon) { $Pure.Lokasyon } else { 'Istanbul' }
        Write-Step "  -> Baglaniyor: $Lokasyon / $($Pure.Name) ($($Pure.IP))" Cyan

        # Token oku
        $apiToken = $null
        try {
            $credObj = Get-CredFromFile -Type 'PureFA' -Name $Pure.Name
            $apiToken = $credObj.Password
        } catch {
            Write-Step "     HATA: $($_.Exception.Message)" Red
            $Rapor_Dash += New-ErrorDashRow -Lokasyon $Lokasyon -Kabinet $Pure.Name -IP $Pure.IP -Hata $_.Exception.Message
            continue
        }

        $BaseUrl     = "https://$($Pure.IP)/api/2.36"
        $PureSession = $null
        $authToken   = $null

        try {
            # 1) Eski session temizle (Pure'da concurrent session limiti var)
            try {
                $logoutHeaders = @{ 'api-token' = $apiToken; 'Content-Type' = 'application/json' }
                Invoke-RestMethod -Uri "$BaseUrl/logout" -Method Post -Headers $logoutHeaders `
                    -UseBasicParsing -ErrorAction SilentlyContinue | Out-Null
                Start-Sleep -Seconds 2
            } catch { Write-Verbose "[L1523] logout atlandi: $($_.Exception.Message)" }

            # 2) Login - api-token ile, x-auth-token header'i don
            $loginHeaders = @{ 'api-token' = $apiToken; 'Content-Type' = 'application/json' }
            $loginResp = Invoke-WebRequest -Uri "$BaseUrl/login" -Method Post -Headers $loginHeaders `
                -SessionVariable PureSession -UseBasicParsing -ErrorAction Stop
            $authToken = $loginResp.Headers['x-auth-token']
            if (-not $authToken) { throw "x-auth-token alinamadi" }
            $reqHeaders = @{ 'x-auth-token' = $authToken }

            # 3) Array kapasite
            $capData = Invoke-RestMethod -Uri "$BaseUrl/arrays" -Method Get -Headers $reqHeaders `
                -WebSession $PureSession -TimeoutSec 30 -ErrorAction Stop
            $arr = $capData.items[0]

            $TotalTB = [math]::Round($arr.capacity / $script:TB, 2)
            $UsedTB  = [math]::Round($arr.space.total_physical / $script:TB, 2)
            $FreeTB  = [math]::Round(($arr.capacity - $arr.space.total_physical) / $script:TB, 2)
            $SubsTB  = if ($arr.space.total_provisioned) { [math]::Round($arr.space.total_provisioned / $script:TB, 2) } else { 0 }
            $Pct     = if ($TotalTB -gt 0) { [math]::Round($UsedTB / $TotalTB * 100, 2) } else { 0 }
            $DRStr   = if ($arr.space.data_reduction) { "$([math]::Round($arr.space.data_reduction, 2)):1" } else { '-' }
            $Version = if ($arr.version) { $arr.version } else { '-' }

            # Lokasyon toplami
            if (-not $LocTotals.ContainsKey($Lokasyon)) {
                $LocTotals[$Lokasyon] = @{ Total=0; Used=0; Subs=0; Free=0 }
            }
            $LocTotals[$Lokasyon].Total += $TotalTB
            $LocTotals[$Lokasyon].Used  += $UsedTB
            $LocTotals[$Lokasyon].Subs  += $SubsTB
            $LocTotals[$Lokasyon].Free  += $FreeTB

            # 4) Host listesi
            Write-Step "     + host listesi..." Gray
            $HostCount = 0
            $OsStats   = @{}
            $hostData = Invoke-RestMethod -Uri "$BaseUrl/hosts" -Method Get -Headers $reqHeaders `
                -WebSession $PureSession -TimeoutSec 30 -ErrorAction Stop

            # 4b) Volume listesi - bağımsız çek (connections'dan önce)
            Write-Step "     + volume listesi..." Gray
            $volSize = @{}
            try {
                # continuation_token ile pagination - Pure API max 1000 item/istek
                $volToken = $null
                do {
                    $volUrl = "$BaseUrl/volumes?destroyed=false&limit=1000"
                    if ($volToken) { $volUrl += "&continuation_token=$volToken" }
                    $volResp = Invoke-RestMethod -Uri $volUrl -Method Get -Headers $reqHeaders `
                        -WebSession $PureSession -TimeoutSec 60 -ErrorAction Stop
                    if ($volResp.items) {
                        foreach ($v in $volResp.items) {
                            $vname = $v.name
                            $vsz   = if ($v.provisioned) { (Parse-Double "$($v.provisioned)") }
                                     elseif ($v.space -and $v.space.total_provisioned) { (Parse-Double "$($v.space.total_provisioned)") }
                                     else { 0 }
                            $volSize[$vname] = $vsz
                            $Rapor_Volumes += [PSCustomObject]@{
                                Lokasyon    = $Lokasyon
                                Kabinet     = $Pure.Name
                                Volume      = $vname
                                'Size (TB)' = [math]::Round($vsz / $script:TB, 3)
                                Serial      = if ($v.serial) { $v.serial } else { '' }
                            }
                        }
                    }
                    $volToken = if ($volResp.continuation_token) { $volResp.continuation_token } else { $null }
                } while ($volToken)
                Write-Step "     Volume: $($volSize.Count) adet" DarkGray
            } catch {
                Write-Step "     ! Volume listesi alinamadi: $($_.Exception.Message)" DarkYellow
            }

            # 4c) Host -> volume provisioning toplami: /connections endpoint
            $hostProvMap = @{}
            try {
                $connToken = $null
                do {
                    $connUrl = "$BaseUrl/connections?limit=1000"
                    if ($connToken) { $connUrl += "&continuation_token=$connToken" }
                    $connResp = Invoke-RestMethod -Uri $connUrl -Method Get -Headers $reqHeaders `
                        -WebSession $PureSession -TimeoutSec 60 -ErrorAction SilentlyContinue
                    if ($connResp.items) {
                        foreach ($c in $connResp.items) {
                            $hName = $null
                            if ($c.host -and $c.host.name)                 { $hName = $c.host.name }
                            elseif ($c.host_group -and $c.host_group.name) { continue }
                            if (-not $hName) { continue }

                            $vName = $null
                            if ($c.volume -and $c.volume.name) { $vName = $c.volume.name }
                            if (-not $vName) { continue }

                            $vsz = if ($volSize.ContainsKey($vName)) { $volSize[$vName] } else { 0 }
                            if ($hostProvMap.ContainsKey($hName)) { $hostProvMap[$hName] += $vsz }
                            else                                  { $hostProvMap[$hName]  = $vsz }
                        }
                    }
                    $connToken = if ($connResp.continuation_token) { $connResp.continuation_token } else { $null }
                } while ($connToken)
            } catch {
                Write-Step "     ! Connections alinamadi: $($_.Exception.Message)" DarkYellow
            }

            if ($hostData.items) {
                foreach ($h in $hostData.items) {
                    $HostCount++

                    $personalityRaw = if ($h.personality) { $h.personality.ToString().ToLower().Trim() } else { '' }
                    $osName = if ($personalityRaw -and $PurePersonalityMap.ContainsKey($personalityRaw)) {
                        $PurePersonalityMap[$personalityRaw]
                    } else { 'Linux' }   # Pure default - bos personality genelde Linux

                    # OS resolver pattern matching uygula (Unknown'lari azaltir)
                    $wwnList = @()
                    if ($h.wwns) {
                        $wwnList = @($h.wwns | ForEach-Object {
                            $w = $_.ToString().ToLower().Replace(':','').Replace('-','').Trim()
                            if ($w -match '^[0-9a-f]{16}$') { ($w -split '(..)' | Where-Object { $_ }) -join ':' }
                        } | Where-Object { $_ })
                    }
                    # OS resolver: skorlama tabanli (personality + WWN + pattern)
                    # $personalityRaw bos olabilir (default 'Linux' atanir); V2 bos personality'yi yok sayar.
                    $osName = Resolve-HostOS -CurrentOs $osName -HostName $h.name -WWNs $wwnList `
                                             -ExplicitPersonality $personalityRaw

                    if ($OsStats.ContainsKey($osName)) { $OsStats[$osName]++ } else { $OsStats[$osName] = 1 }

                    # Protocol tespit: iscsi_iqns varsa iSCSI, yoksa FC
                    $protocol = 'FC'
                    $iqnWwn   = ''
                    if ($h.iscsi_iqns -and $h.iscsi_iqns.Count -gt 0) {
                        $protocol = 'iSCSI'
                        $iqnWwn   = ($h.iscsi_iqns -join ' | ')
                    } elseif ($wwnList.Count -gt 0) {
                        $iqnWwn = ($wwnList -join ' | ')
                    }

                    $hostGroup = if ($h.host_group -and $h.host_group.name) { $h.host_group.name } else { '' }

                    $provBytes = if ($hostProvMap.ContainsKey($h.name)) { $hostProvMap[$h.name] } else { 0 }
                    $provTb    = [math]::Round($provBytes / $script:TB, 2)

                    $Rapor_Hosts += [PSCustomObject]@{
                        Lokasyon     = $Lokasyon
                        Kabinet      = $Pure.Name
                        'Host Name'  = $h.name
                        OS           = $osName
                        'Host Group' = $hostGroup
                        Protocol     = $protocol
                        'Provisioned (TB)' = $provTb
                        'Host WWN'   = $iqnWwn
                    }
                }
            }

            $OsString = if ($OsStats.Count -gt 0) {
                $sl = @(); foreach ($k in $OsStats.Keys) { $sl += "${k}: $($OsStats[$k])" }
                $sl -join ' | '
            } else { '-' }

            $Rapor_Dash += [PSCustomObject]@{
                Lokasyon=$Lokasyon; Kabinet=$Pure.Name; IP=$Pure.IP
                'Total (TB)'=$TotalTB; 'Used (TB)'=$UsedTB; 'Subscribed (TB)'=$SubsTB
                'Free (TB)'=$FreeTB; 'Doluluk (%)'=$Pct
                'Data Reduction'=$DRStr
                'Host Sayisi'=$HostCount; 'OS Dagilimi'=$OsString
                Versiyon=$Version
            }

            Write-Step "     OK: $TotalTB TB | DR: $DRStr | host: $HostCount" Green

            # Logout
            try {
                Invoke-RestMethod -Uri "$BaseUrl/logout" -Method Post -Headers $reqHeaders `
                    -WebSession $PureSession -TimeoutSec 10 -ErrorAction SilentlyContinue | Out-Null
            } catch { Write-Verbose "[L1696] logout atlandi: $($_.Exception.Message)" }

        } catch {
            Write-Step "     REST API basarisiz: $($_.Exception.Message)" Yellow

            # ---- PLINK SSH FALLBACK ----
            # Credential: User = SSH kullanıcısı, Password = SSH şifresi
            $faSshUser = $null; $faSshPass = $null
            try {
                $faCred    = Get-CredFromFile -Type 'PureFA' -Name $Pure.Name
                $faSshUser = if ($faCred.User -and $faCred.User -ne '-') { $faCred.User } else { 'pureuser' }
                $faSshPass = $faCred.Password
            } catch { Write-Verbose "[L1708] logout atlandi: $($_.Exception.Message)" }

            if ((Test-Path $PlinkPath) -and $faSshPass) {
                Write-Step "     -> plink SSH ($faSshUser@$($Pure.IP))..." DarkYellow

                function Invoke-PlinkFA {
                    param([string]$Cmd, [int]$Timeout = 20)
                    try {
                        $out = & $PlinkPath -batch -ssh -l $faSshUser -pw $faSshPass -P 22 $Pure.IP $Cmd 2>&1
                        return ($out | Where-Object { $_ -notmatch '^(Host|key|WARNING|using|keyboard|End of|Keyboard)' }) -join "`n"
                    } catch { return '' }
                }

                # Array kapasitesi: purearray list --space
                # Format: Name  Purity  Model  Capacity  Free  Used  Total  Data Reduction
                $arrRaw  = Invoke-PlinkFA "purearray list --space" 20
                $TotalTB = 0; $UsedTB = 0; $DRStr = '-'; $Versiyon = '(ssh)'
                foreach ($line in ($arrRaw -split "`n")) {
                    $l = $line.Trim()
                    if (-not $l -or $l -match '^Name\s+Purity|^---|^\s*$') { continue }
                    $parts = $l -split '\s{2,}'
                    # Capacity = index 3, Used = index 5 (yaklaşık - sürüme göre değişir)
                    foreach ($p in $parts) {
                        if ($p -match '^([\d\.]+)(T|TiB|G|GiB)$') {
                            $n = [double]$matches[1]
                            $tb = if ($matches[2] -match 'T') { [math]::Round($n, 2) } else { [math]::Round($n/1024, 2) }
                            if ($TotalTB -eq 0) { $TotalTB = $tb }
                            elseif ($UsedTB -eq 0) { $UsedTB = $tb }
                        }
                        if ($p -match '^([\d\.]+)\s+to\s+1') { $DRStr = "$($matches[1]):1" }
                    }
                    if ($parts.Count -ge 2 -and $parts[1] -match '^[\d\.]+$') { $Versiyon = "(Purity $($parts[1]))" }
                }
                $FreeTB = [math]::Round($TotalTB - $UsedTB, 2)
                $Pct    = if ($TotalTB -gt 0) { [math]::Round($UsedTB / $TotalTB * 100, 2) } else { 0 }

                # Host listesi: purehost list
                $hostRaw   = Invoke-PlinkFA "purehost list" 30
                $hostCount = 0
                foreach ($line in ($hostRaw -split "`n")) {
                    $l = $line.Trim()
                    if (-not $l -or $l -match '^Name\s+|^---|^\s*$') { continue }
                    $hostCount++
                    $parts = $l -split '\s{2,}'
                    $hName = $parts[0].Trim()
                    if ($hName -eq 'Name' -or $hName -match '^-+$') { $hostCount--; continue }
                    # Host WWN: purehost list --hgroup ile daha fazla bilgi alınabilir
                    $Rapor_Hosts += [PSCustomObject]@{
                        Lokasyon=$Lokasyon; Kabinet=$Pure.Name
                        'Host Name'=$hName; OS=''; 'Host Group'=''
                        Protocol='FC'; 'Provisioned (TB)'=0; 'Host WWN'=''
                    }
                }

                $Rapor_Dash += [PSCustomObject]@{
                    Lokasyon=$Lokasyon; Kabinet=$Pure.Name; IP=$Pure.IP
                    'Total (TB)'=$TotalTB; 'Used (TB)'=$UsedTB
                    'Subscribed (TB)'=0; 'Free (TB)'=$FreeTB
                    'Doluluk (%)'=$Pct; 'Data Reduction'=$DRStr
                    'Host Sayisi'=$hostCount; 'OS Dagilimi'='-'; Versiyon=$Versiyon
                }

                if (-not $LocTotals.ContainsKey($Lokasyon)) { $LocTotals[$Lokasyon] = @{Total=0;Used=0;Subs=0;Free=0} }
                $LocTotals[$Lokasyon].Total += $TotalTB
                $LocTotals[$Lokasyon].Used  += $UsedTB
                $LocTotals[$Lokasyon].Free  += $FreeTB

                Write-Step "     SSH OK: $TotalTB TB | $hostCount host" Green

            } else {
                Write-Step "     plink bulunamadi veya SSH sifresi tanimli degil" Red
                $Rapor_Dash += New-ErrorDashRow -Lokasyon $Lokasyon -Kabinet $Pure.Name -IP $Pure.IP -Hata $_.Exception.Message
            }
        } finally {
            $apiToken = $null
            $authToken = $null
            [System.GC]::Collect()
        }
    }

    # ---- TOPLAM SATIRLARI (ortak helper) ----
    $Rapor_Dash += Add-LocationTotals -RaporDash $Rapor_Dash -LocTotals $LocTotals -WithSubscribed

    return @{
        Dashboard = $Rapor_Dash
        Hosts     = $Rapor_Hosts
        Volumes   = $Rapor_Volumes
    }
}

# ============================================================
# 4d. PURE FLASHBLADE TARAYICI
# ============================================================
# FlashBlade REST API v2 (port 443 HTTPS)
# Auth: api-token header -> x-auth-token session token (FA ile ayni mekanizma)
# Endpoint'ler:
#   GET /api/2.0/arrays       -> toplam kapasite (space.capacity, space.used)
#   GET /api/2.0/buckets      -> S3 bucket listesi + boyutlar
#   GET /api/2.0/file-systems -> NFS/SMB dosya sistemi listesi
#   GET /api/2.0/arrays/space -> ozet kapasite (unique / shared / snapshot / total)

function Invoke-PureFBScan {
    param([array]$Cabinets)

    $Rapor_Dash    = @()
    $Rapor_Buckets = @()
    $Rapor_FS      = @()
    $Rapor_Repl    = @()
    $LocTotals     = @{}

    foreach ($fb in $Cabinets) {
        $Lokasyon = if ($fb.Lokasyon) { $fb.Lokasyon } else { 'Istanbul' }
        Write-Step "  -> Baglaniyor: $Lokasyon / $($fb.Name) ($($fb.IP)) [FlashBlade]" Cyan

        $apiToken = $null
        try {
            $credObj = Get-CredFromFile -Type 'PureFB' -Name $fb.Name
            $apiToken = $credObj.Password
        } catch {
            Write-Step "     HATA: $($_.Exception.Message)" Red
            $Rapor_Dash += New-ErrorDashRow -Lokasyon $Lokasyon -Kabinet $fb.Name -IP $fb.IP -Hata $_.Exception.Message
            continue
        }

        $BaseUrl   = "https://$($fb.IP)/api/2.0"
        $authToken = $null
        $sshOnly   = $fb.SshOnly -eq $true

        try {
            # ---- LOGIN ----
            # SshOnly=true ise REST deneme, direkt plink
            $loginSuccess = $false
            if (-not $sshOnly) {
                $cacheKey  = "PureFB_ApiVer_$($fb.Name)"
                $cachedVer = if ($script:ApiVersionCache) { $script:ApiVersionCache[$cacheKey] } else { $null }
                if (-not $script:ApiVersionCache) { $script:ApiVersionCache = @{} }
                $versionsToTry = @('2.0', '2', '2.4', '2.36')
                if ($cachedVer -and $versionsToTry -contains $cachedVer) {
                    $versionsToTry = @($cachedVer) + ($versionsToTry | Where-Object { $_ -ne $cachedVer })
                }
                foreach ($apiVersion in $versionsToTry) {
                    $tryUrl = "https://$($fb.IP)/api/${apiVersion}"
                    try {
                        try {
                            Invoke-RestMethod -Uri "$tryUrl/logout" -Method Post `
                                -Headers @{ 'api-token'=$apiToken } `
                                -UseBasicParsing -ErrorAction SilentlyContinue -TimeoutSec 10 | Out-Null
                            Start-Sleep -Milliseconds 500
                        } catch { Write-Verbose "[L1882] logout atlandi: $($_.Exception.Message)" }
                        $loginResp = Invoke-WebRequest -Uri "$tryUrl/login" -Method Post `
                            -Headers @{ 'api-token'=$apiToken; 'Content-Type'='application/json' } `
                            -UseBasicParsing -TimeoutSec 15 -ErrorAction Stop
                        $tok = $loginResp.Headers['x-auth-token']
                        if ($tok) {
                            $authToken    = $tok
                            $BaseUrl      = $tryUrl
                            $loginSuccess = $true
                            $script:ApiVersionCache[$cacheKey] = $apiVersion
                            Write-Step "     Login OK (API: $apiVersion$(if($cachedVer -eq $apiVersion){' [cached]'} else {''}))" DarkGray
                            break
                        }
                    } catch { Write-Verbose "[L1895] login atlandi: $($_.Exception.Message)" }
                }
            }

            if (-not $loginSuccess) {
                # SSH / plink ile devam et
                throw "SSH moduna geciliyor"
            }
            $hdr = @{ 'x-auth-token'=$authToken; Accept='application/json' }

            # ---- ARRAY KAPASITESI ----
            $arrResp = Invoke-RestMethod -Uri "$BaseUrl/arrays" -Method Get -Headers $hdr `
                -TimeoutSec 30 -ErrorAction Stop
            $arr = if ($arrResp.items) { $arrResp.items[0] } else { $arrResp }

            $TotalBytes = if ($arr.space.capacity)   { (Parse-Double "$($arr.space.capacity)") }   else { 0 }
            $UsedBytes  = if ($arr.space.used)        { (Parse-Double "$($arr.space.used)") }        else {
                            if ($arr.space.total_used) { (Parse-Double "$($arr.space.total_used)") } else { 0 } }
            $Version    = if ($arr.os)        { $arr.os }        elseif ($arr.version) { $arr.version } else { '-' }

            # Data Reduction
            $DR = if ($arr.space.data_reduction) { [math]::Round((Parse-Double "$($arr.space.data_reduction)"), 2) } else { 1 }
            $DRStr = "${DR}:1"

            $TotalTB = [math]::Round($TotalBytes / $script:TB, 2)
            $UsedTB  = [math]::Round($UsedBytes  / $script:TB, 2)
            $FreeTB  = [math]::Round($TotalTB - $UsedTB, 2)
            $Pct     = if ($TotalTB -gt 0) { [math]::Round($UsedTB / $TotalTB * 100, 2) } else { 0 }

            # Lokasyon toplami
            if (-not $LocTotals.ContainsKey($Lokasyon)) {
                $LocTotals[$Lokasyon] = @{ Total=0; Used=0; Free=0 }
            }
            $LocTotals[$Lokasyon].Total += $TotalTB
            $LocTotals[$Lokasyon].Used  += $UsedTB
            $LocTotals[$Lokasyon].Free  += $FreeTB

            # ---- BUCKET LISTESİ (S3) ----
            Write-Step "     + bucket listesi..." DarkGray
            $bucketCount = 0; $totalBucketTB = 0
            $bkToken = $null
            do {
                $bkUrl = "$BaseUrl/buckets?limit=200&sort=space.virtual-"
                if ($bkToken) { $bkUrl += "&token=$bkToken" }
                $bkResp = Invoke-RestMethod -Uri $bkUrl -Method Get -Headers $hdr `
                    -TimeoutSec 60 -ErrorAction Stop
                if ($bkResp.items) {
                    foreach ($bk in $bkResp.items) {
                        $bucketCount++
                        $virtBytes = if ($bk.space.virtual)   { (Parse-Double "$($bk.space.virtual)") }   else { 0 }
                        $uniqBytes = if ($bk.space.unique)    { (Parse-Double "$($bk.space.unique)") }    else { 0 }
                        $snapBytes = if ($bk.space.snapshots) { (Parse-Double "$($bk.space.snapshots)") } else { 0 }
                        $drRat     = if ($bk.space.data_reduction -and (Parse-Double "$($bk.space.data_reduction)") -gt 0) { [math]::Round((Parse-Double "$($bk.space.data_reduction)"), 2) } else { 1 }
                        $virtTB    = [math]::Round($virtBytes / $script:TB, 4)
                        $uniqTB    = [math]::Round($uniqBytes / $script:TB, 4)
                        $totalBucketTB += $virtTB
                        $objCount  = if ($bk.object_count) { [long]$bk.object_count } else { 0 }

                        # History icin onceki ay snapshot
                        $Rapor_Buckets += [PSCustomObject]@{
                            Lokasyon     = $Lokasyon
                            Kabinet      = $fb.Name
                            Bucket       = $bk.name
                            'Virtual (TB)'  = $virtTB
                            'Unique (TB)'   = $uniqTB
                            'Snapshot (TB)' = [math]::Round($snapBytes / $script:TB, 4)
                            'Data Reduction'= "$drRat`:1"
                            'Object Count'  = $objCount
                            'Account'       = if ($bk.account -and $bk.account.name) { $bk.account.name } else { '' }
                            Versioning      = if ($bk.versioning) { $bk.versioning } else { 'none' }
                            Created         = if ($bk.created) { [DateTimeOffset]::FromUnixTimeMilliseconds([long]$bk.created).ToString('yyyy-MM-dd') } else { '' }
                        }
                    }
                }
                $bkToken = if ($bkResp.continuation_token) { $bkResp.continuation_token } else { $null }
            } while ($bkToken)
            Write-Step "     Bucket: $bucketCount adet / $([math]::Round($totalBucketTB,2)) TB virtual" DarkGray

            # ---- FILE SYSTEM LISTESİ (NFS/SMB) ----
            Write-Step "     + file system listesi..." DarkGray
            $fsCount = 0; $totalFsTB = 0
            try {
                $fsResp = Invoke-RestMethod -Uri "$BaseUrl/file-systems?limit=200" -Method Get `
                    -Headers $hdr -TimeoutSec 30 -ErrorAction SilentlyContinue
                if ($fsResp.items) {
                    foreach ($fs in $fsResp.items) {
                        $fsCount++
                        $fsVirt = if ($fs.space.virtual)  { (Parse-Double "$($fs.space.virtual)") }  else { 0 }
                        $fsUniq = if ($fs.space.unique)   { (Parse-Double "$($fs.space.unique)") }   else { 0 }
                        $fsSize = if ($fs.provisioned)    { (Parse-Double "$($fs.provisioned)") }    else { 0 }
                        $totalFsTB += [math]::Round($fsVirt / $script:TB, 4)
                        $protocols = @()
                        if ($fs.nfs   -and ($fs.nfs.enabled   -or $fs.nfs.v3_enabled   -or $fs.nfs.v4_1_enabled))  { $protocols += 'NFS' }
                        if ($fs.smb   -and $fs.smb.enabled)   { $protocols += 'SMB' }
                        if ($fs.http  -and $fs.http.enabled)  { $protocols += 'HTTP' }
                        $Rapor_FS += [PSCustomObject]@{
                            Lokasyon       = $Lokasyon
                            Kabinet        = $fb.Name
                            'File System'  = $fs.name
                            Protokoller    = $protocols -join '|'
                            'Virtual (TB)' = [math]::Round($fsVirt / $script:TB, 4)
                            'Unique (TB)'  = [math]::Round($fsUniq / $script:TB, 4)
                            'Provisioned (TB)' = [math]::Round($fsSize / $script:TB, 4)
                        }
                    }
                }
            } catch { Write-Step "     ! File system listesi alinamadi" DarkYellow }
            Write-Step "     FileSystem: $fsCount adet / $([math]::Round($totalFsTB,2)) TB" DarkGray

            $OsString = "S3 Bucket: $bucketCount | FileSystem: $fsCount"

            $Rapor_Dash += [PSCustomObject]@{
                Lokasyon=$Lokasyon; Kabinet=$fb.Name; IP=$fb.IP
                'Total (TB)'=$TotalTB; 'Used (TB)'=$UsedTB; 'Subscribed (TB)'=[math]::Round($totalBucketTB+$totalFsTB,2)
                'Free (TB)'=$FreeTB; 'Doluluk (%)'=$Pct
                'Data Reduction'=$DRStr
                'Host Sayisi'=$bucketCount; 'OS Dagilimi'=$OsString
                Versiyon=$Version
            }

            Write-Step "     OK: $TotalTB TB total | $UsedTB TB used ($Pct%) | DR: $DRStr" Green

            # ---- BUCKET REPLIKASYON ----
            # GET /bucket-replica-links  -> replike edilen bucket'lar
            # GET /targets               -> hedef FlashBlade bilgisi
            try {
                Write-Step "     + bucket replikasyon..." DarkGray

                # Hedef array bilgisi
                $targResp = Invoke-RestMethod -Uri "$BaseUrl/targets?limit=50" -Method Get `
                    -Headers $hdr -TimeoutSec 20 -ErrorAction SilentlyContinue
                $targetMap = @{}
                if ($targResp -and $targResp.items) {
                    foreach ($tg in $targResp.items) {
                        $targetMap[$tg.name] = @{
                            Name    = $tg.name
                            Address = if ($tg.address) { $tg.address } else { '' }
                            Status  = if ($tg.status)  { $tg.status  } else { '' }
                        }
                    }
                }

                # Bucket replica links
                $replResp = Invoke-RestMethod -Uri "$BaseUrl/bucket-replica-links?limit=200" -Method Get `
                    -Headers $hdr -TimeoutSec 30 -ErrorAction SilentlyContinue

                if ($replResp -and $replResp.items) {
                    foreach ($rl in $replResp.items) {
                        $localBucket  = if ($rl.local_bucket  -and $rl.local_bucket.name)  { $rl.local_bucket.name  } else { '' }
                        $remoteBucket = if ($rl.remote_bucket -and $rl.remote_bucket.name) { $rl.remote_bucket.name } else { $localBucket }
                        $targetName   = if ($rl.remote_credentials -and $rl.remote_credentials.name) { $rl.remote_credentials.name } else { '' }

                        $tgInfo  = $targetMap[$targetName]
                        $tgAddr  = if ($tgInfo) { $tgInfo.Address } else { '' }

                        $status   = if ($rl.status)      { $rl.status      } else { '' }
                        $lag      = if ($rl.lag)          { $rl.lag         } else { '' }
                        $dirStr   = if ($rl.direction)    { $rl.direction   } else { 'sync' }

                        # Lag: nanosaniye → okunakli
                        $lagStr = if ($lag -match '^\d+$' -and [long]$lag -gt 0) {
                            $lagSec = [math]::Round([long]$lag / 1000000000, 0)
                            if     ($lagSec -ge 3600) { "$([math]::Round($lagSec/3600,1)) saat" }
                            elseif ($lagSec -ge 60)   { "$([math]::Round($lagSec/60,0)) dakika" }
                            else                      { "$lagSec saniye" }
                        } elseif ($lag) { $lag } else { '' }

                        $statusTR = switch ($status.ToLower()) {
                            'replicating'   { 'Replike Ediliyor' }
                            'paused'        { 'Duraklatildi' }
                            'quiescing'     { 'Bekleniyor' }
                            'quiesced'      { 'Bekleniyor' }
                            'unhealthy'     { 'Sagliksiz' }
                            'baselining'    { 'Taban Aliniyor' }
                            default         { $status }
                        }

                        $Rapor_Repl += [PSCustomObject]@{
                            Lokasyon          = $Lokasyon
                            Kabinet           = $fb.Name
                            'Yerel Bucket'    = $localBucket
                            'Uzak Bucket'     = $remoteBucket
                            'Hedef'           = "$targetName$(if($tgAddr){' ('+ $tgAddr +')'})"
                            'Yon'             = $dirStr
                            'Durum'           = $statusTR
                            'Gecikme (Lag)'   = $lagStr
                        }
                    }
                    Write-Step "     Replikasyon: $($replResp.items.Count) bucket link" DarkGray
                } else {
                    Write-Step "     Replikasyon: veri yok" DarkGray
                }
            } catch { Write-Step "     ! Replikasyon bilgisi alinamadi: $($_.Exception.Message)" DarkYellow }

            # Logout
            try {
                Invoke-RestMethod -Uri "$BaseUrl/logout" -Method Post -Headers $hdr `
                    -TimeoutSec 10 -ErrorAction SilentlyContinue | Out-Null
            } catch { Write-Verbose "[L2093] logout atlandi: $($_.Exception.Message)" }

        } catch {
            $errMsg = $_.Exception.Message
            if ($errMsg -ne 'SSH moduna geciliyor') {
                Write-Step "     REST API basarisiz: $errMsg" Yellow
            }

            # ---- PLINK SSH FALLBACK ----
            $plinkPath  = $PlinkPath
            # Credential dosyasindan SSH user ve pass al
            # Setup-Credentials.ps1: PureFB_<Name>.cred -> User=sshuser, Password=sshpass
            $fbSshUser  = $null
            $fbSshPass  = $null
            try {
                $fbCred    = Get-CredFromFile -Type 'PureFB' -Name $fb.Name
                $fbSshUser = if ($fbCred.User -and $fbCred.User -ne '-') { $fbCred.User } else { 'pureuser' }
                $fbSshPass = $fbCred.Password
            } catch {
                Write-Step "     Credential okunamadi: $($_.Exception.Message)" Red
            }

            if ((Test-Path $plinkPath) -and $fbSshPass) {
                Write-Step "     -> plink SSH ($fbSshUser@$($fb.IP))..." DarkYellow

                function Invoke-PlinkFB {
                    param([string]$Cmd, [int]$Timeout = 30)
                    try {
                        $out = & $plinkPath -batch -ssh -l $fbSshUser -pw $fbSshPass -P 22 $fb.IP $Cmd 2>&1
                        return ($out | Where-Object { $_ -notmatch '^(Host|key|WARNING|using|keyboard|End of|Keyboard)' }) -join "`n"
                    } catch { return '' }
                }

                # Array kapasitesi: purearray list --space
                # Format: Name  Capacity  Parity  Data Reduction  Unique  Destroyed  Snapshots  Shared  Total
                $arrRaw  = Invoke-PlinkFB "purearray list --space" 20
                $TotalTB = 0; $UsedTB = 0; $DRStr = '-'
                foreach ($line in ($arrRaw -split "`n")) {
                    $l = $line.Trim()
                    if (-not $l -or $l -match '^Name\s+Capacity|^---|^\s*$') { continue }
                    $parts = $l -split '\s{2,}'
                    # Name  Capacity  Parity  Data Reduction  Unique  Destroyed  Snapshots  Shared  Total
                    # [0]   [1]       [2]     [3]             [4]     [5]        [6]        [7]     [8]
                    if ($parts.Count -ge 5) {
                        # Capacity (index 1)
                        if ($parts[1] -match '^([\d\.]+)(T|TiB|G|GiB)$') {
                            $n = [double]$matches[1]
                            $TotalTB = if ($matches[2] -match 'T') { [math]::Round($n, 2) } else { [math]::Round($n/1024, 2) }
                        }
                        # Total used (index 4 = Unique, ya da index 8 = Total)
                        $usedIdx = if ($parts.Count -ge 9) { 4 } else { $parts.Count - 1 }
                        if ($parts[$usedIdx] -match '^([\d\.]+)(T|TiB|G|GiB)$') {
                            $n = [double]$matches[1]
                            $UsedTB = if ($matches[2] -match 'T') { [math]::Round($n, 2) } else { [math]::Round($n/1024, 2) }
                        }
                        # Data Reduction (index 3) - "1.6 to 1" formatı
                        if ($parts.Count -ge 4 -and $parts[3] -match '^([\d\.]+)\s+to\s+1') {
                            $DRStr = "$($matches[1]):1"
                        }
                    }
                }
                $FreeTB = [math]::Round($TotalTB - $UsedTB, 2)
                $Pct    = if ($TotalTB -gt 0) { [math]::Round($UsedTB / $TotalTB * 100, 2) } else { 0 }

                $Rapor_Dash += [PSCustomObject]@{
                    Lokasyon=$Lokasyon; Kabinet=$fb.Name; IP=$fb.IP
                    'Total (TB)'=$TotalTB; 'Used (TB)'=$UsedTB
                    'Subscribed (TB)'=''; 'Free (TB)'=$FreeTB
                    'Doluluk (%)'=$Pct; 'Data Reduction'=$DRStr
                    'Host Sayisi'=0; 'OS Dagilimi'='-'; Versiyon='(ssh)'
                }

                # LocTotals
                if (-not $LocTotals.ContainsKey($Lokasyon)) { $LocTotals[$Lokasyon] = @{Total=0;Used=0;Free=0} }
                $LocTotals[$Lokasyon].Total += $TotalTB
                $LocTotals[$Lokasyon].Used  += $UsedTB
                $LocTotals[$Lokasyon].Free  += $FreeTB

                # Bucket listesi: purebucket list --space
                # Format: Name  Account  Quota Limit  Available  % Available  Virtual  Data Reduction  Total  Object Count
                # [0]    [1]    [2]       [3]          [4]         [5]          [6]      [7]             [8]
                $bkRaw = Invoke-PlinkFB "purebucket list --space" 60
                $bkCount = 0
                foreach ($line in ($bkRaw -split "`n")) {
                    $l = $line.Trim()
                    if (-not $l -or $l -match '^Name\s+Account|^---|^\s*$') { continue }
                    $parts   = $l -split '\s{2,}'
                    if ($parts.Count -lt 2) { continue }
                    $bkName  = $parts[0].Trim()
                    if ($bkName -match '^-+$' -or $bkName -eq 'Name') { continue }
                    $account = if ($parts.Count -gt 1) { $parts[1].Trim() } else { '' }

                    # Virtual = index 5, Total = index 7
                    $parseSize = {
                        param($s)
                        if ($s -match '^([\d\.]+)(T|TiB|G|GiB|M|K)$') {
                            $n = [double]$matches[1]
                            switch ($matches[2]) {
                                'T'   { [math]::Round($n, 4) }
                                'TiB' { [math]::Round($n, 4) }
                                'G'   { [math]::Round($n / 1024, 4) }
                                'GiB' { [math]::Round($n / 1024, 4) }
                                default { 0 }
                            }
                        } else { 0 }
                    }
                    $virtual = 0; $total = 0; $dr = '-'
                    if ($parts.Count -ge 6)  { $virtual = & $parseSize $parts[5] }
                    if ($parts.Count -ge 8)  { $total   = & $parseSize $parts[7] }
                    if ($virtual -eq 0 -and $total -gt 0) { $virtual = $total }
                    if ($parts.Count -ge 7 -and $parts[6] -match '^([\d\.]+)\s+to\s+1') { $dr = "$($matches[1]):1" }

                    # Obje sayisi: ~23.12M (son kolon)
                    $objCount = 0
                    $lastPart = $parts[$parts.Count - 1]
                    if ($lastPart -match '^~?([\d\.]+)([KMG]?)$') {
                        $n = [double]$matches[1]
                        $m = switch ($matches[2]) { 'K'{1000} 'M'{1000000} 'G'{1000000000} default{1} }
                        $objCount = [long]($n * $m)
                    }

                    $Rapor_Buckets += [PSCustomObject]@{
                        Lokasyon=$Lokasyon; Kabinet=$fb.Name
                        Bucket=$bkName; Account=$account
                        'Virtual (TB)'=$virtual; 'Snapshot (TB)'=0
                        'Object Count'=$objCount; 'Data Reduction'=$dr
                    }
                    $bkCount++
                }

                # Filesystem listesi: purefs list --space
                # Format: Name  Size  Available  % Available  Virtual  Data Reduction  Unique  Snapshots  Total
                # [0]    [1]   [2]    [3]         [4]          [5]      [6]             [7]     [8]
                $fsRaw   = Invoke-PlinkFB "purefs list --space" 30
                $fsCount = 0
                foreach ($line in ($fsRaw -split "`n")) {
                    $l = $line.Trim()
                    if (-not $l -or $l -match '^Name\s+Size|^---|^\s*$') { continue }
                    $parts  = $l -split '\s{2,}'
                    if ($parts.Count -lt 2) { continue }
                    $fsName = $parts[0].Trim()
                    if ($fsName -match '^-+$' -or $fsName -eq 'Name') { continue }

                    # Size (index 1) = tahsis edilen, Virtual (index 4) = kullanılan
                    $parseFS = {
                        param($s)
                        if ($s -match '^([\d\.]+)(T|TiB|G|GiB|M)$') {
                            $n = [double]$matches[1]
                            switch ($matches[2]) {
                                'T'   { [math]::Round($n, 4) }
                                'TiB' { [math]::Round($n, 4) }
                                'G'   { [math]::Round($n / 1024, 4) }
                                'GiB' { [math]::Round($n / 1024, 4) }
                                'M'   { [math]::Round($n / 1024 / 1024, 6) }
                                default { 0 }
                            }
                        } else { 0 }
                    }
                    $fsSz   = if ($parts.Count -ge 2) { & $parseFS $parts[1] } else { 0 }
                    $fsVirt = if ($parts.Count -ge 5) { & $parseFS $parts[4] } else { 0 }
                    # Virtual yoksa Size kullan
                    $fsDisplay = if ($fsVirt -gt 0) { $fsVirt } elseif ($fsSz -gt 0) { $fsSz } else { 0 }

                    $Rapor_FS += [PSCustomObject]@{
                        Lokasyon=$Lokasyon; Kabinet=$fb.Name
                        FileSystem=$fsName; Protocol='NFS/SMB'
                        'Virtual (TB)'=$fsDisplay
                        'Size (TB)'=$fsSz
                        'Snapshot (TB)'=0
                    }
                    $fsCount++
                }

                Write-Step "     SSH OK: $bkCount bucket · $fsCount filesystem · $TotalTB TB" Green

                # Replikasyon: purebucket replica-link list
                try {
                    $replRaw = Invoke-PlinkFB "purebucket replica-link list" 30
                    foreach ($line in ($replRaw -split "`n")) {
                        $l = $line.Trim()
                        if (-not $l -or $l -match '^Local Bucket|^---|^\s*$') { continue }
                        $parts = $l -split '\s{2,}'
                        if ($parts.Count -lt 2) { continue }
                        $localBk  = $parts[0].Trim(); if ($localBk -eq 'Local Bucket') { continue }
                        $remoteBk = if ($parts.Count -gt 1) { $parts[1].Trim() } else { '' }
                        $status   = if ($parts.Count -gt 2) { $parts[2].Trim() } else { '' }
                        $lag      = if ($parts.Count -gt 3) { $parts[3].Trim() } else { '' }
                        $statusTR = switch ($status.ToLower()) {
                            'replicating'  { 'Replike Ediliyor' }
                            'paused'       { 'Duraklatildi' }
                            'unhealthy'    { 'Sagliksiz' }
                            'baselining'   { 'Taban Aliniyor' }
                            default        { $status }
                        }
                        $Rapor_Repl += [PSCustomObject]@{
                            Lokasyon       = $Lokasyon
                            Kabinet        = $fb.Name
                            'Yerel Bucket' = $localBk
                            'Uzak Bucket'  = $remoteBk
                            'Hedef'        = ''
                            'Yon'          = 'outbound'
                            'Durum'        = $statusTR
                            'Gecikme (Lag)'= $lag
                        }
                    }
                    Write-Step "     Replikasyon: $($Rapor_Repl | Where-Object { $_.Kabinet -eq $fb.Name } | Measure-Object | Select-Object -ExpandProperty Count) link" DarkGray
                } catch { Write-Verbose "[L2299] islem atlandi: $($_.Exception.Message)" }

            } else {
                Write-Step "     plink bulunamadi veya SSH sifresi tanimli degil" Red
                $Rapor_Dash += New-ErrorDashRow -Lokasyon $Lokasyon -Kabinet $fb.Name -IP $fb.IP -Hata $_.Exception.Message
            }
        } finally {
            $apiToken=$null; $authToken=$null; [System.GC]::Collect()
        }
    }

    # ---- TOPLAM SATIRLARI (ortak helper) ----
    $Rapor_Dash += Add-LocationTotals -RaporDash $Rapor_Dash -LocTotals $LocTotals

    return @{
        Dashboard    = $Rapor_Dash
        Buckets      = $Rapor_Buckets
        FileSystems  = $Rapor_FS
        Replication  = $Rapor_Repl
    }
}

# ============================================================
# 4e. ECS (DELL EMC ELASTIC CLOUD STORAGE) TARAYICI
# ============================================================
# REST API: https://<node>:4443  (Basic auth -> X-SDS-AUTH-TOKEN)
# SSH plink fallback: svc_bucket list, svc_vdc capacity, svc_replicate summary
# Credential: Credentials\ECS_IST.cred (user=admin/root, password=<sifre>)
# PlinkOnly: $true ise REST API atlanir, dogrudan SSH kullanilir

function Invoke-PlinkEcs {
    param([string]$IP, [string]$User, [string]$Pass, [string]$Cmd, [int]$TimeoutSec = 30)
    try {
        $job = Start-Job -ScriptBlock {
            param($plink,$ip,$user,$pass,$cmd)
            & $plink -batch -ssh $ip -l $user -pw $pass $cmd 2>&1
        } -ArgumentList $PlinkPath,$IP,$User,$Pass,$Cmd
        if (Wait-Job $job -Timeout $TimeoutSec) {
            $out = Receive-Job $job; Remove-Job $job -Force
            return ($out -join "`n")
        }
        Stop-Job $job -ErrorAction SilentlyContinue
        Remove-Job $job -Force -ErrorAction SilentlyContinue
        return '__TIMEOUT__'
    } catch { return "__ERROR__: $($_.Exception.Message)" }
}

function Clear-EcsAnsi {
    param([string]$s)
    # Tum ANSI escape sequence'leri temizle
    $s = $s -replace '\x1B\[[0-9;]*[a-zA-Z]', ''   # ESC[ ... m/J/K
    $s = $s -replace '\x1B\([a-zA-Z]', ''            # ESC( charset
    $s = $s -replace '\x1B[^a-zA-Z]', ''             # diger ESC
    $s = $s -replace '\x1B', ''                       # kalan ESC
    $s = $s -replace '^\s*\[[\d;]+m', ''              # satir basi [93m gibi
    $s = $s -replace '\[[\d;]+m', ''                  # satir ici renk kodlari
    return $s
}

function Parse-EcsPct {
    param([string]$s)
    $clean = (Clear-EcsAnsi $s) -replace '[^0-9\.]',''
    $val = 0; [double]::TryParse($clean.Trim(), [ref]$val) | Out-Null
    return [math]::Round($val, 2)
}

function Parse-EcsBucketLine {
    param([string]$Line)
    $l = (Clear-EcsAnsi $Line).Trim()
    # Baslik ve bos satirlari atla
    # Gercek baslik 2 satira bolunmus:
    #   "                                               Replication  Owner"
    #   "Bucket Name      Namespace            Group        User       # objects  Total object size"
    if (-not $l -or $l -match '^Name\s+Account|^---|^\s*$|^Bucket\s+Name\b|^\s*Replication\b|^\s*Group\b|^\s*User\b|^svc_bucket\b|^Started\b') {
        return $null
    }

    # Gercek format (svc_bucket v1.1.3, svc_tools v2.29.0):
    #   Bucket Name   Namespace            Group      User           # objects   Total object size
    #   CM-PROD       centera_...95314f20  qfb-rg1    cm_prod_ecs    622170540   82788.7065 GiB
    #
    # 2+ bosluk ile ayir; "82788.7065 GiB" boslukla ayri kalir AMA
    # son alan birimle bitisik olabilir veya 2-parcali. Once 2+ ile ayir,
    # son alanin birim icerip icermedigini kontrol et.

    $parts = $l -split '\s{2,}'
    if ($parts.Count -lt 2) {
        $parts = $l -split '\s+'
    }
    if ($parts.Count -lt 2) { return $null }

    # Son alan "82788.7065 GiB" gibi tek-parca olabilir (2+ bosluk yoksa parca icinde)
    # ya da ayri 2 alan olabilir. Once tum satirdan regex ile boyutu ara
    # (bu en saglam yontem):
    $totalGiB = 0
    $virtualGiB = 0
    if ($l -match '([\d\.]+)\s*(TiB|GiB|MiB|KiB|TB|GB|MB|KB|T|G|M)\b') {
        $num  = [double]$matches[1]
        $unit = $matches[2]
        $totalGiB = switch ($unit) {
            'TiB' { $num * 1024 }
            'T'   { $num * 1024 }
            'GiB' { $num }
            'G'   { $num }
            'MiB' { $num / 1024 }
            'M'   { $num / 1024 }
            'KiB' { $num / 1024 / 1024 }
            'TB'  { $num * 1000 * 1000 * 1000 / [math]::Pow(1024,3) }   # TB -> GiB
            'GB'  { $num * 1000 * 1000 * 1000 / [math]::Pow(1024,3) }
            'MB'  { $num * 1000 * 1000 / [math]::Pow(1024,3) }
            'KB'  { $num * 1000 / [math]::Pow(1024,3) }
            default { 0 }
        }
        $virtualGiB = $totalGiB   # -usage'da tek boyut kolonu var
    }

    # Obje sayisi: duz sayi (622170540) veya ~23.12M veya ~0
    $objects = 0
    if ($l -match '\s(\d{4,})\s') {
        # 4+ haneli ayri duran sayi -> obje sayisi (kucuk numerikler yanlislikla yakalanmasin)
        $objects = [long]$matches[1]
    } elseif ($l -match '~([\d\.]+)([KMG]?)\b') {
        $num = [double]$matches[1]
        $mult = switch ($matches[2]) { 'K' {1000} 'M' {1000000} 'G' {1000000000} default {1} }
        $objects = [long]($num * $mult)
    }

    # Kolonlar: [0]=Bucket, [1]=Namespace, [2]=Replication Group, [3]=Owner User
    $bucketName = $parts[0].Trim()
    $namespace  = if ($parts.Count -gt 1) { $parts[1].Trim() } else { '' }
    $repGroup   = if ($parts.Count -gt 2) { $parts[2].Trim() } else { '' }
    $owner      = if ($parts.Count -gt 3) { $parts[3].Trim() } else { '' }

    # Bucket adi sayisal ya da bos olmamali (yanlislikla rakam satiri yakalanmasin)
    if (-not $bucketName -or $bucketName -match '^\d+$' -or $bucketName.Length -lt 2) {
        return $null
    }

    return [PSCustomObject]@{
        Bucket              = $bucketName
        Namespace           = $namespace
        'Replication Group' = $repGroup
        Owner               = $owner
        Objects             = $objects
        'Size (GiB)'        = [math]::Round($totalGiB, 4)
        'Virtual (GiB)'     = [math]::Round($virtualGiB, 4)
    }
}



function Invoke-ECSScan {
    # ECS tamamen plink SSH ile calisir - REST API calismıyor
    param([switch]$PlinkOnlyMode)

    $bucketList = @()
    $connRows   = @()
    $nsCount    = 0
    $totalGiB   = 0; $usedGiB = 0; $freeGiB = 0
    $vdcPct     = 0; $istPct  = 0; $ankPct  = 0
    $repTasks   = 0; $repPending = '-'

    # Credential oku
    $ecsUser = 'admin'; $ecsPass = ''
    try {
        $ecsCred = Get-CredFromFile -Type 'ECS' -Name 'IST'
        $ecsUser = $ecsCred.User
        $ecsPass = $ecsCred.Password
    } catch {
        Write-Step "     [!] ECS_IST.cred bulunamadi. Setup-Credentials.ps1 -Type ECS calistirin." Red
        return @{ Dashboard=@(); Buckets=@(); Connectivity=@(); History=@() }
    }

    $plinkOk = (Test-Path $PlinkPath)
    if (-not $plinkOk) {
        Write-Step "     [!] plink bulunamadi: $PlinkPath" Red
        return @{ Dashboard=@(); Buckets=@(); Connectivity=@(); History=@() }
    }
    if (-not $ecsPass) {
        Write-Step "     [!] ECS sifresi tanimli degil" Red
        return @{ Dashboard=@(); Buckets=@(); Connectivity=@(); History=@() }
    }

    # ---- BUCKET LİSTESİ ----
    # svc_bucket list -usage
    # Format: Bucket Name | Namespace | Replication Group | Owner User | # objects | Total object size | GiB
    Write-Step "     -> svc_bucket list -usage..." DarkGray
    $rawUsage = Invoke-PlinkEcs -IP $EcsIstanbul.ManagementIP -User $ecsUser -Pass $ecsPass `
        -Cmd "svc_bucket list -usage" -TimeoutSec 90
    $rawUsage = Clear-EcsAnsi $rawUsage

    $headerPassed = $false
    foreach ($line in ($rawUsage -split "`n")) {
        $l = $line.Trim()
        # Boş, başlık, separator satırlarını atla
        if (-not $l) { continue }
        if ($l -match '^(svc_bucket|Started|Bucket\s+Name|---+|\s*Replication|\s*Group|\s*User)') { continue }
        # Başlık geçti mi? "Bucket Name" satırı veya "---" sonrası
        if ($l -match '^-{5,}') { $headerPassed = $true; continue }
        if (-not $headerPassed) { continue }

        # Parse: boşlukla ayrılmış kolonlar
        # Bucket Name ve Namespace truncated olabilir (centera_...b2395314f20)
        $parts = $l -split '\s{2,}'
        if ($parts.Count -lt 3) { continue }

        $bkName  = $parts[0].Trim()
        $ns      = $parts[1].Trim()
        $repGrp  = if ($parts.Count -gt 2) { $parts[2].Trim() } else { '' }
        $owner   = if ($parts.Count -gt 3) { $parts[3].Trim() } else { '' }

        # # objects (sayısal)
        $objCount = 0
        if ($parts.Count -gt 4 -and $parts[4] -match '^[\d]+$') {
            $objCount = [long]$parts[4]
        }

        # Total object size: "82788.7065 GiB" → son iki parça
        $sizeGiB = 0
        if ($parts.Count -ge 6) {
            # Son iki: değer + birim (GiB/TiB/MiB)
            $sizeVal  = $parts[$parts.Count - 2]
            $sizeUnit = $parts[$parts.Count - 1]
            if ($sizeVal -match '^[\d\.]+$') {
                $n = [double]$sizeVal
                $sizeGiB = switch ($sizeUnit) {
                    'TiB' { [math]::Round($n * 1024, 4) }
                    'GiB' { [math]::Round($n, 4) }
                    'MiB' { [math]::Round($n / 1024, 4) }
                    default { [math]::Round($n, 4) }
                }
            }
            # Alternatif: "82788.7065 GiB" tek parçada
            if ($sizeGiB -eq 0 -and $parts[$parts.Count-1] -match '^([\d\.]+)\s*(GiB|TiB|MiB)$') {
                $n = [double]$matches[1]
                $sizeGiB = switch ($matches[2]) {
                    'TiB' { [math]::Round($n * 1024, 4) }
                    'GiB' { [math]::Round($n, 4) }
                    'MiB' { [math]::Round($n / 1024, 4) }
                    default { [math]::Round($n, 4) }
                }
            }
        }

        $bucketList += [PSCustomObject]@{
            Bucket              = $bkName
            Namespace           = $ns
            'Replication Group' = $repGrp
            Owner               = $owner
            Objects             = $objCount
            'Size (GiB)'        = $sizeGiB
            'Virtual (GiB)'     = $sizeGiB
        }
    }

    Write-Step "     Bucket: $($bucketList.Count) adet" DarkGray

    # ---- KAPASİTE (svc_vdc capacity) ----
    Write-Step "     -> svc_vdc capacity..." DarkGray
    $vdcRaw = Invoke-PlinkEcs -IP $EcsIstanbul.ManagementIP -User $ecsUser -Pass $ecsPass `
        -Cmd "svc_vdc capacity" -TimeoutSec 30
    $vdcRaw = Clear-EcsAnsi $vdcRaw

    foreach ($line in ($vdcRaw -split "`n")) {
        $l = $line.Trim()
        # Total Capacity
        if ($l -match '(?i)Total\s+Capacity[:\s]+([\d\.]+)\s*(TB|TiB|GB|GiB)') {
            $n = [double]$matches[1]
            $totalGiB = if ($matches[2] -match 'T') { [math]::Round($n * 1024, 2) } else { [math]::Round($n, 2) }
        }
        # Used Capacity / Used
        if ($l -match '(?i)Used\s+Capacity[:\s]+([\d\.]+)\s*(TB|TiB|GB|GiB)' -or
            $l -match '(?i)^\s*Used[:\s]+([\d\.]+)\s*(TB|TiB|GB|GiB)') {
            $n = [double]$matches[1]
            $usedGiB = if ($matches[2] -match 'T') { [math]::Round($n * 1024, 2) } else { [math]::Round($n, 2) }
        }
        # Used Percent
        if ($l -match '(?i)Used\s+Percent[:\s]+([\d\.]+)') {
            $vdcPct = [math]::Round([double]$matches[1], 2)
        }
    }

    # Toplam boyut bucket'lardan hesapla eğer svc_vdc boş geldiyse
    if ($totalGiB -eq 0 -and $bucketList.Count -gt 0) {
        $usedGiB  = [math]::Round(($bucketList | Measure-Object 'Size (GiB)' -Sum).Sum, 2)
        if ($vdcPct -gt 0) {
            $totalGiB = [math]::Round($usedGiB / ($vdcPct / 100), 2)
        }
    }
    $freeGiB = [math]::Round($totalGiB - $usedGiB, 2)
    if ($vdcPct -eq 0 -and $totalGiB -gt 0) { $vdcPct = [math]::Round($usedGiB/$totalGiB*100, 2) }

    # ---- REPLİKASYON ----
    Write-Step "     -> replikasyon..." DarkGray
    $repRaw = Invoke-PlinkEcs -IP $EcsIstanbul.ManagementIP -User $ecsUser -Pass $ecsPass `
        -Cmd "svc_replicate summary" -TimeoutSec 20
    $repRaw = Clear-EcsAnsi $repRaw
    if ($repRaw -match '(?i)Active replication tasks[:\s]+(\d+)') { $repTasks   = [int]$matches[1] }
    if ($repRaw -match '(?i)Pending Data[:\s]+(.+)')              { $repPending = $matches[1].Trim() }

    # ---- BAĞLANTI TESTİ (IST ↔ ANK) ----
    Write-Step "     -> baglanti testi..." DarkGray
    $testPorts = @(9096, 9098)
    foreach ($port in $testPorts) {
        foreach ($direction in @('ist2ank', 'ank2ist')) {
            $srcIP = if ($direction -eq 'ist2ank') { $EcsIstanbul.ManagementIP } else { $EcsAnkara.ManagementIP }
            $dstIP = if ($direction -eq 'ist2ank') { $EcsAnkara.ManagementIP   } else { $EcsIstanbul.ManagementIP }
            try {
                $testCmd  = "timeout 5 bash -c 'echo > /dev/tcp/$dstIP/$port' 2>/dev/null && echo OK || echo FAIL"
                $testRaw  = Invoke-PlinkEcs -IP $srcIP -User $ecsUser -Pass $ecsPass -Cmd $testCmd -TimeoutSec 10
                $testClean= (Clear-EcsAnsi $testRaw).Trim()
                $status   = if ($testClean -match 'OK') { 'Success' } else { 'Failed' }
            } catch { $status = 'Failed' }
            $connRows += [PSCustomObject]@{
                Kaynak = if ($direction -eq 'ist2ank') { 'Istanbul' } else { 'Ankara' }
                Hedef  = if ($direction -eq 'ist2ank') { 'Ankara' }   else { 'Istanbul' }
                Port   = $port; Durum = $status
            }
        }
    }

    $statusIst = if ($connRows | Where-Object { $_.Kaynak -eq 'Istanbul' -and $_.Durum -eq 'Failed' }) { 'Failed' } else { 'Success' }
    $statusAnk = if ($connRows | Where-Object { $_.Kaynak -eq 'Ankara'   -and $_.Durum -eq 'Failed' }) { 'Failed' } else { 'Success' }

    $today   = Get-Date -Format 'yyyy-MM-dd'
    $dashRow = [PSCustomObject]@{
        'Tarih'            = $today
        'Total (GiB)'      = [math]::Round($totalGiB, 2)
        'Used (GiB)'       = [math]::Round($usedGiB, 2)
        'Free (GiB)'       = [math]::Round($freeGiB, 2)
        'Doluluk (%)'      = $vdcPct
        'Istanbul Pct'     = $istPct
        'Ankara Pct'       = $ankPct
        'Bucket Sayisi'    = $bucketList.Count
        'Namespace Sayisi' = $nsCount
        'Rep Tasks'        = $repTasks
        'Rep Pending'      = $repPending
        'Ist->Ank'         = $statusIst
        'Ank->Ist'         = $statusAnk
    }

    Write-Step ("     OK: $([math]::Round($totalGiB/1024,2)) TiB | $($bucketList.Count) bucket | Rep: $repTasks task") Green

    # History guncelle
    $historyFile  = Join-Path $LocalEcs 'ECS_Bucket_History.csv'
    $existingHist = @{}
    if (Test-Path $historyFile) {
        try { Import-Csv $historyFile | ForEach-Object { $existingHist[$_.Bucket] = $_ } } catch { Write-Verbose "[L2653] islem atlandi: $($_.Exception.Message)" }
    }
    $cutoff = (Get-Date).AddDays(-35)
    foreach ($bk in $bucketList) {
        $key = $bk.Bucket
        if ($existingHist.ContainsKey($key)) {
            try {
                if ([datetime]$existingHist[$key].SnapshotDate -gt $cutoff) {
                    $existingHist[$key] = [PSCustomObject]@{
                        Bucket=$key; Namespace=$bk.Namespace
                        'Size (GiB)'=$bk.'Size (GiB)'; SnapshotDate=$today
                    }
                }
            } catch {
                $existingHist[$key] = [PSCustomObject]@{ Bucket=$key; Namespace=$bk.Namespace; 'Size (GiB)'=$bk.'Size (GiB)'; SnapshotDate=$today }
            }
        } else {
            $existingHist[$key] = [PSCustomObject]@{ Bucket=$key; Namespace=$bk.Namespace; 'Size (GiB)'=$bk.'Size (GiB)'; SnapshotDate=$today }
        }
    }

    return @{
        Dashboard    = @($dashRow)
        Buckets      = $bucketList
        Connectivity = $connRows
        History      = @($existingHist.Values)
    }
}

# ============================================================
# 4c. NETAPP ONTAP TARAYICI
# ============================================================
#   /api/cluster          -> cluster bilgisi, ONTAP versiyonu
#   /api/storage/aggregates -> aggregate (fiziksel disk havuzu) kapasitesi
#   /api/storage/volumes  -> SVM volume'lari (provisioned kapasite)
#   /api/svm/svms         -> SVM listesi
#   /api/network/ip/interfaces -> LIF'ler

function Invoke-NetAppScan {
    param([array]$Clusters)

    $Rapor_Dash    = @()
    $Rapor_Vols    = @()
    $Rapor_SVMs    = @()
    $Rapor_Aggs    = @()
    $Rapor_SnapPolicy = @()
    $Rapor_MC      = @()
    $LocTotals     = @{}

    foreach ($cl in $Clusters) {
        $Lokasyon = $cl.Lokasyon
        Write-Step "  -> Baglaniyor: $Lokasyon / $($cl.Name) ($($cl.IP))" Cyan

        $cred = $null
        try {
            $cred = Get-CredFromFile -Type 'NetApp' -Name $cl.Name
        } catch {
            Write-Step "     HATA: $($_.Exception.Message)" Red
            $Rapor_Dash += New-ErrorDashRow -Lokasyon $Lokasyon -Kabinet $cl.Name -IP $cl.IP -Hata $_.Exception.Message
            continue
        }

        $user = $cred.User
        $pass = $cred.Password
        $b64  = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${user}:${pass}"))
        $hdrs = @{ Authorization="Basic $b64"; Accept='application/json' }
        $base = "https://$($cl.IP)/api"

        try {
            # ---- CLUSTER bilgisi ----
            $clInfo = Invoke-RestWithRetry {
                Invoke-RestMethod -Uri "$base/cluster" -Method Get -Headers $hdrs `
                    -TimeoutSec 20 -ErrorAction Stop
            }
            $version = if ($clInfo.version.full) { $clInfo.version.full } else { "$($clInfo.version.generation).$($clInfo.version.major).$($clInfo.version.minor)" }
            # "NetApp ONTAP release 9.16.1P1 ..." → sadece "9.16.1P1" gibi kısa versiyon
            if ($version -match '\b(\d+\.\d+[\.\d\w]*)') { $version = $matches[1] }
            Write-Step "     ONTAP: $version" DarkGray

            # ---- AGGREGATE (fiziksel kapasite) ----
            #   Her aggregate icin ayri satir: NetApp_Aggregate.csv
            #   Toplam Total/Used hesabini da burada toplar; ayrica DR (efficiency.ratio)
            #   ek bir cagri ile alinmaz - tek istekte aggregate basina ratio da gelir.
            $aggResp = Invoke-RestWithRetry {
                Invoke-RestMethod -Uri "$base/storage/aggregates?fields=name,space,node,state,block_storage,space.efficiency.ratio&max_records=200" `
                    -Method Get -Headers $hdrs -TimeoutSec 60 -ErrorAction Stop
            }

            $totalBytes = 0; $usedBytes = 0
            $aggRatios  = @()
            $aggCount   = 0
            if ($aggResp.records) {
                foreach ($agg in $aggResp.records) {
                    $aggState  = if ($agg.state) { [string]$agg.state } else { 'unknown' }
                    $nodeName  = if ($agg.node -and $agg.node.name) { $agg.node.name } else { '-' }
                    $bs        = $agg.space.block_storage
                    $aSize     = if ($bs -and $bs.size) { [long]$bs.size } else { 0 }
                    $aUsed     = if ($bs -and $bs.used) { [long]$bs.used } else { 0 }
                    $aAvail    = if ($bs -and $bs.available) { [long]$bs.available } else { [Math]::Max(0, $aSize - $aUsed) }
                    $aSizeTB   = [math]::Round($aSize  / $script:TB, 2)
                    $aUsedTB   = [math]::Round($aUsed  / $script:TB, 2)
                    $aFreeTB   = [math]::Round($aAvail / $script:TB, 2)
                    $aPct      = if ($aSizeTB -gt 0) { [math]::Round($aUsedTB / $aSizeTB * 100, 2) } else { 0 }

                    # Aggregate tipi (SSD/HDD/Hybrid) - block_storage.primary.disk_class'tan
                    $aType = '-'
                    if ($agg.block_storage -and $agg.block_storage.primary -and $agg.block_storage.primary.disk_class) {
                        $dc = [string]$agg.block_storage.primary.disk_class
                        switch -Wildcard ($dc.ToLower()) {
                            '*ssd*'     { $aType = 'SSD'   }
                            '*nvme*'    { $aType = 'NVMe'  }
                            '*sas*'     { $aType = 'SAS'   }
                            '*sata*'    { $aType = 'SATA'  }
                            '*capacity*'{ $aType = 'HDD'   }
                            '*flash*'   { $aType = 'SSD'   }
                            default     { $aType = $dc     }
                        }
                    }

                    # DR ratio (aggregate basina)
                    $aRatio = $null
                    if ($agg.space -and $agg.space.efficiency -and $agg.space.efficiency.ratio) {
                        $rv = (Parse-Double "$($agg.space.efficiency.ratio)")
                        if ($rv -and $rv -gt 0) { $aRatio = $rv; $aggRatios += $rv }
                    }
                    $aDRStr = if ($aRatio) { ("{0}:1" -f [math]::Round($aRatio, 2)) } else { '-' }

                    $Rapor_Aggs += [PSCustomObject]@{
                        Lokasyon       = $Lokasyon
                        Kabinet        = $cl.Name
                        Aggregate      = if ($agg.name) { $agg.name } else { '-' }
                        Node           = $nodeName
                        Tip            = $aType
                        'Total (TB)'   = $aSizeTB
                        'Used (TB)'    = $aUsedTB
                        'Free (TB)'    = $aFreeTB
                        'Doluluk (%)'  = $aPct
                        'Data Reduction' = $aDRStr
                        State          = $aggState
                    }

                    # Toplam hesaba SADECE online aggregate'leri kat
                    if ($aggState -eq 'online') {
                        $totalBytes += $aSize
                        $usedBytes  += $aUsed
                        $aggCount++
                    }
                }
            }
            $TotalTB = [math]::Round($totalBytes / $script:TB, 2)
            $UsedTB  = [math]::Round($usedBytes  / $script:TB, 2)
            $FreeTB  = [math]::Round($TotalTB - $UsedTB, 2)
            $Pct     = if ($TotalTB -gt 0) { [math]::Round($UsedTB / $TotalTB * 100, 2) } else { 0 }

            # ---- DATA REDUCTION (cluster ortalamasi) ----
            #   Aggregate cagrisinda toplandi (efficiency.ratio) - ek cagri yok
            $DRStr = '-'
            if ($aggRatios.Count -gt 0) {
                $avgDR = [math]::Round(($aggRatios | Measure-Object -Average).Average, 2)
                $DRStr = "${avgDR}:1"
            }

            # ---- VOLUME (subscribed / provisioned) ----
            # Volume toplami = host'lara provisioned kapasite
            $SubsTB = 0; $volCount = 0; $svmSet = @{}
            try {
                $volToken = $null
                do {
                    $volUrl = "$base/storage/volumes?fields=name,svm,space,type,state&max_records=500"
                    if ($volToken) { $volUrl += "&return_records=true&return_timeout=15&token=$volToken" }
                    $volResp = Invoke-RestMethod -Uri $volUrl -Method Get -Headers $hdrs -TimeoutSec 60 -ErrorAction Stop
                    if ($volResp.records) {
                        foreach ($v in $volResp.records) {
                            # root volume'lari atla
                            if ($v.name -match '^vol0$|_root$|^.*_root$') { continue }
                            if ($v.type -eq 'dp') { continue }   # data protection (mirror)
                            if ($v.state -ne 'online') { continue }
                            $vsize = if ($v.space.size) { [long]$v.space.size } else { 0 }
                            $SubsTB += $vsize
                            $volCount++
                            if ($v.svm -and $v.svm.name) { $svmSet[$v.svm.name] = 1 }
                            $Rapor_Vols += [PSCustomObject]@{
                                Lokasyon  = $Lokasyon
                                Kabinet   = $cl.Name
                                SVM       = if ($v.svm.name) { $v.svm.name } else { '' }
                                Volume    = $v.name
                                'Size (TB)' = [math]::Round($vsize / $script:TB, 3)
                                State     = $v.state
                                Type      = $v.type
                            }
                        }
                    }
                    $volToken = if ($volResp.next_link) {
                        $volResp.next_link -replace '^.*token=',''
                    } else { $null }
                } while ($volToken)
            } catch { Write-Step "     ! Volume listesi alinamadi: $($_.Exception.Message)" DarkYellow }

            $SubsTB = [math]::Round($SubsTB / $script:TB, 2)

            # Protokol dağılımı (SVM bazlı: hangi protokol kaç SVM'de aktif)
            $protoCount = @{ NFS=0; CIFS=0; iSCSI=0; FCP=0 }
            $svmCount = 0
            try {
                $svmResp = Invoke-RestMethod -Uri "$base/svm/svms?fields=name,state,cifs.enabled,nfs.enabled,iscsi.enabled,fcp.enabled&max_records=100" `
                    -Method Get -Headers $hdrs -TimeoutSec 60 -ErrorAction SilentlyContinue
                if ($svmResp.records) {
                    $svmCount = @($svmResp.records | Where-Object { $_.subtype -ne 'dp_destination' }).Count
                    foreach ($svm in $svmResp.records) {
                        if ($svm.subtype -eq 'dp_destination') { continue }
                        $protos = @()
                        if ($svm.cifs.enabled)  { $protos += 'CIFS';  $protoCount['CIFS']++  }
                        if ($svm.nfs.enabled)   { $protos += 'NFS';   $protoCount['NFS']++   }
                        if ($svm.iscsi.enabled) { $protos += 'iSCSI'; $protoCount['iSCSI']++ }
                        if ($svm.fcp.enabled)   { $protos += 'FCP';   $protoCount['FCP']++   }
                        $Rapor_SVMs += [PSCustomObject]@{
                            Lokasyon  = $Lokasyon
                            Kabinet   = $cl.Name
                            SVM       = $svm.name
                            State     = $svm.state
                            Protocols = $protos -join ' | '
                        }
                    }
                }
            } catch { Write-Verbose "[L2826] svm atlandi: $($_.Exception.Message)" }

            # OsString: NFS:2 | CIFS:1 gibi (0 olanlar yazılmaz)
            $protoStr = ($protoCount.GetEnumerator() | Where-Object { $_.Value -gt 0 } |
                         Sort-Object Name | ForEach-Object { "$($_.Key): $($_.Value)" }) -join ' | '
            if (-not $protoStr) { $protoStr = "SVM: $svmCount" }
            $OsString = $protoStr
            if (-not $LocTotals.ContainsKey($Lokasyon)) {
                $LocTotals[$Lokasyon] = @{ Total=0; Used=0; Subs=0; Free=0 }
            }
            $LocTotals[$Lokasyon].Total += $TotalTB
            $LocTotals[$Lokasyon].Used  += $UsedTB
            $LocTotals[$Lokasyon].Subs  += $SubsTB
            $LocTotals[$Lokasyon].Free  += $FreeTB

            $Rapor_Dash += [PSCustomObject]@{
                Lokasyon=$Lokasyon; Kabinet=$cl.Name; IP=$cl.IP
                'Total (TB)'=$TotalTB; 'Used (TB)'=$UsedTB; 'Subscribed (TB)'=$SubsTB
                'Free (TB)'=$FreeTB; 'Doluluk (%)'=$Pct
                'Data Reduction'=$DRStr
                'Host Sayisi'=$svmCount; 'OS Dagilimi'=$OsString
                Versiyon=$version
            }

            Write-Step "     OK: $TotalTB TB | DR: $DRStr | SVM: $svmCount | Vol: $volCount | Subs: $SubsTB TB" Green

            # ---- SNAPSHOT POLICY ----
            try {
                Write-Step "     + snapshot policy..." DarkGray

                # 1. Tüm snapshot policy'lerini çek
                $spResp = Invoke-RestMethod `
                    -Uri "$base/storage/snapshot-policies?fields=name,copies,svm&max_records=200" `
                    -Method Get -Headers $hdrs -TimeoutSec 30 -ErrorAction SilentlyContinue

                # Policy detayları: schedule ve retention
                $policyMap = @{}
                if ($spResp -and $spResp.records) {
                    foreach ($sp in $spResp.records) {
                        $policyMap[$sp.name] = $sp
                    }
                }

                # 2. Policy detail'leri al (schedule + retention)
                $spDetailResp = Invoke-RestMethod `
                    -Uri "$base/storage/snapshot-policies?fields=name,copies.schedule,copies.count,svm&max_records=200" `
                    -Method Get -Headers $hdrs -TimeoutSec 30 -ErrorAction SilentlyContinue

                $policyDetails = @{}
                if ($spDetailResp -and $spDetailResp.records) {
                    foreach ($sp in $spDetailResp.records) {
                        if (-not $sp.copies) { continue }
                        $schedParts = @()
                        $retParts   = @()
                        foreach ($copy in @($sp.copies)) {
                            $schName = if ($copy.schedule -and $copy.schedule.name) { $copy.schedule.name } else { '?' }
                            $cnt     = if ($copy.count) { [int]$copy.count } else { 0 }

                            # Schedule adından periyot tahmin et
                            $intStr = switch -Wildcard ($schName.ToLower()) {
                                '*hourly*'  { '1 saat'   }
                                '*daily*'   { '1 gun'    }
                                '*weekly*'  { '1 hafta'  }
                                '*monthly*' { '1 ay'     }
                                '*15min*'   { '15 dakika'}
                                '*5min*'    { '5 dakika' }
                                default     { $schName   }
                            }
                            $schedParts += $intStr
                            $retParts   += "$cnt kopya"
                        }
                        $policyDetails[$sp.name] = @{
                            Periyot = $schedParts -join ' + '
                            Saklama = $retParts   -join ' + '
                        }
                    }
                }

                # 3. Volume'larla eşleştir
                $volPolicyResp = Invoke-RestMethod `
                    -Uri "$base/storage/volumes?fields=name,svm,snapshot_policy&max_records=500" `
                    -Method Get -Headers $hdrs -TimeoutSec 60 -ErrorAction SilentlyContinue

                if ($volPolicyResp -and $volPolicyResp.records) {
                    foreach ($vol in $volPolicyResp.records) {
                        $pName  = if ($vol.snapshot_policy -and $vol.snapshot_policy.name) { $vol.snapshot_policy.name } else { continue }
                        if ($pName -eq 'none') { continue }
                        $svmName = if ($vol.svm -and $vol.svm.name) { $vol.svm.name } else { '' }
                        $detail  = $policyDetails[$pName]

                        $Rapor_SnapPolicy += [PSCustomObject]@{
                            Lokasyon      = $Lokasyon
                            Kabinet       = $cl.Name
                            'Policy Adi'  = $pName
                            'LUN / Obje'  = $vol.name
                            'Host'        = $svmName
                            'Periyot'     = if ($detail) { $detail.Periyot } else { '-' }
                            'Saklama'     = if ($detail) { $detail.Saklama } else { '-' }
                            'Durum'       = 'Aktif'
                            'Tip'         = 'NetApp'
                        }
                    }
                }
                Write-Step "     Snapshot policy: $($Rapor_SnapPolicy.Count) volume-policy eslesme" DarkGray
            } catch { Write-Step "     ! NetApp snapshot policy alinamadi: $($_.Exception.Message)" DarkYellow }

            # ---- METROCLUSTER ----
            try {
                Write-Step "     + MetroCluster kontrol..." DarkGray

                # MC endpoint'i yoksa 404 döner - SilentlyContinue ile sessizce geç
                $mcConf = $null
                try {
                    $mcConf = Invoke-RestMethod `
                        -Uri "$base/cluster/metrocluster?fields=mode,type,configuration_state,partner_cluster_reachable" `
                        -Method Get -Headers $hdrs -TimeoutSec 15 -ErrorAction Stop
                } catch {
                    $errCode = $_.Exception.Response.StatusCode.value__
                    if ($errCode -eq 404 -or $errCode -eq 400) {
                        Write-Step "     MetroCluster: bu cluster'da yapilandirma yok (HTTP $errCode)" DarkGray
                    } else {
                        Write-Step "     MetroCluster: $($_.Exception.Message)" DarkYellow
                    }
                    $mcConf = $null
                }

                if ($mcConf -and $mcConf.mode -and $mcConf.mode -ne 'not_applicable') {
                    $mcModeTR = switch ($mcConf.mode.ToLower()) {
                        'normal'             { 'Normal' }
                        'switchover'         { 'Switchover' }
                        'partial_switchover' { 'Kismi Switchover' }
                        'partial_switchback' { 'Kismi Switchback' }
                        default              { $mcConf.mode }
                    }
                    $mcStateTR  = switch ((Coalesce $mcConf.configuration_state '').ToLower()) {
                        'configured'   { 'Yapilandirilmis' }
                        'partial'      { 'Eksik' }
                        default        { $mcConf.configuration_state }
                    }
                    $partReach = if ($mcConf.partner_cluster_reachable -eq $true) { 'Ulasilabilir' }
                                 elseif ($mcConf.partner_cluster_reachable -eq $false) { 'Ulasilamaz' }
                                 else { '' }

                    # MC node'ları
                    try {
                        $mcNodes = Invoke-RestMethod `
                            -Uri "$base/cluster/metrocluster/nodes?fields=node,configuration_state,dr_group_id,dr_partner,ha_partner,partner_cluster" `
                            -Method Get -Headers $hdrs -TimeoutSec 15 -ErrorAction Stop
                        if ($mcNodes -and $mcNodes.records) {
                            foreach ($nd in $mcNodes.records) {
                                $nodeStateTR = switch ((Coalesce $nd.configuration_state '').ToLower()) {
                                    'configured' { 'Normal' }
                                    'partial'    { 'Eksik' }
                                    default      { $nd.configuration_state }
                                }
                                $Rapor_MC += [PSCustomObject]@{
                                    Lokasyon=$Lokasyon; Kabinet=$cl.Name
                                    'MC Modu'=$mcModeTR; 'MC Tipi'=(Coalesce $mcConf.type '')
                                    'MC Durumu'=$mcStateTR; 'Partner Erisim'=$partReach
                                    'Node'=(Coalesce (Get-Prop $nd 'node.name') ''); 'Node Durumu'=$nodeStateTR
                                    'DR Group'=(Coalesce $nd.dr_group_id ''); 'DR Partner'=(Coalesce (Get-Prop $nd 'dr_partner.name') '')
                                    'HA Partner'=(Coalesce (Get-Prop $nd 'ha_partner.name') ''); 'Partner Cluster'=(Coalesce (Get-Prop $nd 'partner_cluster.name') '')
                                    'Tip'='Node'; 'Volume'=''
                                }
                            }
                        }
                    } catch { Write-Verbose "[L2990] cluster atlandi: $($_.Exception.Message)" }

                    # Replication relationships
                    try {
                        $replRel = Invoke-RestMethod `
                            -Uri "$base/replication/relationships?fields=source,destination,state,healthy,lag_time&max_records=300" `
                            -Method Get -Headers $hdrs -TimeoutSec 20 -ErrorAction Stop
                        if ($replRel -and $replRel.records) {
                            foreach ($rel in $replRel.records) {
                                $srcPath  = Coalesce (Get-Prop $rel 'source.path') ''
                                $dstPath  = Coalesce (Get-Prop $rel 'destination.path') ''
                                $relState = Coalesce $rel.state ''
                                $healthy  = if ($rel.healthy -eq $true) { 'Saglikli' } elseif ($rel.healthy -eq $false) { 'Sagliksiz' } else { '' }

                                # Lag ISO8601: PT5M30S
                                $lagStr = ''
                                if ($rel.lag_time -match 'PT(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?') {
                                    $h = [int](Coalesce $matches[1] 0); $m = [int](Coalesce $matches[2] 0); $s = [int](Coalesce $matches[3] 0)
                                    $parts2 = @()
                                    if ($h -gt 0) { $parts2 += "$h saat" }
                                    if ($m -gt 0) { $parts2 += "$m dakika" }
                                    if ($s -gt 0 -and $h -eq 0) { $parts2 += "$s saniye" }
                                    $lagStr = $parts2 -join ' '
                                }

                                $stateTR = switch ($relState.ToLower()) {
                                    'snapmirrored'  { 'Mirrorlandi' }
                                    'in-sync'       { 'Eslesik' }
                                    'out-of-sync'   { 'Eslesik Degil' }
                                    'broken-off'    { 'Kesildi' }
                                    'uninitialized' { 'Baslatilmamis' }
                                    'synchronizing' { 'Eslesleniyor' }
                                    default         { $relState }
                                }
                                $Rapor_MC += [PSCustomObject]@{
                                    Lokasyon=$Lokasyon; Kabinet=$cl.Name
                                    'MC Modu'=''; 'MC Tipi'=''; 'MC Durumu'=$stateTR; 'Partner Erisim'=$healthy
                                    'Node'=$srcPath; 'Node Durumu'=$dstPath; 'DR Group'=$lagStr
                                    'DR Partner'=''; 'HA Partner'=''; 'Partner Cluster'=''
                                    'Tip'='Replication'; 'Volume'=''
                                }
                            }
                        }
                    } catch { Write-Verbose "[L3033] islem atlandi: $($_.Exception.Message)" }

                    Write-Step "     MetroCluster: $mcModeTR | $($Rapor_MC.Count) kayit" DarkGray
                } else {
                    Write-Step "     MetroCluster: yapilandirma yok veya gecerli degil" DarkGray
                }
            } catch { Write-Step "     ! MetroCluster alinamadi: $($_.Exception.Message)" DarkYellow }

        } catch {
            Write-Step "     HATA: $($_.Exception.Message)" Red
            $Rapor_Dash += New-ErrorDashRow -Lokasyon $Lokasyon -Kabinet $cl.Name -IP $cl.IP -Hata $_.Exception.Message
        } finally {
            $pass = $null; $b64 = $null; [System.GC]::Collect()
        }
    }

    # ---- TOPLAM SATIRLARI (ortak helper) ----
    $Rapor_Dash += Add-LocationTotals -RaporDash $Rapor_Dash -LocTotals $LocTotals

    return @{
        Dashboard  = $Rapor_Dash
        Volumes    = $Rapor_Vols
        SVMs       = $Rapor_SVMs
        Aggregates = $Rapor_Aggs
        SnapPolicy = $Rapor_SnapPolicy
        MetroCluster = $Rapor_MC
    }
}

# ============================================================
# 5. SAN YARDIMCI FONKSIYONLAR
# ============================================================

function Get-BrocadeModel($SwitchType) {
    $t = 0
    if ([int]::TryParse([string]$SwitchType, [ref]$t)) {
        switch ($t) {
            180 { return 'Brocade X7-8' }
            181 { return 'Brocade G720' }
            179 { return 'Brocade X7-4' }
            165 { return 'Brocade X6-4' }
            166 { return 'Brocade X6-8' }
            178 { return 'Brocade G620' }
            162 { return 'Brocade G610' }
            170 { return 'Brocade G630' }
        }
    }
    return "Unknown ($SwitchType)"
}

function Invoke-BrocadeCmd {
    param([string]$IP,[string]$User,[string]$Pass,[string]$Cmd,[int]$TimeoutSec=20)
    $job = Start-Job -ScriptBlock {
        param($plink,$ip,$user,$pass,$cmd)
        & $plink -batch -ssh $ip -l $user -pw $pass $cmd 2>&1
    } -ArgumentList $PlinkPath,$IP,$User,$Pass,$Cmd
    if (Wait-Job $job -Timeout $TimeoutSec) {
        $out = Receive-Job $job; Remove-Job $job -Force; return $out
    } else {
        Stop-Job $job -ErrorAction SilentlyContinue
        Remove-Job $job -Force -ErrorAction SilentlyContinue
        return @('__TIMEOUT__')
    }
}

function Parse-SwitchShow {
    param($Lines)
    $ports = @()
    if (-not $Lines) { return $ports }
    $inPortSection = $false
    foreach ($line in $Lines) {
        $l = "$line"
        if (-not $l) { continue }
        if ($l -match '^\s*Index\s+Port\s+Address' -or $l -match '^\s*Index\s+Slot\s+Port') {
            $inPortSection = $true; continue
        }
        if (-not $inPortSection) { continue }
        if ($l -match '^\s*(\d+)\s+(\d+)\s+(?:(\d+)\s+)?([0-9a-f]{6})\s+\S+\s+(\S+)\s+(\S+)\s*(.*)$') {
            $idx   = [int]$matches[1]
            $slot  = $matches[2]
            $port  = if ($matches[3]) { $matches[3] } else { $matches[2] }
            $speed = $matches[5]
            $state = $matches[6]
            $rest  = ($matches[7]).Trim()
            $spdNorm = switch -Regex ($speed) {
                'N?8'   { '8G';   break } 'N?16' { '16G'; break }
                'N?32'  { '32G';  break } 'N?64' { '64G'; break }
                'N?128' { '128G'; break } 'AN'   { 'AUTO';break } default { '-' }
            }
            $role = 'Free'
            $wwn  = $null

            # Tum satirda E-Port ara (Director'larda $rest bos veya farkli olabilir)
            if ($l -match '\bE-Port\b' -or $l -match '\bEX-Port\b' -or
                $l -match '\bVE-Port\b' -or $l -match '\bME-Port\b' -or
                $l -match '\bLE\b' -or $l -match '\bICL\b') {
                $role = 'ISL'
            }
            elseif ($l -match '\bF-Port\b' -or $l -match '\bFL-Port\b' -or $l -match '\bNF-Port\b') {
                $role = 'Host/Storage'
            }
            elseif ($state -match '^No_' -or $state -match '^In_Sync' -or $state -eq 'Disabled') {
                $role = 'Free'
            }
            # Fallback: Online + tırnak icinde switch adi var = E-Port
            elseif ($state -eq 'Online' -and $l -match '"[^"]+"') {
                $role = 'ISL'
            }
            if ($l -match '(([0-9a-fA-F]{2}:){7}[0-9a-fA-F]{2})') { $wwn = $matches[1].ToLower() }
            $ports += [PSCustomObject]@{ Index=$idx; Slot=$slot; Port=$port; SpeedRaw=$speed; Speed=$spdNorm; State=$state; Role=$role; PortWWN=$wwn; Rest=$rest }
        }
    }
    return $ports
}

function Parse-NsShow {
    param($Lines)
    $hosts = @(); if (-not $Lines) { return $hosts }
    $current = $null
    foreach ($line in $Lines) {
        $l = "$line"
        if (-not $l) { continue }
        if ($l -match '^\s*N\s+([0-9a-fA-F]{6});\s*[\d,]+\s*;\s*([0-9a-fA-F:]{23})\s*;\s*([0-9a-fA-F:]{23})') {
            if ($current) { $hosts += $current }
            $current = [PSCustomObject]@{ Pid=$matches[1].ToLower(); PortWWN=$matches[2].ToLower(); NodeWWN=$matches[3].ToLower(); Symbolic=''; NodeSymb=''; FabricPort='' }
        }
        elseif ($current -and $l -match 'PortSymb:\s*\[(\d+)\]\s*"?(.*?)"?\s*$') { $current.Symbolic = $matches[2] }
        elseif ($current -and $l -match 'NodeSymb:\s*\[(\d+)\]\s*"?(.*?)"?\s*$') { $current.NodeSymb = $matches[2] }
        elseif ($current -and $l -match 'Fabric Port Name:\s+([0-9a-fA-F:]{23})') { $current.FabricPort = $matches[1].ToLower() }
    }
    if ($current) { $hosts += $current }
    return $hosts
}

function Parse-PortErrShow {
    param($Lines)
    $result = @{}; if (-not $Lines) { return $result }
    foreach ($line in $Lines) {
        $l = "$line"
        if ($l -match '^\s*(\d+):\s+([\w\.]+)\s+([\w\.]+)\s+([\w\.]+)\s+([\w\.]+)') {
            $idx = [int]$matches[1]
            $discC3 = 0
            if ($l -match '^\s*\d+:\s+\S+\s+\S+\s+\S+\s+\S+\s+\S+\s+\S+\s+\S+\s+\S+\s+\S+\s+(\S+)') { $discC3 = $matches[1] }
            $result[$idx] = [PSCustomObject]@{ EncOut=$matches[4]; CRC=$matches[5]; DiscC3=$discC3 }
        }
    }
    return $result
}

# Brocade cfgshow ciktisindan aktif cfg adini parse et
# Format: ...
#   Effective configuration:
#    cfg:    CFG_NAME
#    zone:   zone1
#           member1
function Parse-ActiveCfg {
    param($Lines)
    if (-not $Lines) { return '' }

    $inEffective = $false
    foreach ($line in $Lines) {
        $l = "$line"
        if ($l -match '^Effective configuration:') {
            $inEffective = $true
            continue
        }
        if ($inEffective) {
            if ($l -match '^\s*cfg:\s*(\S+)') { return $matches[1].Trim() }
        }
    }
    foreach ($line in $Lines) {
        $l = "$line"
        if ($l -match '^\s*cfg:\s*(\S+)') { return $matches[1].Trim() }
    }
    return ''
}

function Parse-ZoneMembers {
    # cfgshow ciktisindaki zone'lari ve WWN uyelerini parse eder
    param($Lines)
    if (-not $Lines) { return @{} }

    $zones = @{}
    $currentZone = $null
    $inEffective = $false

    foreach ($rawLine in $Lines) {
        $l = "$rawLine"

        # Effective Configuration bolumu icindeyiz mi?
        if ($l -match '^Effective configuration:') { $inEffective = $true; continue }
        if ($l -match '^Defined configuration:')   { $inEffective = $false }
        if (-not $inEffective) { continue }

        # Zone satiri: "  zone: ZONE_NAME" veya "zone:ZONE_NAME"
        if ($l -match '^\s+zone:\s*(\S+)') {
            $currentZone = $matches[1].Trim()
            if (-not $zones.ContainsKey($currentZone)) { $zones[$currentZone] = @() }
            continue
        }
        # Alias satiri - atla (alias icerigi ayri)
        if ($l -match '^\s+alias:') { $currentZone = $null; continue }
        # cfg satiri - atla
        if ($l -match '^\s+cfg:') { $currentZone = $null; continue }

        # Uye satiri: girintili, noktalı virgülle ayrilmis WWN/alias listesi
        if ($currentZone -and $l -match '^\s+\S') {
            # Satiri temizle, birden fazla uye olabilir (.; ile ayrilmis)
            $parts = $l.Trim() -split '\s*;\s*' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
            foreach ($part in $parts) {
                if ($part -ne '') { $zones[$currentZone] += $part }
            }
        }
    }
    return $zones
}

function Get-CleanAlias {
    param([string]$raw, [string]$nodeSymb)
    if (-not $raw) {
        if ($nodeSymb -and $nodeSymb.Length -gt 0 -and $nodeSymb.Length -lt 40) { return $nodeSymb }
        return ''
    }
    if ($raw.Length -gt 50 -and $raw -match '::') {
        $parts    = $raw -split '::'
        $vendor   = if ($parts.Count -ge 1) { $parts[0].Trim() } else { '' }
        $arraySn  = if ($parts.Count -ge 2) { $parts[1].Trim() } else { '' }
        $portLbl  = if ($parts.Count -ge 3) { $parts[2].Trim() } else { '' }
        $vendorShort = switch -Regex ($vendor.ToUpper()) {
            'SYMMETRIX|EMC' { 'EMC' } 'HUAWEI|OCEANSTOR|DORADO' { 'HW' }
            'NETAPP' { 'NTF' } 'HITACHI|HDS' { 'HIT' }
            default { if ($vendor.Length -le 4) { $vendor } else { $vendor.Substring(0,4) } }
        }
        $snShort = if ($arraySn.Length -gt 6) { $arraySn.Substring($arraySn.Length-6) } else { $arraySn }
        if ($arraySn -and $portLbl) { return "$vendorShort-$snShort $portLbl" }
        elseif ($arraySn)           { return "$vendorShort-$arraySn" }
        else                        { return $vendor }
    }
    return $raw.Trim()
}

$StorageOuiPatterns = @(
    '^50:00:09:7', '^50:06:0b:', '^58:00:', '^50:0a:09:',
    '^50:06:0e:', '^50:05:07:', '^52:4a:93:', '^50:02:ac:',
    '^50:00:d3:', '^21:00:00:24:ff'
)

function Test-IsStorageWwn {
    param([string]$wwn)
    if (-not $wwn) { return $false }
    foreach ($pat in $StorageOuiPatterns) { if ($wwn -match $pat) { return $true } }
    return $false
}

# ============================================================
# 5b. INVOKE-SANSCAN
# ============================================================

function Invoke-SANScan {
    param([array]$Switches, [int]$TimeoutSec = 20)

    if (-not (Test-Path $PlinkPath)) {
        Write-Step "[!] plink bulunamadi: $PlinkPath - SAN tarama atlandi" Red
        return $null
    }

    $DashboardRows = @()
    $PortRows      = @()
    $FabricHosts   = @()
    $ZoneAuditRows = @()
    $swCounter = 0

    foreach ($sw in $Switches) {
        $swCounter++

        $swName     = $sw['Name']
        $swIp       = $sw['IP']
        $swLokasyon = $sw['Lokasyon']
        $swFabric   = $sw['Fabric']

        if (-not $swName) {
            Write-Step "  [!] Switch ${swCounter}: Name bos, atlaniyor" Red
            continue
        }

        Write-Step ""
        Write-Step "  [$swCounter/$($Switches.Count)] $swName ($swIp) - $swLokasyon/Fab$swFabric" Yellow

        $credPath = Join-Path $CredDir "SAN_${swName}.cred"
        if (-not (Test-Path $credPath)) {
            Write-Step "     [!] Credential yok: SAN_$($swName).cred - atlandi" Red
            $DashboardRows += [PSCustomObject]@{
                Lokasyon=$swLokasyon; Fabric=$swFabric; SwitchName=$swName; IP=$swIp
                Status='NO_CRED'; Model='-'; Firmware='-'
                TotalPorts=0; OnlinePorts=0; FreePorts=0
                HostPorts=0; StoragePorts=0; ISLPorts=0
                Speed8G=0; Speed16G=0; Speed32G=0; Speed64G=0
                ErrorPorts=0; Uptime='-'; ActiveCfg=''
            }
            continue
        }

        $cred = Get-CredFromFile -FilePath $credPath
        $user = $cred.User
        $pass = $cred.Password

        # switchshow
        Write-Step "     -> switchshow..." DarkGray
        $ssLines = Invoke-BrocadeCmd -IP $swIp -User $user -Pass $pass -Cmd 'switchshow' -TimeoutSec $TimeoutSec
        if ($ssLines -contains '__TIMEOUT__' -or ($ssLines -match 'denied|refused|connection|unable')) {
            Write-Step "     [!] Baglanti hatasi - atlandi" Red
            $pass = $null; [System.GC]::Collect()
            $DashboardRows += [PSCustomObject]@{
                Lokasyon=$swLokasyon; Fabric=$swFabric; SwitchName=$swName; IP=$swIp
                Status='UNREACHABLE'; Model='-'; Firmware='-'
                TotalPorts=0; OnlinePorts=0; FreePorts=0
                HostPorts=0; StoragePorts=0; ISLPorts=0
                Speed8G=0; Speed16G=0; Speed32G=0; Speed64G=0
                ErrorPorts=0; Uptime='-'; ActiveCfg=''
            }
            continue
        }

        # islshow - ISL portlarini ek olarak tespit et (E-Port satirini Parse-SwitchShow yakalayamazsa)
        $islPortSet = @{}
        try {
            Write-Step "     -> islshow..." DarkGray
            $islLines = Invoke-BrocadeCmd -IP $swIp -User $user -Pass $pass -Cmd 'islshow' -TimeoutSec 20
            if ($islLines -and $islLines -ne '__TIMEOUT__') {
                foreach ($il in $islLines) {
                    $il2 = "$il".Trim()
                    if (-not $il2) { continue }
                    # Brocade X7-8 Director islshow formatlari:
                    # "  1:  0-> 0(10:00:...)  50N  2.50G  Online  L-Port"  → local port = 0 (2. sayi)
                    # "  1: 22->000 10:00:..."                               → local port = 22
                    # "  1->000 23 10:00:..."                                → local port = 23

                    # Format 1: "N: LOCAL->REMOTE(..." veya "N: LOCAL->REMOTE WWN..."
                    if ($il2 -match '^\d+:\s+(\d+)\s*->') {
                        $localPort = [int]$matches[1]
                        $islPortSet[$localPort] = $true
                    }
                    # Format 2: "N->REMOTE LOCAL ..."
                    elseif ($il2 -match '^\d+->\d+\s+(\d+)') {
                        $islPortSet[[int]$matches[1]] = $true
                    }
                    # Format 3: sadece port numarasi ile baslayan ("  22  ...")
                    elseif ($il2 -match '^(\d+)\s+\d+\s+->\s+\d+') {
                        $islPortSet[[int]$matches[1]] = $true
                    }
                }
                if ($islPortSet.Count -gt 0) {
                    Write-Step "     islshow: $($islPortSet.Count) ISL port tespit edildi (indexler: $($islPortSet.Keys -join ', '))" DarkGray
                }
            }
        } catch { Write-Verbose "[L3409] islem atlandi: $($_.Exception.Message)" }

        # Model
        $modelType = ''
        foreach ($ln in $ssLines) { if ("$ln" -match 'switchType:\s*([\d\.]+)') { $modelType = ($matches[1] -split '\.')[0]; break } }
        $model = Get-BrocadeModel $modelType

        # FOS version
        $verLines = Invoke-BrocadeCmd -IP $swIp -User $user -Pass $pass -Cmd 'version' -TimeoutSec $TimeoutSec
        $firmware = 'unknown'
        foreach ($ln in $verLines) { if ("$ln" -match 'Fabric OS:\s*v?(\S+)') { $firmware = $matches[1]; break } }

        # Uptime
        $chLines = Invoke-BrocadeCmd -IP $swIp -User $user -Pass $pass -Cmd 'uptime' -TimeoutSec $TimeoutSec
        $uptime = '-'
        foreach ($ln in $chLines) { if ("$ln" -match 'up\s+(.+?),\s+\d+\s+user') { $uptime = $matches[1].Trim(); break } }

        # cfgshow - Effective configuration sonrasi ilk cfg: adi + zone uyeleri
        Write-Step "     -> cfgshow..." DarkGray
        $cfgLines = Invoke-BrocadeCmd -IP $swIp -User $user -Pass $pass -Cmd 'cfgshow' -TimeoutSec $TimeoutSec
        $activeCfg  = Parse-ActiveCfg    -Lines $cfgLines
        $zoneMap    = Parse-ZoneMembers  -Lines $cfgLines   # zone -> [wwn/alias listesi]

        # Hala bos ise cfgactvshow dene
        if (-not $activeCfg) {
            $cfgActLines = Invoke-BrocadeCmd -IP $swIp -User $user -Pass $pass -Cmd 'cfgactvshow' -TimeoutSec $TimeoutSec
            $activeCfg = Parse-ActiveCfg   -Lines $cfgActLines
            if ($zoneMap.Count -eq 0) { $zoneMap = Parse-ZoneMembers -Lines $cfgActLines }
        }

        if ($activeCfg) { Write-Step "     ActiveCfg: $activeCfg ($($zoneMap.Count) zone)" DarkGray }
        else             { Write-Step "     ActiveCfg: bulunamadi" DarkYellow }

        # Port parse
        $ports = Parse-SwitchShow -Lines $ssLines

        # nsshow
        Write-Step "     -> nsshow..." DarkGray
        $nsLines = Invoke-BrocadeCmd -IP $swIp -User $user -Pass $pass -Cmd 'nsshow' -TimeoutSec $TimeoutSec
        $nsHosts = Parse-NsShow -Lines $nsLines

        # porterrshow
        Write-Step "     -> porterrshow..." DarkGray
        $errLines = Invoke-BrocadeCmd -IP $swIp -User $user -Pass $pass -Cmd 'porterrshow' -TimeoutSec $TimeoutSec
        $errMap = Parse-PortErrShow -Lines $errLines

        # sfpshow - modval (alarm) tespiti icin
        Write-Step "     -> sfpshow..." DarkGray
        $sfpLines = Invoke-BrocadeCmd -IP $swIp -User $user -Pass $pass -Cmd 'sfpshow' -TimeoutSec $TimeoutSec
        $sfpAlarmPorts = @{}   # portIndex -> 'alarm' | 'warning'
        if ($sfpLines -and $sfpLines -ne '__TIMEOUT__') {
            $currentPort = -1
            foreach ($sl in $sfpLines) {
                $sl2 = "$sl"
                # Port numarasi satiri: "port  0:"  veya  "Port:  0"
                if ($sl2 -match '^\s*[Pp]ort[:\s]+(\d+)') { $currentPort = [int]$matches[1] }
                # modval/alarm tespiti
                if ($currentPort -ge 0) {
                    if ($sl2 -match '(?i)modval|module.*alarm|alarm.*module') {
                        $sfpAlarmPorts[$currentPort] = 'alarm'
                    } elseif ($sl2 -match '(?i)warning|warn') {
                        if (-not $sfpAlarmPorts.ContainsKey($currentPort)) {
                            $sfpAlarmPorts[$currentPort] = 'warning'
                        }
                    }
                }
            }
        }

        $pass = $null; [System.GC]::Collect()

        # nsshow map
        $wwnToAlias    = @{}
        $wwnToNodeSymb = @{}
        foreach ($nh in $nsHosts) {
            if ($nh.PortWWN) { $wwnToAlias[$nh.PortWWN] = $nh.Symbolic; $wwnToNodeSymb[$nh.PortWWN] = $nh.NodeSymb }
        }

        # Sayaçlar
        $online=0; $free=0; $hostCount=0; $storage=0; $isl=0
        $s8=0; $s16=0; $s32=0; $s64=0; $errPorts=0

        foreach ($p in $ports) {
            if ($p.State -eq 'Online') { $online++ } else { $free++ }
            if ($p.State -eq 'Online') {
                switch ($p.Speed) { '8G'{$s8++} '16G'{$s16++} '32G'{$s32++} '64G'{$s64++} }
            }

            $rawAlias  = if ($p.PortWWN) { $wwnToAlias[$p.PortWWN] }    else { $null }
            $nodeSymb  = if ($p.PortWWN) { $wwnToNodeSymb[$p.PortWWN] } else { $null }
            $cleanAls  = Get-CleanAlias -raw $rawAlias -nodeSymb $nodeSymb

            $finalRole = $p.Role
            # islshow'dan gelen liste varsa, ISL override (Parse-SwitchShow yakalayamamis olabilir)
            if ($islPortSet.ContainsKey($p.Index)) {
                $finalRole = 'ISL'
            }
            elseif ($p.Role -eq 'Host/Storage') {
                if ($p.PortWWN -and (Test-IsStorageWwn -wwn $p.PortWWN)) {
                    $finalRole = 'Storage'
                } elseif ($rawAlias -and $rawAlias -match '(?i)SYMMETRIX|DORADO|OCEANSTOR|VMAX|PMAX|NETAPP|HITACHI|PURE|3PAR|UNITY|STORWIZE|IBM|EMC|HDS') {
                    $finalRole = 'Storage'
                } else {
                    $finalRole = 'Host'
                }
            } elseif ($p.Role -eq 'Free' -and $p.State -eq 'Online' -and $p.PortWWN) {
                if (Test-IsStorageWwn -wwn $p.PortWWN) { $finalRole = 'Storage' }
                else { $finalRole = 'Host' }
            }

            if ($p.State -eq 'Online') {
                switch ($finalRole) { 'Host'{$hostCount++} 'Storage'{$storage++} 'ISL'{$isl++} }
            }

            $portErr = $errMap[$p.Index]
            $encOut  = if ($portErr) { $portErr.EncOut } else { '0' }
            $crc     = if ($portErr) { $portErr.CRC }    else { '0' }
            $discC3  = if ($portErr) { $portErr.DiscC3 } else { '0' }
            $sfpStatus = if ($sfpAlarmPorts.ContainsKey($p.Index)) { $sfpAlarmPorts[$p.Index] } else { '' }

            # DiscC3 alarm seviyesi: 75+ = alarm, 1-74 = warning
            $discC3Num = 0
            [long]::TryParse("$discC3", [ref]$discC3Num) | Out-Null
            $discC3Level = if ($discC3Num -ge 75) { 'alarm' } elseif ($discC3Num -ge 1) { 'warning' } else { '' }

            $hasErr = ($encOut -match '^[1-9]') -or ($crc -match '^[1-9]') -or ($discC3Num -ge 1) -or ($sfpStatus -eq 'alarm')
            if ($hasErr) { $errPorts++ }

            $PortRows += [PSCustomObject]@{
                Lokasyon=$swLokasyon; Fabric=$swFabric; SwitchName=$swName
                PortIndex=$p.Index; Slot=$p.Slot; Port=$p.Port
                Speed=$p.Speed; State=$p.State; Role=$finalRole
                PortWWN=$p.PortWWN; Alias=$cleanAls
                EncOut=$encOut; CRC=$crc; DiscC3=$discC3
                DiscC3Level=$discC3Level; SFP=$sfpStatus
            }

            if ($finalRole -eq 'Host' -and $p.PortWWN) {
                $FabricHosts += [PSCustomObject]@{
                    Lokasyon=$swLokasyon; Fabric=$swFabric; SwitchName=$swName
                    PortIndex=$p.Index; PortWWN=$p.PortWWN; Alias=$cleanAls
                    State=$p.State; Speed=$p.Speed
                }
            }
        }

        $total = $ports.Count
        Write-Step ("     OK  $total port  ON:$online  Host:$hostCount Storage:$storage ISL:$isl  " +
                    "8G:$s8 16G:$s16 32G:$s32 64G:$s64  Err:$errPorts") Green

        # ---- ZONE AUDIT ----
        # Fabric'te gorunen host WWN'lerini topla
        $fabricWwns = @{}   # wwn -> alias
        foreach ($nh in $nsHosts) {
            if ($nh.PortWWN) {
                $alias = if ($wwnToAlias[$nh.PortWWN]) { $wwnToAlias[$nh.PortWWN] } else { '' }
                $fabricWwns[$nh.PortWWN] = $alias
            }
        }

        if ($zoneMap.Count -gt 0 -and $fabricWwns.Count -gt 0) {
            # Zone'larda tanimlanan tum WWN'leri topla
            $zoneWwns = @{}   # wwn -> zone adlari listesi
            foreach ($zoneName in $zoneMap.Keys) {
                foreach ($member in $zoneMap[$zoneName]) {
                    # WWN formati: xx:xx:xx:xx:xx:xx:xx:xx veya duz hex
                    $memberClean = $member.ToLower() -replace '[^0-9a-f:]',''
                    if ($memberClean.Length -ge 16) {
                        if (-not $zoneWwns.ContainsKey($memberClean)) { $zoneWwns[$memberClean] = @() }
                        $zoneWwns[$memberClean] += $zoneName
                    }
                }
            }

            # 1. ORPHAN: Fabric'te gorunuyor ama hicbir zone'da degil (sadece host portlari)
            foreach ($wwn in $fabricWwns.Keys) {
                # Storage WWN'leri atla
                if (Test-IsStorageWwn -wwn $wwn) { continue }
                $wwnNorm = $wwn.ToLower() -replace '[^0-9a-f:]',''
                $inZone  = $false
                foreach ($zw in $zoneWwns.Keys) {
                    if ($zw -eq $wwnNorm -or $zw.Replace(':','') -eq $wwnNorm.Replace(':','')) { $inZone = $true; break }
                }
                if (-not $inZone) {
                    $ZoneAuditRows += [PSCustomObject]@{
                        Lokasyon   = $swLokasyon
                        Fabric     = $swFabric
                        SwitchName = $swName
                        ActiveCfg  = $activeCfg
                        'Sorun'    = 'Orphan HBA'
                        'Aciklama' = 'Fabric görünüyor ama aktif zone yok'
                        'WWN'      = $wwn
                        'Alias'    = $fabricWwns[$wwn]
                        'Zone'     = '—'
                    }
                }
            }

            # 2. GHOST: Zone'da tanimlı ama fabric'te görünmüyor
            foreach ($zw in $zoneWwns.Keys) {
                if (Test-IsStorageWwn -wwn $zw) { continue }
                $inFabric = $false
                foreach ($fw in $fabricWwns.Keys) {
                    if ($fw.Replace(':','') -eq $zw.Replace(':','')) { $inFabric = $true; break }
                }
                if (-not $inFabric) {
                    $zones = $zoneWwns[$zw] -join ', '
                    $ZoneAuditRows += [PSCustomObject]@{
                        Lokasyon   = $swLokasyon
                        Fabric     = $swFabric
                        SwitchName = $swName
                        ActiveCfg  = $activeCfg
                        'Sorun'    = 'Ghost Zone Uyesi'
                        'Aciklama' = 'Zone tanımlı ama fabric görünmüyor'
                        'WWN'      = $zw
                        'Alias'    = ''
                        'Zone'     = $zones
                    }
                }
            }
            Write-Step "     Zone Audit: $($ZoneAuditRows | Where-Object { $_.SwitchName -eq $swName } | Measure-Object | Select-Object -ExpandProperty Count) sorun" DarkGray
        }

        $DashboardRows += [PSCustomObject]@{
            Lokasyon=$swLokasyon; Fabric=$swFabric; SwitchName=$swName; IP=$swIp
            Status='OK'; Model=$model; Firmware=$firmware
            TotalPorts=$total; OnlinePorts=$online; FreePorts=$free
            HostPorts=$hostCount; StoragePorts=$storage
            # ISL: switchshow'daki E-Port/EX-Port/VE-Port/ME-Port satirlarini say
            # (grep E-Port -wc ile ayni sonuc - rol tespiti bypass)
            ISLPorts = ($ssLines | Where-Object { $_ -match '\bE-Port\b|\bEX-Port\b|\bVE-Port\b|\bME-Port\b' } | Measure-Object).Count
            Speed8G=$s8; Speed16G=$s16; Speed32G=$s32; Speed64G=$s64
            ErrorPorts=$errPorts; Uptime=$uptime; ActiveCfg=$activeCfg
        }
    }

    return @{ Dashboard=$DashboardRows; Ports=$PortRows; Hosts=$FabricHosts; ZoneAudit=$ZoneAuditRows }
}

# ============================================================
# 6. CSV YAZ + PUBLISH
# ============================================================

function Write-CSVAndPublish {
    param(
        [array]$Data,
        [string]$LocalPath,
        [string]$RemotePath,
        [switch]$WithHistory,
        [int]$HistoryDays = 30,   # Varsayilan 30 gun
        [switch]$NoPublish        # Global yerine acik parametre (test/tasinabilirlik)
    )

    # BOS VERI KONTROLU - kritik
    if (-not $Data -or $Data.Count -eq 0) {
        Write-Step "     (bos veri - dosya yazilmadi)" DarkGray
        return
    }

    # VERI TIPI KONTROLU - Data'nin dizi oldugundan emin ol
    $dataArray = @($Data)
    if ($dataArray.Count -eq 0) {
        Write-Step "     (bos dizi - dosya yazilmadi)" DarkGray
        return
    }

    Write-Step "     Yazilacak satir sayisi: $($dataArray.Count)" DarkGray

    $today = Get-Date -Format 'yyyy-MM-dd'

    # Veriyi isle: Tarih ekle (gerekirse), NULL'lari temizle ve Protect-CsvCell uygula
    $finalData = $dataArray | ForEach-Object {
        $o = [ordered]@{}
        
        # 1. Tarih kolonu (History istenmisse ve yoksa basa ekle)
        $hasTarih = $_ | Get-Member -Name 'Tarih' -ErrorAction SilentlyContinue
        if ($WithHistory -and -not $hasTarih) {
            $o['Tarih'] = $today
        }

        # 2. Tum property'leri kopyala ve koru
        foreach ($prop in $_.PSObject.Properties) {
            $val = $prop.Value
            if ($null -eq $val) { $val = '' }
            elseif ($val -is [string]) { $val = Protect-CsvCell $val }
            $o[$prop.Name] = $val
        }
        [PSCustomObject]$o
    }

    # ON IZLEME - debug icin ilk satir
    if ($finalData.Count -gt 0) {
        Write-Step "     Ornek veri (ilk satir):" DarkGray
        $firstRow = $finalData[0]
        $firstRow.PSObject.Properties | Select-Object -First 3 | ForEach-Object {
            Write-Step "       $($_.Name) = $($_.Value)" DarkGray
        }
    }

    try {
        # ConvertTo-Csv + WriteAllText: Protect-CsvData by-pass (pipeline scope sorununa karsi guvenli)
        # Ayrica byte boyutu dogrulamak icin manuel yazim
        $csvContent = $finalData | ConvertTo-Csv -NoTypeInformation
        [System.IO.File]::WriteAllText($LocalPath, ($csvContent -join "`r`n"), [System.Text.UTF8Encoding]::new($false))

        # Dosya boyutunu kontrol et
        $fileInfo = Get-Item $LocalPath -ErrorAction SilentlyContinue
        if ($fileInfo -and $fileInfo.Length -gt 0) {
            Write-Step "     lokal:  $LocalPath ($([math]::Round($fileInfo.Length/1KB,1)) KB)" Green
        } else {
            Write-Step "     UYARI: Dosya olusturuldu ama boyut 0! Alternatif yontem deneniyor..." Yellow
            $finalData | Export-Csv -Path $LocalPath -NoTypeInformation -Encoding UTF8 -Force
            Write-Step "     lokal (alternatif): $LocalPath" Green
        }
    } catch {
        Write-Step "     lokal HATA: $($_.Exception.Message)" Red
        Write-Step "     Hata detayi: $($_.Exception.ToString())" Red

        # SON CARE: basit CSV yaz (her satiri elle olustur)
        try {
            $simpleCsv = @()
            # Header
            $headers = $finalData[0].PSObject.Properties.Name
            $simpleCsv += ($headers | ForEach-Object { '"' + ($_ -replace '"','""') + '"' }) -join ','
            # Rows
            foreach ($row in $finalData) {
                $line = ($row.PSObject.Properties | ForEach-Object {
                    $val = if ($null -eq $_.Value) { '' } else { [string]$_.Value }
                    $val = $val -replace '"','""'
                    '"' + $val + '"'
                }) -join ','
                $simpleCsv += $line
            }
            [System.IO.File]::WriteAllLines($LocalPath, $simpleCsv, [System.Text.UTF8Encoding]::new($false))
            Write-Step "     lokal (basit csv fallback): $LocalPath" Yellow
        } catch {
            Write-Step "     FATAL HATA: $($_.Exception.Message)" Red
            return
        }
    }

    # History
    if ($WithHistory) {
        $localDir = Split-Path $LocalPath -Parent
        $fileName = Split-Path $LocalPath -Leaf
        $baseName = [System.IO.Path]::GetFileNameWithoutExtension($fileName)
        $ext      = [System.IO.Path]::GetExtension($fileName)
        $histDir  = Join-Path $localDir '_history'

        if (-not (Test-Path $histDir)) { New-Item -ItemType Directory -Path $histDir -Force | Out-Null }

        $snapName = "${baseName}_${today}${ext}"
        $snapPath = Join-Path $histDir $snapName
        try {
            Copy-Item -Path $LocalPath -Destination $snapPath -Force
        } catch { Write-Verbose "[L3697] islem atlandi: $($_.Exception.Message)" }

        # 30 gunden eski snapshot'lari sil
        $cutoff = (Get-Date).AddDays(-$HistoryDays)
        Get-ChildItem -Path $histDir -Filter "${baseName}_*.csv" -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt $cutoff } |
            ForEach-Object { try { Remove-Item $_.FullName -Force } catch { Write-Verbose "Eski history silinemedi: $($_.FullName)" } }

        Write-Step "     history: $snapPath ($HistoryDays gun)" DarkGray
    }

    if ($NoPublish) { return }

    try {
        $remoteDir = Split-Path $RemotePath -Parent
        if (-not (Test-Path $remoteDir)) {
            New-Item -ItemType Directory -Path $remoteDir -Force -ErrorAction Stop | Out-Null
        }
        Copy-Item -Path $LocalPath -Destination $RemotePath -Force -ErrorAction Stop
        Write-Step "     remote: $RemotePath" Green
    } catch {
        Write-Step "     remote HATA: $($_.Exception.Message)" DarkYellow
    }

    # Remote'a da history kopyala
    if ($WithHistory) {
        try {
            $remoteHistDir = Join-Path (Split-Path $RemotePath -Parent) '_history'
            if (-not (Test-Path $remoteHistDir)) {
                New-Item -ItemType Directory -Path $remoteHistDir -Force -ErrorAction Stop | Out-Null
            }
            $remoteSnap = Join-Path $remoteHistDir $snapName
            Copy-Item -Path $LocalPath -Destination $remoteSnap -Force -ErrorAction Stop
        } catch { Write-Step "     remote history HATA: $($_.Exception.Message)" DarkYellow }
    }
}

# ============================================================
# 7. MAIN
# ============================================================

# Pester test modu: fonksiyonlar yuklendi, ana akisi calistirma
if ($TestMode) { return }

Write-Hdr "STORAGE PORTAL UNIFIED REPORTER"
Write-Step " Baslangic: $($script:StartTime)" Gray
Write-Step " Credentials: $CredDir" Gray

$runHuawei   = (-not $OnlyPowerMax -and -not $OnlySAN -and -not $OnlyPure -and -not $OnlyNetApp -and -not $OnlyPureFB -and -not $OnlyECS)
$runPowerMax = (-not $OnlyHuawei   -and -not $OnlySAN -and -not $OnlyPure -and -not $OnlyNetApp -and -not $OnlyPureFB -and -not $OnlyECS)
$runPure     = (-not $OnlyHuawei   -and -not $OnlyPowerMax -and -not $OnlySAN -and -not $OnlyNetApp -and -not $OnlyPureFB -and -not $OnlyECS)
$runPureFB   = (-not $OnlyHuawei   -and -not $OnlyPowerMax -and -not $OnlySAN -and -not $OnlyNetApp -and -not $OnlyPure  -and -not $OnlyECS)
$runNetApp   = (-not $OnlyHuawei   -and -not $OnlyPowerMax -and -not $OnlySAN -and -not $OnlyPure  -and -not $OnlyPureFB -and -not $OnlyECS)
$runECS      = (-not $OnlyHuawei   -and -not $OnlyPowerMax -and -not $OnlySAN -and -not $OnlyPure  -and -not $OnlyPureFB -and -not $OnlyNetApp)
$runSAN      = (-not $OnlyHuawei   -and -not $OnlyPowerMax -and -not $OnlyPure -and -not $OnlyNetApp -and -not $OnlyPureFB -and -not $OnlyECS)

if ($OnlySAN)    { $runSAN=$true;    $runHuawei=$false; $runPowerMax=$false; $runPure=$false; $runNetApp=$false; $runPureFB=$false; $runECS=$false }
if ($OnlyHuawei) { $runHuawei=$true; $runPowerMax=$false; $runSAN=$false; $runPure=$false; $runNetApp=$false; $runPureFB=$false; $runECS=$false }
if ($OnlyPowerMax){ $runPowerMax=$true;$runHuawei=$false; $runSAN=$false; $runPure=$false; $runNetApp=$false; $runPureFB=$false; $runECS=$false }
if ($OnlyPure)   { $runPure=$true;   $runHuawei=$false; $runPowerMax=$false; $runSAN=$false; $runNetApp=$false; $runPureFB=$false; $runECS=$false }
if ($OnlyPureFB) { $runPureFB=$true; $runHuawei=$false; $runPowerMax=$false; $runSAN=$false; $runNetApp=$false; $runPure=$false; $runECS=$false }
if ($OnlyNetApp) { $runNetApp=$true; $runHuawei=$false; $runPowerMax=$false; $runSAN=$false; $runPure=$false; $runPureFB=$false; $runECS=$false }
if ($OnlyECS)    { $runECS=$true;    $runHuawei=$false; $runPowerMax=$false; $runSAN=$false; $runPure=$false; $runPureFB=$false; $runNetApp=$false }
if ($OnlySwitch) { $runSAN=$true;    $runHuawei=$false; $runPowerMax=$false; $runPure=$false; $runNetApp=$false; $runPureFB=$false; $runECS=$false }

Write-Step (" Modlar: HW={0} PMAX={1} PureFA={2} PureFB={3} NetApp={4} ECS={5} SAN={6}" -f $runHuawei,$runPowerMax,$runPure,$runPureFB,$runNetApp,$runECS,$runSAN) Gray

# ── HUAWEI ──
if ($runHuawei) {
    Write-Hdr "HUAWEI TARAMA"
    $hw = Invoke-HuaweiScan -Cabinets $HuaweiCabinets
    Write-Step "`n  Cikti dosyalari:" Cyan
    Write-CSVAndPublish -Data $hw.Dashboard   -LocalPath (Join-Path $LocalHw 'Dorado_Dashboard.csv') -RemotePath (Join-Path $RemoteHw 'Dorado_Dashboard.csv') -WithHistory -NoPublish:$NoPublish
    Write-CSVAndPublish -Data $hw.Hosts       -LocalPath (Join-Path $LocalHw 'Dorado_Host.csv')      -RemotePath (Join-Path $RemoteHw 'Dorado_Host.csv')      -WithHistory -NoPublish:$NoPublish
    Write-CSVAndPublish -Data $hw.LunGroups   -LocalPath (Join-Path $LocalHw 'Dorado_Lun.csv')       -RemotePath (Join-Path $RemoteHw 'Dorado_Lun.csv') -NoPublish:$NoPublish
    Write-CSVAndPublish -Data $hw.PortGroups  -LocalPath (Join-Path $LocalHw 'Dorado_PortGroup.csv') -RemotePath (Join-Path $RemoteHw 'Dorado_PortGroup.csv') -NoPublish:$NoPublish
    Write-CSVAndPublish -Data $hw.Snapshots   -LocalPath (Join-Path $LocalHw 'Dorado_Snapshot.csv')   -RemotePath (Join-Path $RemoteHw 'Dorado_Snapshot.csv') -NoPublish:$NoPublish
    Write-CSVAndPublish -Data $hw.NAS         -LocalPath (Join-Path $LocalHw 'Dorado_NAS.csv')        -RemotePath (Join-Path $RemoteHw 'Dorado_NAS.csv') -NoPublish:$NoPublish
    Write-CSVAndPublish -Data $hw.HyperMetro  -LocalPath (Join-Path $LocalHw 'Dorado_HyperMetro.csv') -RemotePath (Join-Path $RemoteHw 'Dorado_HyperMetro.csv') -WithHistory -NoPublish:$NoPublish
}

# ── POWERMAX ──
if ($runPowerMax) {
    Write-Hdr "POWERMAX TARAMA"
    $pm = Invoke-PowerMaxScan -Cabinets $PowerMaxCabinets
    Write-Step "`n  Cikti dosyalari:" Cyan
    Write-CSVAndPublish -Data $pm.Dashboard   -LocalPath (Join-Path $LocalPmax 'PmaxPoolDash.csv')  -RemotePath (Join-Path $RemotePmax 'PmaxPoolDash.csv')  -WithHistory -NoPublish:$NoPublish
    Write-CSVAndPublish -Data $pm.Hosts       -LocalPath (Join-Path $LocalPmax 'PmaxPoolHost.csv')  -RemotePath (Join-Path $RemotePmax 'PmaxPoolHost.csv')  -WithHistory -NoPublish:$NoPublish
    Write-CSVAndPublish -Data $pm.LunGroups   -LocalPath (Join-Path $LocalPmax 'PmaxLunGroups.csv') -RemotePath (Join-Path $RemotePmax 'PmaxLunGroups.csv') -WithHistory -NoPublish:$NoPublish
    Write-CSVAndPublish -Data $pm.PortGroups  -LocalPath (Join-Path $LocalPmax 'PmaxPortGroup.csv') -RemotePath (Join-Path $RemotePmax 'PmaxPortGroup.csv') -NoPublish:$NoPublish
    Write-CSVAndPublish -Data $pm.SnapPolicy  -LocalPath (Join-Path $LocalPmax 'Pmax_SnapPolicy.csv') -RemotePath (Join-Path $RemotePmax 'Pmax_SnapPolicy.csv') -NoPublish:$NoPublish
}

# ── PURE FLASHARRAY ──
if ($runPure) {
    Write-Hdr "PURE FLASHARRAY TARAMA"
    $pf = Invoke-PureScan -Cabinets $PureFACabinets
    Write-Step "`n  Cikti dosyalari:" Cyan
    Write-CSVAndPublish -Data $pf.Dashboard -LocalPath (Join-Path $LocalPure 'Pure_Dashboard.csv') -RemotePath (Join-Path $RemotePure 'Pure_Dashboard.csv') -WithHistory -NoPublish:$NoPublish
    Write-CSVAndPublish -Data $pf.Hosts     -LocalPath (Join-Path $LocalPure 'Pure_Host.csv')      -RemotePath (Join-Path $RemotePure 'Pure_Host.csv')      -WithHistory -NoPublish:$NoPublish
    Write-CSVAndPublish -Data $pf.Volumes   -LocalPath (Join-Path $LocalPure 'Pure_Volume.csv')    -RemotePath (Join-Path $RemotePure 'Pure_Volume.csv') -NoPublish:$NoPublish
}

# ── PURE FLASHBLADE ──
if ($runPureFB) {
    Write-Hdr "PURE FLASHBLADE TARAMA"
    $fb = Invoke-PureFBScan -Cabinets $PureFBCabinets
    Write-Step "`n  Cikti dosyalari:" Cyan
    Write-CSVAndPublish -Data $fb.Dashboard   -LocalPath (Join-Path $LocalPure 'FB_Dashboard.csv')    -RemotePath (Join-Path $RemotePure 'FB_Dashboard.csv') -WithHistory -NoPublish:$NoPublish
    Write-CSVAndPublish -Data $fb.Buckets     -LocalPath (Join-Path $LocalPure 'FB_Buckets.csv')      -RemotePath (Join-Path $RemotePure 'FB_Buckets.csv')   -WithHistory -NoPublish:$NoPublish
    Write-CSVAndPublish -Data $fb.FileSystems -LocalPath (Join-Path $LocalPure 'FB_FileSystems.csv')  -RemotePath (Join-Path $RemotePure 'FB_FileSystems.csv') -NoPublish:$NoPublish
    Write-CSVAndPublish -Data $fb.Replication -LocalPath (Join-Path $LocalPure 'FB_Replication.csv')  -RemotePath (Join-Path $RemotePure 'FB_Replication.csv') -NoPublish:$NoPublish
}

# ── ECS ──
if ($runECS) {
    Write-Hdr "ECS TARAMA"
    $ecs = Invoke-ECSScan -PlinkOnlyMode:$PlinkOnly
    Write-Step "`n  Cikti dosyalari:" Cyan
    Write-CSVAndPublish -Data $ecs.Dashboard    -LocalPath (Join-Path $LocalEcs 'ECS_Dashboard.csv')    -RemotePath (Join-Path $RemoteEcs 'ECS_Dashboard.csv')    -WithHistory -NoPublish:$NoPublish
    Write-CSVAndPublish -Data $ecs.Buckets      -LocalPath (Join-Path $LocalEcs 'ECS_Buckets.csv')      -RemotePath (Join-Path $RemoteEcs 'ECS_Buckets.csv')      -WithHistory -NoPublish:$NoPublish
    Write-CSVAndPublish -Data $ecs.Connectivity -LocalPath (Join-Path $LocalEcs 'ECS_Connectivity.csv') -RemotePath (Join-Path $RemoteEcs 'ECS_Connectivity.csv') -NoPublish:$NoPublish
    # History kaydet
    # ECS History - Artik Write-CSVAndPublish kullaniyoruz (Bug #2 fix)
    Write-CSVAndPublish -Data $ecs.History -LocalPath (Join-Path $LocalEcs 'ECS_Bucket_History.csv') -RemotePath (Join-Path $RemoteEcs 'ECS_Bucket_History.csv') -NoPublish:$NoPublish
}

# ── NETAPP ONTAP ──
if ($runNetApp) {
    Write-Hdr "NETAPP ONTAP TARAMA"
    $na = Invoke-NetAppScan -Clusters $NetAppClusters
    Write-Step "`n  Cikti dosyalari:" Cyan
    Write-CSVAndPublish -Data $na.Dashboard -LocalPath (Join-Path $LocalNetApp 'NetApp_Dashboard.csv') -RemotePath (Join-Path $RemoteNetApp 'NetApp_Dashboard.csv') -WithHistory -NoPublish:$NoPublish
    Write-CSVAndPublish -Data $na.Volumes   -LocalPath (Join-Path $LocalNetApp 'NetApp_Volume.csv')    -RemotePath (Join-Path $RemoteNetApp 'NetApp_Volume.csv') -NoPublish:$NoPublish
    Write-CSVAndPublish -Data $na.SVMs      -LocalPath (Join-Path $LocalNetApp 'NetApp_SVM.csv')       -RemotePath (Join-Path $RemoteNetApp 'NetApp_SVM.csv') -NoPublish:$NoPublish
    Write-CSVAndPublish -Data $na.SnapPolicy    -LocalPath (Join-Path $LocalNetApp 'NetApp_SnapPolicy.csv')    -RemotePath (Join-Path $RemoteNetApp 'NetApp_SnapPolicy.csv') -NoPublish:$NoPublish
    Write-CSVAndPublish -Data $na.MetroCluster  -LocalPath (Join-Path $LocalNetApp 'NetApp_MetroCluster.csv')  -RemotePath (Join-Path $RemoteNetApp 'NetApp_MetroCluster.csv') -NoPublish:$NoPublish
}

# ── BROCADE SAN ──
if ($runSAN) {
    Write-Hdr "BROCADE SAN TARAMA"

    $switchList = if ($OnlySwitch) {
        $filtered = @($AllSwitches | Where-Object { $_.Name -eq $OnlySwitch })
        if ($filtered.Count -eq 0) {
            Write-Step "[!] Switch bulunamadi: $OnlySwitch" Red
            Write-Step "    Gecerli isimler: $($AllSwitches.Name -join ', ')" DarkGray
            $null
        } else { $filtered }
    } else { $AllSwitches }

    if ($switchList) {
        $san = Invoke-SANScan -Switches $switchList -TimeoutSec $SANTimeout

        if ($san) {
            Write-Step "`n  Cikti dosyalari:" Cyan
            $dashFile = Join-Path $LocalSan 'SAN_Director_Dashboard.csv'
            $portFile = Join-Path $LocalSan 'SAN_Director_Ports.csv'
            $hostFile = Join-Path $LocalSan 'SAN_Fabric_Hosts.csv'

            Write-CSVAndPublish -Data $san.Dashboard -LocalPath $dashFile -RemotePath (Join-Path $RemoteSan 'SAN_Director_Dashboard.csv') -WithHistory -NoPublish:$NoPublish
            Write-CSVAndPublish -Data $san.Ports     -LocalPath $portFile -RemotePath (Join-Path $RemoteSan 'SAN_Director_Ports.csv') -NoPublish:$NoPublish
            Write-CSVAndPublish -Data $san.Hosts     -LocalPath $hostFile -RemotePath (Join-Path $RemoteSan 'SAN_Fabric_Hosts.csv') -NoPublish:$NoPublish
            Write-CSVAndPublish -Data $san.ZoneAudit -LocalPath (Join-Path $LocalSan 'SAN_ZoneAudit.csv') -RemotePath (Join-Path $RemoteSan 'SAN_ZoneAudit.csv') -NoPublish:$NoPublish

            # Host Last Seen ozet dosyasi
            $lastSeenFile = Join-Path $LocalSan 'SAN_Host_LastSeen.csv'
            $existingLS = @{}
            if (Test-Path $lastSeenFile) {
                try { Import-Csv $lastSeenFile | ForEach-Object { $existingLS["$($_.SwitchName)::$($_.PortWWN)"] = $_ } } catch { Write-Verbose "[L3868] san atlandi: $($_.Exception.Message)" }
            }
            $today = Get-Date -Format 'yyyy-MM-dd'
            foreach ($row in $san.Hosts) {
                $key = "$($row.SwitchName)::$($row.PortWWN)"
                $existingLS[$key] = [PSCustomObject]@{
                    Lokasyon=$row.Lokasyon; Fabric=$row.Fabric; SwitchName=$row.SwitchName
                    PortIndex=$row.PortIndex; PortWWN=$row.PortWWN; Alias=$row.Alias
                    Speed=$row.Speed; LastSeen=$today
                    FirstSeen=if ($existingLS.ContainsKey($key)) { $existingLS[$key].FirstSeen } else { $today }
                }
            }
            # SAN Host LastSeen - Artik Write-CSVAndPublish kullaniyoruz (Bug #2 fix)
            Write-CSVAndPublish -Data ($existingLS.Values | Sort-Object SwitchName, PortWWN) -LocalPath $lastSeenFile -RemotePath (Join-Path $RemoteSan 'SAN_Host_LastSeen.csv') -NoPublish:$NoPublish
        }
    }
}

$duration = (Get-Date) - $script:StartTime
Write-Hdr "TAMAMLANDI"
Write-Step " Sure: $([math]::Round($duration.TotalSeconds, 1)) saniye" Green

# ── ALARM / MAIL BILDIRIMI ──
# Vendor bazli dashboard'lari topla, config'deki esik+vendor filtresine gore mail.
# alert-config.json enabled=false ise HIC mail gitmez (guvenli varsayilan).
Write-Hdr "ALARM KONTROL"
$vendorDash = @{}
$vendorMap = @{ hw='Huawei'; pm='PowerMax'; pf='PureFA'; fb='PureFB'; ecs='ECS'; na='NetApp' }
foreach ($v in $vendorMap.Keys) {
    $varObj = Get-Variable -Name $v -ValueOnly -ErrorAction SilentlyContinue
    if ($varObj -and $varObj.Dashboard) { $vendorDash[$vendorMap[$v]] = $varObj.Dashboard }
}
if ($vendorDash.Count -gt 0) {
    Send-CapacityAlert -VendorDashboards $vendorDash
} else {
    Write-Step "  Alarm: taranan dashboard yok, kontrol atlandi" DarkGray
}

Write-Host ""