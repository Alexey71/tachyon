const fs = require('fs');

function sfh_get16(d, off) {
  return (d[off] & 0xff) + ((d[off + 1] & 0xff) << 8);
}

function sfh_hash(str) {
  const data = Buffer.from(str, 'utf8');
  const len = data.length;
  if (len <= 0) return 0;
  let hash = len;
  let rem = len & 3;
  let offset = 0;
  const words = len >> 2;
  for (let i = 0; i < words; i++) {
    hash += sfh_get16(data, offset);
    let tmp = (sfh_get16(data, offset + 2) << 11) ^ hash;
    hash = (hash << 16) ^ tmp;
    offset += 4;
    hash += hash >>> 11;
  }
  switch (rem) {
    case 3:
      hash += sfh_get16(data, offset);
      hash ^= hash << 16;
      hash ^= data[offset + 2] << 18;
      hash += hash >>> 11;
      break;
    case 2:
      hash += sfh_get16(data, offset);
      hash ^= hash << 11;
      hash += hash >>> 17;
      break;
    case 1:
      hash += data[offset];
      hash ^= hash << 10;
      hash += hash >>> 1;
  }
  hash ^= hash << 3;
  hash += hash >>> 5;
  hash ^= hash << 4;
  hash += hash >>> 17;
  hash ^= hash << 25;
  hash += hash >>> 6;
  return hash >>> 0;
}

// Reference: adblock.bg.lmo entry 1 keyId=0x1545b51f
// msgid for "Клиент" in adblock bg is likely "Client"
console.log('sfh_hash(Client):', sfh_hash('Client').toString(16), '(target: 1545b51f)');
console.log('sfh_hash(Save):', sfh_hash('Save').toString(16));
console.log('sfh_hash(Close):', sfh_hash('Close').toString(16));
console.log('sfh_hash(Enable):', sfh_hash('Enable').toString(16));
console.log('sfh_hash(Enabled):', sfh_hash('Enabled').toString(16));
console.log('sfh_hash(General settings):', sfh_hash('General settings').toString(16));
console.log('sfh_hash(Action):', sfh_hash('Action').toString(16));
console.log('sfh_hash(Download):', sfh_hash('Download').toString(16));
console.log('sfh_hash(Email):', sfh_hash('Email').toString(16));
console.log('sfh_hash(Subject):', sfh_hash('Subject').toString(16));
console.log('sfh_hash(Enable detailed logs):', sfh_hash('Enable detailed logs').toString(16));
console.log('sfh_hash(Save & Apply):', sfh_hash('Save & Apply').toString(16));

// Now test with some of our tachyon strings
console.log('\nTachyon strings:');
console.log('sfh_hash(Periodically checks if the proxy is responding. Restarts Tachyon after consecutive failures.):', sfh_hash('Periodically checks if the proxy is responding. Restarts Tachyon after consecutive failures.').toString(16));
console.log('sfh_hash(Enable Proxy Health Monitor):', sfh_hash('Enable Proxy Health Monitor').toString(16));
