<#
.SYNOPSIS
    Storage Portal — Otomatik README.md Üretici
    storage_config.json ve canlı CSV verilerini okuyarak güncel bir README üretir.

.DESCRIPTION
    Çalıştırıldığında repo kökündeki README.md dosyasını günceller:
      - Kabinet ve vendor listesi (storage_config.json'dan)
      - Son tarama istatistikleri (last-run.json'dan)
      - CSV durum tablosu (hangi CSV var, kaç satır, ne zaman güncellendi)
      - Kurulum ve çalıştırma kılavuzu

.PARAMETER RepoRoot
    Portal dosyalarının bulunduğu dizin. Varsayılan: script'in bulunduğu dizin.

.PARAMETER OutputPath
    README.md çıktı yolu. Varsayılan: RepoRoot\README.md

.EXAMPLE
    .\Generate_README.ps1
    .\Generate_README.ps1 -RepoRoot "C:\Scripts\Storage" -OutputPath "C:\Portal\README.md"
#>

[CmdletBinding()]
param(
    [string]$RepoRoot   = $PSScriptRoot,
    [string]$OutputPath = (Join-Path $PSScriptRoot 'README.md')
)

$ErrorActionPreference = 'Continue'
$now = Get-Date

function Get-CsvInfo {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return @{exists=$false; rows=0; updated='—'} }
    $fi = Get-Item $Path
    try {
        $lines = [System.IO.File]::ReadAllLines($Path)
        $rows  = [math]::Max(0, $lines.Count - 1)
    } catch { $rows = 0 }
    @{
        exists  = $true
        rows    = $rows
        updated = $fi.LastWriteTime.ToString('yyyy-MM-dd HH:mm')
        size    = [math]::Round($fi.Length / 1KB, 1)
    }
}

# ── Load config ────────────────────────────────────────────────
$cfgPath = Join-Path $RepoRoot 'storage_config.json'
$cfg = $null
if (Test-Path $cfgPath) {
    try { $cfg = Get-Content $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { Write-Warning "storage_config.json okunamadı: $_" }
}

# ── Load last-run.json ─────────────────────────────────────────
$lrPath = Join-Path $RepoRoot 'last-run.json'
$lr = $null
if (Test-Path $lrPath) {
    try { $lr = Get-Content $lrPath -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { Write-Warning "last-run.json okunamadı: $_" }
}

# ── CSV inventory ──────────────────────────────────────────────
$csvList = @(
    @{path='Hw\Dorado_Dashboard.csv';        label='Huawei Dashboard'},
    @{path='Hw\Dorado_Host.csv';             label='Huawei Hosts'},
    @{path='Hw\Dorado_Lun.csv';              label='Huawei LUN Groups'},
    @{path='Hw\Dorado_Snapshot.csv';         label='Huawei Snapshots'},
    @{path='Hw\Dorado_NAS.csv';              label='Huawei NAS'},
    @{path='Hw\Dorado_HyperMetro.csv';       label='Huawei HyperMetro'},
    @{path='Hw\Dorado_PortGroup.csv';        label='Huawei Port Groups'},
    @{path='Pmax\PmaxPoolDash.csv';          label='PowerMax Dashboard'},
    @{path='Pmax\PmaxPoolHost.csv';          label='PowerMax Hosts'},
    @{path='Pmax\PmaxLunGroups.csv';         label='PowerMax LUN Groups'},
    @{path='Pmax\PmaxPortGroup.csv';         label='PowerMax Port Groups'},
    @{path='Pmax\Pmax_SnapPolicy.csv';       label='PowerMax Snap Policy'},
    @{path='Pure\Pure_Dashboard.csv';        label='Pure FA Dashboard'},
    @{path='Pure\Pure_Host.csv';             label='Pure FA Hosts'},
    @{path='Pure\Pure_Volume.csv';           label='Pure FA Volumes'},
    @{path='Pure\Pure_Capacity_Dashboard.csv';label='Pure FA DR Kapasitesi'},
    @{path='Pure\Pure_Host_Details.csv';     label='Pure FA Host Detay'},
    @{path='Pure\FB_Dashboard.csv';          label='Pure FB Dashboard'},
    @{path='Pure\FB_Buckets.csv';            label='Pure FB Buckets'},
    @{path='Pure\FB_FileSystems.csv';        label='Pure FB FileSystems'},
    @{path='Pure\FB_Replication.csv';        label='Pure FB Replikasyon'},
    @{path='NetApp\NetApp_Dashboard.csv';    label='NetApp Dashboard'},
    @{path='NetApp\NetApp_SVM.csv';          label='NetApp SVMs'},
    @{path='NetApp\NetApp_Volume.csv';       label='NetApp Volumes'},
    @{path='NetApp\NetApp_SnapPolicy.csv';   label='NetApp Snap Policy'},
    @{path='Ecs\ECS_Dashboard.csv';          label='ECS Dashboard'},
    @{path='Ecs\ECS_Buckets.csv';            label='ECS Buckets'},
    @{path='Ecs\ECS_Connectivity.csv';       label='ECS Bağlantı'},
    @{path='Hitachi\Hitachi_PROD.csv';       label='Hitachi PROD'},
    @{path='Hitachi\Hitachi_DR.csv';         label='Hitachi DR'},
    @{path='San\SAN_Director_Dashboard.csv'; label='SAN Director Dashboard'},
    @{path='San\SAN_Director_Ports.csv';     label='SAN Director Ports'},
    @{path='San\SAN_Fabric_Hosts.csv';       label='SAN Fabric Hosts'},
    @{path='San\SAN_Host_LastSeen.csv';      label='SAN Host LastSeen'},
    @{path='San\SAN_ZoneAudit.csv';          label='SAN Zone Audit'}
)

$csvRows = $csvList | ForEach-Object {
    $full = Join-Path $RepoRoot $_.path
    $info = Get-CsvInfo -Path $full
    $status = if ($info.exists) { "✅" } else { "⬜" }
    "| $status | $($_.label) | $($_.path) | $($info.rows) | $($info.updated) | $($info.size) KB |"
}

# ── Vendor summary from config ─────────────────────────────────
$vendorSummary = ''
if ($cfg) {
    if ($cfg.Huawei)   { $vendorSummary += "- **Huawei OceanStor/Dorado**: $($cfg.Huawei.Count) kabinet`n" }
    if ($cfg.PowerMax) { $vendorSummary += "- **Dell EMC PowerMax**: $($cfg.PowerMax.Count) array`n" }
    if ($cfg.PureFA)   { $vendorSummary += "- **Pure FlashArray**: $($cfg.PureFA.Count) array`n" }
    if ($cfg.PureFB)   { $vendorSummary += "- **Pure FlashBlade**: $($cfg.PureFB.Count) appliance`n" }
    if ($cfg.NetApp)   { $vendorSummary += "- **NetApp ONTAP**: $($cfg.NetApp.Count) cluster`n" }
    if ($cfg.SAN)      { $vendorSummary += "- **Brocade SAN**: $($cfg.SAN.Count) switch`n" }
    if ($cfg.ECS)      { $vendorSummary += "- **Dell ECS**: 2 cluster (Istanbul + Ankara)`n" }
    $vendorSummary += "- **Hitachi VSP**: PROD + DR (CCI tabanlı)`n"
}

# ── Last scan info ─────────────────────────────────────────────
$lastScanBlock = '> ⚠ `last-run.json` bulunamadı. Henüz hiç tarama yapılmamış.'
if ($lr) {
    $ts  = [DateTime]::Parse($lr.timestamp)
    $dur = $lr.durationSec
    $errs = $lr.errorCount
    $lastScanBlock = @"
| Alan | Değer |
|------|-------|
| Son Tarama | $($ts.ToString('yyyy-MM-dd HH:mm')) |
| Süre | $dur saniye |
| Hata Sayısı | $errs |
| Script Versiyon | $($lr.scriptVersion) |
"@
}

# ── Page inventory ─────────────────────────────────────────────
$pages = @(
    @{file='index.html';           desc='Ana Dashboard — Özet KPI, alarm durumu, site karşılaştırması'},
    @{file='huawei.html';          desc='Huawei OceanStor/Dorado — Pool, Host, LUN, Snapshot, NAS, HyperMetro'},
    @{file='pmax.html';            desc='Dell EMC PowerMax — Pool, Host, Storage Group, Snap Policy'},
    @{file='pure-fa.html';         desc='Pure FlashArray — Dashboard, Host, Volume, Data Reduction, IQN/WWN'},
    @{file='pure-fb.html';         desc='Pure FlashBlade — Dashboard, Bucket, FileSystems, Replikasyon'},
    @{file='netapp.html';          desc='NetApp ONTAP — Dashboard, SVM, Volume, Aggregate, Snap Policy'},
    @{file='ecs.html';             desc='Dell ECS — Dashboard, Bucket, Bağlantı Matrisi'},
    @{file='hitachi.html';         desc='Hitachi VSP — PROD + DR pool kapasiteleri (CCI)'},
    @{file='san.html';             desc='SAN Fabric — Director, Port, Zone Audit, Uyumluluk'},
    @{file='trend.html';           desc='Trend Analizi — 30 günlük kapasite grafiği, gap detector'},
    @{file='anomaly.html';         desc='Anomali Dedektörü — 3-sigma sapma tespiti'},
    @{file='capacity-planner.html';desc='Capacity Planner — Lineer projeksiyon, kritik ETA'},
    @{file='impact.html';          desc='Impact Analysis — Kabinet bağımlılık haritası'},
    @{file='topology.html';        desc='Topology — Path Arama, Şema, Fabric Matrisi, Switch Detay'},
    @{file='hostsearch.html';      desc='Cross-Vendor Host Search — Tüm vendor host araması'},
    @{file='portgroups.html';      desc='Port Group Mapping — Huawei + PowerMax target port görünümü'},
    @{file='executive.html';       desc='Executive Summary — Yönetici özet, health score, print-ready'},
    @{file='management.html';      desc='Operations Hub — Nöbet, envanter, alarm config, rezervasyon'},
    @{file='zone-builder.html';    desc='Zone Builder — FC zone konfigürasyon üreticisi'},
    @{file='portal.html';          desc='Portal SPA — Sidebar + sekme, Ctrl+K hızlı açma'}
)
$pagesTable = $pages | ForEach-Object {
    $exists = if (Test-Path (Join-Path $RepoRoot $_.file)) { "✅" } else { "⬜" }
    "| $exists | ``$($_.file)`` | $($_.desc) |"
}

# ── Build README ───────────────────────────────────────────────
$readme = @"
# Enterprise Storage Portal

QNB / Enpara ibtech Storage Operations — Tam otomatik çok-vendor depolama izleme ve yönetim portalı.

> 📅 Bu README otomatik oluşturulmuştur: **$($now.ToString('yyyy-MM-dd HH:mm'))** · ``Generate_README.ps1``

---

## Desteklenen Sistemler

$vendorSummary
---

## Son Tarama Durumu

$lastScanBlock

---

## Portal Sayfaları

| Durum | Dosya | Açıklama |
|-------|-------|----------|
$($pagesTable -join "`n")

---

## CSV Veri Katmanı

| Durum | Açıklama | Yol | Satır | Güncelleme | Boyut |
|-------|----------|-----|-------|------------|-------|
$($csvRows -join "`n")

---

## Kurulum

### Gereksinimler
- PowerShell 5.1 (Windows)
- Plink (Brocade SAN taraması için): ``$($cfg ? $cfg.paths.plinkExe : 'C:\PLINK\plink.exe')``
- Yerel çıktı dizini: ``$($cfg ? $cfg.paths.localBase : 'C:\Scripts\Storage')``
- Ağ paylaşımı (opsiyonel): ``$($cfg ? $cfg.paths.remoteBase : '\\server\share')``

### İlk Çalıştırma

``````powershell
# 1. Credential dosyalarını oluştur (bir kez)
.\Setup-Credentials.ps1

# 2. Tüm sistemi tara
.\Storage_report.ps1

# 3. Sadece bir vendor tara
.\Storage_report.ps1 -OnlyHuawei
.\Storage_report.ps1 -OnlySAN -NoPublish

# 4. Hitachi (PROD/DR sunucusunda yerel çalıştırın)
.\Hitachi_CCI_Collector.ps1 -Lokasyon PROD -RemotePath "\\server\share\Hitachi\Hitachi_PROD.csv"

# 5. Eksik history backfill
.\Backfill_History.ps1 -Days 14 -Commit
``````

### Portal Açma

Herhangi bir web sunucusu kullanın veya doğrudan dosya olarak açın:

``````powershell
# Python ile hızlı sunucu (opsiyonel)
cd "$($cfg ? $cfg.paths.localBase : 'C:\Scripts\Storage')"
python -m http.server 8080
# Tarayıcıda: http://localhost:8080
``````

---

## Konfigürasyon

| Dosya | Amaç |
|-------|------|
| ``storage_config.json`` | IP adresleri, vendor listesi, yollar |
| ``alert-config.json`` | Kapasite alarm eşikleri, SMTP, alıcılar |
| ``zone-rules.json`` | SAN zone uyumluluk kuralları |
| ``asset-inventory.json`` | Kontrat/garanti envanter verisi |

---

## Test

``````powershell
# Pester v5+ gerekir
Install-Module Pester -Force
Invoke-Pester .\Storage_report.Tests.ps1 -Output Detailed
``````

---

*Storage Portal · ibtech · QNB/Enpara | Oluşturulma: $($now.ToString('yyyy-MM-dd HH:mm'))*
"@

$readme | Set-Content -Path $OutputPath -Encoding UTF8 -Force
Write-Host "README.md yazıldı: $OutputPath" -ForegroundColor Green
Write-Host "  Satır sayısı: $((Get-Content $OutputPath).Count)" -ForegroundColor Gray
