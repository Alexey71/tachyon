#!/usr/bin/env node
'use strict';

const fs = require('fs');

// OpenWrt LuCI SuperFastHash (from LMO.md / template_lmo.c)
// sfh_get16 reads uint16 in little-endian
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

  // Main loop
  for (let i = 0; i < words; i++) {
    hash += sfh_get16(data, offset);
    let tmp = (sfh_get16(data, offset + 2) << 11) ^ hash;
    hash = (hash << 16) ^ tmp;
    offset += 4;
    hash += hash >>> 11;
  }

  // Handle end cases
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

  // Force "avalanching" of final 127 bits
  hash ^= hash << 3;
  hash += hash >>> 5;
  hash ^= hash << 4;
  hash += hash >>> 17;
  hash ^= hash << 25;
  hash += hash >>> 6;

  return hash >>> 0;
}

function pad4(len) {
  return (4 - (len % 4)) % 4;
}

function parsePo(content) {
  const entries = [];
  const lines = content.split('\n');
  let state = null;
  let msgid = '';
  let msgstr = '';

  function flush() {
    if (state === 'msgstr' && msgid !== '' && msgstr !== '') {
      entries.push({ key: msgid, value: msgstr });
    }
    msgid = '';
    msgstr = '';
    state = null;
  }

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (line.startsWith('msgid ')) {
      flush();
      state = 'msgid';
      msgid = line.slice(7, -1).replace(/\\n/g, '\n').replace(/\\"/g, '"');
    } else if (line.startsWith('msgstr ')) {
      state = 'msgstr';
      msgstr = line.slice(8, -1).replace(/\\n/g, '\n').replace(/\\"/g, '"');
    } else if (line.startsWith('"')) {
      const val = line.slice(1, -1).replace(/\\n/g, '\n').replace(/\\"/g, '"');
      if (state === 'msgid') msgid += val;
      else if (state === 'msgstr') msgstr += val;
    }
  }
  flush();
  return entries;
}

function compileLmo(entries) {
  const payload = [];
  const index = [];
  let offset = 0;

  for (const entry of entries) {
    const keyBuf = Buffer.from(entry.key, 'utf8');
    const valBuf = Buffer.from(entry.value, 'utf8');

    const keyId = sfh_hash(entry.key);
    const valId = sfh_hash(entry.value);

    const paddedLen = valBuf.length + pad4(valBuf.length);
    const padded = Buffer.alloc(paddedLen, 0);
    valBuf.copy(padded);
    payload.push(padded);

    index.push({ keyId, valId, offset, length: valBuf.length });
    offset += paddedLen;
  }

  const indexBuf = Buffer.alloc(index.length * 16);
  for (let i = 0; i < index.length; i++) {
    indexBuf.writeUInt32BE(index[i].keyId, i * 16);
    indexBuf.writeUInt32BE(index[i].valId, i * 16 + 4);
    indexBuf.writeUInt32BE(index[i].offset, i * 16 + 8);
    indexBuf.writeUInt32BE(index[i].length, i * 16 + 12);
  }

  const payloadData = Buffer.concat(payload);
  const totalLen = payloadData.length + indexBuf.length + 4;
  const out = Buffer.alloc(totalLen);
  payloadData.copy(out, 0);
  indexBuf.copy(out, payloadData.length);
  out.writeUInt32BE(payloadData.length, totalLen - 4);

  return out;
}

const [input, output] = process.argv.slice(2);
if (!input || !output) {
  console.error('Usage: node po2lmo.js input.po output.lmo');
  process.exit(1);
}

const poContent = fs.readFileSync(input, 'utf8');
const entries = parsePo(poContent);
console.log(`Parsed ${entries.length} translation entries from ${input}`);
const lmo = compileLmo(entries);
fs.writeFileSync(output, lmo);
console.log(`Written ${lmo.length} bytes to ${output}`);
