// OpenWrt luci-core uses this hash (from lmo.c):
function lmo_hash(s) {
  let h = 0;
  for (let i = 0; i < s.length; i++) {
    h += s.charCodeAt(i);
    h = (h + (h << 10)) >>> 0;
    h ^= h >>> 6;
  }
  h = (h + (h << 3)) >>> 0;
  h ^= h >>> 11;
  h = (h + (h << 15)) >>> 0;
  return h >>> 0;
}
// Reference: entry 1 keyId=0x1545b51f
console.log('lmo_hash(Client):', lmo_hash('Client').toString(16), '(target: 1545b51f)');
console.log('lmo_hash(Download):', lmo_hash('Download').toString(16));
console.log('lmo_hash(Save):', lmo_hash('Save').toString(16));
console.log('lmo_hash(Action):', lmo_hash('Action').toString(16));
console.log('lmo_hash(Enabled):', lmo_hash('Enabled').toString(16));
console.log('lmo_hash(General):', lmo_hash('General').toString(16));
console.log('lmo_hash(Email):', lmo_hash('Email').toString(16));
console.log('lmo_hash(Subject):', lmo_hash('Subject').toString(16));
console.log('lmo_hash(Enable detailed logs):', lmo_hash('Enable detailed logs').toString(16));
console.log('lmo_hash(Enable):', lmo_hash('Enable').toString(16));
console.log('lmo_hash(Close):', lmo_hash('Close').toString(16));
console.log('lmo_hash(Save & Apply):', lmo_hash('Save & Apply').toString(16));
