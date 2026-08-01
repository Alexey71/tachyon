const fs = require('fs');

// LuCI uses this specific SuperFastHash from OpenWrt
// Let me try to match it against the reference lmo
// adblock.bg.lmo entry 1: keyId=0x1545b51f
// We need to know what string produces this hash

// Try the OpenWrt luci sfh_hash
function luci_sfh_hash(data) {
  let hash = 0;
  const len = data.length;
  let i;
  for (i = 0; i < len; i++) {
    hash += data.charCodeAt(i);
    hash = (hash << 10) + hash;
    hash ^= hash >>> 6;
  }
  hash += hash << 3;
  hash ^= hash >>> 11;
  hash += hash << 15;
  return hash >>> 0;
}

console.log('luci_sfh empty:', luci_sfh_hash('').toString(16));
console.log('luci_sfh Plural-Forms:', luci_sfh_hash('Plural-Forms').toString(16));

// Now check my po2lmo sfh_hash
function po2lmo_sfh(data) {
  let hash = 0;
  let i = data.length;
  let k;
  while (i >= 4) {
    k = (data.charCodeAt(i - 4) & 0xff) |
        ((data.charCodeAt(i - 3) & 0xff) << 8) |
        ((data.charCodeAt(i - 2) & 0xff) << 16) |
        ((data.charCodeAt(i - 1) & 0xff) << 24);
    k = Math.imul(k, 0x5bd1e995);
    k = k >>> 0;
    k ^= k >>> 24;
    k = Math.imul(k, 0x5bd1e995);
    k = k >>> 0;
    hash = Math.imul(hash, 0x5bd1e995) + k;
    hash = hash >>> 0;
    i -= 4;
  }
  switch (i) {
    case 3: hash ^= (data.charCodeAt(0) & 0xff) << 16;
    case 2: hash ^= (data.charCodeAt(i - 2) & 0xff) << 8;
    case 1: hash ^= (data.charCodeAt(i - 1) & 0xff);
            hash = Math.imul(hash, 0x5bd1e995);
            hash = hash >>> 0;
  }
  hash ^= hash >>> 13;
  hash = Math.imul(hash, 0x5bd1e995);
  hash = hash >>> 0;
  hash ^= hash >>> 15;
  return hash >>> 0;
}

console.log('po2lmo_sfh empty:', po2lmo_sfh('').toString(16));
console.log('po2lmo_sfh Plural-Forms:', po2lmo_sfh('Plural-Forms').toString(16));

// Read the reference LMO
const buf = fs.readFileSync('tools/test_ref.lmo');
const indexOffset = buf.readUInt32BE(buf.length - 4);
const entryCount = (buf.length - 4 - indexOffset) / 16;
console.log('\nReference LMO entries:');
for (let i = 0; i < Math.min(10, entryCount); i++) {
  const off = indexOffset + i * 16;
  const keyId = buf.readUInt32BE(off);
  console.log('  keyId:', keyId.toString(16));
}

// Read payload to get actual strings
for (let i = 0; i < Math.min(10, entryCount); i++) {
  const off = indexOffset + i * 16;
  const keyId = buf.readUInt32BE(off);
  const valId = buf.readUInt32BE(off + 4);
  const offset = buf.readUInt32BE(off + 8);
  const length = buf.readUInt32BE(off + 12);
  
  // Read the payload at offset
  const valBuf = buf.slice(offset, offset + length);
  const valStr = valBuf.toString('utf8').replace(/\0/g, '');
  
  console.log(`  [${i}] keyId:${keyId.toString(16).padStart(8,'0')} off:${offset} len:${length} val:"${valStr}"`);
  
  // If this is entry 1+, try to compute hash of the key
  if (i > 0 && valStr.length > 0) {
    console.log(`    luci_sfh("${valStr}") = ${luci_sfh_hash(valStr).toString(16)}`);
    console.log(`    po2lmo_sfh("${valStr}") = ${po2lmo_sfh(valStr).toString(16)}`);
  }
}
