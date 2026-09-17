let fs = require("fs");

function config(ctx) {
    let env_get = function(key, fallback) {
        let val = getenv(key);
        return val != null ? val : fallback;
    };

    let bin = env_get("TACHYON_FPTN_BIN", "/usr/bin/fptn-client-cli");
    if (fs.stat(bin) == null && fs.stat("/usr/bin/fptn-client") != null)
        bin = "/usr/bin/fptn-client";

    let state_dir = env_get("TACHYON_FPTN_STATE_DIR", "/var/run/tachyon/fptn");

    return {
        kind: "fptn",
        action: "fptn",
        binary: bin,
        tun_interface: env_get("TACHYON_FPTN_TUN", "tun-fptn"),
        route_table: env_get("TACHYON_FPTN_ROUTE_TABLE", "4249"),
        fwmark: env_get("TACHYON_FPTN_FWMARK", "0x00300000"),
        mark_mask: env_get("TACHYON_FPTN_MARK_MASK", "0x00ff0000"),
        rule_priority: env_get("TACHYON_FPTN_RULE_PRIORITY", "102"),
        state_dir: state_dir,
        shims_dir: state_dir + "/bin",
        pid_file: state_dir + "/fptn.pid",
        log_file: state_dir + "/fptn.log",
        package_name: "fptn",
        runtime_path: (ctx && ctx.lib_dir ? ctx.lib_dir : "/usr/lib/tachyon") + "/providers/fptn/runtime.uc",
        config_name: "fptn",
        status_label: "fptn",
        check_prefix: "fptn"
    };
}

function validator() {
    return require("providers.fptn.validator");
}

return { config, validator };
