#!/usr/bin/env ucode

// DNS Turbo Cache prefetch worker.
// Resolves popular blocked domains through the local DNS (127.0.0.1) to
// pre-populate the sing-box FakeIP cache so first-visit latency is 0 ms.

let common = require("core.common");
let uci_core = require("core.uci");

const CONFIG_NAME = getenv("TACHYON_CONFIG_NAME") || "tachyon";

// Popular blocked domains – resolved once at startup to warm FakeIP cache.
const PREFETCH_DOMAINS = [
    // ── Telegram ─────────────────────────────────────────────────────────────
    "t.me", "telegram.org", "web.telegram.org", "desktop.telegram.org",
    "api.telegram.org", "core.telegram.org", "cdn.telegram.org",
    "updates.telegram.org", "media.telegram.org",

    // ── YouTube ───────────────────────────────────────────────────────────────
    "youtube.com", "www.youtube.com", "youtu.be", "m.youtube.com",
    "music.youtube.com", "studio.youtube.com", "ytimg.com", "s.ytimg.com",
    "i.ytimg.com", "yt3.ggpht.com", "googlevideo.com", "yt.be",
    "youtubei.googleapis.com", "youtube-nocookie.com", "jnn-pa.googleapis.com",
    "suggestqueries-clients6.youtube.com",

    // ── Instagram / Meta ──────────────────────────────────────────────────────
    "instagram.com", "www.instagram.com", "cdninstagram.com",
    "i.instagram.com", "graph.instagram.com", "business.instagram.com",
    "facebook.com", "www.facebook.com", "m.facebook.com", "static.xx.fbcdn.net",
    "video.xx.fbcdn.net", "z-m-scontent.xx.fbcdn.net", "fbcdn.net",
    "messenger.com", "www.messenger.com", "connect.facebook.net",
    "graph.facebook.com", "edge-chat.messenger.com",
    "whatsapp.com", "www.whatsapp.com", "web.whatsapp.com",
    "media.whatsapp.net", "mmg.whatsapp.net",

    // ── Twitter / X ───────────────────────────────────────────────────────────
    "twitter.com", "www.twitter.com", "x.com", "www.x.com",
    "t.co", "twimg.com", "abs.twimg.com", "pbs.twimg.com",
    "video.twimg.com", "api.twitter.com", "api.x.com",
    "upload.twitter.com", "cards.twitter.com",

    // ── Discord ───────────────────────────────────────────────────────────────
    "discord.com", "www.discord.com", "discordapp.com", "discord.gg",
    "cdn.discordapp.com", "media.discordapp.net", "gateway.discord.gg",
    "status.discord.com", "discord.media", "discordstatus.com",

    // ── Reddit ────────────────────────────────────────────────────────────────
    "reddit.com", "www.reddit.com", "old.reddit.com", "redd.it",
    "redditmedia.com", "redditstatic.com", "reddituploads.com",
    "v.redd.it", "preview.redd.it", "i.redd.it",

    // ── GitHub ────────────────────────────────────────────────────────────────
    "github.com", "www.github.com", "api.github.com", "gist.github.com",
    "raw.githubusercontent.com", "objects.githubusercontent.com",
    "codeload.github.com", "avatars.githubusercontent.com",
    "user-images.githubusercontent.com", "github.githubassets.com",
    "copilot.github.com",

    // ── Google (поверх стандартных блокировок) ────────────────────────────────
    "google.com", "www.google.com", "google.ru", "mail.google.com",
    "drive.google.com", "docs.google.com", "sheets.google.com",
    "slides.google.com", "meet.google.com", "calendar.google.com",
    "photos.google.com", "play.google.com", "accounts.google.com",
    "translate.google.com", "news.google.com", "maps.google.com",
    "classroom.google.com", "chat.google.com",
    "lh3.googleusercontent.com", "lh4.googleusercontent.com",

    // ── Netflix ───────────────────────────────────────────────────────────────
    "netflix.com", "www.netflix.com", "api-global.netflix.com",
    "nflxvideo.net", "nflximg.net", "nflxext.com", "nflxso.net",
    "cdnjs.cloudflare.com",

    // ── Spotify ───────────────────────────────────────────────────────────────
    "spotify.com", "open.spotify.com", "api.spotify.com",
    "accounts.spotify.com", "scdn.co", "audio-ak-spotify-com.akamaized.net",
    "dealer.spotify.com",

    // ── TikTok ────────────────────────────────────────────────────────────────
    "tiktok.com", "www.tiktok.com", "m.tiktok.com", "vm.tiktok.com",
    "tiktokcdn.com", "tiktokcdn-us.com", "musical.ly",
    "api16-normal-c-useast1a.tiktokv.com", "p16-sign-va.tiktokcdn.com",

    // ── Twitch ────────────────────────────────────────────────────────────────
    "twitch.tv", "www.twitch.tv", "m.twitch.tv", "clips.twitch.tv",
    "static-cdn.jtvnw.net", "vod-secure.twitch.tv", "gql.twitch.tv",
    "api.twitch.tv", "usher.twitchapps.com", "irc.chat.twitch.tv",

    // ── Wikipedia ────────────────────────────────────────────────────────────
    "wikipedia.org", "ru.wikipedia.org", "en.wikipedia.org",
    "de.wikipedia.org", "fr.wikipedia.org", "upload.wikimedia.org",
    "wikimedia.org", "wikidata.org", "mediawiki.org",

    // ── LinkedIn ──────────────────────────────────────────────────────────────
    "linkedin.com", "www.linkedin.com", "media.licdn.com",
    "static.licdn.com", "platform.linkedin.com",

    // ── Pinterest ─────────────────────────────────────────────────────────────
    "pinterest.com", "www.pinterest.com", "ru.pinterest.com",
    "i.pinimg.com", "v.pinimg.com", "s.pinimg.com",

    // ── Snapchat ──────────────────────────────────────────────────────────────
    "snapchat.com", "www.snapchat.com", "sc-cdn.net",
    "feelinsonice-hrd.appspot.com",

    // ── Signal ────────────────────────────────────────────────────────────────
    "signal.org", "www.signal.org", "api.signal.org",
    "cdn.signal.org", "storage.signal.org",

    // ── Steam / Gaming ────────────────────────────────────────────────────────
    "steampowered.com", "store.steampowered.com", "steamcommunity.com",
    "steamcdn-a.akamaihd.net", "cdn.cloudflare.steamstatic.com",
    "api.steampowered.com", "help.steampowered.com",
    "epicgames.com", "www.epicgames.com", "launcher.epicgames.com",
    "account.epicgames.com", "cdn1.epicgames.com",
    "roblox.com", "www.roblox.com", "rbxcdn.com",
    "gaming.youtube.com",

    // ── Medium / Substack ────────────────────────────────────────────────────
    "medium.com", "www.medium.com", "cdn-images-1.medium.com",
    "substack.com", "cdn.substack.com",

    // ── ProtonMail / Privacy ──────────────────────────────────────────────────
    "proton.me", "mail.proton.me", "protonmail.com", "protonvpn.com",
    "account.proton.me",

    // ── News ──────────────────────────────────────────────────────────────────
    "bbc.com", "www.bbc.com", "bbc.co.uk", "www.bbc.co.uk",
    "reuters.com", "www.reuters.com",
    "theguardian.com", "www.theguardian.com",
    "nytimes.com", "www.nytimes.com",

    // ── Cloudflare CDN ───────────────────────────────────────────────────────
    "cloudflare.com", "www.cloudflare.com", "one.one.one.one",
    "cdnjs.cloudflare.com", "dash.cloudflare.com",

    // ── Misc популярные ───────────────────────────────────────────────────────
    "patreon.com", "www.patreon.com",
    "onlyfans.com", "www.onlyfans.com",
    "canva.com", "www.canva.com",
    "notion.so", "www.notion.so",
    "figma.com", "www.figma.com",
    "trello.com", "www.trello.com",
    "slack.com", "www.slack.com", "files.slack.com",
    "zoom.us", "www.zoom.us",
    "dropbox.com", "www.dropbox.com",
    "1password.com", "bitwarden.com",
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
