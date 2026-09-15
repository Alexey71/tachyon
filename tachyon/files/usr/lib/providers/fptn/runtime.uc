#!/usr/bin/env ucode

let fs = require("fs");
let common = require("core.common");
let uci_core = require("core.uci");
let connections = require("config.connections");

let as_string = common.as_string;
let bool_value = common.bool_value;
let write_json = common.write_json;
let shell_quote = common.shell_quote;
let command_from_args = common.command_from_args;
let command_output = common.command_output;
let command_status = common.command_status;
let command_success_from_args = common.command_success_from_args;
let object_or_empty = common.object_or_empty;
let option = common.option;
let bool_option = common.bool_option;
let section_name = common.section_name;
let remove_file = common.remove_file;

const MODE = as_string(getenv("TACHYON_CONFIG_NAME")) || "tachyon";
const LIB_DIR = as_string(getenv("TACHYON_LIB_DIR")) || "/usr/lib/tachyon";
const CONFIG_NAME = MODE;

let cfg = require("providers.fptn.common").config({ lib_dir: LIB_DIR });

function log_message(msg, level) {
    level = level || "info";
    command_status("logger -t tachyon-fptn -p " + (level == "fatal" ? "user.err" : level == "warn" ? "user.warning" : "user.info") + " " + shell_quote(msg));
}

function provider_available() {
    let st = fs.stat(cfg.binary);
    return st != null && st.mode != null && (int(st.mode) & 73) != 0;
}

function enabled_sections() {
    if (connections && connections.fptn_sections)
        return connections.fptn_sections();

    let result = [];
    let sections = uci_core.section_objects(CONFIG_NAME, "section");
    for (let s in sections) {
        if (bool_option(s, "enabled", true) && option(s, "action", "") == "fptn")
            push(result, s);
    }
    return result;
}

function enabled_rule_count() {
    return length(enabled_sections());
}

function running_pid() {
    let pid_data = trim(as_string(fs.readfile(cfg.pid_file) || ""));
    if (pid_data == "" || match(pid_data, /[^0-9]/))
        return null;

    let pid = int(pid_data);
    if (pid <= 0)
        return null;

    if (fs.stat("/proc/" + pid) != null)
        return pid;

    remove_file(cfg.pid_file);
    return null;
}

function package_version() {
    if (!provider_available())
        return "";

    let out = trim(command_output(shell_quote(cfg.binary) + " --version 2>&1 || true"));
    let m = match(out, /version[ \t]*([0-9a-zA-Z._-]+)/i) || match(out, /([0-9]+\.[0-9a-zA-Z._-]+)/);
    if (m)
        return m[1];

    let pkgs = require("core.packages");
    if (pkgs && pkgs.version)
        return pkgs.version("fptn") || pkgs.version("fptn-client") || "";

    return "";
}

function remove_kernel_routing() {
    let p = cfg.rule_priority || "102";
    let mark_spec = cfg.fwmark + "/" + cfg.mark_mask;

    for (let i = 0; i < 5; i++) {
        if (command_status("ip rule del fwmark " + mark_spec + " table " + cfg.route_table + " priority " + p + " 2>/dev/null") != 0)
            break;
    }

    command_status("ip route flush table " + cfg.route_table + " 2>/dev/null; true");
    if (command_status("ip link show " + shell_quote(cfg.tun_interface) + " >/dev/null 2>&1") == 0)
        command_status("ip link set dev " + shell_quote(cfg.tun_interface) + " down 2>/dev/null; true");
}

function install_kernel_routing() {
    remove_kernel_routing();

    command_status("ip link set dev " + shell_quote(cfg.tun_interface) + " up 2>/dev/null; true");
    let route_ok = command_status("ip route replace default dev " + shell_quote(cfg.tun_interface) + " table " + cfg.route_table + " 2>/dev/null") == 0;
    if (!route_ok) {
        log_message("Failed to add default route dev " + cfg.tun_interface + " to table " + cfg.route_table, "warn");
        return false;
    }

    let p = cfg.rule_priority || "102";
    let mark_spec = cfg.fwmark + "/" + cfg.mark_mask;
    let rule_ok = command_status("ip rule add fwmark " + mark_spec + " table " + cfg.route_table + " priority " + p + " 2>/dev/null") == 0;
    if (!rule_ok) {
        log_message("Failed to add ip rule for table " + cfg.route_table, "warn");
        return false;
    }

    return true;
}

function stop_runtime() {
    let pid = running_pid();
    if (pid != null) {
        log_message("Stopping FPTN daemon (PID " + pid + ")", "info");
        command_status("kill -15 " + pid + " 2>/dev/null; true");

        let stopped = false;
        for (let i = 0; i < 20; i++) {
            if (fs.stat("/proc/" + pid) == null) {
                stopped = true;
                break;
            }
            system("sleep 0.1 2>/dev/null || sleep 1");
        }

        if (!stopped && fs.stat("/proc/" + pid) != null) {
            log_message("FPTN daemon did not stop gracefully; sending SIGKILL", "warn");
            command_status("kill -9 " + pid + " 2>/dev/null; true");
        }
    }

    remove_file(cfg.pid_file);
    remove_kernel_routing();
    return true;
}

function start_runtime() {
    let sections = enabled_sections();
    if (length(sections) == 0) {
        stop_runtime();
        return true;
    }

    if (!provider_available()) {
        log_message("Cannot start FPTN: binary " + cfg.binary + " not found or not executable", "warn");
        return false;
    }

    let section = sections[0];
    let token = as_string(option(section, "access_token", ""));
    if (token == "") {
        log_message("Cannot start FPTN: access_token not configured for section " + section_name(section), "warn");
        return false;
    }

    stop_runtime();

    command_status("mkdir -p " + shell_quote(cfg.state_dir) + " 2>/dev/null");

    let cmd_args = [
        cfg.binary,
        "--access-token", token,
        "--tun-interface-name", cfg.tun_interface,
        "--enable-split-tunnel", "false"
    ];

    let sni = as_string(option(section, "sni", ""));
    if (sni != "") {
        push(cmd_args, "--sni");
        push(cmd_args, sni);
    }

    let bypass_method = as_string(option(section, "bypass_method", ""));
    if (bypass_method != "") {
        push(cmd_args, "--bypass-method");
        push(cmd_args, bypass_method);
    }

    let preferred_server = as_string(option(section, "preferred_server", ""));
    if (preferred_server != "") {
        push(cmd_args, "--preferred-server");
        push(cmd_args, preferred_server);
    }

    let cmd_str = command_from_args(cmd_args) + " >> " + shell_quote(cfg.log_file) + " 2>&1 & echo $! > " + shell_quote(cfg.pid_file);
    log_message("Starting FPTN client on interface " + cfg.tun_interface, "info");
    system(cmd_str);

    let started = false;
    for (let i = 0; i < 30; i++) {
        if (command_status("ip link show " + shell_quote(cfg.tun_interface) + " >/dev/null 2>&1") == 0) {
            started = true;
            break;
        }
        let p = running_pid();
        if (p == null && i > 5)
            break;
        system("sleep 0.1 2>/dev/null || sleep 1");
    }

    if (!started) {
        log_message("FPTN interface " + cfg.tun_interface + " did not come up", "warn");
        return false;
    }

    install_kernel_routing();
    log_message("FPTN client successfully started on " + cfg.tun_interface + " (table " + cfg.route_table + ")", "info");
    return true;
}

function status_json() {
    let installed = provider_available();
    let pid = running_pid();
    let running = pid != null;
    let rule_count = enabled_rule_count();
    let ver = package_version();

    write_json({
        installed: installed,
        configured: rule_count > 0,
        enabled_rule_count: rule_count,
        service_running: running,
        pid: pid,
        version: ver,
        binary: cfg.binary,
        tun_interface: cfg.tun_interface,
        route_table: cfg.route_table,
        log_file: cfg.log_file,
        ready: installed && running && rule_count > 0,
        status_message: running ? "FPTN is running" : (installed ? "FPTN is installed but not running" : "FPTN is not installed")
    });
    return true;
}

function check_json() {
    write_json({
        fptn_installed: provider_available() ? 1 : 0,
        fptn_version: package_version(),
        binary: cfg.binary
    });
    return true;
}

function module_exports() {
    return {
        provider_available: provider_available,
        package_version: package_version,
        start_runtime: start_runtime,
        stop_runtime: stop_runtime,
        status_json: status_json,
        check_json: check_json
    };
}

if (sourcepath(1) != null && sourcepath(1) != "")
    return module_exports();

let mode = as_string(ARGV[0]);
if (mode == "start-runtime")
    exit(start_runtime() ? 0 : 1);
else if (mode == "stop-runtime")
    exit(stop_runtime() ? 0 : 1);
else if (mode == "restart-runtime") {
    stop_runtime();
    exit(start_runtime() ? 0 : 1);
}
else if (mode == "status")
    status_json();
else if (mode == "check")
    check_json();
else if (mode == "installed" || mode == "provider-available")
    exit(provider_available() ? 0 : 1);
else if (mode == "package-version" || mode == "version")
    printf("%s\n", package_version());
else if (mode == "enabled-rule-count")
    printf("%d\n", enabled_rule_count());
else {
    warn("Usage: providers/fptn/runtime.uc <start-runtime|stop-runtime|restart-runtime|status|check|installed|version>\n");
    exit(1);
}
