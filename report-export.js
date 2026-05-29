/**
 * report-export.js — Storage Portal HTML Rapor Üretici
 * Çağrı: StorageReport.generate({ stat, alarmList, assetInventory })
 * Çıktı: Tek dosya, self-contained HTML blob → tarayıcı indirir veya yeni sekmede açar.
 * Hiç sunucu gerekmez; tamamen client-side.
 */

const StorageReport = (() => {

  function fmtTB(v, d=2){ return (typeof v==='number'?v:parseFloat(v||0)).toFixed(d)+' TB'; }
  function fmtPct(v)    { return (typeof v==='number'?v:parseFloat(v||0)).toFixed(1)+'%'; }
  function esc(s){ return String(s??'').replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;'); }

  function barSvg(pct, w=120, h=10){
    const p = Math.min(100, Math.max(0, pct));
    const col = p>=80?'#e84b4b':p>=70?'#e8844b':'#4be8a0';
    return `<svg width="${w}" height="${h}" style="vertical-align:middle"><rect width="${w}" height="${h}" fill="#111b2e"/><rect width="${p/100*w}" height="${h}" fill="${col}" opacity=".7"/></svg> <span style="font-size:10px;color:${col}">${p.toFixed(1)}%</span>`;
  }

  function contractRows(inv){
    if(!inv||!inv.length) return '<tr><td colspan="4" style="text-align:center;color:#5a7090;padding:10px">Kontrat verisi yok</td></tr>';
    const now=new Date();
    return inv
      .filter(r=>r.contractEnd)
      .map(r=>({ ...r, days:Math.round((new Date(r.contractEnd)-now)/86400000) }))
      .sort((a,b)=>a.days-b.days)
      .slice(0,15)
      .map(r=>{
        const col=r.days<0?'#e84b4b':r.days<90?'#e8844b':r.days<180?'#e8b84b':'#4be8a0';
        const lbl=r.days<0?'SÜRESİ DOLDU':r.days<90?'KRİTİK':r.days<180?'UYARI':'OK';
        return `<tr>
          <td style="padding:6px 10px;color:#e8f2ff">${esc(r.productName||'')}</td>
          <td style="padding:6px 10px;color:#5a7090;font-size:10px">${esc(r.assetId||'')}</td>
          <td style="padding:6px 10px;color:#c8d8f0">${esc(r.location||'')}</td>
          <td style="padding:6px 10px">${esc(r.contractEnd)}</td>
          <td style="padding:6px 10px"><span style="color:${col};border:1px solid ${col};padding:1px 6px;font-size:9px">${lbl}</span></td>
        </tr>`;
      }).join('');
  }

  function alarmRows(list){
    if(!list||!list.length) return '<tr><td colspan="4" style="text-align:center;color:#4be8a0;padding:10px">✓ Alarm yok</td></tr>';
    return list
      .sort((a,b)=>b.pct-a.pct)
      .map(r=>{
        const col=r.pct>=80?'#e84b4b':'#e8844b';
        return `<tr>
          <td style="padding:6px 10px;color:#e8f2ff;font-weight:500">${esc(r.kabinet||'')}</td>
          <td style="padding:6px 10px;color:#c8d8f0">${esc(r.vendor||'')}</td>
          <td style="padding:6px 10px">${barSvg(r.pct)}</td>
          <td style="padding:6px 10px;color:#5a7090">${fmtTB(r.free)} boş</td>
        </tr>`;
      }).join('');
  }

  function generate({ stat={}, alarmList=[], assetInventory=[] }={}) {
    const now    = new Date();
    const nowStr = now.toLocaleString('tr-TR');
    const totalTB  = ((stat.hwCap||0)+(stat.pmCap||0)+(stat.pureCap||0)).toFixed(2);
    const usedTB   = ((stat.hwUsed||0)+(stat.pmUsed||0)+(stat.pureUsed||0)).toFixed(2);
    const freeTB   = ((stat.hwFree||0)+(stat.pmFree||0)+(stat.pureFree||0)).toFixed(2);
    const usedPct  = totalTB>0 ? (usedTB/totalTB*100).toFixed(1) : '—';
    const totalCabs= (stat.hwCabs||0)+(stat.pmCabs||0)+(stat.pureCabs||0);
    const totalHosts=(stat.hwHosts||0)+(stat.pmHosts||0)+(stat.pureHosts||0);
    const critN    = alarmList.filter(a=>a.level==='critical').length;
    const warnN    = alarmList.filter(a=>a.level==='warning').length;

    const html = `<!DOCTYPE html>
<html lang="tr">
<head>
<meta charset="UTF-8">
<title>Storage Portal Raporu — ${nowStr}</title>
<style>
*{margin:0;padding:0;box-sizing:border-box;}
body{background:#080c14;color:#c8d8f0;font-family:'Courier New',Courier,monospace;font-size:12px;padding:28px;}
h1{font-family:Arial,sans-serif;font-size:22px;font-weight:800;color:#e8f2ff;margin-bottom:4px;}
h2{font-family:Arial,sans-serif;font-size:13px;font-weight:700;color:#e8b84b;letter-spacing:2px;text-transform:uppercase;margin:24px 0 10px;padding-bottom:6px;border-bottom:1px solid #1e2d44;}
.meta{font-size:10px;color:#5a7090;margin-bottom:24px;}
.kpi-grid{display:grid;grid-template-columns:repeat(4,1fr);gap:12px;margin-bottom:24px;}
.kpi{background:#0d1420;border:1px solid #1e2d44;padding:14px 16px;}
.kpi-lbl{font-size:9px;letter-spacing:1.5px;text-transform:uppercase;color:#5a7090;margin-bottom:6px;}
.kpi-val{font-family:Arial,sans-serif;font-size:26px;font-weight:800;color:#e8f2ff;line-height:1;}
.kpi-sub{font-size:9px;color:#5a7090;margin-top:5px;}
.kpi.crit{border-left:3px solid #e84b4b;}
.kpi.warn{border-left:3px solid #e8844b;}
.kpi.ok  {border-left:3px solid #4be8a0;}
.kpi.blue{border-left:3px solid #4b9fe8;}
table{width:100%;border-collapse:collapse;font-size:11px;}
th{background:#0d1420;color:#5a7090;font-size:9px;letter-spacing:1px;text-transform:uppercase;padding:8px 10px;text-align:left;border-bottom:1px solid #1e2d44;}
tr{border-bottom:1px solid rgba(30,45,68,.5);}
tr:nth-child(even){background:rgba(13,20,32,.4);}
.footer{margin-top:28px;font-size:9px;color:#5a7090;border-top:1px solid #1e2d44;padding-top:10px;}
</style>
</head>
<body>
<h1>Enterprise Storage Portal — Kapasite Raporu</h1>
<div class="meta">Rapor tarihi: ${nowStr} &nbsp;·&nbsp; Otomatik oluşturuldu</div>

<div class="kpi-grid">
  <div class="kpi blue">
    <div class="kpi-lbl">Toplam Kapasite</div>
    <div class="kpi-val">${totalTB}</div>
    <div class="kpi-sub">TB · tüm vendor</div>
  </div>
  <div class="kpi ok">
    <div class="kpi-lbl">Kullanım</div>
    <div class="kpi-val">${usedPct}%</div>
    <div class="kpi-sub">${usedTB} TB kullanılan</div>
  </div>
  <div class="kpi ${critN>0?'crit':'ok'}">
    <div class="kpi-lbl">Kritik Alarm</div>
    <div class="kpi-val">${critN}</div>
    <div class="kpi-sub">${warnN} uyarı</div>
  </div>
  <div class="kpi blue">
    <div class="kpi-lbl">Toplam Kabinet</div>
    <div class="kpi-val">${totalCabs}</div>
    <div class="kpi-sub">${totalHosts} host</div>
  </div>
</div>

<h2>Kapasite Alarm Durumu</h2>
<table>
  <thead><tr><th>Kabinet</th><th>Vendor</th><th>Doluluk</th><th>Boş Alan</th></tr></thead>
  <tbody>${alarmRows(alarmList)}</tbody>
</table>

<h2>Kontrat / Garanti Durumu</h2>
<table>
  <thead><tr><th>Ürün</th><th>Asset ID</th><th>Lokasyon</th><th>Bitiş</th><th>Durum</th></tr></thead>
  <tbody>${contractRows(assetInventory)}</tbody>
</table>

<div class="footer">Storage Portal · QNB/ibtech · ${nowStr}</div>
</body>
</html>`;

    return html;
  }

  function download(opts){
    const html = generate(opts);
    const blob = new Blob([html], { type: 'text/html;charset=utf-8' });
    const a    = document.createElement('a');
    const now  = new Date();
    const stamp= `${now.getFullYear()}${String(now.getMonth()+1).padStart(2,'0')}${String(now.getDate()).padStart(2,'0')}`;
    a.href     = URL.createObjectURL(blob);
    a.download = `storage-raporu-${stamp}.html`;
    a.click();
    setTimeout(() => URL.revokeObjectURL(a.href), 5000);
  }

  function openInTab(opts){
    const html = generate(opts);
    const win  = window.open('', '_blank');
    const blob = new Blob([html], { type: 'text/html;charset=utf-8' });
    const url  = URL.createObjectURL(blob);
    const tab  = window.open(url, '_blank');
    if(tab) setTimeout(() => URL.revokeObjectURL(url), 10000);
  }

  return { generate, download, openInTab };
})();
