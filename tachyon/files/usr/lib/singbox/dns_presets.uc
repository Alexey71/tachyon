#!/usr/bin/env ucode

let common = require("core.common");
let as_string = common.as_string;

let DNS_PRESETS = {
    udp: [
        { name: "Cloudflare", servers: ["1.1.1.1", "1.0.0.1"], tags: ["privacy", "fast"], country: "🌐" },
        { name: "Google", servers: ["8.8.8.8", "8.8.4.4"], tags: ["fast"], country: "🌐" },
        { name: "Quad9", servers: ["9.9.9.9", "149.112.112.112"], tags: ["privacy", "security"], country: "🌐" },
        { name: "AdGuard", servers: ["94.140.14.14", "94.140.15.15"], tags: ["privacy", "adblock"], country: "🌐" },
        { name: "Yandex", servers: ["77.88.8.8", "77.88.8.1"], tags: [], country: "🇷🇺" },
        { name: "DNS.SB", servers: ["185.222.222.222", "185.228.168.9"], tags: ["privacy"], country: "🌐" },
        { name: "Mullvad", servers: ["194.242.2.2"], tags: ["privacy", "no-logs"], country: "🇸🇪" },
        { name: "Comodo", servers: ["8.26.56.26", "8.20.247.20"], tags: ["security"], country: "🌐" },
        { name: "OpenNIC", servers: ["198.41.0.4", "199.9.14.201"], tags: ["decentralized"], country: "🌐" },
        { name: "CleanBrowsing", servers: ["185.228.168.9", "185.228.169.9"], tags: ["security", "family"], country: "🌐" }
    ],
    dot: [
        { name: "Cloudflare", servers: ["1.1.1.1", "1.0.0.1"], tags: ["privacy", "fast"], country: "🌐" },
        { name: "Google", servers: ["dns.google"], tags: ["fast"], country: "🌐" },
        { name: "Quad9", servers: ["dns.quad9.net"], tags: ["privacy", "security"], country: "🌐" },
        { name: "AdGuard", servers: ["dns.adguard.com"], tags: ["privacy", "adblock"], country: "🌐" },
        { name: "Mullvad", servers: ["dns.mullvad.net"], tags: ["privacy", "no-logs"], country: "🇸🇪" },
        { name: "NextDNS", servers: ["dns.nextdns.io"], tags: ["privacy", "customizable"], country: "🌐" },
        { name: "CleanBrowsing", servers: ["family-filter-dns.cleanbrowsing.org"], tags: ["security", "family"], country: "🌐" },
        { name: "Yandex", servers: ["common.dot.dns.yandex.net"], tags: [], country: "🇷🇺" }
    ],
    doh: [
        { name: "Cloudflare", servers: ["https://cloudflare-dns.com/dns-query"], tags: ["privacy", "fast"], country: "🌐" },
        { name: "Google", servers: ["https://dns.google/dns-query"], tags: ["fast"], country: "🌐" },
        { name: "Quad9", servers: ["https://dns.quad9.net/dns-query"], tags: ["privacy", "security"], country: "🌐" },
        { name: "AdGuard", servers: ["https://dns.adguard.com/dns-query"], tags: ["privacy", "adblock"], country: "🌐" },
        { name: "Mullvad", servers: ["https://dns.mullvad.net/dns-query"], tags: ["privacy", "no-logs"], country: "🇸🇪" },
        { name: "NextDNS", servers: ["https://dns.nextdns.io/dns-query"], tags: ["privacy", "customizable"], country: "🌐" },
        { name: "AliDNS", servers: ["https://dns.alidns.com/dns-query"], tags: ["fast"], country: "🇨🇳" },
        { name: "CleanBrowsing", servers: ["https://doh.cleanbrowsing.org/doh/family-filter/"], tags: ["security", "family"], country: "🌐" }
    ],
    doq: [
        { name: "Cloudflare", servers: ["1.1.1.1:784", "1.0.0.1:784"], tags: ["privacy", "fast"], country: "🌐" },
        { name: "Google", servers: ["dns.google:784"], tags: ["fast"], country: "🌐" },
        { name: "AdGuard", servers: ["dns.adguard.com:785"], tags: ["privacy", "adblock"], country: "🌐" },
        { name: "Mullvad", servers: ["dns.mullvad.net:784"], tags: ["privacy", "no-logs"], country: "🇸🇪" },
        { name: "NextDNS", servers: ["dns.nextdns.io:784"], tags: ["privacy", "customizable"], country: "🌐" }
    ]
};

let BOOTSTRAP_PRESETS = [
    { name: "Cloudflare UDP", servers: ["1.1.1.1", "1.0.0.1"], tags: ["fast", "reliable"], country: "🌐" },
    { name: "Google UDP", servers: ["8.8.8.8", "8.8.4.4"], tags: ["fast", "reliable"], country: "🌐" },
    { name: "Quad9 UDP", servers: ["9.9.9.9", "149.112.112.112"], tags: ["security"], country: "🌐" },
    { name: "Yandex UDP", servers: ["77.88.8.8", "77.88.8.1"], tags: [], country: "🇷🇺" },
    { name: "AdGuard UDP", servers: ["94.140.14.14", "94.140.15.15"], tags: ["privacy"], country: "🌐" },
    { name: "Mullvad UDP", servers: ["194.242.2.2"], tags: ["privacy"], country: "🇸🇪" }
];

function get_presets(dns_type) {
    return DNS_PRESETS[as_string(dns_type)] || DNS_PRESETS.udp;
}

function get_bootstrap_presets() {
    return BOOTSTRAP_PRESETS;
}

function get_preset_servers(preset) {
    return preset.servers;
}

function format_preset(preset, index) {
    let tags_str = "";
    if (length(preset.tags) > 0)
        tags_str = " [" + join(", ", preset.tags) + "]";
    return preset.country + " " + preset.name + tags_str + "\n    " + join(", ", preset.servers);
}

function format_presets_list(dns_type) {
    let presets = get_presets(dns_type);
    let text = "📋 <b>Рекомендованные DNS серверы</b> (" + dns_type + ")\n\n";
    for (let i = 0; i < length(presets); i++) {
        text += "<b>" + (i + 1) + ".</b> " + format_preset(presets[i], i) + "\n\n";
    }
    return text;
}

function format_bootstrap_presets_list() {
    let text = "📋 <b>Рекомендованные Bootstrap DNS серверы</b> (UDP)\n\n";
    text += "Bootstrap DNS используется для начального разрешения имён.\n";
    text += "Рекомендуется использовать быстрые UDP серверы.\n\n";
    for (let i = 0; i < length(BOOTSTRAP_PRESETS); i++) {
        text += "<b>" + (i + 1) + ".</b> " + format_preset(BOOTSTRAP_PRESETS[i], i) + "\n\n";
    }
    return text;
}

function format_protocol_info() {
    let text = "🔍 <b>Поддержка DNS протоколов провайдерами</b>\n\n";
    text += "<b>Cloudflare</b>\n";
    text += "  UDP: 1.1.1.1, 1.0.0.1\n";
    text += "  DoT: 1.1.1.1, 1.0.0.1\n";
    text += "  DoH: cloudflare-dns.com\n";
    text += "  DoQ: 1.1.1.1:784, 1.0.0.1:784\n\n";
    text += "<b>Google</b>\n";
    text += "  UDP: 8.8.8.8, 8.8.4.4\n";
    text += "  DoT: dns.google\n";
    text += "  DoH: dns.google\n";
    text += "  DoQ: dns.google:784\n\n";
    text += "<b>Quad9</b>\n";
    text += "  UDP: 9.9.9.9, 149.112.112.112\n";
    text += "  DoT: dns.quad9.net\n";
    text += "  DoH: dns.quad9.net\n";
    text += "  DoQ: ❌\n\n";
    text += "<b>AdGuard</b>\n";
    text += "  UDP: 94.140.14.14, 94.140.15.15\n";
    text += "  DoT: dns.adguard.com\n";
    text += "  DoH: dns.adguard.com\n";
    text += "  DoQ: dns.adguard.com:785\n\n";
    text += "<b>Mullvad</b>\n";
    text += "  UDP: 194.242.2.2\n";
    text += "  DoT: dns.mullvad.net\n";
    text += "  DoH: dns.mullvad.net\n";
    text += "  DoQ: dns.mullvad.net:784\n\n";
    text += "<b>NextDNS</b>\n";
    text += "  UDP: ❌\n";
    text += "  DoT: dns.nextdns.io\n";
    text += "  DoH: dns.nextdns.io\n";
    text += "  DoQ: dns.nextdns.io:784\n";
    return text;
}

return {
    DNS_PRESETS,
    BOOTSTRAP_PRESETS,
    get_presets,
    get_bootstrap_presets,
    get_preset_servers,
    format_preset,
    format_presets_list,
    format_bootstrap_presets_list,
    format_protocol_info
};
