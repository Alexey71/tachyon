#!/usr/bin/env node
'use strict';

const fs = require('fs');

// Paul Hsieh's SuperFastHash
function sfh_hash(data) {
  let hash = 0;
  let i = data.length;
  let k;
  while (i >= 4) {
    k = (data.charCodeAt(i - 4) & 0xff) |
        ((data.charCodeAt(i - 3) & 0xff) << 8) |
        ((data.charCodeAt(i - 2) & 0xff) << 16) |
        ((data.charCodeAt(i - 1) & 0xff) << 24);
    k = (k * 0x5bd1e995) >>> 0;
    k ^= k >>> 24;
    k = (k * 0x5bd1e995) >>> 0;
    hash = (hash * 0x5bd1e995 + k) >>> 0;
    i -= 4;
  }
  switch (i) {
    case 3: hash ^= (data.charCodeAt(i - 3) & 0xff) << 16;
    case 2: hash ^= (data.charCodeAt(i - 2) & 0xff) << 8;
    case 1: hash ^= (data.charCodeAt(i - 1) & 0xff);
            hash = (hash * 0x5bd1e995) >>> 0;
  }
  hash ^= hash >>> 13;
  hash = (hash * 0x5bd1e995) >>> 0;
  hash ^= hash >>> 15;
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
  let key = '';

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

    // Write value to payload
    const paddedLen = valBuf.length + pad4(valBuf.length);
    const padded = Buffer.alloc(paddedLen, 0);
    valBuf.copy(padded);
    payload.push(padded);

    index.push({
      keyId,
      valId,
      offset,
      length: valBuf.length,
    });

    offset += paddedLen;
  }

  // Build index section
  const indexBuf = Buffer.alloc(index.length * 16);
  for (let i = 0; i < index.length; i++) {
    indexBuf.writeUInt32BE(index[i].keyId, i * 16);
    indexBuf.writeUInt32BE(index[i].valId, i * 16 + 4);
    indexBuf.writeUInt32BE(index[i].offset, i * 16 + 8);
    indexBuf.writeUInt32BE(index[i].length, i * 16 + 12);
  }

  // Total: payload + index + 4 bytes for index offset
  const payloadData = Buffer.concat(payload);
  const totalLen = payloadData.length + indexBuf.length + 4;
  const out = Buffer.alloc(totalLen);
  payloadData.copy(out, 0);
  indexBuf.copy(out, payloadData.length);
  out.writeUInt32BE(payloadData.length, totalLen - 4);

  return out;
}

// Main
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
