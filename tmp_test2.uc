#!/usr/bin/env ucode
let fs = require("fs");
function as_string(value) { return value == null ? "" : "" + value; }
function shell_quote(value) { return "'" + replace(as_string(value), /'/g, "'\\''") + "'"; }

print("Test 1: direct system()\n");
let r1 = system("wget -q -O /tmp/t1.txt --timeout=15 https://raw.githubusercontent.com/AvenCores/Unlock_AI_and_EN_Services_for_Russia/main/source/system/etc/hosts");
print("system result: ", as_string(r1), "\n");
let s1 = fs.stat("/tmp/t1.txt");
print("file exists: ", as_string(s1 != null), "\n");

print("\nTest 2: via shell_quote\n");
let url = "https://raw.githubusercontent.com/AvenCores/Unlock_AI_and_EN_Services_for_Russia/main/source/system/etc/hosts";
let output = "/tmp/t2.txt";
let cmd = "wget -q -O " + shell_quote(output) + " --timeout=30 " + shell_quote(url);
print("cmd: ", cmd, "\n");
let r2 = system(cmd);
print("system result: ", as_string(r2), "\n");
let s2 = fs.stat("/tmp/t2.txt");
print("file exists: ", as_string(s2 != null), "\n");
if (s2 != null) print("size: ", as_string(s2.size), "\n");
