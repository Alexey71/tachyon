function sfh_hash(data) {
  let hash = 0;
  let i = data.length;
  let k;
  while (i >= 4) {
    k = (data.charCodeAt(i - 4) & 0xff) | ((data.charCodeAt(i - 3) & 0xff) << 8) | ((data.charCodeAt(i - 2) & 0xff) << 16) | ((data.charCodeAt(i - 1) & 0xff) << 24);
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
console.log('Empty:', sfh_hash('').toString(16));
console.log('Plural-Forms:', sfh_hash('Plural-Forms').toString(16));
console.log('Test str:', sfh_hash('Hello').toString(16));
