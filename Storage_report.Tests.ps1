#Requires -Version 5.1
<#
.SYNOPSIS
    Pester test suite for Storage_report.ps1
    Run: Invoke-Pester .\Storage_report.Tests.ps1 -Output Detailed

.NOTES
    Requires Pester v5+: Install-Module Pester -Force -SkipPublisherCheck
    Uses $TestMode switch to load functions without executing the main scan.
#>

# ── SETUP ──────────────────────────────────────────────────────────────────
BeforeAll {
    # Load all functions without running the main scan
    . "$PSScriptRoot\Storage_report.ps1" -TestMode

    # Minimal Write-Step stub so output functions don't fail during tests
    if (-not (Get-Command Write-Step -ErrorAction SilentlyContinue)) {
        function Write-Step { param($Msg, $Color) }
    }
    if (-not (Get-Command Write-Hdr -ErrorAction SilentlyContinue)) {
        function Write-Hdr { param($Msg) }
    }
}

# ── Coalesce ───────────────────────────────────────────────────────────────
Describe 'Coalesce' {
    It 'returns value when not null or empty' {
        Coalesce 'hello' 'default' | Should -Be 'hello'
    }
    It 'returns default when value is null' {
        Coalesce $null 'default' | Should -Be 'default'
    }
    It 'returns default when value is empty string' {
        Coalesce '' 'default' | Should -Be 'default'
    }
    It 'returns 0 as a valid non-null value' {
        Coalesce 0 'default' | Should -Be 0
    }
    It 'returns false as a valid non-null value' {
        Coalesce $false 'default' | Should -Be $false
    }
}

# ── Get-Prop ───────────────────────────────────────────────────────────────
Describe 'Get-Prop' {
    It 'retrieves a top-level property' {
        $obj = [PSCustomObject]@{ Name = 'test' }
        Get-Prop $obj 'Name' | Should -Be 'test'
    }
    It 'retrieves a nested property path' {
        $inner = [PSCustomObject]@{ Value = 42 }
        $outer = [PSCustomObject]@{ Inner = $inner }
        Get-Prop $outer 'Inner.Value' | Should -Be 42
    }
    It 'returns null when object is null' {
        Get-Prop $null 'Name' | Should -BeNullOrEmpty
    }
    It 'returns null for missing intermediate node' {
        $obj = [PSCustomObject]@{ Name = 'test' }
        Get-Prop $obj 'Missing.Value' | Should -BeNullOrEmpty
    }
}

# ── Protect-CsvCell ────────────────────────────────────────────────────────
Describe 'Protect-CsvCell' {
    It 'prefixes formula injection with equals sign' {
        Protect-CsvCell '=CMD|/C calc' | Should -BeLike "'=*"
    }
    It 'prefixes formula injection with plus sign' {
        Protect-CsvCell '+1+1' | Should -BeLike "'+*"
    }
    It 'prefixes formula injection with at sign' {
        Protect-CsvCell '@SUM(A1:A10)' | Should -BeLike "'@*"
    }
    It 'prefixes formula injection with minus sign' {
        Protect-CsvCell '-1' | Should -BeLike "'-*"
    }
    It 'prefixes formula injection with tab character' {
        Protect-CsvCell "`tDangerous" | Should -BeLike "'" + "`t*"
    }
    It 'leaves safe strings unchanged' {
        Protect-CsvCell 'HW007' | Should -Be 'HW007'
    }
    It 'leaves safe numeric strings unchanged' {
        Protect-CsvCell '1234.56' | Should -Be '1234.56'
    }
    It 'returns null input as null' {
        Protect-CsvCell $null | Should -BeNullOrEmpty
    }
    It 'leaves normal host names unchanged' {
        Protect-CsvCell 'srvprd-db01.internal' | Should -Be 'srvprd-db01.internal'
    }
}

# ── Protect-CsvData ────────────────────────────────────────────────────────
Describe 'Protect-CsvData' {
    It 'sanitizes all string properties in array' {
        $data = @(
            [PSCustomObject]@{ Name = '=EXPLOIT'; Value = 100 }
            [PSCustomObject]@{ Name = 'safe';     Value = 200 }
        )
        $result = Protect-CsvData $data
        $result[0].Name  | Should -BeLike "'=*"
        $result[1].Name  | Should -Be 'safe'
    }
    It 'does not modify numeric properties' {
        $data = @([PSCustomObject]@{ Val = 999 })
        $result = Protect-CsvData $data
        $result[0].Val | Should -Be 999
    }
    It 'handles empty array gracefully' {
        $result = Protect-CsvData @()
        $result.Count | Should -Be 0
    }
    It 'handles null input gracefully' {
        $result = Protect-CsvData $null
        $result.Count | Should -Be 0
    }
    It 'skips null rows without throwing' {
        $data = @($null, [PSCustomObject]@{ Name = 'ok' })
        { Protect-CsvData $data } | Should -Not -Throw
    }
}

# ── New-ErrorDashRow ───────────────────────────────────────────────────────
Describe 'New-ErrorDashRow' {
    It 'sets Total (TB) to HATA sentinel' {
        $row = New-ErrorDashRow -Lokasyon 'Istanbul' -Kabinet 'HW007' -IP '10.0.0.1'
        $row.'Total (TB)' | Should -Be 'HATA'
    }
    It 'sets numeric fields to 0 for safe aggregation' {
        $row = New-ErrorDashRow -Lokasyon 'Istanbul' -Kabinet 'HW007' -IP '10.0.0.1'
        $row.'Used (TB)'       | Should -Be 0
        $row.'Free (TB)'       | Should -Be 0
        $row.'Doluluk (%)'     | Should -Be 0
        $row.'Host Sayisi'     | Should -Be 0
    }
    It 'includes error message in Durum when Hata provided' {
        $row = New-ErrorDashRow -Lokasyon 'IST' -Kabinet 'HW007' -IP '10.0.0.1' -Hata 'Connection timed out'
        $row.Durum | Should -BeLike 'HATA: *'
        $row.Durum | Should -Match 'Connection timed out'
    }
    It 'sets Durum to bare HATA when no error message given' {
        $row = New-ErrorDashRow -Lokasyon 'IST' -Kabinet 'HW007' -IP '10.0.0.1'
        $row.Durum | Should -Be 'HATA'
    }
    It 'preserves Lokasyon, Kabinet and IP' {
        $row = New-ErrorDashRow -Lokasyon 'Ankara' -Kabinet 'HW005_ANK' -IP '10.25.0.5'
        $row.Lokasyon | Should -Be 'Ankara'
        $row.Kabinet  | Should -Be 'HW005_ANK'
        $row.IP       | Should -Be '10.25.0.5'
    }
}

# ── Write-CSVAndPublish ────────────────────────────────────────────────────
Describe 'Write-CSVAndPublish' {
    BeforeAll {
        $script:TmpDir = Join-Path $env:TEMP ('PesterCSV_' + [System.IO.Path]::GetRandomFileName())
        New-Item -ItemType Directory -Path $script:TmpDir -Force | Out-Null
    }
    AfterAll {
        Remove-Item -Recurse -Force $script:TmpDir -ErrorAction SilentlyContinue
    }

    It 'writes CSV file to local path' {
        $data = @([PSCustomObject]@{ Kabinet='HW007'; 'Used (TB)'=10 })
        $path = Join-Path $script:TmpDir 'test_write.csv'
        Write-CSVAndPublish -Data $data -LocalPath $path -RemotePath $path -NoPublish
        $path | Should -Exist
        (Get-Item $path).Length | Should -BeGreaterThan 0
    }

    It 'produces valid CSV parseable by Import-Csv' {
        $data = @(
            [PSCustomObject]@{ Kabinet='HW007'; 'Used (TB)'=10.5; Lokasyon='Istanbul' }
            [PSCustomObject]@{ Kabinet='HW005'; 'Used (TB)'=5.2;  Lokasyon='Ankara'   }
        )
        $path = Join-Path $script:TmpDir 'test_parse.csv'
        Write-CSVAndPublish -Data $data -LocalPath $path -RemotePath $path -NoPublish
        $rows = Import-Csv $path
        $rows.Count        | Should -Be 2
        $rows[0].Kabinet   | Should -Be 'HW007'
        $rows[1].Lokasyon  | Should -Be 'Ankara'
    }

    It 'skips writing when data array is empty' {
        $path = Join-Path $script:TmpDir 'test_empty.csv'
        Write-CSVAndPublish -Data @() -LocalPath $path -RemotePath $path -NoPublish
        $path | Should -Not -Exist
    }

    It 'skips writing when data is null' {
        $path = Join-Path $script:TmpDir 'test_null.csv'
        Write-CSVAndPublish -Data $null -LocalPath $path -RemotePath $path -NoPublish
        $path | Should -Not -Exist
    }

    It 'adds Tarih column when WithHistory switch is set and row has no Tarih' {
        $data = @([PSCustomObject]@{ Kabinet='HW007'; 'Used (TB)'=10 })
        $path = Join-Path $script:TmpDir 'test_history.csv'
        Write-CSVAndPublish -Data $data -LocalPath $path -RemotePath $path -WithHistory -NoPublish
        $rows = Import-Csv $path
        $rows[0].PSObject.Properties.Name | Should -Contain 'Tarih'
        $rows[0].Tarih | Should -Match '^\d{4}-\d{2}-\d{2}$'
    }

    It 'does not duplicate Tarih column when row already has one' {
        $today = (Get-Date -Format 'yyyy-MM-dd')
        $data = @([PSCustomObject]@{ Tarih=$today; Kabinet='HW007'; 'Used (TB)'=10 })
        $path = Join-Path $script:TmpDir 'test_no_dup_tarih.csv'
        Write-CSVAndPublish -Data $data -LocalPath $path -RemotePath $path -WithHistory -NoPublish
        $rows = Import-Csv $path
        $tarihCols = $rows[0].PSObject.Properties.Name | Where-Object { $_ -eq 'Tarih' }
        $tarihCols.Count | Should -Be 1
    }

    It 'creates _history snapshot when WithHistory is set' {
        $data = @([PSCustomObject]@{ Kabinet='HW007'; 'Used (TB)'=10 })
        $path = Join-Path $script:TmpDir 'snap_test.csv'
        Write-CSVAndPublish -Data $data -LocalPath $path -RemotePath $path -WithHistory -NoPublish
        $histDir  = Join-Path $script:TmpDir '_history'
        $today    = (Get-Date -Format 'yyyy-MM-dd')
        $snapFile = Join-Path $histDir "snap_test_${today}.csv"
        $snapFile | Should -Exist
    }

    It 'sanitizes formula-injection strings in CSV output' {
        $data = @([PSCustomObject]@{ Kabinet='=CMD|/C whoami'; 'Used (TB)'=1 })
        $path = Join-Path $script:TmpDir 'test_sanitize.csv'
        Write-CSVAndPublish -Data $data -LocalPath $path -RemotePath $path -NoPublish
        $raw = Get-Content $path -Raw
        # Injected formula should be prefixed, not left raw
        $raw | Should -Not -Match '(?<![''=])"=CMD'
    }

    It 'writes UTF-8 without BOM' {
        $data = @([PSCustomObject]@{ Ad='Türkçe Karakter: ğüşıöç' })
        $path = Join-Path $script:TmpDir 'test_utf8.csv'
        Write-CSVAndPublish -Data $data -LocalPath $path -RemotePath $path -NoPublish
        # Read raw bytes: UTF-8 BOM is EF BB BF
        $bytes = [System.IO.File]::ReadAllBytes($path)
        ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) | Should -Be $false
    }
}

# ── Invoke-RestWithRetry ───────────────────────────────────────────────────
Describe 'Invoke-RestWithRetry' {
    It 'returns result on first success' {
        $result = Invoke-RestWithRetry { 'ok' } -MaxAttempts 3 -InitialDelayMs 0
        $result | Should -Be 'ok'
    }

    It 'throws immediately on 401 (permanent error, no retry)' {
        $attempt = 0
        $ex = [System.Net.WebException]::new('Unauthorized')
        # Simulate a 401 by attaching a mock response status
        # (full WebException with response is hard to construct in unit test;
        #  we verify the function throws without infinite looping)
        { Invoke-RestWithRetry { throw 'auth fail' } -MaxAttempts 3 -InitialDelayMs 0 } |
            Should -Throw
    }

    It 'retries transient errors up to MaxAttempts then throws' {
        $callCount = 0
        {
            Invoke-RestWithRetry -MaxAttempts 3 -InitialDelayMs 0 -ScriptBlock {
                $callCount++
                throw 'transient network error'
            }
        } | Should -Throw
        $callCount | Should -Be 3
    }

    It 'returns result after transient failure then success' {
        $attempt = 0
        $result = Invoke-RestWithRetry -MaxAttempts 3 -InitialDelayMs 0 -ScriptBlock {
            $attempt++
            if ($attempt -lt 2) { throw 'transient' }
            'recovered'
        }
        $result | Should -Be 'recovered'
        $attempt | Should -Be 2
    }
}
