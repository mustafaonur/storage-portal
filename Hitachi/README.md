# Hitachi CSV Klasörü

Bu klasör `hitachi.html` tarafından okunur.

## Dosyalar
| Dosya | Üretici Script | Açıklama |
|---|---|---|
| `Hitachi_PROD.csv` | `Hitachi_CCI_Collector.ps1 -Lokasyon PROD` | PROD sistemi pool kapasiteleri |
| `Hitachi_DR.csv`   | `Hitachi_CCI_Collector.ps1 -Lokasyon DR`   | DR sistemi pool kapasiteleri   |

## CSV Şeması
```
Kabinet, Lokasyon, Pool, Total (TB), Used (TB), Free (TB), Doluluk (%), Pool ID, Toplanan
```

## Çalıştırma

### PROD Sunucusunda (yerel)
```powershell
.\Hitachi_CCI_Collector.ps1 -Lokasyon PROD `
    -RemotePath "\\btprdsrc01\source_drive\genel\StorageScriptOutput\Hitachi\Hitachi_PROD.csv"
```

### DR Sunucusunda (yerel)
```powershell
.\Hitachi_CCI_Collector.ps1 -Lokasyon DR `
    -RemotePath "\\btprdsrc01\source_drive\genel\StorageScriptOutput\Hitachi\Hitachi_DR.csv"
```

### Zamanlanmış Görev Örneği (Task Scheduler)
- Program: `powershell.exe`
- Argümanlar: `-NonInteractive -File "C:\Scripts\Hitachi_CCI_Collector.ps1" -Lokasyon PROD -RemotePath "\\server\share\Hitachi\Hitachi_PROD.csv"`
- Tetikleyici: Günlük 06:00

## raidcom Komutları
Script iki komut dener (önce `get dp_pool`, fallback `get pool -key opt`).
HORCM instance'ı `-HorcmInstance` parametresiyle ayarlanır (varsayılan: 0).
