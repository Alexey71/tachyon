#!/usr/bin/env ucode

// DNS Turbo Cache prefetch worker.
// Resolves popular blocked domains through the local DNS (127.0.0.1) to
// pre-populate the sing-box FakeIP cache so first-visit latency is 0 ms.

let common = require("core.common");
let uci_core = require("core.uci");

const CONFIG_NAME = getenv("TACHYON_CONFIG_NAME") || "tachyon";

// Popular blocked domains – resolved once at startup to warm FakeIP cache.
const PREFETCH_DOMAINS = [
    // Telegram
    "t.me", "telegram.org", "web.telegram.org", "desktop.telegram.org",
    // YouTube
    "youtube.com", "www.youtube.com", "youtu.be", "ytimg.com",
    "yt3.ggpht.com", "googlevideo.com", "youtubei.googleapis.com",
    // Instagram / Meta
    "instagram.com", "www.instagram.com", "cdninstagram.com",
    "facebook.com", "www.facebook.com", "static.xx.fbcdn.net",
    "messenger.com", "fbcdn.net",
    // Twitter / X
    "twitter.com", "x.com", "t.co", "twimg.com", "abs.twimg.com",
    // Discord
    "discord.com", "discordapp.com", "discord.gg", "cdn.discordapp.com",
    // Reddit
    "reddit.com", "www.reddit.com", "redd.it", "redditmedia.com",
    // GitHub
    "github.com", "api.github.com", "raw.githubusercontent.com",
    "objects.githubusercontent.com", "codeload.github.com",
    // Google
    "google.com", "www.google.com", "google.ru",
    "gmail.com", "mail.google.com", "drive.google.com",
    "docs.google.com", "meet.google.com",
    // Netflix
    "netflix.com", "www.netflix.com", "nflxvideo.net", "nflximg.net",
    // Spotify
    "spotify.com", "open.spotify.com", "scdn.co",
    // TikTok
    "tiktok.com", "www.tiktok.com", "tiktokcdn.com", "tiktokcdn-us.com",
    // Twitch
    "twitch.tv", "www.twitch.tv", "static-cdn.jtvnw.net",
    // Wikipedia
    "wikipedia.org", "ru.wikipedia.org", "en.wikipedia.org",
    // Gaming
    "steampowered.com", "store.steampowered.com", "steamcommunity.com",
    "steamcdn.com", "epicgames.com",
    // Messaging
    "whatsapp.com", "www.whatsapp.com", "signal.org",
    // LinkedIn
    "linkedin.com", "www.linkedin.com",
    // News
    "bbc.com", "bbc.co.uk", "reuters.com",
    // Privacy / ProtonMail
    "proton.me", "protonmail.com",
    // Medium / Substack
    "medium.com", "substack.com",
    // Pinterest / Snapchat
    "pinterest.com", "snapchat.com",
];

function prefetch() {
    let settings = common.object_or_empty(uci_core.get_all(CONFIG_NAME, "settings"));
    if (!common.bool_option(settings, "dns_turbo_cache", true))
        return;

    // Give sing-box time to fully initialize before issuing queries.
    common.command_success_from_args([ "sleep", "10" ]);

    for (let domain in PREFETCH_DOMAINS)
        common.command_success_from_args([ "nslookup", domain, "127.0.0.1" ]);
}

let mode = ARGV[0];
if (mode == "prefetch")
    prefetch();
