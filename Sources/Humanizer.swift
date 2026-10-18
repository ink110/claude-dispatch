import Foundation

enum RiskLevel: Int, Comparable {
    case low = 0
    case medium = 1
    case high = 2

    static func < (lhs: RiskLevel, rhs: RiskLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// 给用户看的中文描述：不展示一大段代码，只说「要做什么、有什么后果、你要决定什么」。
struct HumanDescription {
    let title: String
    let summary: String
    let detail: String
    let action: String
    let risk: RiskLevel
    let rawDetail: String
    let rawLabel: String
    /// 复合命令逐条的中文说明（「1. 删除 build」），无则空。
    var segments: [String] = []
}

enum Humanizer {

    // MARK: - 需要操作的请求

    static func describePermission(toolName: String, input: [String: Any]) -> HumanDescription {
        switch toolName {
        case "Bash", "PowerShell":
            return describeShell(input: input)
        case "Write":
            return describeWrite(input: input)
        case "Edit", "MultiEdit", "NotebookEdit":
            return describeEdit(input: input)
        case "Read":
            return describeRead(input: input)
        case "WebFetch":
            return describeWebFetch(input: input)
        case "WebSearch":
            return describeWebSearch(input: input)
        case "Task", "Agent":
            return describeTask(input: input)
        case "TodoWrite":
            return HumanDescription(
                title: "Claude 请求更新任务清单",
                summary: "更新当前任务的待办清单",
                detail: "这只会改变 Claude 自己的任务进度记录，不会修改你的项目文件。",
                action: "需要你决定：允许更新，还是拒绝？",
                risk: .low,
                rawDetail: "",
                rawLabel: ""
            )
        default:
            return HumanDescription(
                title: "Claude 请求执行一个操作",
                summary: "使用工具「\(toolName)」执行操作",
                detail: "这个工具不在常见清单里，请确认你了解它的作用。",
                action: "需要你决定：允许这次操作，还是拒绝？",
                risk: .medium,
                rawDetail: prettyJSON(input),
                rawLabel: "查看技术细节"
            )
        }
    }

    static func describeQuestion() -> HumanDescription {
        HumanDescription(
            title: "Claude 需要你回答一个问题",
            summary: "它现在停下来等你补充信息",
            detail: "回答后，任务会从当前位置继续。",
            action: "请选择下面的选项，或直接输入你的回答。",
            risk: .low,
            rawDetail: "",
            rawLabel: ""
        )
    }

    static func describePlan() -> HumanDescription {
        HumanDescription(
            title: "Claude 提交了一份执行计划",
            summary: "它准备按计划开始执行",
            detail: "计划内容在下方。你可以直接批准，也可以写下修改意见让它先改。",
            action: "请选择「批准计划」开始执行，或填写意见后「要求修改」。",
            risk: .medium,
            rawDetail: "",
            rawLabel: ""
        )
    }

    // MARK: - 状态里的「在干嘛」

    static func describeActivity(toolName: String, input: [String: Any]) -> String {
        switch toolName {
        case "Bash", "PowerShell":
            let command = input["command"] as? String ?? ""
            let verb = shellVerb(command.lowercased())
            if showTarget(verb), let target = shellTarget(command) {
                return "正在\(verb)「\(target)」"
            }
            return "正在\(verb)"
        case "Write":
            return "正在写入「\(displayPath(filePath(input)))」"
        case "Edit", "MultiEdit", "NotebookEdit":
            return "正在修改「\(displayPath(filePath(input)))」"
        case "Read":
            return "正在读取「\(displayPath(filePath(input)))」"
        case "WebFetch":
            return "正在访问「\(pageHost(input))」"
        case "WebSearch":
            return "正在搜索「\(shortQuery(input))」"
        case "Task", "Agent":
            return "正在执行子任务"
        case "TodoWrite":
            return "正在更新任务清单"
        default:
            return "正在使用「\(toolName)」"
        }
    }

    static func activityVerb(toolName: String, input: [String: Any]) -> String {
        switch toolName {
        case "Bash", "PowerShell":
            return shellVerb((input["command"] as? String ?? "").lowercased())
        case "Write":
            return "写入文件"
        case "Edit", "MultiEdit", "NotebookEdit":
            return "修改文件"
        case "Read":
            return "读取文件"
        case "WebFetch":
            return "访问网页"
        case "WebSearch":
            return "搜索网络"
        default:
            return "执行操作"
        }
    }

    static func rawDetail(toolName: String, input: [String: Any]) -> String {
        switch toolName {
        case "Bash", "PowerShell":
            return input["command"] as? String ?? ""
        case "Write", "Edit", "MultiEdit", "NotebookEdit", "Read":
            return filePath(input)
        case "WebFetch":
            return input["url"] as? String ?? ""
        default:
            return prettyJSON(input)
        }
    }

    // MARK: - 命令行的中文翻译

    private static func describeShell(input: [String: Any]) -> HumanDescription {
        let command = (input["command"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else {
            return HumanDescription(
                title: "Claude 请求执行一条命令",
                summary: "执行一条命令行操作",
                detail: "命令内容为空，请确认是否继续。",
                action: "需要你决定：允许这次操作，还是拒绝？",
                risk: .medium,
                rawDetail: command,
                rawLabel: "查看完整命令"
            )
        }

        let lower = command.lowercased()
        let compound = isCompound(lower)

        // 单条命令按「真正的执行体」识别：sudo/env 前缀后的第一个词。
        let bare = compound ? lower : bareCommand(lower)
        let isKillCmd = bare.hasPrefix("kill") || bare.hasPrefix("pkill")
        let isRmCmd = bare.hasPrefix("rm ") || bare.hasPrefix("rm\t")

        if !compound && isKillCmd {
            // kill/pkill 是结束进程，不是删除文件——目标只给进程名/信号，纯 PID 数字不展示。
            let target = killTarget(command)
            return HumanDescription(
                title: "Claude 请求结束一个进程",
                summary: target.map { "结束进程「\($0)」" } ?? "结束进程",
                detail: "进程会被终止，未保存的工作可能丢失。",
                action: "需要你决定：允许结束进程，还是拒绝？",
                risk: bare.contains("-9") || bare.contains("sigkill") ? .high : .medium,
                rawDetail: command,
                rawLabel: "查看完整命令"
            )
        }

        if !compound && isRmCmd {
            let target = shellTarget(command)
            return HumanDescription(
                title: "高风险操作，需要你确认",
                summary: target.map { "删除文件「\($0)」" } ?? "删除文件或目录",
                detail: "这会删除目标文件或目录，删除后通常无法恢复，请确认目标无误后再决定。",
                action: "需要你决定：允许删除，还是拒绝？",
                risk: .high,
                rawDetail: command,
                rawLabel: "查看完整命令"
            )
        }

        // 复合命令统一走逐条分析：高危、sudo、普通步骤都在同一张卡里说明。
        if compound {
            return describeCompound(command: command, lower: lower)
        }

        let verb = shellVerb(bare)
        let rawTargetSuffix = shellTarget(command).map { "「\($0)」" } ?? ""
        let targetSuffix = showTarget(verb) ? rawTargetSuffix : ""

        if let hit = highRiskHit(bare) {
            return HumanDescription(
                title: "高风险操作，需要你确认",
                summary: "\(hit.verb)\(rawTargetSuffix)",
                detail: "\(hit.detail) 这类操作可能造成不可恢复的后果，请确认目标无误后再决定。",
                action: "需要你决定：允许这次高风险操作，还是拒绝？",
                risk: .high,
                rawDetail: command,
                rawLabel: "查看完整命令"
            )
        }

        if lower.hasPrefix("sudo ") || lower.hasPrefix("sudo\t") {
            return HumanDescription(
                title: "需要管理员权限，请确认",
                summary: "以管理员权限\(shellVerb(bare))\(rawTargetSuffix)",
                detail: "该命令会以管理员权限运行，影响范围可能超出当前项目。",
                action: "需要你决定：允许这次操作，还是拒绝？",
                risk: .high,
                rawDetail: command,
                rawLabel: "查看完整命令"
            )
        }

        return HumanDescription(
            title: "Claude 请求执行一条命令",
            summary: "\(verb)\(targetSuffix)",
            detail: shellDetail(bare),
            action: "需要你决定：允许这次操作，还是拒绝？",
            risk: shellRisk(bare),
            rawDetail: command,
            rawLabel: "查看完整命令"
        )
    }

    private static func isCompound(_ lower: String) -> Bool {
        splitSegments(lower).count > 1
    }

    /// 去掉 sudo/env/time/nohup 等前缀与 VAR=val 赋值，返回真正被执行的命令行（用于动词/风险识别）。
    static func bareCommand(_ lower: String) -> String {
        let tokens = shellTokens(lower)
        let prefixes = ["sudo", "env", "time", "nohup", "command"]
        guard let index = tokens.firstIndex(where: { token in
            !token.contains("=") && !prefixes.contains(token)
        }) else { return lower }
        return tokens.dropFirst(index).joined(separator: " ")
    }

    /// kill/pkill 的展示目标：进程名或信号；纯 PID 数字不展示（避免「67317」这类误报）。
    static func killTarget(_ command: String) -> String? {
        let tokens = shellTokens(command)
        let prefixes = ["sudo", "env", "time", "nohup", "command"]
        guard let cmdIndex = tokens.firstIndex(where: { token in
            !token.contains("=") && !prefixes.contains(token)
        }) else { return nil }
        let cmd = (tokens[cmdIndex] as NSString).lastPathComponent
        let args = tokens.dropFirst(cmdIndex + 1)

        if cmd == "pkill" {
            // pkill 的参数是模式（通常 -f 后的词），给一个能看懂的名字。
            let argsArray = Array(args)
            var pattern: String?
            var i = 0
            while i < argsArray.count {
                let token = argsArray[i]
                if token == "-f" || token == "-u" || token == "-t" {
                    i += 2
                    continue
                }
                if token.hasPrefix("-") {
                    i += 1
                    continue
                }
                pattern = token
                break
            }
            return pattern.map(trimTarget)
        }

        // kill：找信号名（-9/-TERM）之外的第一个非数字参数；纯 PID 不展示。
        let meaningful = args.filter { token in
            if token.hasPrefix("-") { return false }
            return !token.allSatisfy { $0.isNumber }
        }
        return meaningful.first.map(trimTarget)
    }

    /// 顶层拆分复合命令：只在引号外、`$()` 和反引号外按 `;` `&&` `||` `|` 拆分。
    /// `sh -c "…"` 这类把整段脚本当参数的命令不再二次拆分。
    static func splitSegments(_ command: String) -> [String] {
        var segments: [String] = []
        var current = ""
        var quote: Character?
        var dollarParenDepth = 0
        var backtickDepth = 0
        var escaped = false

        func flush() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { segments.append(trimmed) }
            current = ""
        }

        var iterator = command.makeIterator()
        while let ch = iterator.next() {
            if escaped {
                current.append(ch)
                escaped = false
                continue
            }
            if ch == "\\", quote != "'" {
                current.append(ch)
                escaped = true
                continue
            }
            if let q = quote {
                current.append(ch)
                if ch == q { quote = nil }
                continue
            }
            if ch == "'" || ch == "\"" {
                quote = ch
                current.append(ch)
                continue
            }
            if ch == "$" {
                // 预读下一个字符
                var lookahead = iterator
                if let next = lookahead.next(), next == "(" {
                    dollarParenDepth += 1
                    current.append("$(")
                    iterator = lookahead
                    continue
                }
                current.append(ch)
                continue
            }
            if ch == "(" , dollarParenDepth > 0 {
                dollarParenDepth += 1
                current.append(ch)
                continue
            }
            if ch == ")", dollarParenDepth > 0 {
                dollarParenDepth -= 1
                current.append(ch)
                continue
            }
            if ch == "`" {
                backtickDepth += backtickDepth == 0 ? 1 : -1
                current.append(ch)
                continue
            }
            // `|` 与 `||` 都是分隔符；单个 `&` 不是。
            if ch == "|" {
                var lookahead = iterator
                if let next = lookahead.next(), next == "|" {
                    flush()
                    iterator = lookahead
                    continue
                }
                flush()
                continue
            }
            if ch == ";" {
                flush()
                continue
            }
            if ch == "&" {
                var lookahead = iterator
                if let next = lookahead.next(), next == "&" {
                    flush()
                    iterator = lookahead
                    continue
                }
                current.append(ch)
                continue
            }
            current.append(ch)
        }
        flush()

        // `sh -c "多步脚本"`：整体算一步，不拆内层。
        if segments.count > 1,
           let first = segments.first?.lowercased(),
           first.hasPrefix("sh -c") || first.hasPrefix("bash -c") || first.hasPrefix("zsh -c") || first.hasPrefix("dash -c") {
            return [command.trimmingCharacters(in: .whitespacesAndNewlines)]
        }
        return segments
    }

    /// 复合命令的卡片：逐条分析每个步骤，任何一条高风险 → 整卡高风险。
    private static func describeCompound(command: String, lower: String) -> HumanDescription {
        let parts = splitSegments(command)
        var lines: [String] = []
        var maxRisk: RiskLevel = .low
        var anyHighRiskHit: (verb: String, detail: String)?
        var needsAdmin = false

        for part in parts {
            let partLower = part.lowercased()
            if let hit = highRiskHit(partLower), anyHighRiskHit == nil {
                anyHighRiskHit = hit
            }
            if shellTokens(partLower).first == "sudo" { needsAdmin = true }
            let risk = shellRisk(partLower)
            if risk > maxRisk { maxRisk = risk }
            // 逐条剥离 sudo/env 前缀后再识别动作，避免把「sudo rm」当成一条普通命令。
            let verb = shellVerb(bareCommand(partLower))
            let target = showTarget(verb) ? shellTarget(part) : nil
            lines.append(target.map { "\(verb)「\($0)」" } ?? verb)
        }

        // 每一步都列出来：即使某一步只能落到「执行一条命令」的兜底描述，
        // 也要让用户看清共有几步、高危动作夹在哪一步，而不是只给一句笼统摘要。
        let listed = lines
        if needsAdmin { maxRisk = .high }
        let adminHint = needsAdmin ? " 其中包含需要管理员权限的步骤，影响范围可能超出当前项目。" : ""

        if let hit = anyHighRiskHit {
            return HumanDescription(
                title: "高风险操作，需要你确认",
                summary: "执行 \(parts.count) 条命令，其中包含「\(hit.verb)」",
                detail: "\(hit.detail) 建议先逐条确认步骤，再决定是否允许。\(adminHint)",
                action: "需要你决定：允许这组命令，还是拒绝？",
                risk: .high,
                rawDetail: command,
                rawLabel: "查看完整命令",
                segments: enumerated(listed)
            )
        }

        let summary: String
        if listed.isEmpty {
            summary = "执行包含 \(parts.count) 个步骤的命令"
        } else {
            let head = listed.prefix(3).map { $0.replacingOccurrences(of: "「", with: " ").replacingOccurrences(of: "」", with: "") }
            summary = "执行 \(parts.count) 条命令：\(head.joined(separator: "、"))\(listed.count > 3 ? "…" : "")"
        }

        return HumanDescription(
            title: needsAdmin ? "需要管理员权限，请确认" : "Claude 请求执行一组命令",
            summary: summary,
            detail: "这组命令会依次执行，前一步失败可能中断后续步骤。建议展开完整命令逐条确认。\(adminHint)",
            action: "需要你决定：允许执行，还是拒绝？",
            risk: maxRisk,
            rawDetail: command,
            rawLabel: "查看完整命令",
            segments: enumerated(listed)
        )
    }

    private static func enumerated(_ lines: [String]) -> [String] {
        lines.enumerated().map { "\($0.offset + 1). \($0.element)" }
    }

    private static func highRiskHit(_ lower: String) -> (verb: String, detail: String)? {
        if lower.contains("--force-with-lease") { return nil }

        let patterns: [(String, String, String)] = [
            ("rm -rf", "删除文件和目录", "这会递归删除目标，删除后通常无法恢复。"),
            ("rm -r", "递归删除目录", "这会递归删除目标，删除后通常无法恢复。"),
            ("-delete", "批量删除文件", "这会批量删除匹配到的文件，删除后通常无法恢复。"),
            ("git push --force", "强制推送代码到远程仓库", "这会覆盖远程历史，可能影响其他人。"),
            ("git push -f", "强制推送代码到远程仓库", "这会覆盖远程历史，可能影响其他人。"),
            ("git reset --hard", "强制回退代码并丢弃本地修改", "尚未提交的本地修改会丢失。"),
            ("git clean -fd", "删除未跟踪的文件", "未被 Git 跟踪的文件会被永久删除。"),
            ("mkfs", "格式化磁盘", "这会抹掉磁盘上的数据。"),
            ("dd if=", "直接写入磁盘", "写错目标可能损坏磁盘或数据。"),
            ("| sh", "下载并执行网络脚本", "脚本来源不可信时，可能执行任意代码。"),
            ("| bash", "下载并执行网络脚本", "脚本来源不可信时，可能执行任意代码。"),
            ("chmod 777", "把文件权限改成所有人可读写执行", "这会让本机任何用户都能修改该文件。"),
            ("shutdown", "关闭电脑", "其他正在运行的任务会被中断。"),
            ("reboot", "重启电脑", "其他正在运行的任务会被中断。"),
            ("killall", "结束多个进程", "未保存的工作可能丢失。")
        ]

        for (pattern, verb, detail) in patterns where lower.contains(pattern) {
            return (verb, detail)
        }
        if lower.contains("rm ") {
            return ("删除文件或目录", "删除后的内容通常无法恢复。")
        }
        return nil
    }

    private static func shellVerb(_ lower: String) -> String {
        // 先按「命令名」识别只读/低风险动作，避免 `echo "rm ..."` 之类被关键词误判。
        let head = lower.split(separator: " ").first.map(String.init) ?? lower
        switch head {
        case "ls": return "查看目录内容"
        case "cat", "head", "tail", "less", "more": return "查看文件内容"
        case "grep", "rg", "ag": return "搜索内容"
        case "echo", "printf": return "输出文本"
        case "ps", "pgrep", "top": return "查看进程"
        case "sleep": return "等待"
        case "pwd": return "查看当前目录"
        case "find": return "查找文件"
        case "wc": return "统计文件内容"
        case "diff": return "比较文件差异"
        case "du", "df": return "查看磁盘空间"
        default: break
        }
        if lower.contains("rm ") { return "删除文件或目录" }
        if lower.contains("mv ") { return "移动或重命名文件" }
        if lower.contains("cp ") { return "复制文件" }
        if lower.contains("mkdir") { return "创建目录" }
        if lower.contains("touch") { return "创建空文件" }
        if lower.contains("chmod") { return "修改文件权限" }
        if lower.contains("chown") { return "修改文件所有者" }
        if lower.contains("git push") { return "把代码推送到远程仓库" }
        if lower.contains("git pull") { return "从远程仓库拉取代码" }
        if lower.contains("git commit") { return "提交代码修改" }
        if lower.contains("git checkout") || lower.contains("git restore") { return "切换分支或恢复文件" }
        if lower.contains("git clone") { return "克隆远程仓库" }
        if lower.contains("npm run") || lower.contains("pnpm run") || lower.contains("yarn run")
            || lower.contains("npm test") || lower.contains("pnpm test") || lower.contains("yarn test")
            || lower.contains("npx ") {
            return "运行脚本"
        }
        if lower.contains("npm install") || lower.contains("pnpm install") || lower.contains("yarn install")
            || lower.contains("pip install") || lower.contains("brew install") {
            return "安装依赖"
        }
        if lower.contains("curl") || lower.contains("wget") { return "从网络下载内容" }
        if lower.contains("docker") { return "操作 Docker 容器" }
        if lower.contains("kill ") || lower.hasPrefix("kill ") || lower.hasPrefix("pkill ") || lower.contains(" pkill ") {
            return "结束进程"
        }
        if lower.contains("osascript") { return "执行系统脚本" }
        if lower.contains("python") || lower.contains("node ") || lower.contains("bash ") || lower.contains("sh ") {
            return "运行脚本"
        }
        if lower.contains("open ") { return "打开文件或应用" }
        return "执行一条命令"
    }

    /// 只对能说清楚目标的操作展示目标；未知命令不把原始代码带到提醒里。
    private static func showTarget(_ verb: String) -> Bool {
        switch verb {
        case "执行一条命令", "执行一组命令", "运行脚本", "执行系统脚本":
            return false
        default:
            return true
        }
    }

    private static func shellRisk(_ lower: String) -> RiskLevel {
        if lower.contains("rm ") || lower.contains("mv ") || lower.contains("chmod") || lower.contains("chown") {
            return .high
        }
        if lower.contains("git push") || lower.contains("git reset") || lower.contains("git clean") {
            return .medium
        }
        if lower.contains("curl") || lower.contains("wget") || lower.contains("docker") {
            return .medium
        }
        return .medium
    }

    private static func shellDetail(_ lower: String) -> String {
        if lower.contains("rm ") { return "这会删除目标文件或目录，删除后通常无法恢复。" }
        if lower.contains("git push") { return "这会把本地提交同步到远程仓库，可能影响其他人。" }
        if lower.contains("mv ") { return "这会移动或重命名目标文件，原路径将不再存在。" }
        if lower.contains("chmod") || lower.contains("chown") { return "这会改变文件的访问权限或所有者。" }
        if lower.contains("curl") || lower.contains("wget") { return "这会从网络获取内容，来源不可信时请谨慎。" }
        if lower.contains("npm install") || lower.contains("pip install") || lower.contains("brew install") {
            return "这会安装或更新依赖，可能改变运行环境。"
        }
        return "确认后 Claude 会立即执行这条命令。"
    }

    // MARK: - 文件与网络工具

    private static func describeWrite(input: [String: Any]) -> HumanDescription {
        let path = filePath(input)
        let sensitive = isSensitivePath(path)
        return HumanDescription(
            title: sensitive ? "高风险文件修改，需要你确认" : "Claude 请求写入文件",
            summary: "创建或覆盖文件「\(displayPath(path))」",
            detail: sensitive
                ? "这个文件可能包含密钥、账号或系统配置；覆盖后原内容会丢失。"
                : "如果文件已经存在，原内容会被新内容替换。",
            action: "需要你决定：允许写入，还是拒绝？",
            risk: sensitive ? .high : .medium,
            rawDetail: path,
            rawLabel: "查看完整路径"
        )
    }

    private static func describeEdit(input: [String: Any]) -> HumanDescription {
        let path = filePath(input)
        let sensitive = isSensitivePath(path)
        return HumanDescription(
            title: sensitive ? "高风险文件修改，需要你确认" : "Claude 请求修改文件",
            summary: "修改文件「\(displayPath(path))」",
            detail: sensitive
                ? "这个文件可能包含密钥、账号或系统配置；修改前请确认变更内容。"
                : "Claude 会在这份文件里做局部修改，原内容可能被替换。",
            action: "需要你决定：允许修改，还是拒绝？",
            risk: sensitive ? .high : .medium,
            rawDetail: path,
            rawLabel: "查看完整路径"
        )
    }

    private static func describeRead(input: [String: Any]) -> HumanDescription {
        let path = filePath(input)
        return HumanDescription(
            title: "Claude 请求读取文件",
            summary: "读取文件「\(displayPath(path))」",
            detail: "Claude 会查看这个文件的内容，但不会修改它。",
            action: "需要你决定：允许读取，还是拒绝？",
            risk: .low,
            rawDetail: path,
            rawLabel: "查看完整路径"
        )
    }

    private static func describeWebFetch(input: [String: Any]) -> HumanDescription {
        let raw = input["url"] as? String ?? ""
        return HumanDescription(
            title: "Claude 请求访问网页",
            summary: "访问网页「\(pageHost(input))」",
            detail: "Claude 会从网络获取页面内容，并可能把它带进当前对话。",
            action: "需要你决定：允许访问，还是拒绝？",
            risk: .medium,
            rawDetail: raw,
            rawLabel: "查看完整网址"
        )
    }

    private static func describeWebSearch(input: [String: Any]) -> HumanDescription {
        let raw = input["query"] as? String ?? ""
        return HumanDescription(
            title: "Claude 请求搜索网络",
            summary: "搜索「\(shortQuery(input))」",
            detail: "Claude 会用这个关键词查询网络内容。",
            action: "需要你决定：允许搜索，还是拒绝？",
            risk: .low,
            rawDetail: raw,
            rawLabel: "查看完整关键词"
        )
    }

    private static func describeTask(input: [String: Any]) -> HumanDescription {
        let desc = input["description"] as? String ?? input["prompt"] as? String ?? "一个子任务"
        let short = desc.count > 60 ? String(desc.prefix(60)) + "…" : desc
        return HumanDescription(
            title: "Claude 请求启动子任务",
            summary: "启动子任务「\(short)」",
            detail: "子任务会独立运行一段时间，期间可能需要额外的确认。",
            action: "需要你决定：允许启动，还是拒绝？",
            risk: .medium,
            rawDetail: desc,
            rawLabel: "查看完整任务描述"
        )
    }

    // MARK: - 工具函数

    private static func shellTokens(_ line: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        for ch in line {
            if let q = quote {
                if ch == q { quote = nil } else { current.append(ch) }
            } else if ch == "'" || ch == "\"" {
                quote = ch
            } else if ch.isWhitespace {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    private static func shellTarget(_ line: String) -> String? {
        let tokens = shellTokens(line)
        guard !tokens.isEmpty else { return nil }

        let prefixes = ["sudo", "env", "time", "nohup", "command"]
        guard let cmdIndex = tokens.firstIndex(where: { token in
            !token.contains("=") && !prefixes.contains(token)
        }) else { return nil }

        let cmd = (tokens[cmdIndex] as NSString).lastPathComponent
        let args = Array(tokens.dropFirst(cmdIndex + 1))

        switch cmd {
        case "rm", "mkdir", "touch", "chmod", "chown", "cat", "open":
            let values = args.filter { !$0.hasPrefix("-") && !$0.allSatisfy { $0.isNumber } }
            return values.first.map(trimTarget)
        case "mv", "cp", "ln":
            let values = args.filter { !$0.hasPrefix("-") }
            if values.count >= 2 { return trimTarget("\(values[0]) → \(values[1])") }
            return values.first.map(trimTarget)
        case "git":
            guard args.count >= 1 else { return nil }
            let sub = args[0]
            let rest = args.dropFirst().filter { !$0.hasPrefix("-") }
            switch sub {
            case "push", "pull", "fetch":
                return rest.isEmpty ? nil : trimTarget(rest.joined(separator: " "))
            case "reset", "clean", "checkout", "restore", "switch":
                return rest.isEmpty ? nil : trimTarget(rest.prefix(2).joined(separator: " "))
            case "clone":
                return rest.first.map(trimTarget)
            default:
                return trimTarget(([sub] + rest.prefix(2)).joined(separator: " "))
            }
        case "curl", "wget":
            if let raw = args.first(where: { $0.contains("://") }) {
                return URL(string: raw)?.host ?? trimTarget(raw)
            }
            return nil
        case "npm", "pnpm", "yarn", "pip", "pip3", "brew":
            let subcommands = ["install", "add", "uninstall", "remove", "update", "upgrade"]
            let values = args.filter { !$0.hasPrefix("-") && !subcommands.contains($0) }
            return values.isEmpty ? nil : trimTarget(values.prefix(2).joined(separator: " "))
        default:
            let values = args.filter { !$0.hasPrefix("-") }
            return values.first.map(trimTarget)
        }
    }

    private static func trimTarget(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > 48 ? String(trimmed.prefix(48)) + "…" : trimmed
    }

    static func filePath(_ input: [String: Any]) -> String {
        input["file_path"] as? String
            ?? input["path"] as? String
            ?? input["notebook_path"] as? String
            ?? ""
    }

    private static func displayPath(_ path: String) -> String {
        guard !path.isEmpty else { return "未命名文件" }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + String(path.dropFirst(home.count)) }
        return path
    }

    private static func pageHost(_ input: [String: Any]) -> String {
        guard let raw = input["url"] as? String,
              let url = URL(string: raw),
              let host = url.host else {
            return input["url"] as? String ?? "网页"
        }
        return host
    }

    private static func shortQuery(_ input: [String: Any]) -> String {
        let query = input["query"] as? String ?? ""
        return query.count > 32 ? String(query.prefix(32)) + "…" : query
    }

    private static func isSensitivePath(_ path: String) -> Bool {
        let lower = path.lowercased()
        let fragments = [
            ".env", "settings.json", ".ssh", "authorized_keys", "id_rsa",
            "credentials", "/etc/", ".zshrc", ".bashrc", ".aws", "token", "secret"
        ]
        return fragments.contains { lower.contains($0) }
    }

    static func prettyJSON(_ value: [String: Any]) -> String {
        guard
            JSONSerialization.isValidJSONObject(value),
            let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
            let text = String(data: data, encoding: .utf8)
        else { return "" }
        return text
    }
}
