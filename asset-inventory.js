// asset-inventory.js — QNB/Enpara Dell Kontrat Envanteri
// Data source: asset-inventory.json (externalized from JS for config-driven updates)
// Do not hardcode assets here; edit asset-inventory.json instead.

let ASSET_INVENTORY = [];

(async function loadAssetInventory() {
  try {
    const r = await fetch('./asset-inventory.json', { cache: 'no-store' });
    if (r.ok) {
      ASSET_INVENTORY = await r.json();
    }
  } catch (e) {
    console.warn('[asset-inventory] Could not load asset-inventory.json:', e.message);
  }
})();
