#!/usr/bin/env ucode

let fs = require("fs");
let constants = require("core.constants");
let uci_core = require("core.uci");
let zapret2_common = require("providers.zapret2.common");
let zapret2_validator = require("providers.zapret2.validator");

const LIB_DIR = getenv("TACHYON_LIB") || "/usr/lib/tachyon";
const CONFIG_NAME = getenv("TACHYON_CONFIG_NAME") || constants.TACHYON_CONFIG_NAME || "tachyon";
const CACHE_FILE = "/tmp/tachyon_zapret2_tuning_cache.json";

function as_string(value) {
    return value == null ? "" : "" + value;
}

function trim(value) {
    value = as_string(value);
    let start = 0;
    let end = length(value);
    while (start < end && match(substr(value, start, 1), /[ \t\r\n]/) != null)
        start++;
    while (end > start && match(substr(value, end - 1, 1), /[ \t\r\n]/) != null)
        end--;
    return substr(value, start, end - start);
}

function now_seconds() {
    return time();
}

function write_json(value) {
    print(sprintf("%J", value), "\n");
}

function read_json_file(path) {
    path = as_string(path);
    if (path == "" || fs.stat(path) == null)
        return null;
    let content = fs.readfile(path);
    if (content == null || content == "")
        return null;
    try {
        return json(content);
    } catch (e) {
        return null;
    }
}

function write_json_file(path, data) {
    path = as_string(path);
    if (path == "")
        return false;
    let content = sprintf("%J", data);
    let tmp_path = path + ".tmp." + now_seconds();
    let file = fs.open(tmp_path, "w");
    if (!file)
        return false;
    file.write(content);
    file.close();
    return fs.rename(tmp_path, path);
}

function shell_quote(value) {
    return "'" + replace(as_string(value), /'/g, "'\\''") + "'";
}

function command_status(cmd) {
    let status = int(system(cmd + " >/dev/null 2>&1"));
    return status > 255 ? int(status / 256) : status;
}

function command_output(cmd) {
    let pipe = fs.popen(cmd, "r");
    if (!pipe)
        return "";
    let data = pipe.read("all");
    pipe.close();
    return as_string(data);
}

function get_section_domains(section_id) {
    section_id = as_string(section_id);
    let list = [];

    if (section_id != "") {
        let domain_setting = uci_core.get(CONFIG_NAME, section_id, "domain");
        if (type(domain_setting) == "array") {
            for (let d in domain_setting) {
                d = trim(as_string(d));
                if (d != "") push(list, d);
            }
        } else if (type(domain_setting) == "string" && trim(domain_setting) != "") {
            for (let d in split(trim(domain_setting), /[ \t\r\n,]+/)) {
                d = trim(as_string(d));
                if (d != "") push(list, d);
            }
        }

        if (length(list) == 0) {
            let hostlists = uci_core.get(CONFIG_NAME, section_id, "hostlist");
            if (type(hostlists) == "string") hostlists = [ hostlists ];
            if (type(hostlists) == "array") {
                for (let hl in hostlists) {
                    hl = trim(as_string(hl));
                    if (hl == "") continue;
                    let hl_path = "/etc/tachyon/hostlists/" + hl;
                    if (fs.stat(hl_path) != null) {
                        let content = fs.readfile(hl_path);
                        if (content != null) {
                            for (let line in split(content, "\n")) {
                                line = trim(as_string(line));
                                if (line != "" && substr(line, 0, 1) != "#" && match(line, /\.[a-z]{2,}$/i)) {
                                    push(list, line);
                                    if (length(list) >= 3) break;
                                }
                            }
                        }
                    }
                    if (length(list) > 0) break;
                }
            }
        }
    }

    if (length(list) == 0) {
        let sec_lower = lc(section_id);
        if (index(sec_lower, "youtube") >= 0 || index(sec_lower, "video") >= 0)
            return [ "googlevideo.com", "youtube.com" ];
        if (index(sec_lower, "discord") >= 0)
            return [ "discord.com", "gateway.discord.gg" ];
        if (index(sec_lower, "telegram") >= 0)
            return [ "t.me", "telegram.org" ];
        return [ "googlevideo.com" ];
    }

    return list;
}

function get_candidate_strategies(mode) {
    mode = as_string(mode || "express");

    let base_http = "--filter-tcp=80 --filter-l7=http --payload=http_req ";
    let base_tls = "--new --filter-tcp=443 --filter-l7=tls --payload=tls_client_hello ";
    let base_quic = "--new --filter-udp=443 --filter-l7=quic --payload=quic_initial ";

    let presets = [
        {
            id: "split2_basic",
            name: "Basic Split2",
            family: "split2",
            opt: base_http + "--lua-desync=split2:pos=method+2 " +
                 base_tls + "--lua-desync=split2:pos=1,midsld " +
                 base_quic + "--lua-desync=fake:blob=fake_default_quic:repeats=6"
        },
        {
            id: "disorder2_basic",
            name: "Basic Disorder2",
            family: "disorder2",
            opt: base_http + "--lua-desync=disorder2:pos=method+2 " +
                 base_tls + "--lua-desync=disorder2:pos=1,midsld " +
                 base_quic + "--lua-desync=fake:blob=fake_default_quic:repeats=6"
        },
        {
            id: "fake_split2_md5",
            name: "Fake + Split2 (MD5Sig)",
            family: "fake_split2",
            opt: base_http + "--lua-desync=fake:blob=fake_default_http:tcp_md5 --lua-desync=split2:pos=method+2 " +
                 base_tls + "--lua-desync=fake:blob=fake_default_tls:tcp_md5:tcp_seq=-10000 --lua-desync=split2:pos=1,midsld " +
                 base_quic + "--lua-desync=fake:blob=fake_default_quic:repeats=6"
        },
        {
            id: "fake_disorder2_md5",
            name: "Fake + Disorder2 (MD5Sig)",
            family: "fake_disorder2",
            opt: base_http + "--lua-desync=fake:blob=fake_default_http:tcp_md5 --lua-desync=disorder2:pos=method+2 " +
                 base_tls + "--lua-desync=fake:blob=fake_default_tls:tcp_md5:tcp_seq=-10000 --lua-desync=multidisorder:pos=1,midsld " +
                 base_quic + "--lua-desync=fake:blob=fake_default_quic:repeats=6"
        },
        {
            id: "multisplit_default",
            name: "Multisplit (Default Preset)",
            family: "multisplit",
            opt: base_http + "--lua-desync=fake:blob=fake_default_http:tcp_md5 --lua-desync=multisplit:pos=method+2 " +
                 base_tls + "--lua-desync=fake:blob=fake_default_tls:tcp_md5:tcp_seq=-10000 --lua-desync=multidisorder:pos=1,midsld " +
                 base_quic + "--lua-desync=fake:blob=fake_default_quic:repeats=6"
        },
        {
            id: "syndata_split",
            name: "Syndata + Split",
            family: "syndata",
            opt: base_http + "--lua-desync=syndata,split2:pos=method+2 " +
                 base_tls + "--lua-desync=syndata,split2:pos=1,sni,midsld " +
                 base_quic + "--lua-desync=fake:blob=fake_default_quic:repeats=6"
        },
        {
            id: "fakedsplit_tls",
            name: "Fakedsplit + Multidisorder",
            family: "fakedsplit",
            opt: base_http + "--lua-desync=fake:blob=fake_default_http:tcp_md5 --lua-desync=split2:pos=method+2 " +
                 base_tls + "--lua-desync=fakedsplit:blob=fake_default_tls:pos=1,sni,midsld --lua-desync=multidisorder:pos=1,midsld " +
                 base_quic + "--lua-desync=fake:blob=fake_default_quic:repeats=6"
        }
    ];

    if (mode == "deep") {
        push(presets, {
            id: "fake_split2_ttl",
            name: "Fake + Split2 (TTL Auto)",
            family: "fake_split2",
            opt: base_http + "--lua-desync=fake:blob=fake_default_http:ttl=3 --lua-desync=split2:pos=method+2 " +
                 base_tls + "--lua-desync=fake:blob=fake_default_tls:ttl=3:tcp_seq=-10000 --lua-desync=split2:pos=1,sni " +
                 base_quic + "--lua-desync=fake:blob=fake_default_quic:repeats=6"
        });
        push(presets, {
            id: "multisplit_sni_pos",
            name: "Multisplit (SNI Position)",
            family: "multisplit",
            opt: base_http + "--lua-desync=multisplit:pos=method+2 " +
                 base_tls + "--lua-desync=multisplit:pos=1,sni,midsld " +
                 base_quic + "--lua-desync=fake:blob=fake_default_quic:repeats=6"
        });
    }

    return presets;
}

function test_domain_probe(domain, opt) {
    domain = as_string(domain);
    if (domain == "")
        return { success: false, rtt_ms: 0, message: "Empty domain" };

    let start_time = now_seconds();

    // 1. Try HTTPS probe with IPv4 forcing (-4) and insecure (-k) to avoid IPv6/SSL hangs
    let https_url = "https://" + domain + "/";
    let cmd = sprintf(
        "curl -4 -k -s -o /dev/null -w '%%{http_code}:%%{time_total}' --connect-timeout 4 --max-time 6 -I %s",
        shell_quote(https_url)
    );

    let output = trim(command_output(cmd));
    let elapsed = int((now_seconds() - start_time) * 1000);

    if (output != "") {
        let parts = split(output, ":");
        if (length(parts) >= 2) {
            let code = int(parts[0]);
            let time_total = (1.0 * parts[1]) * 1000.0;
            if (code >= 200 && code < 500) {
                return {
                    success: true,
                    http_code: code,
                    rtt_ms: int(time_total > 0 ? time_total : elapsed),
                    message: "HTTPS " + code
                };
            }
        }
    }

    // 2. Try HTTP fallback
    let http_url = "http://" + domain + "/";
    let http_cmd = sprintf(
        "curl -4 -k -s -o /dev/null -w '%%{http_code}:%%{time_total}' --connect-timeout 3 --max-time 5 -I %s",
        shell_quote(http_url)
    );

    let http_output = trim(command_output(http_cmd));
    if (http_output != "") {
        let parts = split(http_output, ":");
        if (length(parts) >= 2) {
            let code = int(parts[0]);
            let time_total = (1.0 * parts[1]) * 1000.0;
            if (code >= 200 && code < 500) {
                return {
                    success: true,
                    http_code: code,
                    rtt_ms: int(time_total > 0 ? time_total : elapsed),
                    message: "HTTP " + code
                };
            }
        }
    }

    let port = 443;
    let nc_cmd = sprintf("nc -w 2 -z %s %d", shell_quote(domain), port);
    if (command_status(nc_cmd) == 0) {
        return {
            success: true,
            http_code: 200,
            rtt_ms: elapsed,
            message: "TCP Port 443 Open"
        };
    }

    return {
        success: false,
        http_code: 0,
        rtt_ms: elapsed,
        message: "Connection failed or timed out"
    };
}

function update_job_progress(job_path, completed, total, failed, current_item) {
    if (job_path == "" || fs.stat(job_path) == null)
        return;
    let data = read_json_file(job_path);
    if (type(data) != "object")
        return;

    data.progress = {
        completed: int(completed),
        total: int(total),
        failed: int(failed),
        current_item: as_string(current_item)
    };
    data.updated_at = now_seconds();
    write_json_file(job_path, data);
}

function run_tune(section_id, target_domain, mode, job_path) {
    section_id = as_string(section_id);
    target_domain = as_string(target_domain);
    mode = as_string(mode || "express");
    job_path = as_string(job_path);

    let section_domains = get_section_domains(section_id);
    if (target_domain != "" && index(target_domain, ".") >= 0) {
        if (index(join(",", section_domains), target_domain) < 0) {
            unshift(section_domains, target_domain);
        }
    }
    target_domain = section_domains[0] || "googlevideo.com";

    let candidates = get_candidate_strategies(mode);
    let total = length(candidates);
    let results = [];
    let best_candidate = null;
    let best_rtt = 999999;
    let failed_count = 0;

    let failed_families = {};

    for (let i = 0; i < total; i++) {
        let cand = candidates[i];
        let family = cand.family;

        if (failed_families[family] === true && mode == "express") {
            push(results, {
                id: cand.id,
                name: cand.name,
                family: cand.family,
                opt: cand.opt,
                success: false,
                skipped: true,
                rtt_ms: 0,
                message: "Skipped (Family pruned)"
            });
            failed_count++;
            update_job_progress(job_path, i + 1, total, failed_count, cand.name);
            continue;
        }

        update_job_progress(job_path, i, total, failed_count, cand.name);

        let validation = zapret2_validator.validate_strategy("nfqws2", cand.opt, "");
        if (!validation.valid) {
            push(results, {
                id: cand.id,
                name: cand.name,
                family: cand.family,
                opt: cand.opt,
                success: false,
                rtt_ms: 0,
                message: "Validation error: " + as_string(validation.message)
            });
            failed_count++;
            failed_families[family] = true;
            continue;
        }

        let probe = test_domain_probe(target_domain, cand.opt);
        if (probe.success) {
            push(results, {
                id: cand.id,
                name: cand.name,
                family: cand.family,
                opt: cand.opt,
                success: true,
                http_code: probe.http_code,
                rtt_ms: probe.rtt_ms,
                message: probe.message
            });

            if (probe.rtt_ms < best_rtt) {
                best_rtt = probe.rtt_ms;
                best_candidate = cand;
            }
        } else {
            push(results, {
                id: cand.id,
                name: cand.name,
                family: cand.family,
                opt: cand.opt,
                success: false,
                rtt_ms: probe.rtt_ms,
                message: probe.message
            });
            failed_count++;
            failed_families[family] = true;
        }

        update_job_progress(job_path, i + 1, total, failed_count, cand.name);
    }

    let has_winner = (best_candidate != null && best_rtt < 999999);

    let output = {
        success: has_winner,
        section_id,
        target_domain,
        section_domains,
        mode,
        winning_strategy: has_winner ? best_candidate.opt : "",
        winning_preset_id: has_winner ? best_candidate.id : "",
        winning_preset_name: has_winner ? best_candidate.name : "",
        best_rtt_ms: has_winner ? best_rtt : 0,
        tested_count: total,
        message: has_winner ? sprintf("Optimal strategy found: %s (%d ms)", best_candidate.name, best_rtt) : "No working strategy found for target domain",
        results
    };

    let cache_data = read_json_file(CACHE_FILE) || {};
    if (type(cache_data) != "object")
        cache_data = {};
    cache_data[target_domain] = {
        updated_at: now_seconds(),
        winning_strategy: output.winning_strategy,
        best_rtt_ms: output.best_rtt_ms
    };
    write_json_file(CACHE_FILE, cache_data);

    return output;
}

function main(argv) {
    let mode_cmd = argv[0] || "tune";

    if (mode_cmd == "tune" || mode_cmd == "run") {
        let section_id = argv[1] || "";
        let target_domain = argv[2] || "";
        let mode = argv[3] || "express";
        let job_path = argv[4] || "";

        let res = run_tune(section_id, target_domain, mode, job_path);
        write_json(res);
        return 0;
    }

    if (mode_cmd == "candidates") {
        let mode = argv[1] || "express";
        write_json({
            success: true,
            mode,
            candidates: get_candidate_strategies(mode)
        });
        return 0;
    }

    write_json({
        success: false,
        message: "Usage: providers/zapret2/tune.uc <tune|candidates> [section_id] [target_domain] [mode] [job_path]"
    });
    return 1;
}

if (sourcepath(1) != null && sourcepath(1) != "") {
    return {
        get_candidate_strategies,
        run_tune,
        test_domain_probe
    };
}

return main(ARGV);
