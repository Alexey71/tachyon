#!/usr/bin/env ucode

let fs = require("fs");
let uci_core = require("core.uci");
let common = require("core.common");
let helpers = require("core.helpers");
let connections = require("config.connections");

const CONFIG_NAME = getenv("TACHYON_CONFIG_NAME") || "tachyon";
const LIB_DIR = getenv("TACHYON_LIB") || "/usr/lib/tachyon";
const PID_FILE = "/var/run/tachyon_watchdog.pid";
const WATCHDOG_UC = LIB_DIR + "/service/watchdog.uc";
const PAUSE_FILE = "/tmp/tachyon_paused_until";
const SMART_DETECT_SEEN_FILE = "/etc/tachyon/smart_detect_seen.json";


let as_string = common.as_string;
let shell_quote = common.shell_quote;

let proxy_restart_count = 0;
let proxy_restart_window_start = time();
const PROXY_RESTART_LOCK = "/var/run/tachyon_proxy_restart.lock";
let telegram_msg_count = 0;
let telegram_msg_window = time();
// FD-cascade prevention: track logread pipe FD to close it in background spawns
let logread_pipe_fd = -1;
let syslog_start_time = 0;

let command_from_args = common.command_from_args;
let command_status = common.command_status;
let command_success_from_args = common.command_success_from_args;
let is_process_name_running = helpers.is_process_name_running;

function command_capture(command) {
    let pipe = fs.popen(command, "r");
    if (!pipe)
        return { status: 1, output: "" };
    let data = pipe.read("all");
    let status = pipe.close();
    if (status > 255) status = int(status / 256);
    return { status, output: data == null ? "" : as_string(data) };
}

function command_output(command) {
    let result = command_capture(command);
    return result.status == 0 ? result.output : "";
}

function command_output_from_args(args) {
    return command_output(command_from_args(args) + " 2>/dev/null");
}

// Run a command in background, explicitly closing the logread pipe FD to
// prevent FD-cascade: each restart/reload inherits read-end of logread pipe,
// keeping orphaned logread -f processes alive across watchdog generations.
function bg_system(cmd) {
    if (logread_pipe_fd >= 0) {
        system(sprintf("%d<&- ", logread_pipe_fd) + cmd);
    } else {
        system(cmd);
    }
}

function settings() {
    return common.object_or_empty(uci_core.get_all(CONFIG_NAME, "settings"));
}

function remove_file(path) {
    try {
        fs.unlink(as_string(path));
    }
    catch (e) {
    }
}

function log_message(message, level) {
    let priority = 6;
    let lvl = as_string(level || "info");
    if (lvl == "warn" || lvl == "warning") {
        priority = 4;
    } else if (lvl == "err" || lvl == "error" || lvl == "fatal") {
        priority = 3;
    } else if (lvl == "debug") {
        priority = 7;
    }
    
    let kmsg = fs.open("/dev/kmsg", "w");
    if (kmsg) {
        kmsg.write(sprintf("<%d>tachyon: [%s] Watchdog: %s\n", priority, lvl, as_string(message)));
        kmsg.close();
    } else {
        command_success_from_args([ "logger", "-t", "tachyon", "[" + lvl + "] Watchdog: " + as_string(message) ]);
    }
}

function send_telegram_notification(message) {
    let now = time();
    if (now - telegram_msg_window > 300) {
        telegram_msg_count = 0;
        telegram_msg_window = now;
    }
    if (telegram_msg_count >= 10) return;
    telegram_msg_count++;
    let tcfg = common.object_or_empty(uci_core.get_all(CONFIG_NAME, "telegram"));
    if (tcfg.enabled == "1" && tcfg.bot_token && tcfg.admin_ids) {
        system("/usr/bin/tachyon telegram send " + shell_quote(message) + " </dev/null >/dev/null 2>&1 1000<&- &");
    }
}

function process_running(pid, expected_name) {
    if (match(as_string(pid), /^[0-9]+$/) == null)
        return false;
    if (expected_name != null && expected_name != "") {
        return is_process_name_running(pid, expected_name);
    }
    return fs.stat("/proc/" + pid) != null;
}

function stop_runtime() {
    let pid = trim(fs.readfile(PID_FILE) || "");
    if (process_running(pid, "ucode")) {
        command_success_from_args([ "kill", pid ]);
        let wait_limit = 50; // 5 seconds
        while (wait_limit > 0 && process_running(pid, "ucode")) {
            sleep(100);
            wait_limit--;
        }
        if (process_running(pid, "ucode")) {
            command_success_from_args([ "kill", "-9", pid ]);
        }
    }
    remove_file(PID_FILE);

    // Stop Honeypot listener
    let hp_pid = trim(fs.readfile("/var/run/tachyon_honeypot_listener.pid") || "");
    if (process_running(hp_pid)) {
        command_success_from_args([ "kill", hp_pid ]);
        let wait_limit = 20; // 2 seconds
        while (wait_limit > 0 && process_running(hp_pid)) {
            sleep(100);
            wait_limit--;
        }
        if (process_running(hp_pid)) {
            command_success_from_args([ "kill", "-9", hp_pid ]);
        }
    }
    remove_file("/var/run/tachyon_honeypot_listener.pid");
    remove_file("/tmp/tachyon_honeypot.fifo");
    remove_file(PROXY_RESTART_LOCK);

    return 0;
}

// ─── Pause auto-resume ────────────────────────────────────────────────────────
function check_auto_resume_pause() {
    let val = trim(fs.readfile(PAUSE_FILE) || "");
    if (val == "") return false;
    let until = int(val);
    let now = time();
    if (until <= now) {
        remove_file(PAUSE_FILE);
        log_message("Pause expired, auto-resuming Tachyon...", "info");
        command_status("/usr/bin/tachyon start > /dev/null 2>&1");
        let tcfg = common.object_or_empty(uci_core.get_all(CONFIG_NAME, "telegram"));
        if (tcfg.enabled == "1" && tcfg.bot_token && tcfg.admin_ids) {
            send_telegram_notification("▶️ Прокси возобновлён (пауза истекла).");
        }
        return false;
    }
    return true; // still paused, skip normal checks
}

// ─── Smart Detect — self-healing routing ─────────────────────────────────────
function smart_detect_get_proxy_sections() {
    let c = uci_core.cursor();
    if (!c) return [];
    c.load(CONFIG_NAME);
    let connections = require("config.connections");
    let secs = [];
    c.foreach(CONFIG_NAME, "section", function(s) {
        if (s.enabled != "1") return;
        let act = as_string(s.action || "");
        if (act != "bypass" && act != "block" && act != "dns" && act != "") {
            push(secs, s[".name"]);
        }
    });
    return secs;
}

// Extract a candidate domain from a sing-box log line. Returns null when the
// line carries no usable hostname. Kept separate from log handling so the
// pattern can be exercised directly by tests.
function smart_detect_extract_domain(line) {
    if (line == null) return null;
    let text = as_string(line);
    let m = match(text, /"([a-zA-Z0-9][a-zA-Z0-9.-]{1,60}\.[a-zA-Z]{2,})(:[0-9]+)?"/);
    if (!m) m = match(text, /target[= ]([a-zA-Z0-9][a-zA-Z0-9.-]{1,60}\.[a-zA-Z]{2,})/);
    if (!m || !m[1]) return null;
    let domain = m[1];
    if (length(domain) < 5) return null;
    if (index(domain, "*") >= 0 || index(domain, "?") >= 0) return null;
    if (index(domain, "..") >= 0) return null;
    if (index(domain, "-") == 0 || substr(domain, length(domain) - 1) == "-") return null;
    return domain;
}

// A domain that resolves nowhere is a DNS fault, not a block: probing it would
// fail directly and via proxy alike, so treat it as unresolvable and skip.
function smart_detect_domain_resolves(domain) {
    return command_success_from_args([ "nslookup", domain, "127.0.0.1" ]) ||
           command_success_from_args([ "nslookup", domain ]);
}

function smart_detect_add_domain(sec_name, domain) {
    let c = uci_core.cursor();
    if (!c) return false;
    c.load(CONFIG_NAME);
    let sec = c.get_all(CONFIG_NAME, sec_name);
    if (!sec) return false;
    let existing = sec.user_domains;
    if (type(existing) != "array") {
        existing = (existing && trim(as_string(existing)) != "") ? [trim(as_string(existing))] : [];
    }
    for (let d in existing) {
        if (trim(as_string(d)) == domain) return true;
    }
    c.list_add(CONFIG_NAME, sec_name, "user_domains", domain);
    c.commit(CONFIG_NAME);
    command_status("/usr/bin/tachyon reload > /dev/null 2>&1");
    return true;
}




function start_runtime() {
    let cfg = settings();
    stop_runtime();

    let enable_watchdog = cfg.enable_watchdog != "0";
    if (!enable_watchdog) {
        return 0;
    }

    let command = command_from_args([ "ucode", "-L", LIB_DIR, WATCHDOG_UC, "worker" ]) +
        " </dev/null >/dev/null 2>&1 1000<&- & echo $! >" + shell_quote(PID_FILE);
    return command_status(command);
}

function run_zero_rtt_prefetching() {
    let cfg = settings();
    let sections = uci_core.get_all(CONFIG_NAME);
    if (!sections) return;

    let unique_domains = {};
    for (let k in keys(sections)) {
        let sec = sections[k];
        if (sec.enabled == "0") continue;

        let list_val = sec.user_domains;
        let list_array = [];
        if (type(list_val) == "array") {
            list_array = list_val;
        } else if (list_val) {
            list_array = split(trim(as_string(list_val)), /\s+/);
        }

        for (let dom in list_array) {
            dom = trim(dom);
            if (dom != "" && index(dom, "*") < 0 && index(dom, "?") < 0) {
                unique_domains[dom] = true;
            }
        }

        let text_val = sec.user_domains_text;
        if (text_val) {
            for (let line in split(text_val, "\n")) {
                line = trim(line);
                if (line != "" && index(line, "#") != 0 && index(line, "*") < 0 && index(line, "?") < 0) {
                    unique_domains[line] = true;
                }
            }
        }
    }

    let domain_list = keys(unique_domains);
    if (length(domain_list) == 0) return;

    log_message("Zero-RTT Prefetcher: pre-resolving " + length(domain_list) + " domains in batches...", "info");
    let batch = [];
    for (let i, dom in domain_list) {
        push(batch, shell_quote(dom));
        if (length(batch) >= 15 || i == length(domain_list) - 1) {
            let batch_cmd = "for d in " + join(" ", batch) + "; do dig @127.0.0.1 \"$d\" A >/dev/null 2>&1; done &";
            system(batch_cmd + " </dev/null >/dev/null 2>&1 1000<&-");
            batch = [];
        }
    }
}

let uloop = null;
let ubus = null;
try { uloop = require("uloop"); } catch (e) {}
try { ubus = require("ubus"); } catch (e) {}

let last_oom_time = 0;
let last_oom_recovery_time = 0;
let last_restart_time = 0;
let last_urltest_check = 0;
let pending_smart_domains = {};
let smart_detect_last_run = 0;
let last_subnet_heal_time = 0;
let last_wan_heal_time = 0;
let last_gateway_heal_time = 0;
let last_reload_time = 0;
let proxy_consecutive_fails = 0;
let dns_consecutive_fails = 0;
let ai_healthy_streak = 0;
let cached_proxy_port = null;
let proxy_latency_history = [];
let dns_latency_history = [];
let last_anomaly_check = 0;
let last_metrics_export = 0;
let last_fast_check = 0;
let last_normal_check = 0;
let last_slow_check = 0;

function check_tachyon_cli_running() {
    let running = false;
    let proc = fs.opendir("/proc");
    if (proc) {
        let entry;
        while ((entry = proc.read()) != null) {
            if (match(entry, /^[0-9]+$/)) {
                let cmdline = fs.readfile("/proc/" + entry + "/cmdline") || "";
                if (index(cmdline, "/usr/bin/tachyon") >= 0) {
                    if (index(cmdline, "start") >= 0 || index(cmdline, "restart") >= 0 || index(cmdline, "reload") >= 0 || index(cmdline, "stop") >= 0) {
                        running = true;
                        break;
                    }
                }
            }
        }
        proc.close();
    }
    return running;
}

function handle_singbox_stop_event(reason) {
    let now = time();
    if (now - last_restart_time < 30) return;
    last_restart_time = now;

    let cfg = settings();
    if (cfg.recovery_bypass == "1") return;
    if (check_auto_resume_pause()) return;
    if (check_tachyon_cli_running()) return;

    let list_update_pid = trim(fs.readfile("/var/run/tachyon_list_update.pid") || "");
    if (process_running(list_update_pid, "ucode")) return;

    log_message("sing-box is stopped (" + as_string(reason || "health check") + "). Restarting Tachyon...", "warn");
    increment_reconnect_count();
    let tcfg = common.object_or_empty(uci_core.get_all(CONFIG_NAME, "telegram"));
    if (tcfg.notify_crash != "0") {
        send_telegram_notification("⚠️ *Watchdog:* sing-box остановлен. Перезапускаю службы Tachyon...");
    }
    safe_proxy_restart("singbox_stopped");
}

function get_sing_box_pid() {
    for (let path in [ "/var/run/sing-box.pid", "/var/run/sing-box/sing-box.pid" ]) {
        let pid = trim(fs.readfile(path) || "");
        if (pid != "" && process_running(pid, "sing-box")) return pid;
    }

    let ubus_res = command_capture("ubus call service list '{\"name\":\"sing-box\"}' 2>/dev/null");
    if (ubus_res.status == 0 && ubus_res.output != "") {
        let matched = match(ubus_res.output, /"pid":\s*([0-9]+)/);
        if (matched && matched[1] != "") {
            let pid = matched[1];
            if (process_running(pid, "sing-box")) return pid;
        }
    }

    let pidof_res = command_capture("pidof sing-box 2>/dev/null");
    if (pidof_res.status == 0 && pidof_res.output != "") {
        let fields = split(trim(pidof_res.output), /[ \t]+/);
        if (length(fields) > 0 && fields[0] != "") {
            let pid = fields[0];
            if (process_running(pid, "sing-box")) return pid;
        }
    }

    return "";
}

function check_singbox_process() {
    let cfg = settings();
    if (cfg.recovery_bypass == "1") return;
    if (check_auto_resume_pause()) return;
    if (check_tachyon_cli_running()) return;

    let list_update_pid = trim(fs.readfile("/var/run/tachyon_list_update.pid") || "");
    if (process_running(list_update_pid, "ucode")) return;

    // Fast-path check: verify if sing-box process is active
    let sb_pid = get_sing_box_pid();
    if (sb_pid != "" && process_running(sb_pid, "sing-box")) {
        return;
    }

    let has_sections = false;
    let uci_sections = uci_core.get_all(CONFIG_NAME);
    if (uci_sections) {
        for (let k in keys(uci_sections)) {
            if (uci_sections[k][".type"] == "section") {
                has_sections = true;
                break;
            }
        }
    }
    if (!has_sections) return;

    let binary_name = "sing-box";
    let pid = "";
    let proc = fs.opendir("/proc");
    if (proc) {
        let entry;
        while ((entry = proc.read()) != null) {
            if (match(entry, /^[0-9]+$/)) {
                let exe = fs.readlink("/proc/" + entry + "/exe") || "";
                let slash = rindex(exe, "/");
                if ((slash >= 0 ? substr(exe, slash + 1) : exe) == binary_name) {
                    pid = entry;
                    break;
                }
            }
        }
        proc.close();
    }

    if (pid == "") {
        handle_singbox_stop_event("process missing from /proc");
    }
}

function check_memory() {
    let free_mb = -1;
    let mem_info = fs.readfile("/proc/meminfo") || "";
    for (let line in split(mem_info, "\n")) {
        if (index(line, "MemAvailable:") == 0) {
            let fields = split(trim(line), /[ \t]+/);
            if (length(fields) >= 2) {
                free_mb = int(fields[1]) / 1024;
            }
            break;
        }
    }
    if (free_mb >= 0 && free_mb < 15) {
        log_message("Low memory detected (" + free_mb + "MB). Clearing caches...", "warn");
        system("echo 3 > /proc/sys/vm/drop_caches");
    }
}

// ─── AI Watchdog Self-Healing Matrix ──────────────────────────────────────────
let ai_incidents_count = 0;
let last_ai_incident = null;

function ai_export_status() {
    let is_healthy = last_ai_incident == null || (time() - last_ai_incident.timestamp >= 300);
    if (is_healthy) ai_healthy_streak++;
    let status_obj = {
        timestamp: time(),
        status: is_healthy ? "healthy" : "repaired",
        ai_active: true,
        incidents_resolved_total: ai_incidents_count,
        last_incident: last_ai_incident
    };
    fs.writefile("/tmp/tachyon_ai_status.json", sprintf("%J\n", status_obj));
}

function ai_heal_report(event_type, description, resolution, status_code) {
    ai_incidents_count++;
    ai_healthy_streak = 0;
    last_ai_incident = {
        type: event_type,
        description: description,
        resolution: resolution,
        timestamp: time()
    };

    let log_msg = sprintf("🤖 [AI Watchdog] %s. Action taken: %s", description, resolution);
    log_message(log_msg, "warn");

    let tcfg = common.object_or_empty(uci_core.get_all(CONFIG_NAME, "telegram"));
    if (tcfg.enabled == "1" && tcfg.bot_token && tcfg.admin_ids && tcfg.notify_crash != "0") {
        let tg_msg = sprintf("🤖 *[ИИ-Автомеханик Tachyon]*\n⚠️ *Проблема:* %s\n🔧 *Авто-решение:* %s", description, resolution);
        send_telegram_notification(tg_msg);
    }

    ai_export_status();
}

// Guard: skip if a tachyon reload is already in progress (prevents concurrent reload_firewall races)
function is_reload_in_progress() {
    return fs.stat("/var/run/tachyon.reload.lock") != null
        || check_tachyon_cli_running();
}

function safe_proxy_restart(reason) {
    let now = time();
    if (now - proxy_restart_window_start > 600) {
        proxy_restart_count = 0;
        proxy_restart_window_start = now;
    }
    if (proxy_restart_count >= 3) {
        log_message("Proxy restart rate limit: " + as_string(proxy_restart_count) + " in 10 min, skipping (" + reason + ")", "warn");
        return false;
    }
    if (fs.stat(PROXY_RESTART_LOCK) != null) {
        let lock_content = trim(fs.readfile(PROXY_RESTART_LOCK) || "0");
        let lock_age = now - int(lock_content);
        if (lock_age < 300) {
            log_message("Proxy restart lock exists (age " + as_string(lock_age) + "s), skipping (" + reason + ")", "warn");
            return false;
        }
        log_message("Proxy restart lock stale (age " + as_string(lock_age) + "s), removing", "warn");
        remove_file(PROXY_RESTART_LOCK);
    }
    try { fs.writefile(PROXY_RESTART_LOCK, as_string(now)); } catch(e) {}
    proxy_restart_count++;
    cached_proxy_port = null;
    let lock_path = shell_quote(PROXY_RESTART_LOCK);
    bg_system("/etc/init.d/tachyon restart </dev/null >/dev/null 2>&1 & rm -f " + lock_path + " &");
    return true;
}

// ─── Reload dedup: prevent multiple reload_firewall per cycle ─────────────────
function safe_reload_firewall() {
    let now = time();
    let min_interval = 120;
    if (now - last_reload_time < min_interval) return;
    last_reload_time = now;
    bg_system("/usr/bin/tachyon reload_firewall </dev/null >/dev/null 2>&1 &");
}

function ai_heal_nftables() {
    let cfg = settings();
    let routing_mode = cfg.routing_mode || "nftables";
    let nft_table = getenv("NFT_TABLE_NAME") || "TachyonTable";

    let list_update_pid = trim(fs.readfile("/var/run/tachyon_list_update.pid") || "");
    if (process_running(list_update_pid, "ucode")) return true;
    if (is_reload_in_progress()) return true;

    if (routing_mode == "nftables") {
        let out_nft = command_output_from_args(["nft", "list", "table", "inet", nft_table]);
        if (index(out_nft, "tproxy") < 0 || index(out_nft, "priority_rules") < 0) {
            ai_heal_report(
                "nftables",
                "Таблица правил nftables очищена или повреждена",
                "Выполнена быстрая регенерация правил TachyonTable и цепочки TPROXY",
                "fixed"
            );
            safe_reload_firewall();
            return false;
        }
    }
    return true;
}

function ai_heal_qos() {
    let cfg = settings();
    if (cfg.qos_priority_engine == "0") return true;
    if (is_reload_in_progress()) return true;

    let nft_table = getenv("NFT_TABLE_NAME") || "TachyonTable";
    let out_nft = command_output_from_args(["nft", "list", "table", "inet", nft_table]);
    if ((index(out_nft, "dscp set 0x2e") < 0 && index(out_nft, "dscp set ef") < 0) || (index(out_nft, "dscp set 0x22") < 0 && index(out_nft, "dscp set af41") < 0)) {
        ai_heal_report(
            "qos_priority",
            "Правила Игрового & Голосового QoS Ускорителя не найдены в nftables",
            "Применены высокоприоритетные метки DSCP EF (0x2e) для Voice/RTC и DSCP AF41 (0x22) для Gaming",
            "fixed"
        );
        safe_reload_firewall();
        return false;
    }
    return true;
}

function is_dns_working() {
    return command_success_from_args([ "nslookup", "google.com", "127.0.0.1" ]) ||
           command_success_from_args([ "nslookup", "example.com", "127.0.0.1" ]);
}

function ai_heal_dns() {
    let cfg = settings();
    if (cfg.recovery_bypass == "1") return true;

    let sb_pid = get_sing_box_pid();
    if (sb_pid == "" || !process_running(sb_pid, "sing-box")) return true;

    let dns_ok = is_dns_working();
    if (!dns_ok) {
        // Stage 1: Attempt soft sing-box restart without tearing down nftables or network
        command_success_from_args([ "/etc/init.d/sing-box", "restart" ]);
        sleep(2000);
        if (is_dns_working()) {
            ai_heal_report(
                "dns",
                "DNS resolution stalled on sing-box (port 53)",
                "Выполнен быстрейший soft-restart службы sing-box (DNS успешно восстановлен)",
                "fixed"
            );
            return true;
        }

        // Stage 2: Fallback if sing-box soft restart did not restore DNS
        ai_heal_report(
            "dns",
            "DNS resolution failed on sing-box (port 53)",
            "Восстановлена конфигурация dnsmasq и перезапущена служба dhcp",
            "fixed"
        );
        system("/sbin/uci set dhcp.@dnsmasq[0].noresolv='1' >/dev/null 2>&1");
        system("/sbin/uci commit dhcp >/dev/null 2>&1");
        system("/etc/init.d/dnsmasq reload >/dev/null 2>&1");
        return false;
    }
    return true;
}

function ai_heal_proxy_connectivity() {
    let cfg = settings();
    if (cfg.recovery_bypass == "1") return true;

    let sb_pid = get_sing_box_pid();
    if (sb_pid == "" || !process_running(sb_pid, "sing-box")) return true;

    let now = time();
    let proxy_addr = "127.0.0.1:4534";
    if (cached_proxy_port !== null) {
        proxy_addr = "127.0.0.1:" + as_string(cached_proxy_port);
    } else {
        let sb_cfg_data = fs.readfile("/etc/sing-box/config.json");
        if (sb_cfg_data) {
            try {
                let sb_cfg = json(sb_cfg_data);
                if (sb_cfg.inbounds) {
                    for (let inb in sb_cfg.inbounds) {
                        if (inb.type == "http" || inb.type == "mixed") {
                            cached_proxy_port = inb.listen_port || 4534;
                            proxy_addr = "127.0.0.1:" + as_string(cached_proxy_port);
                            break;
                        }
                    }
                }
            } catch(e) {}
        }
    }

    let proxy_ok = command_success_from_args([
        "curl", "-s", "-I", "--connect-timeout", "3", "--max-time", "5",
        "--proxy", "http://" + proxy_addr,
        "https://cp.cloudflare.com/generate_204"
    ]);

    if (!proxy_ok) {
        let direct_ok = command_success_from_args([
            "curl", "-s", "-I", "--connect-timeout", "3", "--max-time", "5",
            "https://cp.cloudflare.com/generate_204"
        ]);
        if (direct_ok) {
            ai_heal_report(
                "proxy",
                "Зависание или неполный отклик прокси-порту sing-box (" + proxy_addr + ")",
                "Очищена база cache.db и выполнен перезапуск sing-box",
                "fixed"
            );
            remove_file("/tmp/sing-box/cache.db");
            safe_proxy_restart("proxy_connectivity");
            return false;
        }
    }
    return true;
}

// ─── Subnet cache restore: /etc/tachyon/rulesets/ → /tmp/sing-box/rulesets/ ──
function ai_heal_subnet_cache() {
    let etc_dir = "/etc/tachyon/rulesets";
    let tmp_dir = "/tmp/sing-box/rulesets";

    let dir = fs.opendir(etc_dir);
    if (!dir) return;

    let restored = [];
    let entry;
    while ((entry = dir.read()) != null) {
        if (!match(entry, /^community-subnets-.+\.lst$/)) continue;
        let tmp_path = tmp_dir + "/" + entry;
        let etc_path = etc_dir + "/" + entry;
        let tmp_st = fs.stat(tmp_path);
        let etc_st = fs.stat(etc_path);
        if (!helpers.file_is_usable(etc_path, 50)) continue;
        if (helpers.file_is_usable(tmp_path, 50)) continue;
        // /tmp file missing or empty, restore from persistent storage
        let content = fs.readfile(etc_path);
        if (content == null || content == "") continue;
        // Ensure /tmp dir exists
        command_success_from_args(["mkdir", "-p", tmp_dir]);
        if (fs.writefile(tmp_path, content) != null) {
            push(restored, entry);
        }
    }
    dir.close();

    if (length(restored) > 0) {
        let names = join(", ", restored);
        log_message("Subnet cache restored from /etc to /tmp: " + names, "info");
    }
}

// ─── Check nft sets are populated (community subnets) ─────────────────────────
function ai_heal_community_subnet_sets() {
    let cfg = settings();
    if (cfg.recovery_bypass == "1") return true;

    // Don't run more than once every 5 minutes
    let now = time();
    if (now - last_subnet_heal_time < 300) return true;
    if (is_reload_in_progress()) return true;

    // Skip if list-update is running (it will populate sets itself)
    let list_update_pid = trim(fs.readfile("/var/run/tachyon_list_update.pid") || "");
    if (process_running(list_update_pid, "ucode")) return true;

    let sb_pid = get_sing_box_pid();
    if (sb_pid == "" || !process_running(sb_pid, "sing-box")) return true;

    let nft_table = getenv("NFT_TABLE_NAME") || "TachyonTable";
    let all_sections = uci_core.get_all(CONFIG_NAME);
    if (!all_sections) return true;

    let empty_sets_found = false;

    for (let sec_name in keys(all_sections)) {
        let s = all_sections[sec_name];
        if (s[".type"] != "section" || s.enabled != "1") continue;
        if (!s.community_lists) continue;

        // Check if the _subnets set exists for this section.
        // If nft returns a valid set definition but no 'elements =' block → it's empty.
        // If nft exits non-zero (set doesn't exist) → section has no subnet community → skip.
        let set_name = "tachyon_rule_" + sec_name + "_subnets";
        let result = command_capture(command_from_args(["nft", "list", "set", "inet", nft_table, set_name]) + " 2>/dev/null");
        if (result.status != 0 || result.output == "") continue; // set doesn't exist for this section
        if (index(result.output, "elements") < 0) {
            log_message("Community subnet set " + set_name + " is empty — will repopulate", "warn");
            empty_sets_found = true;
        }
    }

    if (empty_sets_found) {
        last_subnet_heal_time = now;
        ai_heal_subnet_cache();
        ai_heal_report(
            "nft_community_sets",
            "Пустые nftables sets подсетей (community) — данные не были загружены при reload",
            "Восстановлены nftables sets из persistent кеша (/etc/tachyon/rulesets/)",
            "fixed"
        );
        bg_system("/usr/bin/tachyon reload_firewall </dev/null >/dev/null 2>&1 &");
        return false;
    }
    return true;
}


// ─── TPROXY port liveness check ───────────────────────────────────────────────
function ai_heal_tproxy_port() {
    let cfg = settings();
    if (cfg.recovery_bypass == "1") return true;

    let sb_pid = get_sing_box_pid();
    if (sb_pid == "" || !process_running(sb_pid, "sing-box")) return true;
    if (is_reload_in_progress()) return true;

    // Read TPROXY port from sing-box config
    let tproxy_port = 4530;
    let sb_cfg_data = fs.readfile("/etc/sing-box/config.json");
    if (sb_cfg_data) {
        try {
            let sb_cfg = json(sb_cfg_data);
            if (sb_cfg.inbounds) {
                for (let inb in sb_cfg.inbounds) {
                    if (inb.type == "tproxy") {
                        tproxy_port = int(inb.listen_port || tproxy_port);
                        break;
                    }
                }
            }
        } catch(e) {}
    }

    // Check /proc/net/tcp6 and /proc/net/tcp for the TPROXY port (hex format)
    let hex_port = sprintf("%04X", tproxy_port);
    let listening = false;
    for (let proc_file in ["/proc/net/tcp6", "/proc/net/tcp"]) {
        let tcp_data = fs.readfile(proc_file) || "";
        // Format: local_address (0.0.0.0:PORT in hex), state 0A = LISTEN
        for (let line in split(tcp_data, "\n")) {
            if (index(line, ":" + hex_port + " ") >= 0 && index(line, " 0A ") >= 0) {
                listening = true;
                break;
            }
        }
        if (listening) break;
    }

    if (!listening) {
        ai_heal_report(
            "tproxy_port",
            sprintf("TPROXY порт %d не слушает — правила перехвата трафика не работают", tproxy_port),
            "Выполнен reload_firewall для восстановления TPROXY правил",
            "fixed"
        );
        safe_reload_firewall();
        return false;
    }
    return true;
}

// ─── Fixes undefined function referenced from ubus firewall.reload handler ────
function check_firewall_rules() {
    ai_heal_nftables();
    ai_heal_community_subnet_sets();
}

function ai_heal_wan_and_gateway() {
    let now = time();
    if (now - last_wan_heal_time < 300) return;
    if (is_reload_in_progress()) return;

    let need_restart = false;

    // Check WAN interface
    let proto = uci_core.get("network", "wan", "proto") || "pppoe";
    let device = trim(uci_core.get("network", "wan", "device") || "eth0");
    let iface_to_check = device;
    if (proto == "pppoe") iface_to_check = "pppoe-wan";

    let out = command_capture("ip addr show " + shell_quote(iface_to_check) + " 2>/dev/null").output;
    if (index(out, "inet ") < 0) need_restart = true;

    // Check gateway
    let route_out = command_capture("ip route 2>/dev/null").output;
    if (index(route_out, "default") < 0) need_restart = true;

    if (!need_restart) return;

    last_wan_heal_time = now;
    let tcfg = common.object_or_empty(uci_core.get_all(CONFIG_NAME, "telegram"));
    if (tcfg.notify_crash != "0") {
        send_telegram_notification("⚠️ *Watchdog:* WAN/Gateway проблема. Перезапуск wan...");
    }
    bg_system("/sbin/ifdown wan >/dev/null 2>&1 && /sbin/ifup wan >/dev/null 2>&1 &");
}

function ai_heal_subscriptions() {
    let cfg = settings();
    let sub_url = trim(cfg.subscription_url || "");
    if (sub_url == "") return;

    let res = command_capture("curl -s -o /dev/null -w %{http_code} --connect-timeout 10 " + shell_quote(sub_url) + " 2>&1");
    let code = int(res.output);
    if (res.status == 0 && code >= 200 && code < 400) return;

    let tcfg = common.object_or_empty(uci_core.get_all(CONFIG_NAME, "telegram"));
    if (tcfg.notify_crash != "0") {
        send_telegram_notification("⚠️ *Watchdog:* Подписка недоступна (HTTP " + code + "). Обновите подписку вручную.");
    }
}

function ai_heal_uci_config() {
    let data = fs.readfile("/etc/config/tachyon");
    if (data == null || data == "") {
        let tcfg = common.object_or_empty(uci_core.get_all(CONFIG_NAME, "telegram"));
        if (tcfg.notify_crash != "0") {
            send_telegram_notification("⚠️ *Watchdog:* Конфигурация Tachyon повреждена! Восстановление из backup...");
        }
        let backup = fs.readfile("/etc/backup/tachyon_config");
        if (backup != null && backup != "") {
            let valid = command_success_from_args([ "uci", "-c", "/etc/config", "valid", CONFIG_NAME ]) ||
                        command_success_from_args([ "/sbin/uci", "valid", CONFIG_NAME ]);
            if (!valid) {
                log_message("Backup config also invalid, skipping restore", "warn");
                return;
            }
            let tmp = "/etc/config/tachyon.restore-tmp";
            if (fs.writefile(tmp, backup) != null) {
                fs.rename(tmp, "/etc/config/tachyon");
                system("chmod 0600 /etc/config/tachyon 2>/dev/null");
                safe_proxy_restart("uci_config_restore");
            }
        }
    }
}

// ─── AI Settings helpers ──────────────────────────────────────────────────────
function ai_setting(key, default_val) {
    let cfg = settings();
    let val = cfg[key];
    return val != null ? as_string(val) : as_string(default_val);
}
function ai_enabled(key, default_val) {
    return ai_setting(key, default_val) == "1";
}

// ─── Config validation: sing-box check ────────────────────────────────────────
function validate_singbox_config() {
    if (!ai_enabled("ai_config_validation_enabled", "1")) return true;
    return command_success_from_args(["sing-box", "check", "-c", "/etc/sing-box/config.json"]);
}

// ─── Proxy Health Monitor (fast tier) ─────────────────────────────────────────
function ai_heal_proxy_health() {
    if (!ai_enabled("ai_proxy_health_enabled", "1")) return;
    if (is_reload_in_progress()) return;

    let sb_pid = get_sing_box_pid();
    if (sb_pid == "" || !process_running(sb_pid, "sing-box")) return;

    let proxy_port = "4534";
    let sb_cfg_data = fs.readfile("/etc/sing-box/config.json");
    if (sb_cfg_data) {
        try {
            let sb_cfg = json(sb_cfg_data);
            if (sb_cfg.inbounds) {
                for (let inb in sb_cfg.inbounds) {
                    if (inb.type == "http" || inb.type == "mixed") {
                        proxy_port = as_string(inb.listen_port || 4534);
                        break;
                    }
                }
            }
        } catch(e) {}
    }

    let check_url = ai_setting("ai_proxy_health_url", "https://cp.cloudflare.com/generate_204");
    let threshold = int(ai_setting("ai_proxy_health_fail_threshold", "3"));

    let start_time = time();
    let proxy_ok = command_success_from_args([
        "curl", "-s", "-o", "/dev/null", "-w", "%{http_code}", "--connect-timeout", "3", "--max-time", "5",
        "--proxy", "http://127.0.0.1:" + proxy_port,
        check_url
    ]);
    let elapsed = (time() - start_time) * 1000;

    push(proxy_latency_history, { ok: proxy_ok, ms: elapsed, ts: time() });
    if (length(proxy_latency_history) > 20) {
        let new_arr = [];
        for (let i = length(proxy_latency_history) - 20; i < length(proxy_latency_history); i++)
            push(new_arr, proxy_latency_history[i]);
        proxy_latency_history = new_arr;
    }

    if (!proxy_ok) {
        proxy_consecutive_fails++;
        if (proxy_consecutive_fails >= threshold) {
            ai_heal_report(
                "proxy_health",
                sprintf("Proxy health check failed %d times consecutively (port %s)", proxy_consecutive_fails, proxy_port),
                "Restarting Tachyon to restore proxy connectivity",
                "fixed"
            );
            if (ai_enabled("ai_config_validation_enabled", "1") && !validate_singbox_config()) {
                log_message("sing-box config validation failed before proxy restart", "err");
                return;
            }
            safe_proxy_restart("proxy_health");
            proxy_consecutive_fails = 0;
        }
    } else {
        proxy_consecutive_fails = 0;
    }
}

// ─── DNS Continuous Check (fast tier) ─────────────────────────────────────────
function ai_heal_dns_continuous() {
    if (!ai_enabled("ai_dns_continuous_enabled", "1")) return;
    if (is_reload_in_progress()) return;

    let sb_pid = get_sing_box_pid();
    if (sb_pid == "" || !process_running(sb_pid, "sing-box")) return;

    let start_time = time();
    let dns_ok = is_dns_working();
    let elapsed = (time() - start_time) * 1000;

    push(dns_latency_history, { ok: dns_ok, ms: elapsed, ts: time() });
    if (length(dns_latency_history) > 20) {
        let new_arr = [];
        for (let i = length(dns_latency_history) - 20; i < length(dns_latency_history); i++)
            push(new_arr, dns_latency_history[i]);
        dns_latency_history = new_arr;
    }

    if (!dns_ok) {
        dns_consecutive_fails++;
        if (dns_consecutive_fails >= 3) {
            ai_heal_report(
                "dns_continuous",
                "DNS resolution failed 3 times consecutively",
                "Restoring dnsmasq config and reloading",
                "fixed"
            );
            system("/sbin/uci set dhcp.@dnsmasq[0].noresolv='1' >/dev/null 2>&1");
            system("/sbin/uci commit dhcp >/dev/null 2>&1");
            system("/etc/init.d/dnsmasq reload >/dev/null 2>&1");
            dns_consecutive_fails = 0;
        }
    } else {
        dns_consecutive_fails = 0;
    }
}

// ─── AI Empty Sections Recovery ─────────────────────────────────────────────
let last_section_heal_attempt = 0;
function ai_heal_empty_sections() {
    if (!ai_enabled("ai_section_failover_enabled", "1")) return;
    if (is_reload_in_progress()) return;
    let now = time();
    if (now - last_section_heal_attempt < 120) return;
    last_section_heal_attempt = now;

    let cfg = settings();
    let sections = common.object_or_empty(uci_core.get_all(CONFIG_NAME));
    let recovered = [];

    for (let name in sections) {
        let s = common.object_or_empty(sections[name]);
        let action = common.as_string(s.action || "");
        if (!connections.is_connections_action(action)) continue;
        let sub_urls = common.list_option(s, "subscription_url");
        if (length(sub_urls) == 0) continue;

        let cache_path = "/var/run/tachyon/section-cache/" + name + ".json";
        let cache = common.object_or_empty(common.read_json_file(cache_path));
        let servers = common.array_or_empty(cache.servers);
        let urls = common.array_or_empty(cache.urls);
        let selector_urls = common.array_or_empty(cache.selector_urls);
        let domains = common.array_or_empty(cache.domain);
        let domain_suffixes = common.array_or_empty(cache.domain_suffix);
        let ip_cidrs = common.array_or_empty(cache.ip_cidr);
        let usable = length(servers) + length(urls) + length(selector_urls) + length(domains) + length(domain_suffixes) + length(ip_cidrs);
        if (usable > 0) continue;

        // Section with subscriptions but 0 usable outbounds — trigger async reload
        log_message("Empty proxy section '" + name + "' — triggering subscription update", "warn");
        bg_system("/usr/bin/tachyon subscription_update_async " + common.shell_quote(name) + " </dev/null >/dev/null 2>&1 1000<&- &");
        push(recovered, name);
    }

    if (length(recovered) > 0) {
        ai_heal_report(
            "empty_proxy_sections",
            "Empty proxy sections detected: " + join(", ", recovered),
            "Auto-triggering subscription update for " + as_string(length(recovered)) + " section(s)",
            "fixed"
        );
    }
}

// ─── DNS Loop Recovery (dead proxy + DNS detour = total DNS loss) ────────────
let DNS_RECOVERY_STATE_FILE = "/var/run/tachyon/dns-detour-recovery.json";
let dns_recovery_active = false;

function is_dns_dead() {
    return !is_dns_working();
}

function read_dns_recovery_state() {
    let data = common.read_json_file(DNS_RECOVERY_STATE_FILE);
    return common.object_or_empty(data);
}

function write_dns_recovery_state(state) {
    common.write_json_file(DNS_RECOVERY_STATE_FILE, state);
}

function remove_dns_recovery_state() {
    try { fs.unlink(DNS_RECOVERY_STATE_FILE); } catch(e) {}
}

let last_dns_loop_heal_attempt = 0;
function ai_heal_dns_loop() {
    if (!ai_enabled("ai_dns_loop_heal_enabled", "1")) return;
    if (is_reload_in_progress()) return;
    let now = time();
    if (now - last_dns_loop_heal_attempt < 60) return;
    last_dns_loop_heal_attempt = now;

    let cfg = settings();
    let detour_enabled = common.bool_option(cfg, "dns_detour_enabled", false);
    if (!detour_enabled) return;

    let detour_section = common.option(cfg, "dns_detour_section", "");
    if (detour_section == "") return;

    // Check if DNS is dead
    if (!is_dns_dead()) {
        // DNS works — if we were in recovery, try to restore
        let recovery = read_dns_recovery_state();
        if (recovery.phase == "detour_disabled") {
            let reenable_cooldown = recovery.ts ? (now - int(recovery.ts)) : 0;
            if (reenable_cooldown < 300) return;
            let test_dns = is_dns_working();
            if (test_dns) {
                log_message("DNS loop recovery: DNS works, re-enabling DNS detour section", "info");
                system("/sbin/uci set tachyon.settings.dns_detour_enabled='1' >/dev/null 2>&1");
                system("/sbin/uci commit tachyon >/dev/null 2>&1");
                safe_proxy_restart("dns_loop_recovery");
                remove_dns_recovery_state();
                ai_heal_report(
                    "dns_loop_recovery",
                    "DNS recovered with detour re-enabled",
                    "Restored DNS detour section " + detour_section,
                    "fixed"
                );
            }
        }
        return;
    }

    // DNS is dead — check if detour section has outbounds
    let recovery = read_dns_recovery_state();
    if (recovery.phase == "detour_disabled") {
        // Already in recovery — just wait and retry
        log_message("DNS loop recovery: DNS still dead, retrying subscription update", "info");
        bg_system("/usr/bin/tachyon subscription_update_async " + common.shell_quote(detour_section) + " </dev/null >/dev/null 2>&1 1000<&- &");
        return;
    }

    // Check if detour section is empty
    let cache_path = "/var/run/tachyon/section-cache/" + detour_section + ".json";
    let cache = common.object_or_empty(common.read_json_file(cache_path));
    let servers = common.array_or_empty(cache.servers);
    let urls = common.array_or_empty(cache.urls);
    let usable = length(servers) + length(urls);

    if (usable > 0) {
        // Section has outbounds but DNS is still dead — may be transient
        return;
    }

    // Detour section empty AND DNS dead — disable DNS detour to recover
    log_message("DNS loop detected: DNS detour section '" + detour_section + "' is empty, disabling DNS detour to recover", "warn");
    system("/sbin/uci set tachyon.settings.dns_detour_enabled='0' >/dev/null 2>&1");
    system("/sbin/uci commit tachyon >/dev/null 2>&1");
    safe_proxy_restart("dns_loop_disable");
    write_dns_recovery_state({ phase: "detour_disabled", section: detour_section, ts: now });

    // Trigger subscription update for the empty section
    bg_system("/usr/bin/tachyon subscription_update_async " + common.shell_quote(detour_section) + " </dev/null >/dev/null 2>&1 1000<&- &");

    ai_heal_report(
        "dns_loop_detected",
        "DNS loop: detour section '" + detour_section + "' has 0 outbounds, DNS completely dead",
        "Temporarily disabled DNS detour to restore DNS, triggered subscription reload",
        "fixed"
    );
}

// ─── Metrics helpers ──────────────────────────────────────────────────────────
// Defined before export_metrics to ensure forward-reference safety in ucode
// closure/timer contexts (see issue #14).
function average_latency(history) {
    let sum = 0;
    let count = 0;
    for (let entry in history) {
        if (entry.ok) {
            sum += entry.ms;
            count++;
        }
    }
    return count > 0 ? int(sum / count) : -1;
}

// ─── Metrics export (normal tier) ─────────────────────────────────────────────
function export_metrics() {
    if (!ai_enabled("ai_metrics_enabled", "1")) return;

    let now = time();
    let metrics_path = "/tmp/tachyon_metrics.json";
    let data = { hours: [] };
    let existing = fs.readfile(metrics_path);
    if (existing) {
        try { data = json(existing) || data; } catch(e) {}
    }

    let hour_bucket = int(now / 3600) * 3600;
    let last_bucket = length(data.hours) > 0 ? data.hours[length(data.hours) - 1] : null;
    if (last_bucket && int(last_bucket.ts) == hour_bucket) {
        last_bucket.proxy_ok = proxy_consecutive_fails == 0;
        last_bucket.proxy_lat_ms = average_latency(proxy_latency_history);
        last_bucket.dns_lat_ms = average_latency(dns_latency_history);
        last_bucket.incidents = ai_incidents_count;
    } else {
        push(data.hours, {
            ts: hour_bucket,
            proxy_ok: proxy_consecutive_fails == 0,
            proxy_lat_ms: average_latency(proxy_latency_history),
            dns_lat_ms: average_latency(dns_latency_history),
            incidents: ai_incidents_count
        });
    }

    let retention = int(ai_setting("ai_metrics_retention_hours", "24"));
    while (length(data.hours) > retention)
        data.hours = slice(data.hours, 1);

    fs.writefile(metrics_path, sprintf("%J\n", data));
}

// ─── Anomaly Detection (slow tier) ────────────────────────────────────────────
function analyze_anomalies() {
    if (!ai_enabled("ai_anomaly_detection_enabled", "1")) return;

    let now = time();
    if (now - last_anomaly_check < 300) return;
    last_anomaly_check = now;

    let threshold = int(ai_setting("ai_anomaly_reconnect_threshold", "10"));
    let count_file = "/tmp/tachyon_reconnect_count";
    let count_data = fs.readfile(count_file) || "0";
    let reconnects = int(trim(count_data));

    if (reconnects > threshold) {
        ai_heal_report(
            "anomaly_reconnects",
            sprintf("sing-box reconnected %d times in the last hour (threshold: %d)", reconnects, threshold),
            "High reconnect rate detected. Check proxy server health or ISP stability.",
            "warn"
        );
        fs.writefile(count_file, "0\n");
    }
}

function increment_reconnect_count() {
    let count_file = "/tmp/tachyon_reconnect_count";
    let count = int(trim(fs.readfile(count_file) || "0")) + 1;
    fs.writefile(count_file, as_string(count) + "\n");
}

// ─── Adaptive Intervals ───────────────────────────────────────────────────────
function adaptive_normal_interval() {
    if (!ai_enabled("ai_adaptive_intervals_enabled", "1")) return 120;
    return ai_healthy_streak > 25 ? 300 : 120;
}

// ─── Graceful Degradation wrapper ─────────────────────────────────────────────
function safe_call(fn, name) {
    if (!ai_enabled("ai_graceful_degradation_enabled", "1")) {
        fn();
        return;
    }
    try {
        fn();
    } catch(e) {
        log_message("Graceful degradation: " + name + " failed: " + as_string(e), "err");
    }
}

// ─── rpcd FD leak watchdog ────────────────────────────────────────────────────
// rpcd accumulates file descriptors over time from LuCI API calls.
// When FD count approaches the process limit (~1024), it can no longer
// fork to execute /usr/bin/tachyon → LuCI shows everything as "stopped".
// Threshold 512 = 50% of limit, safe to restart without user impact.
const RPCD_FD_THRESHOLD = 512;

function ai_heal_rpcd() {
    // Find rpcd PID via /proc scan (avoid shell fork for pidof)
    let rpcd_pid = null;
    let proc_dir = fs.opendir("/proc");
    if (!proc_dir) return true;
    let entry;
    while ((entry = proc_dir.read()) != null) {
        if (!match(entry, /^[0-9]+$/)) continue;
        let comm = trim(fs.readfile("/proc/" + entry + "/comm") || "");
        if (comm == "rpcd") { rpcd_pid = entry; break; }
    }
    proc_dir.close();
    if (!rpcd_pid) return true;

    // Count open file descriptors
    let fd_dir = fs.opendir("/proc/" + rpcd_pid + "/fd");
    if (!fd_dir) return true;
    let fd_count = 0;
    while ((entry = fd_dir.read()) != null) {
        if (match(entry, /^[0-9]+$/)) fd_count++;
    }
    fd_dir.close();

    if (fd_count > RPCD_FD_THRESHOLD) {
        ai_heal_report(
            "rpcd_fd_leak",
            sprintf("rpcd накопил %d открытых FD (порог %d/1024) — LuCI не может запускать команды", fd_count, RPCD_FD_THRESHOLD),
            "Выполнен перезапуск rpcd для освобождения файловых дескрипторов",
            "fixed"
        );
        system("/etc/init.d/rpcd restart </dev/null >/dev/null 2>&1");
        return false;
    }
    return true;
}

// ─── Full health audit ────────────────────────────────────────────────────────
function ai_full_health_audit() {
    safe_call(check_memory, "check_memory");
    safe_call(ai_heal_rpcd, "ai_heal_rpcd");
    safe_call(ai_heal_nftables, "ai_heal_nftables");
    safe_call(ai_heal_qos, "ai_heal_qos");
    safe_call(ai_heal_dns, "ai_heal_dns");
    safe_call(ai_heal_proxy_connectivity, "ai_heal_proxy_connectivity");
    safe_call(ai_heal_community_subnet_sets, "ai_heal_community_subnet_sets");
    safe_call(ai_heal_wan_and_gateway, "ai_heal_wan_and_gateway");
    safe_call(ai_heal_subscriptions, "ai_heal_subscriptions");
    safe_call(ai_heal_uci_config, "ai_heal_uci_config");
    safe_call(ai_heal_tproxy_port, "ai_heal_tproxy_port");
    safe_call(ai_export_status, "ai_export_status");
}

function check_urltest_switches() {
    let now = time();
    if (now - last_urltest_check < 5) return;
    last_urltest_check = now;

    let tcfg = common.object_or_empty(uci_core.get_all(CONFIG_NAME, "telegram"));
    if (tcfg.enabled != "1" || tcfg.notify_crash == "0") return;

    let p_res = command_capture(command_from_args(["curl", "-s", "http://127.0.0.1:4534/proxies"]));
    if (p_res && p_res.status == 0 && p_res.output) {
        try {
            let p_data = json(p_res.output);
            let proxies = p_data.proxies;
            for (let name in proxies) {
                let p = proxies[name];
                if (p.type == "URLTest" && p.now) {
                    let safe_name = replace(name, /[^a-zA-Z0-9_\-]/g, "_");
                    let last_now = trim(fs.readfile("/tmp/watchdog_urltest_" + safe_name) || "");
                    if (last_now != "" && last_now != p.now) {
                        send_telegram_notification("🔀 *Watchdog:* Смена прокси в группе `" + name + "`\nНовый активный узел: `" + p.now + "`");
                    }
                    fs.writefile("/tmp/watchdog_urltest_" + safe_name, p.now);
                }
            }
        } catch(e) {}
    }
}

function smart_detect_process_pending() {
    let cfg = settings();
    if (cfg.smart_detect != "1") {
        pending_smart_domains = {};
        return;
    }
    let now = time();
    if (now - smart_detect_last_run < 30) return;

    let domain_list = keys(pending_smart_domains);
    if (length(domain_list) == 0) return;
    smart_detect_last_run = now;

    let seen = {};
    let seen_data = fs.readfile(SMART_DETECT_SEEN_FILE);
    if (seen_data) {
        try { seen = json(seen_data) || {}; } catch(e) {}
    }

    let candidate_domains = [];
    for (let dom in domain_list) {
        if (!seen[dom]) {
            push(candidate_domains, dom);
        }
    }
    pending_smart_domains = {};

    if (length(candidate_domains) == 0) return;

    let sections = smart_detect_get_proxy_sections();
    if (length(sections) == 0) return;

    let proxy_addr = "127.0.0.1:4534";
    let sb_cfg_data = fs.readfile("/etc/sing-box/config.json");
    if (sb_cfg_data) {
        try {
            let sb_cfg = json(sb_cfg_data);
            if (sb_cfg.inbounds) {
                for (let inb in sb_cfg.inbounds) {
                    if (inb.type == "http" || inb.type == "mixed") {
                        proxy_addr = "127.0.0.1:" + as_string(inb.listen_port || 4534);
                        break;
                    }
                }
            }
        } catch(e) {}
    }

    let detect_sections = [];
    let raw_list = cfg.smart_detect_sections;
    if (type(raw_list) == "array") {
        detect_sections = raw_list;
    } else if (raw_list && trim(as_string(raw_list)) != "") {
        detect_sections = [ trim(as_string(raw_list)) ];
    }
    if (length(detect_sections) == 0) {
        detect_sections = sections;
    }

    for (let domain in candidate_domains) {
        try {
        seen[domain] = now;

        // DNS pre-check: skip if domain doesn't resolve at all (not a block, DNS fault)
        if (!smart_detect_domain_resolves(domain)) {
            log_message("Smart Detect: " + domain + " does not resolve via DNS, skipping", "debug");
            continue;
        }

        let direct_ok = command_success_from_args([
            "curl", "-s", "-I", "--connect-timeout", "4", "--max-time", "6",
            "https://" + domain
        ]);
        if (direct_ok) continue;

        // Single probe through the shared http/mixed inbound. This inbound follows
        // the global routing rules, so it cannot be aimed at one specific section:
        // the result is the same for every candidate section. Probe once, then hand
        // the domain to the first section that accepts it (user-defined order).
        let proxy_ok = command_success_from_args([
            "curl", "-s", "-I", "--connect-timeout", "5", "--max-time", "8",
            "--proxy", "http://" + proxy_addr,
            "https://" + domain
        ]);
        if (!proxy_ok) {
            log_message("Smart Detect: " + domain + " fails directly and via proxy, skipping", "info");
            continue;
        }

        let added = false;
        for (let sec_name in detect_sections) {
            sec_name = trim(as_string(sec_name));
            if (sec_name == "") continue;

            log_message("Smart Detect: adding " + domain + " to section " + sec_name, "info");
            if (smart_detect_add_domain(sec_name, domain)) {
                let tcfg = common.object_or_empty(uci_core.get_all(CONFIG_NAME, "telegram"));
                if (tcfg.enabled == "1" && tcfg.bot_token && tcfg.admin_ids) {
                    send_telegram_notification(
                        "🔍 *Smart Detect*: `" + domain + "` недоступен напрямую, работает через прокси.\nДобавлен в секцию *" + sec_name + "*."
                    );
                }
                added = true;
                break;
            }
        }
        if (!added) {
            log_message("Smart Detect: domain " + domain + " not handled by any section", "info");
        }
        } catch (e) {
            log_message("Smart Detect: failed to process " + domain + ": " + as_string(e), "err");
        }
    }

    let clean = {};
    let cutoff = now - 86400;
    for (let k in keys(seen)) {
        if (seen[k] >= cutoff) clean[k] = seen[k];
    }
    fs.writefile(SMART_DETECT_SEEN_FILE, sprintf("%J", clean));
}

function handle_log_line(line) {
    if (!line || line == "") return;

    // Fast keyword pre-filter: skip 95%+ of irrelevant log lines instantly
    if (index(line, "direct") < 0 && index(line, "DIRECT") < 0 &&
        index(line, "memory") < 0 && index(line, "oom") < 0 && index(line, "OOM") < 0 &&
        index(line, "URLTest") < 0 && index(line, "proxy") < 0) {
        return;
    }
    let line_lower = lc(line);

    // 1. OOM Detection (Kernel OOM-killer or sing-box process OOM crash only)
    let is_oom = (index(line_lower, "oom-killer") >= 0 ||
                  index(line_lower, "out of memory: kill process") >= 0 ||
                  (index(line_lower, "kernel:") >= 0 && index(line_lower, "out of memory") >= 0) ||
                  (index(line_lower, "sing-box") >= 0 && index(line_lower, "out of memory") >= 0) ||
                  index(line_lower, "fatal error: out of memory") >= 0);
    let is_netlink_warning = (index(line_lower, "netlink") >= 0 || index(line_lower, "nlbwmon") >= 0);

    if (is_oom && !is_netlink_warning) {
        let now = time();
        // Ignore replay of old historical log buffer dumped when logread -f starts
        if (syslog_start_time > 0 && (now - syslog_start_time > 3) && (now - last_oom_time > 60)) {
            last_oom_time = now;
            log_message("OOM event detected from syslog! Reducing GOMEMLIMIT scaling...", "err");
            send_telegram_notification("🚨 *Watchdog:* Обнаружено событие OOM (Out Of Memory)! Уменьшаю GOMEMLIMIT и перезапускаю службы...");
            let scale = 1.0;
            let scale_path = "/etc/tachyon/mem_scale";
            let scale_data = fs.readfile(scale_path);
            if (scale_data != null) {
                let parsed_scale = double(trim(as_string(scale_data)));
                if (parsed_scale > 0.1) scale = parsed_scale;
            }
            let new_scale = scale * 0.8;
            if (new_scale < 0.2) new_scale = 0.2;
            fs.mkdir("/etc/tachyon");
            fs.writefile(scale_path, sprintf("%.2f", new_scale));
            system("logread -c >/dev/null 2>&1");
            command_status("/usr/bin/tachyon restart >/dev/null 2>&1");
        }
        return;
    }

    // 2. Smart Detect candidate domain extraction
    let cfg = settings();
    if (cfg.smart_detect == "1") {
        if ((index(line_lower, "direct") >= 0 || index(line_lower, "DIRECT") >= 0) &&
            (index(line_lower, "failed") >= 0 || index(line_lower, "timeout") >= 0 || index(line_lower, "reset") >= 0)) {
            let domain = smart_detect_extract_domain(line);
            if (domain != null) {
                pending_smart_domains[domain] = time();
            }
        }
    }

    // 3. URLTest proxy switch notifications
    if (index(line, "URLTest") >= 0 || index(line_lower, "selected proxy") >= 0 || index(line_lower, "switch proxy") >= 0) {
        check_urltest_switches();
    }
}

function setup_honeypot_listener() {
    system("mkfifo /tmp/tachyon_honeypot.fifo >/dev/null 2>&1");
    system("chmod 0660 /tmp/tachyon_honeypot.fifo >/dev/null 2>&1");

    let hp_pid = trim(fs.readfile("/var/run/tachyon_honeypot_listener.pid") || "");
    if (hp_pid != "" && match(hp_pid, /^[0-9]+$/) != null) {
        if (process_running(hp_pid)) {
            command_success_from_args([ "kill", hp_pid ]);
            let wait_limit = 20;
            while (wait_limit > 0 && process_running(hp_pid)) {
                sleep(100);
                wait_limit--;
            }
            if (process_running(hp_pid)) {
                command_success_from_args([ "kill", "-9", hp_pid ]);
            }
        }
    }
    remove_file("/var/run/tachyon_honeypot_listener.pid");

    let fifo_fd = fs.open("/tmp/tachyon_honeypot.fifo", "r+");
    if (uloop && fifo_fd) {
        try {
            uloop.handle(fifo_fd.fileno(), function(events) {
                let line;
                while ((line = fifo_fd.read("line")) != null) {
                    let ip = trim(as_string(line));
                    if (ip != "" && match(ip, /^[0-9a-fA-F:.]+$/) != null) {
                        let cfg = settings();
                        let ttl = cfg.honeypot_ttl || "86400";
                        let nft_table = getenv("NFT_TABLE_NAME") || "TachyonTable";
                        command_success_from_args(["nft", "add", "element", "inet", nft_table, "tachyon_honeypot", "{", ip, "timeout", ttl + "s", "}"]);
                    }
                }
            }, uloop.ULOOP_READ);
        } catch (e) {
            log_message("Failed to bind honeypot fifo to uloop: " + as_string(e), "warn");
        }
    } else {
        let cfg = settings();
        let ttl = cfg.honeypot_ttl || "86400";
        let nft_table = getenv("NFT_TABLE_NAME") || "TachyonTable";
        let hp_cmd = "tail -f /tmp/tachyon_honeypot.fifo | while read ip; do " +
            "if [ -n \"$ip\" ]; then " +
            "nft add element inet " + shell_quote(nft_table) + " tachyon_honeypot { \"$ip\" timeout " + shell_quote(ttl) + "s } >/dev/null 2>&1; " +
            "fi; done </dev/null >/dev/null 2>&1 1000<&- & echo $! > /var/run/tachyon_honeypot_listener.pid";
        system(hp_cmd);
    }
}

function recover_oom_scale() {
    let now = time();
    if (now - last_oom_time < 1800) return;
    if (last_oom_time == 0) return;
    if (now - last_oom_recovery_time < 600) return;
    last_oom_recovery_time = now;

    let scale_path = "/etc/tachyon/mem_scale";
    let scale_data = fs.readfile(scale_path);
    if (scale_data == null) return;
    let current_scale = double(trim(as_string(scale_data)));
    if (current_scale >= 1.0 || current_scale < 0.1) {
        if (current_scale >= 1.0) try { fs.unlink(scale_path); } catch(e) {}
        return;
    }
    let new_scale = current_scale + 0.05;
    if (new_scale > 1.0) new_scale = 1.0;
    log_message("OOM recovery: restoring GOMEMLIMIT scale from " + sprintf("%.2f", current_scale) + " to " + sprintf("%.2f", new_scale), "info");
    try { fs.writefile(scale_path, sprintf("%.2f", new_scale)); } catch(e) {}
}

function setup_syslog_listener() {
    if (!uloop) return null;
    syslog_start_time = time();
    // Kill orphaned logread -f processes from previous watchdog instances.
    // Without this, every restart cascades: new watchdog inherits old watchdog's
    // logread pipe read-end, keeping old logread alive. Over N restarts,
    // watchdog accumulates N inherited FDs → hits 1024 limit → config generator fails.
    // Use pkill to target only logread in follow mode, not one-shot logread calls.
    system("pkill -f 'logread -f' 2>/dev/null; true");
    let log_pipe = fs.popen("logread -f 2>/dev/null", "r");
    if (!log_pipe) return null;
    // Track the FD so bg_system() can close it before spawning background processes
    logread_pipe_fd = log_pipe.fileno();

    try {
        uloop.handle(log_pipe.fileno(), function(events) {
            let line;
            while ((line = log_pipe.read("line")) != null) {
                handle_log_line(trim(as_string(line)));
            }
        }, uloop.ULOOP_READ);
    } catch (e) {
        log_message("Failed to register syslog listener: " + as_string(e), "warn");
    }
    return log_pipe;
}

function setup_ubus_listener() {
    if (!ubus || !uloop) return null;
    let conn = null;
    try { conn = ubus.connect(); } catch (e) {}
    if (!conn || type(conn.listener) != "function") return null;

    try {
        conn.listener("service.instance.stop", function(ev, msg) {
            if (type(msg) == "object" && msg.name == "sing-box") {
                handle_singbox_stop_event("ubus service.instance.stop event");
            }
        });
        conn.listener("service.stop", function(ev, msg) {
            if (type(msg) == "object" && msg.name == "sing-box") {
                handle_singbox_stop_event("ubus service.stop event");
            }
        });
        conn.listener("firewall.reload", function(ev, msg) {
            check_firewall_rules();
        });
    } catch (e) {
        log_message("Failed to register ubus listeners: " + as_string(e), "warn");
    }
    return conn;
}

function worker() {
    log_message("Watchdog daemon started.", "info");

    setup_honeypot_listener();
    // Restore subnet cache from persistent storage at startup (in case /tmp was cleared)
    ai_heal_subnet_cache();
    run_zero_rtt_prefetching();

    // Ensure /etc/tachyon exists for persistent smart detect
    try { fs.mkdir("/etc/tachyon"); } catch(e) {}

    // H-14: Save config backup after successful start
    let current_cfg = fs.readfile("/etc/config/tachyon");
    if (current_cfg != null && current_cfg != "") {
        try { fs.writefile("/etc/backup/tachyon_config", current_cfg); } catch(e) {}
    }

    // H-8: Write keepalive timestamp for init.d supervision
    try { fs.writefile("/var/run/tachyon_watchdog.keepalive", as_string(time())); } catch(e) {}

    if (uloop) {
        try {
            uloop.init();
        } catch (e) {
            log_message("Failed to initialize uloop: " + as_string(e), "warn");
        }
    }

    let log_pipe = setup_syslog_listener();
    let ubus_conn = setup_ubus_listener();

    function perform_fast_checks() {
        safe_call(check_singbox_process, "check_singbox_process");
        safe_call(ai_heal_proxy_health, "ai_heal_proxy_health");
        safe_call(ai_heal_dns_continuous, "ai_heal_dns_continuous");
    }

    function perform_normal_checks() {
        safe_call(check_auto_resume_pause, "check_auto_resume_pause");
        safe_call(ai_full_health_audit, "ai_full_health_audit");
        safe_call(smart_detect_process_pending, "smart_detect_process_pending");
        safe_call(export_metrics, "export_metrics");
    }

    function perform_slow_checks() {
        safe_call(ai_heal_community_subnet_sets, "ai_heal_community_subnet_sets");
        safe_call(ai_heal_tproxy_port, "ai_heal_tproxy_port");
        safe_call(ai_heal_subscriptions, "ai_heal_subscriptions");
        safe_call(ai_heal_uci_config, "ai_heal_uci_config");
        safe_call(ai_heal_empty_sections, "ai_heal_empty_sections");
        safe_call(ai_heal_dns_loop, "ai_heal_dns_loop");
        safe_call(analyze_anomalies, "analyze_anomalies");
        safe_call(recover_oom_scale, "recover_oom_scale");
    }

    if (uloop) {
        let tick;
        tick = function() {
            let now = time();
            try {
                try { fs.writefile("/var/run/tachyon_watchdog.keepalive", as_string(time())); } catch(e) {}
                if (now - last_fast_check >= 15) {
                    last_fast_check = now;
                    perform_fast_checks();
                }
                if (now - last_normal_check >= adaptive_normal_interval()) {
                    last_normal_check = now;
                    perform_normal_checks();
                }
                if (now - last_slow_check >= 300) {
                    last_slow_check = now;
                    perform_slow_checks();
                }
            } catch (e) {
                log_message("Error in tick: " + as_string(e), "err");
            }
            uloop.timer(5000, tick);
        };
        uloop.timer(10000, tick);

        log_message("Watchdog running in event-driven uloop mode (fast: 15s, normal: adaptive, slow: 300s).", "info");
        uloop.run();
    } else {
        log_message("uloop not available. Running Watchdog in legacy fallback loop mode.", "warn");
        signal("SIGTERM", function(sig) { log_message("SIGTERM received, shutting down", "info"); stop_runtime(); exit(0); });
        signal("SIGINT", function(sig) { log_message("SIGINT received, shutting down", "info"); stop_runtime(); exit(0); });
        while (true) {
            perform_fast_checks();
            perform_normal_checks();
            perform_slow_checks();
            sleep(15000);
        }
    }

    if (log_pipe) log_pipe.close();
    if (ubus_conn) try { ubus_conn.close(); } catch (e) {}
    return 0;
}

function get_status() {
    let pid = trim(fs.readfile(PID_FILE) || "");
    if (process_running(pid, "ucode")) {
        print("running (pid " + pid + ")\n");
        return 0;
    }
    print("stopped\n");
    return 1;
}

function print_ai_status() {
    let data = fs.readfile("/tmp/tachyon_ai_status.json");
    if (data) {
        print(data);
    } else {
        print("{\"status\":\"unknown\",\"ai_active\":false}\n");
    }
}

function print_ai_status_full() {
    let now = time();
    let proxy_ok = proxy_consecutive_fails == 0;
    let dns_ok = dns_consecutive_fails == 0;

    let sb_uptime = 0;
    let sb_pid = get_sing_box_pid();
    if (sb_pid != "" && process_running(sb_pid, "sing-box")) {
        try {
            let stat_data = fs.readfile("/proc/" + sb_pid + "/stat");
            if (stat_data) {
                let fields = split(trim(stat_data), /[ \t]+/);
                if (length(fields) >= 22) {
                    let starttime = int(fields[21]);
                    let clk_tck = 100;
                    let uptime_seconds = 0;
                    try { uptime_seconds = int(trim(fs.readfile("/proc/uptime") || "0")); } catch(e) {}
                    sb_uptime = uptime_seconds - int(starttime / clk_tck);
                }
            }
        } catch(e) {}
    }

    let mem_mb = -1;
    let mem_info = fs.readfile("/proc/meminfo") || "";
    for (let line in split(mem_info, "\n")) {
        if (index(line, "MemAvailable:") == 0) {
            let fields = split(trim(line), /[ \t]+/);
            if (length(fields) >= 2) mem_mb = int(fields[1]) / 1024;
            break;
        }
    }

    let status = last_ai_incident != null && (now - last_ai_incident.timestamp < 300) ? "repaired" : "healthy";

    let result = {
        status: status,
        ai_active: true,
        uptime_s: sb_uptime,
        memory_mb: mem_mb,
        proxy_ok: proxy_ok,
        proxy_latency_ms: average_latency(proxy_latency_history),
        proxy_consecutive_fails: proxy_consecutive_fails,
        dns_ok: dns_ok,
        dns_latency_ms: average_latency(dns_latency_history),
        dns_consecutive_fails: dns_consecutive_fails,
        incidents_total: ai_incidents_count,
        last_incident: last_ai_incident,
        healthy_streak: ai_healthy_streak,
        adaptive_interval_s: adaptive_normal_interval(),
        reconnects_hour: int(trim(fs.readfile("/tmp/tachyon_reconnect_count") || "0"))
    };

    print(sprintf("%J\n", result));
}

let mode = (ARGV[0] == "") ? ARGV[1] : ARGV[0];
if (!mode) mode = "";

if (mode == "start-runtime")
    exit(start_runtime());
else if (mode == "stop-runtime")
    exit(stop_runtime());
else if (mode == "worker")
    exit(worker());
else if (mode == "status")
    exit(get_status());
else if (mode == "ai-heal") {
    ai_full_health_audit();
    print_ai_status();
    exit(0);
}
else if (mode == "ai-status") {
    print_ai_status();
    exit(0);
}
else if (mode == "ai-status-full") {
    print_ai_status_full();
    exit(0);
}
else if (mode == "smart-detect-extract-domain") {
    let extracted = smart_detect_extract_domain(ARGV[1]);
    if (extracted == null) exit(1);
    print(extracted + "\n");
    exit(0);
}
else {
    warn("Usage: service/watchdog.uc <start-runtime|stop-runtime|worker|status|ai-heal|ai-status|ai-status-full|smart-detect-extract-domain> ...\n");
    exit(1);
}
