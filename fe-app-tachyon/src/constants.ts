export const TACHYON_UCI_PACKAGE = 'tachyon';
export const TACHYON_LUCI_APP_VERSION = '__COMPILED_VERSION_VARIABLE__';
export const TACHYON_ACTION_PROVIDERS_AVAILABILITY_EVENT =
  'tachyon:action-providers-availability';
export const FAKEIP_CHECK_DOMAIN = 'fakeip.podkop.fyi';
export const IP_CHECK_DOMAIN = 'ip.podkop.fyi';
export const DEFAULT_LATENCY_TEST_URL = 'https://www.gstatic.com/generate_204';
export const LATENCY_TEST_URL_OPTIONS = [
  DEFAULT_LATENCY_TEST_URL,
  'https://cp.cloudflare.com/generate_204',
  'https://captive.apple.com',
  'https://connectivity-check.ubuntu.com',
];

export const DOMAIN_LIST_OPTIONS = {
  russia_inside: 'Russia inside',
  russia_outside: 'Russia outside',
  ukraine_inside: 'Ukraine',
  geoblock: 'Geo Block',
  block: 'Block',
  porn: 'Porn',
  news: 'News',
  anime: 'Anime',
  youtube: 'Youtube',
  discord: 'Discord',
  meta: 'Meta',
  twitter: 'Twitter (X)',
  hdrezka: 'HDRezka',
  tiktok: 'Tik-Tok',
  telegram: 'Telegram',
  cloudflare: 'Cloudflare',
  google_ai: 'Google AI',
  google_play: 'Google Play',
  hodca: 'H.O.D.C.A',
  roblox: 'Roblox',
  ads_hagezi_pro: 'Ads (Hagezi Pro)',
  supercell: 'Supercell',
  github: 'GitHub',
  hetzner: 'Hetzner ASN',
  ovh: 'OVH ASN',
  digitalocean: 'Digital Ocean ASN',
  cloudfront: 'CloudFront ASN',
};

export const DNS_SERVERS_BY_PROTOCOL: Record<string, Record<string, string>> = {
  udp: {
    '1.1.1.1': '1.1.1.1 (Cloudflare)',
    '8.8.8.8': '8.8.8.8 (Google)',
    '9.9.9.9': '9.9.9.9 (Quad9)',
    '77.88.8.8': '77.88.8.8 (Yandex)',
    '94.140.14.14': '94.140.14.14 (AdGuard)',
    '185.222.222.222': '185.222.222.222 (DNS.SB)',
    '194.242.2.2': '194.242.2.2 (Mullvad)',
  },
  doh: {
    'https://cloudflare-dns.com/dns-query': 'Cloudflare',
    'https://dns.google/dns-query': 'Google',
    'https://dns.quad9.net/dns-query': 'Quad9',
    'https://dns.adguard.com/dns-query': 'AdGuard',
    'https://dns.mullvad.net/dns-query': 'Mullvad',
    'https://dns.nextdns.io/dns-query': 'NextDNS',
    'https://doh.cleanbrowsing.org/doh/family-filter/': 'CleanBrowsing Family',
  },
  dot: {
    '1.1.1.1': '1.1.1.1 (Cloudflare)',
    'dns.google': 'Google',
    'dns.quad9.net': 'Quad9',
    'dns.adguard.com': 'AdGuard',
    'dns.mullvad.net': 'Mullvad',
    'dns.nextdns.io': 'NextDNS',
    'common.dot.dns.yandex.net': 'Yandex',
  },
  doq: {
    '1.1.1.1:784': 'Cloudflare',
    'dns.google:784': 'Google',
    'dns.adguard.com:785': 'AdGuard',
    'dns.mullvad.net:784': 'Mullvad',
    'dns.nextdns.io:784': 'NextDNS',
  },
};
export const BOOTSTRAP_DNS_SERVER_OPTIONS = {
  '77.88.8.8': '77.88.8.8 (Yandex DNS)',
  '77.88.8.1': '77.88.8.1 (Yandex DNS)',
  '1.1.1.1': '1.1.1.1 (Cloudflare DNS)',
  '1.0.0.1': '1.0.0.1 (Cloudflare DNS)',
  '8.8.8.8': '8.8.8.8 (Google DNS)',
  '8.8.4.4': '8.8.4.4 (Google DNS)',
  '9.9.9.9': '9.9.9.9 (Quad9 DNS)',
  '9.9.9.11': '9.9.9.11 (Quad9 DNS)',
};

export const COMMAND_TIMEOUT = 10000; // 10 seconds
