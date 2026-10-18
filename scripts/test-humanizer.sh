#!/bin/bash
# Humanizer 纯函数测试：swiftc 编译 Humanizer.swift + 断言 main，覆盖复合命令、
# 管道、引号、kill/pkill 误报样本、敏感路径。无需启动 App。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/main.swift" <<'SWIFT'
import Foundation

var failures = 0
func check(_ cond: Bool, _ name: String, _ detail: String = "") {
    if cond {
        print("PASS  \(name)")
    } else {
        failures += 1
        print("FAIL  \(name)  \(detail)")
    }
}

// MARK: - splitSegments

let s1 = Humanizer.splitSegments("rm -rf a; rm -rf b")
check(s1 == ["rm -rf a", "rm -rf b"], "分号拆分", "\(s1)")

let s2 = Humanizer.splitSegments("rm -rf a && rm -rf b")
check(s2 == ["rm -rf a", "rm -rf b"], "&& 拆分", "\(s2)")

let s3 = Humanizer.splitSegments("ps aux | grep claude")
check(s3 == ["ps aux", "grep claude"], "管道拆分", "\(s3)")

let s4 = Humanizer.splitSegments("echo \"a;b\" && rm -rf c")
check(s4 == ["echo \"a;b\"", "rm -rf c"], "引号内分号不拆", "\(s4)")

let s5 = Humanizer.splitSegments("rm -rf $(ls /tmp)")
check(s5.count == 1, "$() 整体不拆", "\(s5)")

let s6 = Humanizer.splitSegments("sh -c 'rm -rf a; rm -rf b'")
check(s6.count == 1, "sh -c 整体不拆", "\(s6)")

let s7 = Humanizer.splitSegments("false || echo ok")
check(s7 == ["false", "echo ok"], "|| 拆分", "\(s7)")

let s8 = Humanizer.splitSegments("sleep 1 & echo hi")
check(s8.count == 1, "单个 & 不拆（后台符）", "\(s8)")

// MARK: - bareCommand

check(Humanizer.bareCommand("sudo rm -rf /tmp/x").hasPrefix("rm"), "sudo 前缀剥离")
check(Humanizer.bareCommand("FOO=bar rm -rf /tmp/x").hasPrefix("rm"), "环境变量赋值剥离")
check(Humanizer.bareCommand("sudo FOO=1 pkill -f 'x'").hasPrefix("pkill"), "sudo+env 后 pkill")

// MARK: - kill / pkill

let d1 = Humanizer.describePermission(toolName: "Bash", input: ["command": "pkill -f 'ClaudePulse.app/Contents/MacOS/ClaudePulse'"])
check(!d1.summary.contains("删除"), "pkill 不误报删除", d1.summary)
check(d1.summary.contains("进程") || d1.summary.contains("结束"), "pkill 是结束进程", d1.summary)
check(d1.risk == .medium || d1.risk == .high, "pkill 至少 medium 风险", "\(d1.risk)")

let d2 = Humanizer.describePermission(toolName: "Bash", input: ["command": "kill 67317"])
check(d2.summary == "结束进程", "kill 纯 PID 不展示数字目标", d2.summary)
check(!d2.summary.contains("67317"), "kill 不把 PID 当目标", d2.summary)

let d3 = Humanizer.describePermission(toolName: "Bash", input: ["command": "kill -9 67317"])
check(d3.risk == .high, "kill -9 是 high 风险", "\(d3.risk)")

// MARK: - 单条 rm 仍是高风险且带目标

let d4 = Humanizer.describePermission(toolName: "Bash", input: ["command": "rm -rf /tmp/build"])
check(d4.risk == .high, "rm -rf 高风险", "\(d4.risk)")
check(d4.summary.contains("/tmp/build") || d4.summary.contains("build"), "rm 带目标", d4.summary)

// MARK: - 复合命令：含高危 → 整卡 high，含逐条说明

let d5 = Humanizer.describePermission(toolName: "Bash", input: ["command": "rm -rf /tmp/build && npm run build && ls -la"])
check(d5.risk == .high, "复合含 rm → 整卡 high", "\(d5.risk)")
check(d5.summary.contains("删除") || d5.detail.contains("删除"), "复合 high 提到删除", d5.summary)
check(!d5.segments.isEmpty, "复合给逐条说明", "\(d5.segments)")

// 复合不含高危 → 不夸大
let d6 = Humanizer.describePermission(toolName: "Bash", input: ["command": "npm run build && ls -la && echo done"])
check(d6.risk != .high, "复合无高危 → 不 high", "\(d6.risk)")
check(d6.summary.contains("3 条命令"), "复合摘要含条数", d6.summary)

// MARK: - 敏感路径

let d7 = Humanizer.describePermission(toolName: "Write", input: ["file_path": "/Users/ink/.ssh/authorized_keys"])
check(d7.risk == .high, "敏感路径 Write 高风险", "\(d7.risk)")

let d8 = Humanizer.describePermission(toolName: "Edit", input: ["file_path": "/tmp/plain.txt"])
check(d8.risk == .medium, "普通路径 Edit 中风险", "\(d8.risk)")

// MARK: - 汇总

if failures > 0 {
    print("\n\(failures) 个失败")
    exit(1)
}
print("\n全部通过")
SWIFT

swiftc -O -swift-version 5 -target arm64-apple-macos14.0 \
  "$ROOT/Sources/Humanizer.swift" \
  "$TMP/main.swift" \
  -o "$TMP/humanizer-test"

"$TMP/humanizer-test"
