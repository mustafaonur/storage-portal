// asset-inventory.js — QNB/Enpara Dell Kontrat Envanteri
// Data source: asset-inventory.json (externalized for config-driven updates)
// Computes contractStatus and daysLeft on each asset so management.html can use them.

let ASSET_INVENTORY = [];
let _assetInventoryReady = false;
let _assetInventoryPromise = null;

function _computeContractFields(assets) {
  const now = new Date();
  return assets.map(a => {
    const end  = a.contractEnd ? new Date(a.contractEnd) : null;
    const days = end ? Math.round((end - now) / 86400000) : null;
    let status = 'ok';
    if (days === null)   status = 'ok';
    else if (days < 0)  status = 'expired';
    else if (days < 90) status = 'critical';
    else if (days < 180) status = 'warning';
    return { ...a, daysLeft: days, contractStatus: status };
  });
}

_assetInventoryPromise = (async function loadAssetInventory() {
  try {
    const r = await fetch('./asset-inventory.json', { cache: 'no-store' });
    if (r.ok) {
      const raw = await r.json();
      ASSET_INVENTORY = _computeContractFields(raw);
    }
  } catch (e) {
    console.warn('[asset-inventory] Could not load asset-inventory.json:', e.message);
  }
  _assetInventoryReady = true;
  // Dispatch event so listeners can react
  document.dispatchEvent(new CustomEvent('assetInventoryReady'));
})();
