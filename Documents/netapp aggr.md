<!DOCTYPE html>
<html lang="tr">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>NetApp ONTAP Dashboard</title>
<link rel="stylesheet" href="./storage-styles.css">
<script src="./storage-utils.js"></script>
<link href="https://protect2.fireeye.com/v1/url?k=988847e2-fbdfd59c-988974f8-74fe486eb94f-43fd20c105957608&q=1&e=2cab7cbe-08cd-4570-85d3-2ca44ae232fa&u=https%3A%2F%2Furldefense.com%2Fv3%2F__https%3A%2F%2Ffonts.googleapis.com%2Fcss2%3Ffamily%3DJetBrains%2AMono%3Awght%40300%3B400%3B500%3B700%26family%3DSyne%3Awght%40400%3B600%3B700%3B800%26display%3Dswap__%3BKw%21%21LI3htEUvy8-3%21sKMU7uyQSSEQ6i8toZNa8SXomAW0tDfQ1MprkmqdWpO0GX3tevyEOp9hC025niwGhVPyqtbbQTGArLrLVtAQfZMVVdLQzn2shX4oMA%24" rel="stylesheet">
<style>
  :root {
    --bg:#080c14; --surface:#0d1420; --surface2:#111b2e; --border:#1e2d44;
    --accent:#e8b84b; --accent2:#4b9fe8; --accent3:#4be8a0;
    --danger:#e84b4b; --purple:#c084fc; --warn:#e8844b;
    --text:#c8d8f0; --text-dim:#5a7090; --text-bright:#e8f2ff; --grid:#0f1928;
  }
  * { margin:0; padding:0; box-sizing:border-box; }
  body { background:var(--bg); color:var(--text); font-family:'JetBrains Mono',monospace; min-height:100vh; overflow-x:hidden; }
  body::before {
    content:''; position:fixed; inset:0;
    background-image: linear-gradient(rgba(30,45,68,.3) 1px,transparent 1px), linear-gradient(90deg,rgba(30,45,68,.3) 1px,transparent 1px);
    background-size:40px 40px; pointer-events:none; z-index:0;
  }

  #loading-overlay {
    position:fixed; inset:0; background:rgba(8,12,20,.96); z-index:999;
    display:flex; align-items:center; justify-content:center; flex-direction:column; gap:16px;
  }
  .spinner { width:40px; height:40px; border:2px solid var(--border); border-top-color:var(--accent); border-radius:50%; animation:spin .8s linear infinite; }
  @keyframes spin { to { transform:rotate(360deg); } }
  .loading-text { font-size:12px; letter-spacing:3px; text-transform:uppercase; color:var(--text-dim); animation:blink 1.5s ease-in-out infinite; }

  .shell { position:relative; z-index:1; max-width:1600px; margin:0 auto; padding:24px; }
  .back-link { display:inline-block; margin-bottom:14px; font-size:11px; color:var(--text-dim); text-decoration:none; letter-spacing:1.5px; text-transform:uppercase; transition:color .2s; }
  .back-link:hover { color:var(--accent2); }

  header { display:flex; align-items:flex-end; justify-content:space-between; margin-bottom:32px; padding-bottom:20px; border-bottom:1px solid var(--border); }
  .brand { display:flex; align-items:center; gap:14px; }
  .brand-icon { width:42px; height:42px; border:2px solid var(--accent); display:grid; place-items:center; animation:pulse-border 3s ease-in-out infinite; }
  @keyframes pulse-border { 0%,100%{ box-shadow:0 0 0 0 rgba(232,184,75,.4); } 50%{ box-shadow:0 0 0 6px rgba(232,184,75,0); } }
  .brand-icon svg { width:22px; height:22px; stroke:var(--accent); fill:none; stroke-width:1.5; stroke-linecap:round; stroke-linejoin:round; }
  .brand-title { font-family:'Syne',sans-serif; font-size:22px; font-weight:800; color:var(--text-bright); letter-spacing:-.5px; }
  .brand-sub { font-size:10px; color:var(--text-dim); letter-spacing:3px; text-transform:uppercase; margin-top:2px; }
  .header-meta { text-align:right; font-size:11px; color:var(--text-dim); line-height:1.8; }
  .live-dot { display:inline-block; width:6px; height:6px; background:var(--accent3); border-radius:50%; margin-right:6px; animation:blink 2s ease-in-out infinite; vertical-align:middle; }
  @keyframes blink { 0%,100%{opacity:1} 50%{opacity:.3} }

  .tabs { display:flex; gap:2px; margin-bottom:24px; border-bottom:1px solid var(--border); }
  .tab-btn { background:none; border:none; color:var(--text-dim); font-family:'JetBrains Mono',monospace; font-size:12px; letter-spacing:1px; text-transform:uppercase; padding:10px 20px; cursor:pointer; position:relative; transition:color .2s; }
  .tab-btn::after { content:''; position:absolute; bottom:-1px; left:0; right:0; height:2px; background:var(--accent); transform:scaleX(0); transition:transform .2s; }
  .tab-btn.active { color:var(--accent); }
  .tab-btn.active::after { transform:scaleX(1); }
  .tab-btn:hover { color:var(--text); }
  .tab-panel { display:none; }
  .tab-panel.active { display:block; }

  .summary-grid { display:grid; grid-template-columns:repeat(auto-fit,minmax(200px,1fr)); gap:16px; margin-bottom:28px; }
  .stat-card { background:var(--surface); border:1px solid var(--border); padding:20px; position:relative; overflow:hidden; transition:border-color .2s,transform .2s; }
  .stat-card::before { content:''; position:absolute; top:0; left:0; width:3px; height:100%; }
  .stat-card.gold::before { background:var(--accent); }
  .stat-card.blue::before { background:var(--accent2); }
  .stat-card.green::before { background:var(--accent3); }
  .stat-card.red::before { background:var(--danger); }
  .stat-card:hover { border-color:var(--accent); transform:translateY(-2px); }
  .stat-card-click { cursor:pointer; }
  .stat-card-click:hover { border-color:var(--accent2); }
  
  .cabinet-card-click { cursor:pointer; }
  .os-legend-clickable { cursor:pointer; transition:background .15s; }
  .os-legend-clickable:hover {
    background:rgba(75,159,232,.1);
    border-radius:3px;
  }
  .stat-label { font-size:10px; letter-spacing:2px; text-transform:uppercase; color:var(--text-dim); margin-bottom:8px; }
  .stat-value { font-family:'Syne',sans-serif; font-size:28px; font-weight:700; color:var(--text-bright); line-height:1; }
  .stat-unit { font-family:'JetBrains Mono',monospace; font-size:12px; color:var(--text-dim); margin-left:4px; }
  .stat-sub { font-size:11px; color:var(--text-dim); margin-top:6px; }

  .location-block { margin-bottom:36px; }
  .location-header { display:flex; align-items:center; gap:12px; margin-bottom:16px; }
  .location-tag { font-family:'Syne',sans-serif; font-size:13px; font-weight:700; letter-spacing:2px; text-transform:uppercase; color:var(--accent); padding:4px 12px; border:1px solid var(--accent); }
  .location-line { flex:1; height:1px; background:linear-gradient(90deg,var(--accent) 0%,transparent 100%); opacity:.3; }

  .cabinet-grid { display:grid; grid-template-columns:repeat(auto-fill,minmax(340px,1fr)); gap:16px; }
  .cabinet-card { background:var(--surface); border:1px solid var(--border); position:relative; overflow:hidden; transition:border-color .25s,box-shadow .25s; animation:fadeInUp .4s ease both; }
  @keyframes fadeInUp { from{opacity:0;transform:translateY(16px)} to{opacity:1;transform:translateY(0)} }
  .cabinet-card:hover { border-color:rgba(75,159,232,.5); box-shadow:0 0 30px rgba(75,159,232,.07); }
  .cabinet-card.error { border-color:rgba(232,75,75,.4); }
  .cabinet-card.warn-high { border-color:rgba(232,132,75,.4); }
  .card-header { display:flex; justify-content:space-between; align-items:flex-start; padding:16px 18px 12px; border-bottom:1px solid var(--border); background:var(--surface2); }
  .card-name { font-family:'Syne',sans-serif; font-size:16px; font-weight:700; color:var(--text-bright); }
  .card-ip { font-size:11px; color:var(--text-dim); margin-top:3px; }
  .status-badge { font-size:10px; padding:3px 8px; border-radius:2px; letter-spacing:1px; text-transform:uppercase; font-weight:500; }
  .badge-ok  { background:rgba(75,232,160,.15); color:var(--accent3); border:1px solid rgba(75,232,160,.3); }
  .badge-warn{ background:rgba(232,132,75,.15); color:var(--warn);    border:1px solid rgba(232,132,75,.3); }
  .badge-err { background:rgba(232,75,75,.15);  color:var(--danger);  border:1px solid rgba(232,75,75,.3); }
  .card-body { padding:16px 18px; }
  .cap-row { display:flex; justify-content:space-between; align-items:center; margin-bottom:8px; }
  .cap-label { font-size:10px; color:var(--text-dim); letter-spacing:1px; text-transform:uppercase; }
  .cap-pct { font-family:'Syne',sans-serif; font-size:20px; font-weight:700; }
  .bar-track { height:6px; background:var(--grid); border:1px solid var(--border); margin-bottom:14px; position:relative; overflow:hidden; }
  .bar-fill { height:100%; position:absolute; left:0; top:0; }
  .bar-low { background:var(--accent3); } .bar-mid { background:var(--accent); }
  .bar-high { background:var(--warn); }   .bar-crit { background:var(--danger); }
  .metrics-row { display:grid; grid-template-columns:repeat(4,1fr); gap:8px; margin-bottom:14px; }
  .metric { background:var(--grid); border:1px solid var(--border); padding:8px; text-align:center; }
  .metric-val { font-size:13px; font-weight:500; color:var(--text-bright); }
  .metric-lbl { font-size:9px; color:var(--text-dim); letter-spacing:1px; text-transform:uppercase; margin-top:3px; }
  .os-section { margin-bottom:12px; }
  .os-title { font-size:9px; letter-spacing:2px; text-transform:uppercase; color:var(--text-dim); margin-bottom:8px; }
  .os-bars { display:flex; gap:4px; align-items:flex-end; height:32px; }
  .os-bar-wrap { flex:1; display:flex; flex-direction:column; align-items:center; height:100%; }
  .os-bar { width:100%; min-height:3px; border-radius:1px; }
  .os-vmware { background:#4b9fe8; } .os-linux { background:#4be8a0; }
  .os-aix    { background:#e8b84b; } .os-windows{ background:#e87a4b; }
  .os-iscsi  { background:#c084fc; }
  /* AGGREGATE OZET BLOKU (kabinet kartinda) */
  .agg-section { margin:14px 0 12px; padding:10px 12px; background:var(--surface2); border:1px solid var(--border); border-radius:2px; }
  .agg-section-empty { opacity:.55; }
  .agg-empty { font-size:10px; color:var(--text-dim); text-align:center; padding:6px 0; letter-spacing:1px; text-transform:uppercase; }
  .agg-header { display:flex; justify-content:space-between; align-items:center; font-size:10px; letter-spacing:1.5px; text-transform:uppercase; color:var(--text-dim); margin-bottom:8px; }
  .agg-title { color:var(--accent2); font-weight:500; }
  .agg-overall { font-family:'JetBrains Mono',monospace; font-size:11px; display:flex; align-items:center; gap:6px; }
  .agg-crit-badge { background:rgba(232,75,75,.18); color:var(--danger); border:1px solid rgba(232,75,75,.4); font-size:9px; padding:1px 5px; border-radius:8px; }
  .agg-warn-badge { background:rgba(232,132,75,.18); color:var(--warn); border:1px solid rgba(232,132,75,.4); font-size:9px; padding:1px 5px; border-radius:8px; }
  .agg-alert { font-size:10px; padding:5px 8px; margin-bottom:8px; border-radius:2px; cursor:pointer; transition:background .15s; }
  .agg-alert:hover { filter:brightness(1.15); }
  .agg-alert-crit { background:rgba(232,75,75,.10); border-left:2px solid var(--danger); color:var(--danger); }
  .agg-alert-warn { background:rgba(232,132,75,.10); border-left:2px solid var(--warn); color:var(--warn); }
  .agg-nodes { display:flex; flex-direction:column; gap:3px; }
  .agg-node-row { display:grid; grid-template-columns:1fr auto auto; gap:8px; align-items:center; font-size:10px; padding:2px 4px; }
  .agg-node-row:hover { background:var(--grid); border-radius:2px; }
  .agg-node-name { color:var(--text); font-family:'JetBrains Mono',monospace; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
  .agg-node-stat { color:var(--text-dim); font-size:9px; letter-spacing:1px; text-transform:uppercase; }
  .agg-node-pct { font-family:'JetBrains Mono',monospace; min-width:42px; text-align:right; font-weight:500; }
  /* AGGREGATE TABLOSU (sekme) */
  .agg-stat-card { background:var(--surface); border:1px solid var(--border); border-left:3px solid var(--accent2); padding:12px 14px; }
  .agg-stat-card.crit { border-left-color:var(--danger); }
  .agg-stat-card.warn { border-left-color:var(--warn); }
  .agg-stat-card.ok   { border-left-color:var(--accent3); }
  .agg-stat-label { font-size:9px; letter-spacing:2px; text-transform:uppercase; color:var(--text-dim); margin-bottom:4px; }
  .agg-stat-val   { font-family:'Syne',sans-serif; font-size:22px; font-weight:700; color:var(--text-bright); line-height:1; }
  .agg-stat-sub   { font-size:10px; color:var(--text-dim); margin-top:4px; }
  .agg-type-pill { font-size:9px; padding:2px 6px; border-radius:2px; letter-spacing:1px; text-transform:uppercase; font-weight:500; }
  .agg-type-SSD  { background:rgba(75,232,160,.15);  color:var(--accent3); }
  .agg-type-NVMe { background:rgba(192,132,252,.15); color:var(--purple); }
  .agg-type-SAS  { background:rgba(75,159,232,.15);  color:var(--accent2); }
  .agg-type-SATA { background:rgba(232,184,75,.15);  color:var(--accent); }
  .agg-type-HDD  { background:rgba(232,132,75,.15);  color:var(--warn); }
  .agg-type-na   { background:rgba(90,112,144,.15);  color:var(--text-dim); }
  .os-legend { display:flex; gap:12px; flex-wrap:wrap; margin-top:8px; }
  .os-legend-item { display:flex; align-items:center; gap:5px; font-size:10px; color:var(--text-dim); }
  .os-dot { width:8px; height:8px; border-radius:1px; }
  .card-footer { display:flex; justify-content:space-between; align-items:center; padding:10px 18px; border-top:1px solid var(--border); background:var(--surface2); font-size:11px; }
  .footer-dr { color:var(--accent); } .footer-ver { color:var(--text-dim); }
  .error-overlay { display:flex; flex-direction:column; align-items:center; justify-content:center; height:140px; gap:10px; color:var(--danger); font-size:12px; letter-spacing:1px; }

  .section-title { font-family:'Syne',sans-serif; font-size:14px; font-weight:700; color:var(--accent); letter-spacing:2px; text-transform:uppercase; margin-bottom:16px; padding-bottom:8px; border-bottom:1px solid var(--border); }
  .filter-row { display:flex; gap:10px; margin-bottom:16px; flex-wrap:wrap; }
  .filter-select { background:var(--surface); border:1px solid var(--border); color:var(--text); font-family:'JetBrains Mono',monospace; font-size:12px; padding:8px 12px; outline:none; transition:border-color .2s; }
  .filter-select:focus { border-color:var(--accent2); }
  .filter-select option { background:var(--surface2); }

  .active-filter-chips {
    display:none; gap:8px; flex-wrap:wrap; align-items:center;
    background:rgba(232,184,75,.08);
    border:1px solid rgba(232,184,75,.25);
    border-left:3px solid var(--accent);
    padding:10px 14px; margin-bottom:14px;
  }
  .filter-chip {
    background:var(--surface2); border:1px solid var(--border);
    color:var(--text-dim); font-size:10px;
    padding:3px 10px; letter-spacing:.5px;
  }
  .filter-chip strong { color:var(--accent); margin-left:4px; }
  .filter-chip-clear {
    background:transparent; border:1px solid var(--text-dim);
    color:var(--text-dim); font-family:'JetBrains Mono',monospace;
    font-size:10px; padding:3px 10px; cursor:pointer;
    letter-spacing:1px; text-transform:uppercase;
    margin-left:auto; transition:all .2s;
  }
  .filter-chip-clear:hover { color:var(--danger); border-color:var(--danger); }
  .search-box { position:relative; flex:1; max-width:280px; }
  .search-box input { width:100%; background:var(--surface); border:1px solid var(--border); color:var(--text); font-family:'JetBrains Mono',monospace; font-size:12px; padding:8px 12px 8px 32px; outline:none; transition:border-color .2s; }
  .search-box input:focus { border-color:var(--accent2); }
  .search-icon { position:absolute; left:10px; top:50%; transform:translateY(-50%); color:var(--text-dim); font-size:13px; }
  table { width:100%; border-collapse:collapse; font-size:12px; }
  thead th { background:var(--surface2); border:1px solid var(--border); padding:10px 14px; text-align:left; font-size:10px; letter-spacing:1.5px; text-transform:uppercase; color:var(--text-dim); white-space:nowrap; cursor:pointer; user-select:none; transition:color .2s; }
  thead th:hover { color:var(--accent); }
  tbody tr { border:1px solid var(--border); transition:background .15s; }
  tbody tr:hover { background:var(--surface2); }
  tbody td { padding:9px 14px; border-bottom:1px solid rgba(30,45,68,.6); color:var(--text); }
  .tag-os { display:inline-block; padding:2px 7px; font-size:10px; border-radius:2px; font-weight:500; }
  .tag-vmware  { background:rgba(75,159,232,.2); color:#4b9fe8; }
  .tag-linux   { background:rgba(75,232,160,.2); color:#4be8a0; }
  .tag-aix     { background:rgba(232,184,75,.2); color:#e8b84b; }
  .tag-windows { background:rgba(232,122,75,.2); color:#e87a4b; }
  .map-status { font-size:10px; padding:2px 8px; border-radius:2px; }
  .mapped   { background:rgba(75,232,160,.15); color:var(--accent3); }
  .unmapped { background:rgba(90,112,144,.15); color:var(--text-dim); }

  .wwn-cell-clickable { cursor:pointer; transition:opacity .15s; }
  .wwn-cell-clickable:hover { opacity:.7; }
  .wwn-cell-clickable .wwn-extra {
    background:rgba(75,159,232,.12); border:1px solid rgba(75,159,232,.3);
    color:var(--accent2); padding:1px 6px; border-radius:2px;
    font-size:9px; margin-left:4px;
  }

  .modal-backdrop {
    position:fixed; inset:0; background:rgba(8,12,20,.85); z-index:1000;
    display:none; align-items:center; justify-content:center;
    animation:fadeIn .2s ease;
  }
  .modal-backdrop.show { display:flex; }
  @keyframes fadeIn { from{opacity:0} to{opacity:1} }
  .modal-card {
    background:var(--surface); border:1px solid var(--border);
    border-left:3px solid var(--accent);
    width:90%; max-width:560px; max-height:80vh;
    display:flex; flex-direction:column;
    animation:slideUp .25s ease;
  }
  @keyframes slideUp { from{opacity:0;transform:translateY(20px)} to{opacity:1;transform:translateY(0)} }
  .modal-header {
    padding:16px 20px; border-bottom:1px solid var(--border);
    display:flex; align-items:center; justify-content:space-between;
    background:var(--surface2);
  }
  .modal-title {
    font-family:'Syne',sans-serif; font-size:14px; font-weight:700;
    color:var(--text-bright); letter-spacing:.5px;
  }
  .modal-host { font-size:11px; color:var(--text-dim); margin-top:3px; letter-spacing:.5px; }
  .modal-close {
    background:transparent; border:none; color:var(--text-dim);
    font-size:20px; cursor:pointer; padding:0 6px; transition:color .2s;
  }
  .modal-close:hover { color:var(--danger); }
  .modal-body { padding:16px 20px; overflow-y:auto; flex:1; }
  .wwn-row {
    display:flex; align-items:center; gap:10px;
    padding:8px 10px; background:var(--grid); border:1px solid var(--border);
    margin-bottom:8px; font-family:'JetBrains Mono',monospace;
  }
  .wwn-row:hover { border-color:var(--accent2); }
  .wwn-index { font-size:10px; color:var(--text-dim); min-width:18px; }
  .wwn-value {
    flex:1; font-size:12px; color:var(--accent3);
    word-break:break-all; letter-spacing:.5px; user-select:all;
  }
  .wwn-copy-btn {
    background:transparent; border:1px solid var(--border); color:var(--text-dim);
    font-family:'JetBrains Mono',monospace; font-size:9px;
    padding:4px 10px; cursor:pointer; letter-spacing:1px;
    text-transform:uppercase; transition:all .2s; white-space:nowrap;
  }
  .wwn-copy-btn:hover { border-color:var(--accent2); color:var(--accent2); }
  .wwn-copy-btn.copied { border-color:var(--accent3); color:var(--accent3); }
  .modal-actions {
    padding:12px 20px; border-top:1px solid var(--border);
    background:var(--surface2); display:flex; gap:8px; justify-content:flex-end;
  }
  .modal-btn {
    background:transparent; border:1px solid var(--border); color:var(--text);
    font-family:'JetBrains Mono',monospace; font-size:11px;
    padding:7px 14px; cursor:pointer; letter-spacing:1px;
    text-transform:uppercase; transition:all .2s;
  }
  .modal-btn:hover { border-color:var(--accent2); color:var(--accent2); }
  .modal-btn.primary { border-color:var(--accent); color:var(--accent); }
  .modal-btn.primary:hover { background:var(--accent); color:var(--bg); }
  .wwn-format-toggle {
    display:flex; gap:0; margin-bottom:12px; border:1px solid var(--border);
  }
  .wwn-format-btn {
    flex:1; background:transparent; border:none; color:var(--text-dim);
    font-family:'JetBrains Mono',monospace; font-size:10px;
    padding:6px 10px; cursor:pointer; letter-spacing:1px;
    text-transform:uppercase; transition:all .15s;
  }
  .wwn-format-btn.active { background:var(--surface2); color:var(--accent2); }
  .wwn-format-btn:hover:not(.active) { color:var(--text); }

  .dash-footer { margin-top:40px; padding-top:16px; border-top:1px solid var(--border); display:flex; justify-content:space-between; font-size:10px; color:var(--text-dim); letter-spacing:1px; }

  ::-webkit-scrollbar { width:6px; height:6px; }
  ::-webkit-scrollbar-track { background:var(--bg); }
  ::-webkit-scrollbar-thumb { background:var(--border); border-radius:3px; }
  ::-webkit-scrollbar-thumb:hover { background:var(--accent2); }

  .sbtn{background:var(--surface);border:1px solid var(--border);color:var(--text-dim);
    font-family:'JetBrains Mono',monospace;font-size:10px;padding:5px 12px;cursor:pointer;
    letter-spacing:1px;text-transform:uppercase;transition:all .2s;}
  .sbtn.active{color:var(--accent);border-color:var(--accent);background:rgba(232,184,75,.08);}
  .sbtn:hover:not(.active){border-color:var(--text-dim);color:var(--text);}
</style>
</head>
<body>

<div id="loading-overlay">
  <div class="spinner"></div>
  <div class="loading-text">CSV Dosyalari Yukleniyor</div>
</div>

<div class="shell">

  <a href="./index.html" class="back-link">&larr; Portala Don</a>

  <header>
    <div class="brand">
      <div class="brand-icon">
        <svg viewBox="0 0 24 24"><path d="M12 2L2 7l10 5 10-5-10-5zM2 17l10 5 10-5M2 12l10 5 10-5"/></svg>
      </div>
      <div>
        <div class="brand-title">Storage Intelligence</div>
        <div class="brand-sub">NetApp ONTAP Cluster Fleet</div>
      </div>
    </div>
    <div class="header-meta">
      <div><span class="live-dot"></span>LIVE MONITORING</div>
      <div id="clock"></div>
      <div id="data-fresh-badge" data-fresh-badge style="margin-top:2px"></div>
      <div id="header-summary">-</div>
    </div>
  </header>

  <div class="tabs">
    <button class="tab-btn active" onclick="switchTab('overview')">Overview</button>
    <button class="tab-btn" onclick="switchTab('hosts')">SVM Listesi</button>
    <button class="tab-btn" onclick="switchTab('luns')">Volumes</button>
    <button class="tab-btn" onclick="switchTab('aggregates')">Aggregates</button>
    <button class="tab-btn" onclick="switchTab('snapshots')">Snapshot Policy</button>
    <button class="tab-btn" onclick="switchTab('metrocluster')">MetroCluster</button>
  </div>

  <div class="tab-panel active" id="tab-overview">
    <div class="summary-grid" id="global-summary"></div>
    <div id="location-blocks"></div>
  </div>

  <div class="tab-panel" id="tab-hosts">
    <div class="section-title">SVM Envanteri</div>
    <div class="active-filter-chips" id="hostFilterChips"></div>
    <div class="filter-row">
      <div class="search-box">
        <span class="search-icon">&#9906;</span>
        <input type="text" placeholder="SVM ara..." id="host-search" oninput="renderHostTable()">
      </div>
      <select class="filter-select" id="host-location" onchange="renderHostTable()"><option value="">Tum Lokasyonlar</option></select>
      <select class="filter-select" id="host-cabinet" onchange="renderHostTable()"><option value="">Tum Kabinetler</option></select>
      <select class="filter-select" id="host-os" onchange="renderHostTable()">
        <option value="">Tum Protokoller</option>
        <option value="CIFS">CIFS</option>
        <option value="NFS">NFS</option>
        <option value="iSCSI">iSCSI</option>
        <option value="FCP">FCP</option>
      </select>
      <select class="filter-select" id="host-map" onchange="renderHostTable()">
        <option value="">Tum Durumlar</option>
        <option value="Mapped">running</option>
        <option value="Unmapped">offline</option>
      </select>
    </div>
    <div id="host-table-wrap"></div>
  </div>

  <div class="tab-panel" id="tab-luns">
    <div class="section-title">Volume Envanteri</div>
    <div class="filter-row">
      <div class="search-box">
        <span class="search-icon">&#9906;</span>
        <input type="text" placeholder="Volume ara..." id="lun-search" oninput="renderLunTable()">
      </div>
      <select class="filter-select" id="lun-location" onchange="renderLunTable()"><option value="">Tum Lokasyonlar</option></select>
      <select class="filter-select" id="lun-cabinet" onchange="renderLunTable()"><option value="">Tum Kabinetler</option></select>
    </div>
    <div id="lun-table-wrap"></div>
  </div>

  <div class="tab-panel" id="tab-aggregates">
    <div class="section-title">Aggregate Envanteri</div>
    <div id="agg-summary" style="display:grid;grid-template-columns:repeat(auto-fit,minmax(180px,1fr));gap:12px;margin-bottom:18px"></div>
    <div class="filter-row">
      <div class="search-box">
        <span class="search-icon">&#9906;</span>
        <input type="text" placeholder="Aggregate, Node ara..." id="agg-search" oninput="renderAggTable()">
      </div>
      <select class="filter-select" id="agg-location" onchange="renderAggTable()"><option value="">Tum Lokasyonlar</option></select>
      <select class="filter-select" id="agg-cabinet" onchange="renderAggTable()"><option value="">Tum Cluster'lar</option></select>
      <select class="filter-select" id="agg-node" onchange="renderAggTable()"><option value="">Tum Node'lar</option></select>
      <select class="filter-select" id="agg-state" onchange="renderAggTable()">
        <option value="">Tum Durumlar</option>
        <option value="online">online</option>
        <option value="offline">offline</option>
        <option value="restricted">restricted</option>
      </select>
      <select class="filter-select" id="agg-fill" onchange="renderAggTable()">
        <option value="">Tum Doluluk</option>
        <option value="crit">Kritik (&ge;80%)</option>
        <option value="warn">Uyari (70-80%)</option>
        <option value="ok">OK (&lt;70%)</option>
      </select>
    </div>
    <div id="agg-table-wrap"></div>
  </div>

  <div class="tab-panel" id="tab-snapshots">
    <div class="section-title">Snapshot Policy Listesi</div>
    <div id="na-snap-summary" style="display:grid;grid-template-columns:repeat(3,1fr);gap:12px;margin-bottom:18px"></div>
    <div class="filter-row">
      <div class="search-box">
        <span class="search-icon">&#9906;</span>
        <input type="text" placeholder="Policy adı, volume, SVM ara..." id="na-snap-search" oninput="renderNaSnap()">
      </div>
      <select class="filter-select" id="na-snap-cab" onchange="renderNaSnap()"><option value="">Tüm Cluster'lar</option></select>
      <select class="filter-select" id="na-snap-svm" onchange="renderNaSnap()"><option value="">Tüm SVM'ler</option></select>
    </div>
    <div id="na-snap-table-wrap"></div>
  </div>

  <div class="tab-panel" id="tab-metrocluster">
    <div class="section-title">MetroCluster Durumu</div>
    <div id="mc-cluster-info" style="margin-bottom:20px"></div>
    <div style="display:flex;gap:6px;margin-bottom:16px;border-bottom:1px solid var(--border);padding-bottom:12px">
      <button class="sbtn active" id="mc-tab-nodes"  onclick="mcSubTab('nodes')" >Node'lar</button>
      <button class="sbtn"        id="mc-tab-vols"   onclick="mcSubTab('vols')"  >Volume'lar</button>
      <button class="sbtn"        id="mc-tab-repl"   onclick="mcSubTab('repl')"  >Replication</button>
    </div>
    <div class="filter-row" style="margin-bottom:14px">
      <div class="search-box">
        <span class="search-icon">&#9906;</span>
        <input type="text" placeholder="Node, volume, SVM, kaynak, hedef ara..." id="mc-search" oninput="renderMc()">
      </div>
      <select class="filter-select" id="mc-cab" onchange="renderMc()"><option value="">Tüm Cluster'lar</option></select>
    </div>
    <div id="mc-table-wrap"></div>
  </div>

  <div class="dash-footer">
    <span>NETAPP ONTAP CLUSTER DASHBOARD</span>
    <span>POWERSHELL AUTOMATION v2.0</span>
  </div>
</div>

<!-- WWN MODAL -->
<div class="modal-backdrop" id="wwnModal" onclick="if(event.target===this)closeWwnModal()">
  <div class="modal-card">
    <div class="modal-header">
      <div>
        <div class="modal-title">Host WWN'ler</div>
        <div class="modal-host" id="modalHostName">-</div>
      </div>
      <button class="modal-close" onclick="closeWwnModal()" title="Kapat">&times;</button>
    </div>
    <div class="modal-body">
      <div class="wwn-format-toggle">
        <button class="wwn-format-btn active" id="fmtColon" onclick="setWwnFormat('colon')">aa:aa:aa:aa</button>
        <button class="wwn-format-btn" id="fmtPlain" onclick="setWwnFormat('plain')">aaaaaaaa</button>
      </div>
      <div id="wwnList"></div>
    </div>
    <div class="modal-actions">
      <button class="modal-btn" onclick="copyAllWwns()">Hepsini Kopyala</button>
      <button class="modal-btn primary" onclick="closeWwnModal()">Kapat</button>
    </div>
  </div>
</div>

<script>
let cabinets  = [];
let hosts     = [];
let lunGroups = [];
let aggregates = [];

const CSV_DASHBOARD = './NetApp/NetApp_Dashboard.csv';
const CSV_HOSTS     = './NetApp/NetApp_SVM.csv';
const CSV_LUNGROUPS = './NetApp/NetApp_Volume.csv';
const CSV_AGGS      = './NetApp/NetApp_Aggregate.csv';

function updateClock() {
  document.getElementById('clock').textContent =
    new Date().toLocaleDateString('tr-TR') + ' · ' + new Date().toLocaleTimeString('tr-TR');
}
setInterval(updateClock, 1000);
updateClock();

function parseDashboard(text) {
  const skip = ['---', '==='];
  return parseCSV(text)
    .filter(r => {
      const k = (r['Kabinet'] || '').trim();
      const l = (r['Lokasyon'] || '').trim();
      if (!k) return false;
      if (skip.includes(l)) return false;
      if (/^TOPLAM|^GENEL/i.test(k)) return false;
      return true;
    })
    .map(r => {
      const ip  = (r['IP'] || '').trim();
      const tot = (r['Total (TB)'] || '').trim();
      const isErr = ip === 'HATA' || tot === '' || tot === '-' || tot.toUpperCase() === 'HATA';

      if (isErr) return { location:r['Lokasyon'], name:r['Kabinet'], ip, error:true };

      const osObj = {};
      (r['OS Dagilimi'] || '').split('|').forEach(p => {
        const m = p.trim().match(/^(.+?):\s*(\d+)$/);
        if (m) osObj[m[1].trim()] = parseInt(m[2]);
      });

      return {
        location:   r['Lokasyon'],
        name:       r['Kabinet'],
        ip,
        total:      toN(r['Total (TB)']),
        used:       toN(r['Used (TB)']),
        subscribed: toN(r['Subscribed (TB)']),
        free:       toN(r['Free (TB)']),
        pct:        toN(r['Doluluk (%)']),
        dr:         (r['Data Reduction'] || '-').trim(),
        hostCount:  parseInt(r['Host Sayisi']) || 0,
        os:         osObj,
        version: (function(v) {
          const m = (v||'').match(/\b(\d+\.\d+[\.\w]*)/);
          return m ? m[1] : (v||'').trim().substring(0,20);
        })(r['Versiyon']),
      };
    });
}

function parseHosts(text) {
  return parseCSV(text)
    .filter(r => (r['SVM'] || '').trim() !== '')
    .map(r => ({
      location:  r['Lokasyon'],
      cabinet:   r['Kabinet'],
      host:      r['SVM'],
      os:        r['Protocols'] || 'NFS',
      map:       r['State'] === 'running' ? 'Mapped' : 'Offline',
      provTB:    0,
      wwns:      [],
    }));
}

function expandWwns(raw) {
  const result = [];
  (raw || '').split('|').forEach(chunk => {
    const hex = chunk.trim().toLowerCase().replace(/[^0-9a-f]/g, '');
    if (hex.length === 0) return;
    for (let i = 0; i + 16 <= hex.length; i += 16) {
      const w = hex.substring(i, i + 16);
      result.push(w.match(/.{2}/g).join(':'));
    }
  });
  return result;
}

function parseLunGroups(text) {
  return parseCSV(text)
    .filter(r => (r['Volume'] || '').trim() !== '')
    .map(r => ({
      location: r['Lokasyon'],
      cabinet:  r['Kabinet'],
      name:     r['Volume'],
      svm:      r['SVM'] || '',
      capacity: toN(r['Size (TB)']),
      lunCount: 0,
      state:    r['State'] || 'online',
      type:     r['Type'] || 'rw',
    }));
}

function parseAggregates(text) {
  if (!text) return [];
  return parseCSV(text)
    .filter(r => (r['Aggregate'] || '').trim() !== '')
    .map(r => ({
      location:  (r['Lokasyon']  || '').trim(),
      cabinet:   (r['Kabinet']   || '').trim(),
      name:      (r['Aggregate'] || '').trim(),
      node:      (r['Node']      || '-').trim(),
      type:      (r['Tip']       || '-').trim(),
      total:     toN(r['Total (TB)']),
      used:      toN(r['Used (TB)']),
      free:      toN(r['Free (TB)']),
      pct:       toN(r['Doluluk (%)']),
      dr:        (r['Data Reduction'] || '-').trim(),
      state:     (r['State']     || 'unknown').trim(),
    }));
}

async function loadCSVs() {
  setOverlay(true, '<div class="spinner"></div><div class="loading-text">CSV Dosyalari Yukleniyor</div>');

  const fetchCSV = async (file) => {
    try {
      const r = await fetch(file, { cache:'no-store' });
      if (!r.ok) return '';
      return await r.text();
    } catch(e) { return ''; }
  };

  const [dashText, hostText, lunText, aggText] = await Promise.all([
    fetchCSV(CSV_DASHBOARD), fetchCSV(CSV_HOSTS), fetchCSV(CSV_LUNGROUPS), fetchCSV(CSV_AGGS),
  ]);

  cabinets   = parseDashboard(dashText);
  hosts      = parseHosts(hostText);
  lunGroups  = parseLunGroups(lunText);
  aggregates = parseAggregates(aggText);

  // Yan sekmeleri (Snapshot ve MetroCluster) de yükle
  await Promise.all([loadNaSnap(), loadMc()]);

  setOverlay(false);

  if (cabinets.length === 0 && hosts.length === 0 && lunGroups.length === 0) {
    document.getElementById('header-summary').textContent = 'Veri bulunamadı';
    document.getElementById('tab-overview').innerHTML = `
      <div style="text-align:center;padding:60px 20px;color:var(--text-dim)">
        <div style="font-size:32px;margin-bottom:16px">⚠</div>
        <div style="font-family:'Syne',sans-serif;font-size:16px;color:var(--warn);margin-bottom:12px">CSV Dosyaları Bulunamadı</div>
        <button onclick="loadCSVs()" style="margin-top:24px;background:transparent;color:var(--accent);border:1px solid var(--accent);font-family:'JetBrains Mono',monospace;font-size:11px;letter-spacing:2px;padding:8px 20px;cursor:pointer">YENİDEN DENE</button>
      </div>`;
    return;
  }

  initDashboard();
}

function setOverlay(show, html) {
  const el = document.getElementById('loading-overlay');
  if(el) {
    el.style.display = show ? 'flex' : 'none';
    if (show && html) el.innerHTML = html;
  }
}

function initDashboard() {
  const locCount = [...new Set(cabinets.map(c => c.location))].length;
  document.getElementById('header-summary').textContent =
    `${cabinets.length} Kabinet · ${locCount} Lokasyon`;
  buildSummary();
  buildOverview();
  populateFilters();
  renderHostTable();
  renderLunTable();
  renderAggTable();
}

/* Protokol renkleri (NetApp'e ozel):
     NFS    = yesil     (Unix/Linux dunyasi)
     CIFS   = mavi      (Windows file)
     iSCSI  = mor       (block-IP)
     FCP    = sari      (block-FC)
   Cluster kart cubuklarinda da ayni renkler kullanilir. */
const dotColors = { vmware:'#4b9fe8', linux:'#4be8a0', aix:'#e8b84b', windows:'#e87a4b', iscsi:'#c084fc',
                    NFS:'#4be8a0', CIFS:'#4b9fe8', iSCSI:'#c084fc', FCP:'#e8b84b' };
const osBarMap  = { 'VMware ESX':'os-vmware', Linux:'os-linux', AIX:'os-aix', Windows:'os-windows',
                    NFS:'os-linux', CIFS:'os-vmware', iSCSI:'os-iscsi', FCP:'os-aix' };

function barClass(p)    { return typeof spBarClass === 'function' ? spBarClass(p) : 'bar-low'; }
function pctColor(p)    { return typeof spPctColor === 'function' ? spPctColor(p) : 'var(--accent3)'; }
function statusBadge(p) { return typeof spStatusBadge === 'function' ? spStatusBadge(p) : '<span class="status-badge badge-ok">OK</span>'; }
function fmt(n) { return typeof n==='number' ? n.toFixed(2) : n; }

function buildSummary() {
  const v = cabinets.filter(c => !c.error);
  const totCap  = v.reduce((s,c)=>s+c.total, 0);
  const totUsed = v.reduce((s,c)=>s+c.used,  0);
  const totFree = v.reduce((s,c)=>s+c.free,  0);
  const totSubs = v.reduce((s,c)=>s+(c.subscribed||0), 0);
  const totSvm  = v.reduce((s,c)=>s+c.hostCount, 0);
  const avgPct  = totCap>0 ? (totUsed/totCap*100).toFixed(1) : '0';

  // STANDART ESIKLER (storage-utils.js SP_THRESH): OK<70, WARN 70-80, CRIT>=80
  const CRIT = (typeof SP_THRESH !== 'undefined') ? SP_THRESH.CRIT : 80;
  const WARN = (typeof SP_THRESH !== 'undefined') ? SP_THRESH.WARN : 70;
  const crit = v.filter(c=>c.pct >= CRIT).length;
  const warn = v.filter(c=>c.pct >= WARN && c.pct < CRIT).length;
  const locs = [...new Set(cabinets.map(c=>c.location))].length;

  // Subscribed ratio: %abs uyari icin (>%200 alarm). Sadece bilgilendirme.
  const overSub = totCap>0 ? (totSubs/totCap*100).toFixed(0) : '0';

  document.getElementById('global-summary').innerHTML = `
    <div class="stat-card gold"><div class="stat-label">Toplam Kapasite</div><div class="stat-value">${(totCap/1024).toFixed(2)}<span class="stat-unit">PB</span></div><div class="stat-sub">${totCap.toFixed(0)} TB</div></div>
    <div class="stat-card blue"><div class="stat-label">Kullanilan</div><div class="stat-value">${(totUsed/1024).toFixed(2)}<span class="stat-unit">PB</span></div><div class="stat-sub">Ort. %${avgPct}</div></div>
    <div class="stat-card green"><div class="stat-label">Bos Alan</div><div class="stat-value">${(totFree/1024).toFixed(2)}<span class="stat-unit">PB</span></div><div class="stat-sub">${totFree.toFixed(0)} TB</div></div>
    <div class="stat-card ${crit>0?'red':(warn>0?'gold':'green')}"><div class="stat-label">Alarm Durumu</div><div class="stat-value">${crit}<span class="stat-unit">kritik</span></div><div class="stat-sub">${warn} uyari &middot; esik %${WARN}/%${CRIT}</div></div>
    <div class="stat-card blue stat-card-click" onclick="applyHostFilter({label:'Tum SVMler'})"><div class="stat-label">Toplam SVM</div><div class="stat-value">${totSvm}</div><div class="stat-sub">${locs} lokasyon &middot; tikla &rarr;</div></div>`;
}

function cabinetCard(c) {
  if (c.error) return `
    <div class="cabinet-card error">
      <div class="card-header"><div><div class="card-name">${c.name}</div><div class="card-ip">${c.location}</div></div><span class="status-badge badge-err">ERROR</span></div>
      <div class="error-overlay">! Baglanti Hatasi</div>
    </div>`;

  const osKeys = Object.keys(c.os);
  const totOS  = osKeys.reduce((s,k)=>s+c.os[k], 0);
  const osBars = osKeys.map(k => `<div class="os-bar-wrap"><div class="os-bar ${osBarMap[k]||'os-linux'}" style="height:${totOS>0?c.os[k]/totOS*100:0}%"></div></div>`).join('');
  const osLegend = osKeys.map(k => {
    const safeK = k.replace(/'/g, "\\'");
    return `<div class="os-legend-item os-legend-clickable" onclick="event.stopPropagation();applyHostFilter({label:'${c.name} - ${k}', cabinet:'${c.name}', os:'${safeK}'})"><div class="os-dot" style="background:${dotColors[(osBarMap[k]||'os-linux').replace('os-','')]}"></div><span>${k}: ${c.os[k]}</span></div>`;
  }).join('');

  const svmCount = c.hostCount;

  // ── AGGREGATE OZETI ──
  // Bu cluster'a ait online aggregate'ler
  const cAggs = aggregates.filter(a => a.cabinet === c.name && a.state === 'online');
  const aggHtml = buildAggSummary(c, cAggs);

  return `
    <div class="${typeof spCabinetClass === 'function' ? spCabinetClass(c.pct) : 'cabinet-card'} cabinet-card-click" onclick="applyHostFilter({label:'${c.name} - Tum SVMler', cabinet:'${c.name}'})">
      <div class="card-header"><div><div class="card-name">${c.name}</div><div class="card-ip">${c.location} · ${c.ip}</div></div>${statusBadge(c.pct)}</div>
      <div class="card-body">
        <div class="cap-row"><span class="cap-label">Doluluk</span><span class="cap-pct" style="color:${pctColor(c.pct)}">%${c.pct}</span></div>
        <div class="bar-track"><div class="bar-fill ${barClass(c.pct)}" style="width:${c.pct}%"></div></div>
        <div class="metrics-row">
          <div class="metric"><div class="metric-val">${fmt(c.total)}</div><div class="metric-lbl">Total</div></div>
          <div class="metric"><div class="metric-val">${fmt(c.used)}</div><div class="metric-lbl">Used</div></div>
          <div class="metric"><div class="metric-val">${fmt(c.subscribed)}</div><div class="metric-lbl">Sub</div></div>
          <div class="metric"><div class="metric-val">${fmt(c.free)}</div><div class="metric-lbl">Free</div></div>
        </div>
        ${aggHtml}
        <div class="os-section">
          <div class="os-title">Protokol Dagılımı · ${svmCount} SVM</div>
          <div class="os-bars">${osBars}</div>
          <div class="os-legend">${osLegend}</div>
        </div>
      </div>
      ${typeof spCabinetFooter === 'function' ? spCabinetFooter({ dr: c.dr, ver: typeof normalizeVersion === 'function' ? normalizeVersion(c.version) : c.version }) : ''}
    </div>`;
}

/* Aggregate ozet bloku - cabinet kartinda kullanilir.
   Onur'un istekleri:
   - Aggregate sayisi + doluluk ozeti (ortalama)
   - En dolu aggregate uyarisi (>80%)
   - Node basina aggregate dagilimi
*/
function buildAggSummary(c, cAggs) {
  if (!cAggs || cAggs.length === 0) {
    return `<div class="agg-section agg-section-empty"><div class="agg-empty">Aggregate verisi yok</div></div>`;
  }

  const CRIT = (typeof SP_THRESH !== 'undefined') ? SP_THRESH.CRIT : 80;
  const WARN = (typeof SP_THRESH !== 'undefined') ? SP_THRESH.WARN : 70;

  const totalA = cAggs.reduce((s,a)=>s+a.total, 0);
  const usedA  = cAggs.reduce((s,a)=>s+a.used,  0);
  const avgPct = totalA>0 ? +(usedA/totalA*100).toFixed(1) : 0;

  // En dolu aggregate
  const sorted = [...cAggs].sort((a,b)=>b.pct - a.pct);
  const top = sorted[0];

  // Kritik/uyari sayilari
  const nCrit = cAggs.filter(a=>a.pct >= CRIT).length;
  const nWarn = cAggs.filter(a=>a.pct >= WARN && a.pct < CRIT).length;

  // Node basina dagilim
  const byNode = {};
  cAggs.forEach(a => {
    if (!byNode[a.node]) byNode[a.node] = { count:0, total:0, used:0 };
    byNode[a.node].count++;
    byNode[a.node].total += a.total;
    byNode[a.node].used  += a.used;
  });
  const nodes = Object.keys(byNode).sort();

  // Uyari satiri: en dolu kritikse goster
  let topAlert = '';
  if (top && top.pct >= CRIT) {
    topAlert = `<div class="agg-alert agg-alert-crit" onclick="event.stopPropagation();switchTab('aggregates');filterAggToCab('${c.name}')">
      ! En dolu: <strong>${esc(top.name)}</strong> %${top.pct}
    </div>`;
  } else if (top && top.pct >= WARN) {
    topAlert = `<div class="agg-alert agg-alert-warn" onclick="event.stopPropagation();switchTab('aggregates');filterAggToCab('${c.name}')">
      En dolu: <strong>${esc(top.name)}</strong> %${top.pct}
    </div>`;
  }

  // Status renk
  const sumColor = avgPct >= CRIT ? 'var(--danger)' : avgPct >= WARN ? 'var(--warn)' : 'var(--accent3)';
  const critBadge = nCrit > 0 ? `<span class="agg-crit-badge">${nCrit}</span>` : '';
  const warnBadge = nWarn > 0 ? `<span class="agg-warn-badge">${nWarn}</span>` : '';

  // Node satirlari
  const nodeRows = nodes.map(n => {
    const nb = byNode[n];
    const nPct = nb.total>0 ? +(nb.used/nb.total*100).toFixed(1) : 0;
    const nColor = nPct >= CRIT ? 'var(--danger)' : nPct >= WARN ? 'var(--warn)' : 'var(--text-dim)';
    return `<div class="agg-node-row">
      <span class="agg-node-name" title="${esc(n)}">${esc(n)}</span>
      <span class="agg-node-stat">${nb.count} agg</span>
      <span class="agg-node-pct" style="color:${nColor}">%${nPct}</span>
    </div>`;
  }).join('');

  return `
    <div class="agg-section">
      <div class="agg-header">
        <span class="agg-title">Aggregate &middot; ${cAggs.length} adet</span>
        <span class="agg-overall" style="color:${sumColor}">ort. %${avgPct} ${critBadge}${warnBadge}</span>
      </div>
      ${topAlert}
      <div class="agg-nodes">${nodeRows}</div>
    </div>`;
}

// Aggregate sekmesine gecip belirli cluster'a filtre uygular
function filterAggToCab(cabName) {
  const sel = document.getElementById('agg-cabinet');
  if (sel) sel.value = cabName;
  renderAggTable();
}

function buildOverview() {
  const locs = [...new Set(cabinets.map(c=>c.location))].sort();
  document.getElementById('location-blocks').innerHTML = locs.map(loc => {
    const lc = cabinets.filter(c=>c.location===loc);
    return `
      <div class="location-block">
        <div class="location-header"><div class="location-tag">${loc}</div><div class="location-line"></div></div>
        <div class="cabinet-grid">${lc.map(c=>cabinetCard(c)).join('')}</div>
      </div>`;
  }).join('');
}

function populateFilters() {
  function fill(id, values) {
    const sel = document.getElementById(id);
    if(!sel) return;
    const first = sel.options[0].outerHTML;
    sel.innerHTML = first;
    [...new Set(values)].filter(v => v).sort().forEach(v => {
      const o = document.createElement('option');
      o.value = v; o.textContent = v;
      sel.appendChild(o);
    });
  }
  fill('host-location', hosts.map(h=>h.location));
  fill('host-cabinet',  hosts.map(h=>h.cabinet));
  fill('lun-location',  lunGroups.map(l=>l.location));
  fill('lun-cabinet',   lunGroups.map(l=>l.cabinet));
  fill('agg-location',  aggregates.map(a=>a.location));
  fill('agg-cabinet',   aggregates.map(a=>a.cabinet));
  fill('agg-node',      aggregates.map(a=>a.node));
}

let hostSort = { col:'host', dir:'asc' };
function renderHostTable() {
  const search = document.getElementById('host-search').value.toLowerCase();
  const loc = document.getElementById('host-location').value;
  const cab = document.getElementById('host-cabinet').value;
  const os = document.getElementById('host-os').value;
  const map = document.getElementById('host-map').value;

  let data = hosts.filter(h =>
    (!search || h.host.toLowerCase().includes(search)) &&
    (!loc || h.location===loc) &&
    (!cab || h.cabinet===cab) &&
    (!os || (h.os||'').includes(os)) &&
    (!map || h.map===map)
  );
  data.sort((a,b) => (hostSort.dir==='asc'?1:-1)*((a[hostSort.col]??'')<(b[hostSort.col]??'')?-1:1));

  const tbody = data.map((h, idx) => {
    const stateOk = h.map === 'Mapped';
    const protocols = h.os || '—';
    return `
    <tr>
      <td>${h.location}</td>
      <td>${h.cabinet}</td>
      <td class="sp-bright-md">${h.host}</td>
      <td style="color:var(--text-dim)">${protocols}</td>
      <td><span class="map-status ${stateOk?'mapped':'unmapped'}">${stateOk?'running':'offline'}</span></td>
    </tr>`;
  }).join('');

  window._renderedHostData = data;
  const summaryHtml = `<span style="font-size:11px;color:var(--text-dim)">${data.length} SVM</span>`;

  document.getElementById('host-table-wrap').innerHTML = `
    <div style="display:flex;align-items:center;justify-content:flex-end;padding:8px 12px;background:var(--surface2);border-bottom:1px solid var(--border);">
      ${summaryHtml}
    </div>
    <table>
      <thead><tr>
        <th onclick="sortHost('location')">Lokasyon</th>
        <th onclick="sortHost('cabinet')">Cluster</th>
        <th onclick="sortHost('host')">SVM</th>
        <th>Protokoller</th>
        <th>Durum</th>
      </tr></thead>
      <tbody>${tbody || '<tr><td colspan="5" style="text-align:center;color:var(--text-dim);padding:20px">Veri yok</td></tr>'}</tbody>
    </table>`;
}

function sortHost(col) { hostSort.dir = hostSort.col===col?(hostSort.dir==='asc'?'desc':'asc'):'asc'; hostSort.col = col; renderHostTable(); }

let lunSort = { col:'capacity', dir:'desc' };
function renderLunTable() {
  const search = document.getElementById('lun-search').value.toLowerCase();
  const loc = document.getElementById('lun-location').value;
  const cab = document.getElementById('lun-cabinet').value;

  let data = lunGroups.filter(l =>
    (!search || l.name.toLowerCase().includes(search) || (l.svm||'').toLowerCase().includes(search)) &&
    (!loc || l.location===loc) &&
    (!cab || l.cabinet===cab)
  );
  data.sort((a,b) => (lunSort.dir==='asc'?1:-1)*(b.capacity - a.capacity));

  const totalCap = data.reduce((s, l) => s + l.capacity, 0);

  const tbody = data.map(l => {
    const typeColor = l.type === 'rw' ? 'var(--accent3)' : l.type === 'dp' ? 'var(--accent2)' : 'var(--text-dim)';
    return `
    <tr>
      <td>${l.location}</td>
      <td>${l.cabinet}</td>
      <td class="sp-dim-sm">${l.svm||'—'}</td>
      <td style="color:var(--text-bright)">${l.name}</td>
      <td style="text-align:right;color:var(--accent2);font-weight:500">${l.capacity.toFixed(3)}</td>
      <td style="color:${typeColor};font-size:10px;text-align:center">${l.type||'rw'}</td>
    </tr>`;
  }).join('');

  document.getElementById('lun-table-wrap').innerHTML = `
    <div style="padding:8px 12px;background:var(--surface2);border-bottom:1px solid var(--border);font-size:11px;color:var(--text-dim);display:flex;justify-content:space-between">
      <span>${data.length} volume</span>
      <span>Toplam: <strong style="color:var(--accent3)">${totalCap.toFixed(2)} TB</strong></span>
    </div>
    <table>
      <thead><tr>
        <th>Lokasyon</th>
        <th>Cluster</th>
        <th>SVM</th>
        <th onclick="lunSort.col='name';lunSort.dir=lunSort.dir==='asc'?'desc':'asc';renderLunTable()">Volume</th>
        <th onclick="lunSort.col='capacity';lunSort.dir=lunSort.dir==='asc'?'desc':'asc';renderLunTable()" style="text-align:right">Boyut (TB)</th>
        <th style="text-align:center">Tip</th>
      </tr></thead>
      <tbody>${tbody || '<tr><td colspan="6" style="text-align:center;color:var(--text-dim);padding:20px">Veri yok</td></tr>'}</tbody>
    </table>`;
}

/* ═══════════════════════════════════════════════
   AGGREGATE TABLE
═══════════════════════════════════════════════ */
let aggSort = { col:'pct', dir:'desc' };
function renderAggTable() {
  const el = document.getElementById('agg-table-wrap');
  if (!el) return;

  const sumEl = document.getElementById('agg-summary');

  if (!aggregates || aggregates.length === 0) {
    if (sumEl) sumEl.innerHTML = '';
    el.innerHTML = typeof spEmptyState === 'function'
      ? spEmptyState({type:'no-data', title:'Aggregate verisi yok',
          message:'NetApp_Aggregate.csv bulunamadi veya bos.',
          hint:'StorageReport.ps1 -OnlyNetApp ile yeni tarama yapilmali (PS1 versiyon 4.x+).'})
      : '<div style="padding:30px;text-align:center;color:var(--text-dim)">NetApp_Aggregate.csv bulunamadi</div>';
    return;
  }

  const CRIT = (typeof SP_THRESH !== 'undefined') ? SP_THRESH.CRIT : 80;
  const WARN = (typeof SP_THRESH !== 'undefined') ? SP_THRESH.WARN : 70;

  // Filtreler
  const search = (document.getElementById('agg-search').value || '').toLowerCase();
  const loc  = document.getElementById('agg-location').value || '';
  const cab  = document.getElementById('agg-cabinet').value  || '';
  const node = document.getElementById('agg-node').value     || '';
  const st   = document.getElementById('agg-state').value    || '';
  const fill = document.getElementById('agg-fill').value     || '';

  let data = aggregates.filter(a =>
    (!search || a.name.toLowerCase().includes(search) || (a.node||'').toLowerCase().includes(search)) &&
    (!loc  || a.location === loc) &&
    (!cab  || a.cabinet  === cab) &&
    (!node || a.node     === node) &&
    (!st   || a.state    === st)
  );
  if (fill === 'crit') data = data.filter(a => a.pct >= CRIT);
  else if (fill === 'warn') data = data.filter(a => a.pct >= WARN && a.pct < CRIT);
  else if (fill === 'ok')   data = data.filter(a => a.pct < WARN);

  data.sort((a,b) => {
    const dir = aggSort.dir === 'asc' ? 1 : -1;
    const va = a[aggSort.col], vb = b[aggSort.col];
    if (typeof va === 'number' && typeof vb === 'number') return dir * (va - vb);
    return dir * (String(va||'') < String(vb||'') ? -1 : 1);
  });

  // Ozet kutucuklari (filtre uygulanmis tum data degil, FILTRE ONCESI tum aggregates)
  const allOnline = aggregates.filter(a => a.state === 'online');
  const totAg     = allOnline.length;
  const totalCap  = allOnline.reduce((s,a)=>s+a.total, 0);
  const totalUsed = allOnline.reduce((s,a)=>s+a.used,  0);
  const avgFill   = totalCap>0 ? +(totalUsed/totalCap*100).toFixed(1) : 0;
  const nCrit     = allOnline.filter(a=>a.pct >= CRIT).length;
  const nWarn     = allOnline.filter(a=>a.pct >= WARN && a.pct < CRIT).length;
  const offlineCt = aggregates.filter(a => a.state !== 'online').length;
  const fillClass = avgFill >= CRIT ? 'crit' : avgFill >= WARN ? 'warn' : 'ok';

  // Tip dagilimi
  const typeBreakdown = {};
  allOnline.forEach(a => { typeBreakdown[a.type] = (typeBreakdown[a.type]||0) + 1; });
  const typeStr = Object.keys(typeBreakdown).sort()
    .map(t => `${t}: ${typeBreakdown[t]}`).join(' &middot; ') || '-';

  if (sumEl) {
    sumEl.innerHTML = `
      <div class="agg-stat-card">
        <div class="agg-stat-label">Toplam Aggregate</div>
        <div class="agg-stat-val">${totAg}</div>
        <div class="agg-stat-sub">${offlineCt > 0 ? offlineCt + ' offline' : 'tumu online'}</div>
      </div>
      <div class="agg-stat-card ${fillClass}">
        <div class="agg-stat-label">Ortalama Doluluk</div>
        <div class="agg-stat-val">%${avgFill}</div>
        <div class="agg-stat-sub">${(totalUsed/1024).toFixed(2)} / ${(totalCap/1024).toFixed(2)} PB</div>
      </div>
      <div class="agg-stat-card ${nCrit>0?'crit':(nWarn>0?'warn':'ok')}">
        <div class="agg-stat-label">Kritik / Uyari</div>
        <div class="agg-stat-val">${nCrit} <span style="font-size:13px;color:var(--text-dim)">/ ${nWarn}</span></div>
        <div class="agg-stat-sub">esik %${WARN} / %${CRIT}</div>
      </div>
      <div class="agg-stat-card">
        <div class="agg-stat-label">Tip Dagilimi</div>
        <div class="agg-stat-val" style="font-size:14px;font-family:'JetBrains Mono',monospace">${typeStr}</div>
        <div class="agg-stat-sub">disk class</div>
      </div>`;
  }

  // Tablo
  const sortable = (col, label, align) => {
    const arrow = aggSort.col === col ? (aggSort.dir === 'asc' ? ' ▲' : ' ▼') : '';
    const style = align ? `style="text-align:${align}"` : '';
    return `<th ${style} onclick="aggSort.col='${col}';aggSort.dir=aggSort.dir==='asc'?'desc':'asc';renderAggTable()">${label}${arrow}</th>`;
  };

  const typeClass = (t) => {
    const known = ['SSD','NVMe','SAS','SATA','HDD'];
    return known.indexOf(t) >= 0 ? 'agg-type-' + t : 'agg-type-na';
  };

  const rows = data.map(a => {
    const pctColor = a.pct >= CRIT ? 'var(--danger)' : a.pct >= WARN ? 'var(--warn)' : 'var(--accent3)';
    const stColor  = a.state === 'online' ? 'var(--accent3)' : a.state === 'restricted' ? 'var(--warn)' : 'var(--danger)';
    const rowCls   = a.pct >= CRIT ? ' class="sp-row-crit"' : '';
    return `<tr${rowCls}>
      <td class="sp-dim-sm">${esc(a.location)}</td>
      <td class="sp-dim-sm">${esc(a.cabinet)}</td>
      <td class="sp-bright-md">${esc(a.name)}</td>
      <td style="color:var(--text-dim)">${esc(a.node)}</td>
      <td><span class="agg-type-pill ${typeClass(a.type)}">${esc(a.type)}</span></td>
      <td style="text-align:right">${a.total.toFixed(2)}</td>
      <td style="text-align:right">${a.used.toFixed(2)}</td>
      <td style="text-align:right">${a.free.toFixed(2)}</td>
      <td style="text-align:right;color:${pctColor};font-weight:500">%${a.pct}</td>
      <td style="text-align:center;color:var(--accent)">${esc(a.dr)}</td>
      <td><span style="color:${stColor};font-size:10px;text-transform:uppercase;letter-spacing:1px">${esc(a.state)}</span></td>
    </tr>`;
  }).join('');

  el.innerHTML = `
    <div style="padding:8px 12px;background:var(--surface2);border-bottom:1px solid var(--border);font-size:11px;color:var(--text-dim);display:flex;justify-content:space-between">
      <span>${data.length} aggregate ${data.length !== aggregates.length ? '(' + aggregates.length + ' toplam)' : ''}</span>
      <span>filtre: ${[loc, cab, node, st, fill].filter(Boolean).join(' &middot; ') || 'yok'}</span>
    </div>
    <table>
      <thead><tr>
        ${sortable('location','Lokasyon')}
        ${sortable('cabinet','Cluster')}
        ${sortable('name','Aggregate')}
        ${sortable('node','Node')}
        <th>Tip</th>
        ${sortable('total','Total (TB)','right')}
        ${sortable('used','Used (TB)','right')}
        ${sortable('free','Free (TB)','right')}
        ${sortable('pct','Doluluk','right')}
        <th style="text-align:center">DR</th>
        ${sortable('state','Durum')}
      </tr></thead>
      <tbody>${rows || '<tr><td colspan="11" style="text-align:center;color:var(--text-dim);padding:20px">Filtre ile esleseyen aggregate yok</td></tr>'}</tbody>
    </table>`;
}

function switchTab(name) {
  document.querySelectorAll('.tab-btn').forEach(b=>b.classList.toggle('active', b.getAttribute('onclick').includes(name)));
  document.querySelectorAll('.tab-panel').forEach(p=>p.classList.remove('active'));
  document.getElementById('tab-'+name).classList.add('active');
}

function applyHostFilter(opts) {
  document.getElementById('host-search').value   = opts.search   || '';
  document.getElementById('host-location').value = opts.location || '';
  document.getElementById('host-cabinet').value  = opts.cabinet  || '';
  document.getElementById('host-os').value       = opts.os       || '';
  document.getElementById('host-map').value      = opts.map      || '';
  
  renderHostFilterChips(opts);
  switchTab('hosts');
  renderHostTable();
  window.scrollTo({ top: 200, behavior: 'smooth' });
}

function renderHostFilterChips(opts) {
  const box = document.getElementById('hostFilterChips');
  if (!box) return;
  const chips = [];
  if (opts.label)    chips.push({ key:'label', val:opts.label });
  if (opts.location) chips.push({ key:'Lokasyon', val:opts.location });
  if (opts.cabinet)  chips.push({ key:'Kabinet',  val:opts.cabinet  });
  if (opts.os)       chips.push({ key:'OS',       val:opts.os       });
  if (opts.map)      chips.push({ key:'Durum',    val:opts.map      });
  
  if (chips.length === 0) {
    box.innerHTML = ''; box.style.display = 'none';
    return;
  }
  box.style.display = 'flex';
  box.innerHTML = chips.map(c =>
    `<span class="filter-chip">${c.key === 'label' ? `<strong>${c.val}</strong>` : `${c.key}: <strong>${c.val}</strong>`}</span>`
  ).join('') + `<button class="filter-chip-clear" onclick="clearHostFilters()">Temizle</button>`;
}

function clearHostFilters() {
  document.getElementById('host-search').value   = '';
  document.getElementById('host-location').value = '';
  document.getElementById('host-cabinet').value  = '';
  document.getElementById('host-os').value       = '';
  document.getElementById('host-map').value      = '';
  renderHostFilterChips({});
  renderHostTable();
}

/* ═══════════════════════════════════════════════
   NETAPP SNAPSHOT POLICY
═══════════════════════════════════════════════ */
const CSV_NA_SNAP = './NetApp/NetApp_SnapPolicy.csv';
let naSnapData = [];

async function loadNaSnap() {
  try {
    const r = await fetch(CSV_NA_SNAP, {cache:'no-store'});
    if (!r.ok) return;
    const text = await r.text();
    naSnapData = parseCSV(text).filter(r => (r['Policy Adi']||'').trim() !== '').map(r => ({
      lokasyon: r['Lokasyon']   || '',
      kabinet:  r['Kabinet']    || '',
      policy:   r['Policy Adi'] || '',
      volume:   r['LUN / Obje'] || '',
      svm:      r['Host']       || '',
      periyot:  r['Periyot']    || '-',
      saklama:  r['Saklama']    || '-',
    }));
  } catch(e) { console.error("Snapshot verisi yuklenemedi", e); }
}

function esc(str) {
  if(!str) return '';
  return String(str).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}

function renderNaSnap() {
  const el = document.getElementById('na-snap-table-wrap');
  if (!el) return;
  if (naSnapData.length === 0) {
    document.getElementById('na-snap-summary').innerHTML = '';
    el.innerHTML = typeof spEmptyState === 'function' ? spEmptyState({type:'no-data',title:'Veri henüz hazır değil',message:'NetApp ONTAP taraması yapıldıktan sonra burada görünecek.',hint:'StorageReport.ps1 -OnlyNetApp'}) : 'Veri yok';
    return;
  }
  const search = (document.getElementById('na-snap-search').value || '').toLowerCase();
  const cabF   =  document.getElementById('na-snap-cab').value    || '';
  const svmF   =  document.getElementById('na-snap-svm').value    || '';

  const cabs = [...new Set(naSnapData.map(r => r.kabinet).filter(Boolean))].sort();
  const svms = [...new Set(naSnapData.map(r => r.svm).filter(Boolean))].sort();
  const cabSel = document.getElementById('na-snap-cab');
  const svmSel = document.getElementById('na-snap-svm');
  const curC = cabSel.value, curS = svmSel.value;
  cabSel.innerHTML = '<option value="">Tüm Clusterlar</option>' + cabs.map(c=>`<option value="${esc(c)}">${esc(c)}</option>`).join('');
  svmSel.innerHTML = '<option value="">Tüm SVMler</option>'    + svms.map(s=>`<option value="${esc(s)}">${esc(s)}</option>`).join('');
  if (curC) cabSel.value = curC;
  if (curS) svmSel.value = curS;

  let data = naSnapData.filter(r =>
    (!search || r.policy.toLowerCase().includes(search) || r.volume.toLowerCase().includes(search) || r.svm.toLowerCase().includes(search)) &&
    (!cabF || r.kabinet === cabF) &&
    (!svmF || r.svm === svmF)
  );

  const uniqPolicies = new Set(data.map(r => r.policy)).size;
  const uniqSvms     = new Set(data.map(r => r.svm).filter(Boolean)).size;

  document.getElementById('na-snap-summary').innerHTML = `
    <div style="background:var(--surface2);border:1px solid var(--border);border-left:3px solid var(--accent2);padding:12px 16px">
      <div style="font-size:9px;letter-spacing:2px;text-transform:uppercase;color:var(--text-dim);margin-bottom:6px">Toplam Policy</div>
      <div style="font-family:'Syne',sans-serif;font-size:24px;font-weight:800;color:var(--text-bright)">${uniqPolicies}</div>
      <div style="font-size:10px;color:var(--text-dim);margin-top:3px">${data.length} volume ataması</div>
    </div>
    <div style="background:var(--surface2);border:1px solid var(--border);border-left:3px solid var(--accent3);padding:12px 16px">
      <div style="font-size:9px;letter-spacing:2px;text-transform:uppercase;color:var(--text-dim);margin-bottom:6px">Volume Sayısı</div>
      <div style="font-family:'Syne',sans-serif;font-size:24px;font-weight:800;color:var(--text-bright)">${data.length}</div>
    </div>
    <div style="background:var(--surface2);border:1px solid var(--border);border-left:3px solid var(--accent);padding:12px 16px">
      <div style="font-size:9px;letter-spacing:2px;text-transform:uppercase;color:var(--text-dim);margin-bottom:6px">SVM Sayısı</div>
      <div style="font-family:'Syne',sans-serif;font-size:24px;font-weight:800;color:var(--text-bright)">${uniqSvms}</div>
    </div>`;

  const rows = data.map(r => `<tr>
    <td class="sp-dim-sm">${esc(r.kabinet)}</td>
    <td class="sp-bright-md">${esc(r.policy)}</td>
    <td style="color:var(--accent2)">${esc(r.volume)}</td>
    <td style="color:var(--text-dim)">${esc(r.svm)}</td>
    <td style="color:var(--accent);font-weight:500">${esc(r.periyot)}</td>
    <td style="color:var(--accent3)">${esc(r.saklama)}</td>
  </tr>`).join('');

  el.innerHTML = `<div style="padding:8px 12px;background:var(--surface2);border-bottom:1px solid var(--border);font-size:11px;color:var(--text-dim)">${data.length} kayıt</div>
  <table><thead><tr>
    <th>Cluster</th><th>Policy Adı</th><th>Volume</th><th>SVM</th><th>Periyot</th><th>Saklama</th>
  </tr></thead><tbody>${rows}</tbody></table>`;
}

/* ═══════════════════════════════════════════════
   NETAPP METROCLUSTER
═══════════════════════════════════════════════ */
const CSV_NA_MC = './NetApp/NetApp_MetroCluster.csv';
let mcData    = [];
let mcSubView = 'nodes';

async function loadMc() {
  try {
    const r = await fetch(CSV_NA_MC, {cache:'no-store'});
    if (!r.ok) return;
    const text = await r.text();
    mcData = parseCSV(text).filter(r => (r['Tip']||'').trim() !== '');
  } catch(e) { console.error("MetroCluster verisi yuklenemedi", e); }
}

function mcSubTab(view) {
  mcSubView = view;
  ['nodes','vols','repl'].forEach(v => {
    const btn = document.getElementById('mc-tab-'+v);
    if(btn) btn.classList.toggle('active', v === view);
  });
  renderMc();
}

function renderMc() {
  const el = document.getElementById('mc-table-wrap');
  if (!el) return;

  if (mcData.length === 0) {
    document.getElementById('mc-cluster-info').innerHTML = '';
    el.innerHTML = typeof spEmptyState === 'function' ? spEmptyState({type:'no-data',title:'MetroCluster yapılandırması yok',message:'Bu cluster MetroCluster modunda değil ya da tarama henüz yapılmadı.',hint:'StorageReport.ps1 -OnlyNetApp'}) : 'Yapılandırma Yok';
    return;
  }

  const search = (document.getElementById('mc-search').value || '').toLowerCase();
  const cabF   =  document.getElementById('mc-cab').value    || '';

  const cabs = [...new Set(mcData.map(r => r['Kabinet']).filter(Boolean))].sort();
  const cabSel = document.getElementById('mc-cab');
  const cur = cabSel.value;
  cabSel.innerHTML = '<option value="">Tüm Clusterlar</option>' + cabs.map(c=>`<option value="${esc(c)}">${esc(c)}</option>`).join('');
  if (cur) cabSel.value = cur;

  const nodeRows = mcData.filter(r => r['Tip'] === 'Node' && (!cabF || r['Kabinet'] === cabF));
  if (nodeRows.length > 0) {
    const n0 = nodeRows[0];
    const modeTR  = n0['MC Modu']   || '—';
    const stateTR = n0['MC Durumu'] || '—';
    const partReach = n0['Partner Erisim'] || '—';
    const modeColor = modeTR === 'Normal' ? 'var(--accent3)' : modeTR.includes('Switchover') ? 'var(--danger)' : 'var(--warn)';
    const reachColor = partReach === 'Ulasilabilir' ? 'var(--accent3)' : 'var(--danger)';

    document.getElementById('mc-cluster-info').innerHTML = `
      <div style="display:grid;grid-template-columns:repeat(3,1fr);gap:12px;margin-bottom:4px">
        <div style="background:var(--surface2);border:1px solid var(--border);border-left:3px solid ${modeColor};padding:12px 16px">
          <div style="font-size:9px;letter-spacing:2px;text-transform:uppercase;color:var(--text-dim);margin-bottom:6px">MC Modu</div>
          <div style="font-family:'Syne',sans-serif;font-size:18px;font-weight:800;color:${modeColor}">${esc(modeTR)}</div>
        </div>
        <div style="background:var(--surface2);border:1px solid var(--border);border-left:3px solid var(--accent2);padding:12px 16px">
          <div style="font-size:9px;letter-spacing:2px;text-transform:uppercase;color:var(--text-dim);margin-bottom:6px">MC Durumu</div>
          <div style="font-family:'Syne',sans-serif;font-size:18px;font-weight:800;color:var(--accent2)">${esc(stateTR)}</div>
        </div>
        <div style="background:var(--surface2);border:1px solid var(--border);border-left:3px solid ${reachColor};padding:12px 16px">
          <div style="font-size:9px;letter-spacing:2px;text-transform:uppercase;color:var(--text-dim);margin-bottom:6px">Partner Erişim</div>
          <div style="font-family:'Syne',sans-serif;font-size:18px;font-weight:800;color:${reachColor}">${esc(partReach)}</div>
        </div>
      </div>`;
  } else {
    document.getElementById('mc-cluster-info').innerHTML = '';
  }

  const tipMap = { nodes:'Node', vols:'Volume', repl:'Replication' };
  const tipF   = tipMap[mcSubView];

  let data = mcData.filter(r =>
    r['Tip'] === tipF &&
    (!cabF || r['Kabinet'] === cabF) &&
    (!search || Object.values(r).some(v => String(v||'').toLowerCase().includes(search)))
  );

  if (data.length === 0) {
    el.innerHTML = '<div class="sp-empty">Bu görünümde veri yok</div>';
    return;
  }

  let tableHtml = '';

  if (mcSubView === 'nodes') {
    const rows = data.map(r => {
      const sc = r['Node Durumu'] === 'Normal' ? 'var(--accent3)' : 'var(--warn)';
      return `<tr>
        <td class="sp-dim-sm">${esc(r['Kabinet'])}</td>
        <td class="sp-bright-md">${esc(r['Node'])}</td>
        <td><span style="color:${sc};font-size:10px">${esc(r['Node Durumu'])}</span></td>
        <td style="color:var(--text-dim)">${esc(r['DR Group'])}</td>
        <td style="color:var(--accent2)">${esc(r['DR Partner'])}</td>
        <td style="color:var(--text-dim)">${esc(r['HA Partner'])}</td>
        <td style="color:var(--accent);font-size:10px">${esc(r['Partner Cluster'])}</td>
      </tr>`;
    }).join('');
    tableHtml = `<table><thead><tr>
      <th>Cluster</th><th>Node</th><th>Durum</th><th>DR Group</th>
      <th>DR Partner</th><th>HA Partner</th><th>Partner Cluster</th>
    </tr></thead><tbody>${rows}</tbody></table>`;
  }

  else if (mcSubView === 'vols') {
    const rows = data.map(r => {
      const sc = r['MC Durumu'] === 'Korunan' ? 'var(--accent3)' : 'var(--danger)';
      return `<tr>
        <td class="sp-dim-sm">${esc(r['Kabinet'])}</td>
        <td class="sp-bright-md">${esc(r['Volume']||'')}</td>
        <td style="color:var(--accent2)">${esc(r['Node'])}</td>
        <td><span style="color:${sc};font-size:10px">${esc(r['MC Durumu'])}</span></td>
        <td class="sp-dim-sm">${esc(r['DR Group'])}</td>
      </tr>`;
    }).join('');
    tableHtml = `<table><thead><tr>
      <th>Cluster</th><th>Volume</th><th>SVM</th><th>MC Durumu</th><th>DR Group</th>
    </tr></thead><tbody>${rows}</tbody></table>`;
  }

  else if (mcSubView === 'repl') {
    const rows = data.map(r => {
      const sc = r['MC Durumu'] === 'Mirrorlandi' || r['MC Durumu'] === 'Eslesik'
        ? 'var(--accent3)' : r['MC Durumu'] === 'Sagliksiz' || r['MC Durumu'] === 'Kesildi'
        ? 'var(--danger)' : 'var(--warn)';
      const hc = r['Partner Erisim'] === 'Saglikli' ? 'var(--accent3)' : r['Partner Erisim'] === 'Sagliksiz' ? 'var(--danger)' : 'var(--text-dim)';
      const lagWarn = r['DR Group'] && (r['DR Group'].includes('saat') || r['DR Group'].includes('gun'));
      return `<tr>
        <td class="sp-dim-sm">${esc(r['Kabinet'])}</td>
        <td style="color:var(--text-bright);font-weight:500;font-size:10px">${esc(r['Node'])}</td>
        <td style="color:var(--accent2);font-size:10px">${esc(r['Node Durumu'])}</td>
        <td><span style="color:${sc};font-size:10px">${esc(r['MC Durumu'])}</span></td>
        <td><span style="color:${hc};font-size:10px">${esc(r['Partner Erisim'])}</span></td>
        <td style="color:${lagWarn?'var(--warn)':'var(--text-dim)'}">${esc(r['DR Group'])||'—'}</td>
      </tr>`;
    }).join('');
    tableHtml = `<table><thead><tr>
      <th>Cluster</th><th>Kaynak</th><th>Hedef</th>
      <th>Durum</th><th>Sağlık</th><th>Gecikme (Lag)</th>
    </tr></thead><tbody>${rows}</tbody></table>`;
  }

  el.innerHTML = `
    <div style="padding:8px 12px;background:var(--surface2);border-bottom:1px solid var(--border);font-size:11px;color:var(--text-dim)">${data.length} kayıt</div>
    ${tableHtml}`;
}

loadCSVs();

if (typeof renderFreshnessBadge === 'function') {
  renderFreshnessBadge('data-fresh-badge', ['./NetApp/NetApp_Dashboard.csv', './NetApp/NetApp_Volume.csv']);
}
</script>
</body>
</html>