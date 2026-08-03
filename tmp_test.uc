#!/usr/bin/env ucode
let fs = require("fs");
function as_string(value) { return value == null ? "" : "" + value; }
let cmd = "wget -q -O /tmp/test_uc_dl.txt --timeout=15 https://raw.githubusercontent.com/AvenCores/Unlock_AI_and_EN_Services_for_Russia/main/source/system/etc/hosts";
print("Running wget...\n");
let result = system(cmd);
print("system result: ", as_string(result), "\n");
let st = fs.stat("/tmp/test_uc_dl.txt");
print("file exists: ", as_string(st != null), "\n");
if (st != null) print("file size: ", as_string(st.size), "\n");
