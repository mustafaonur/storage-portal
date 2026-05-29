// ============================================================
// asset-inventory.js  —  QNB/Enpara Dell Kontrat Envanteri
// Kaynak: QNB-ENPARA_Contracted_Asset_List.xlsx
// Son güncelleme: 2026-05-25
// Kapsam: Sadece QNB ile başlayan lokasyonlar (30 asset)
// ============================================================

const ASSET_INVENTORY = [
  { assetId:"BRCFME1910W014", productName:"Connectrix DS-7720B",               location:"Istanbul", locationRaw:"QNB KRİSTAL KULE", category:"Brocade",  contractEnd:"2028-07-29" },
  { assetId:"BRCFME1910W010", productName:"Connectrix DS-7720B",               location:"Istanbul", locationRaw:"QNB KRİSTAL KULE", category:"Brocade",  contractEnd:"2028-07-29" },
  { assetId:"CKM01232405562", productName:"ECS Appliance Hardware Gen3 EX500", location:"Istanbul", locationRaw:"QNB ISTANBUL",      category:"ECS",      contractEnd:"2026-09-19" },
  { assetId:"CK297600649",    productName:"PowerMax 8000",                     location:"Istanbul", locationRaw:"QNB ISTANBUL",      category:"PowerMax", contractEnd:"2026-12-31" },
  { assetId:"CK297600631",    productName:"PowerMax 8000",                     location:"Istanbul", locationRaw:"QNB ISTANBUL",      category:"PowerMax", contractEnd:"2027-01-07" },
  { assetId:"CK297600630",    productName:"PowerMax 8000",                     location:"Istanbul", locationRaw:"QNB ISTANBUL",      category:"PowerMax", contractEnd:"2027-01-07" },
  { assetId:"CK297600629",    productName:"PowerMax 8000",                     location:"Istanbul", locationRaw:"QNB ISTANBUL",      category:"PowerMax", contractEnd:"2027-01-07" },
  { assetId:"BRCFME2107R001", productName:"Connectrix DS-7720B",               location:"Istanbul", locationRaw:"QNB ISTANBUL",      category:"Brocade",  contractEnd:"2026-12-31" },
  { assetId:"BRCFME2107R002", productName:"Connectrix DS-7720B",               location:"Istanbul", locationRaw:"QNB ISTANBUL",      category:"Brocade",  contractEnd:"2026-12-31" },
  { assetId:"BRCFME2107R003", productName:"Connectrix DS-7720B",               location:"Istanbul", locationRaw:"QNB ISTANBUL",      category:"Brocade",  contractEnd:"2026-12-31" },
  { assetId:"BRCFME2107R004", productName:"Connectrix DS-7720B",               location:"Istanbul", locationRaw:"QNB ISTANBUL",      category:"Brocade",  contractEnd:"2026-12-31" },
  { assetId:"BRCFME2107R005", productName:"Connectrix DS-7720B",               location:"Istanbul", locationRaw:"QNB ISTANBUL",      category:"Brocade",  contractEnd:"2026-12-31" },
  { assetId:"BRCFME2107R006", productName:"Connectrix DS-7720B",               location:"Istanbul", locationRaw:"QNB ISTANBUL",      category:"Brocade",  contractEnd:"2026-12-31" },
  { assetId:"CKM01232405563", productName:"ECS Appliance Hardware Gen3 EX500", location:"Ankara",   locationRaw:"QNB ANKARA",        category:"ECS",      contractEnd:"2026-09-19" },
  { assetId:"BRCFME2003P001", productName:"Connectrix DS-7720B",               location:"Ankara",   locationRaw:"QNB ANKARA",        category:"Brocade",  contractEnd:"2027-05-15" },
  { assetId:"BRCFME2003P002", productName:"Connectrix DS-7720B",               location:"Ankara",   locationRaw:"QNB ANKARA",        category:"Brocade",  contractEnd:"2027-05-15" },
  { assetId:"BRCFME2003P003", productName:"Connectrix DS-7720B",               location:"Ankara",   locationRaw:"QNB ANKARA",        category:"Brocade",  contractEnd:"2027-05-15" },
  { assetId:"BRCFME2003P004", productName:"Connectrix DS-7720B",               location:"Ankara",   locationRaw:"QNB ANKARA",        category:"Brocade",  contractEnd:"2027-05-15" },
  { assetId:"ANK-PMAX-001",   productName:"PowerMax 8000",                     location:"Ankara",   locationRaw:"QNB ANKARA",        category:"PowerMax", contractEnd:"2027-01-07" },
  { assetId:"ANK-PMAX-002",   productName:"PowerMax 8000",                     location:"Ankara",   locationRaw:"QNB ANKARA",        category:"PowerMax", contractEnd:"2027-01-07" },
  { assetId:"KOS-PMAX-001",   productName:"PowerMax 8000",                     location:"Kos",      locationRaw:"QNB KOS",           category:"PowerMax", contractEnd:"2027-06-30" },
  { assetId:"BRCFME2106K001", productName:"Connectrix DS-7720B",               location:"Kos",      locationRaw:"QNB KOS",           category:"Brocade",  contractEnd:"2027-06-30" },
  { assetId:"KK-BROCADE-001", productName:"Connectrix DS-7720B",               location:"Istanbul", locationRaw:"QNB KRİSTAL KULE", category:"Brocade",  contractEnd:"2028-07-29" },
  { assetId:"KK-BROCADE-002", productName:"Connectrix DS-7720B",               location:"Istanbul", locationRaw:"QNB KRİSTAL KULE", category:"Brocade",  contractEnd:"2028-07-29" },
  { assetId:"PURE-FA-001",    productName:"FlashArray //X70",                  location:"Istanbul", locationRaw:"QNB ISTANBUL",      category:"Pure FA",  contractEnd:"2027-09-30" },
  { assetId:"PURE-FA-002",    productName:"FlashArray //X70",                  location:"Istanbul", locationRaw:"QNB ISTANBUL",      category:"Pure FA",  contractEnd:"2027-09-30" },
  { assetId:"PURE-FA-003",    productName:"FlashArray //X70",                  location:"Istanbul", locationRaw:"QNB ISTANBUL",      category:"Pure FA",  contractEnd:"2027-09-30" },
  { assetId:"PURE-FB-001",    productName:"FlashBlade //S200",                 location:"Istanbul", locationRaw:"QNB ISTANBUL",      category:"Pure FB",  contractEnd:"2027-12-31" },
  { assetId:"PURE-FB-002",    productName:"FlashBlade //S200",                 location:"Ankara",   locationRaw:"QNB ANKARA",        category:"Pure FB",  contractEnd:"2027-12-31" },
  { assetId:"NETAPP-001",     productName:"AFF A400",                          location:"Istanbul", locationRaw:"QNB ISTANBUL",      category:"NetApp",   contractEnd:"2028-03-31" },
];

// Compute daysLeft and contractStatus dynamically on load
(function() {
  const today = new Date();
  today.setHours(0,0,0,0);
  ASSET_INVENTORY.forEach(a => {
    const end = new Date(a.contractEnd);
    a.daysLeft = Math.round((end - today) / 86400000);
    a.contractStatus = a.daysLeft < 0 ? 'expired'
      : a.daysLeft < 180 ? 'critical'
      : a.daysLeft < 365 ? 'warning'
      : 'ok';
  });
})();
