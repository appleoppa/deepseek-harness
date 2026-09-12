// pgg-dsh-web-watchdog — DSH Web 会话健康看门狗（launchd KeepAlive 常驻 + 内部 30s 循环）
//
// 行为（每轮，幂等）：
//   1. 服务不在 launchd 域 → bootstrap/load plist 拉回
//   2. 服务不可达（curl 无响应）→ launchctl kickstart -k 重启 dsh-web 服务，等待就绪
//   3. 服务可达但自身 cookie 失效（401/403）→ 从 dsh-web.stdout.log 取最新 token 重登
//      重登成功 → open 带 token URL 把 App 拉起来（App cookie 与服务端同签名体系，同时失效）
//   4. 服务健康但 App 进程不在（用户点开失败/窗口被关）→ 用最新 token 拉起 App
//   5. 服务健康且 cookie 有效且 App 活着 → 什么都不做，等下一轮
//
// 防抖：两次 open 间隔 >= 30s（state 文件记录），但服务 PID 变化或 cookie 刚刷新时强制重开
//
// 依赖：仅系统自带 /usr/bin/curl、/usr/bin/open、/bin/launchctl、/usr/bin/pgrep；无第三方库。
// 日志：~/.deepseek-harness/logs/dsh-web-watchdog.log（追加、时间戳）
// cookie jar（watchdog 自持，不触碰 App 侧 Safari cookie）：~/.deepseek-harness/runtime/dsh-web-watchdog.cookies
import Foundation

let HOME = FileManager.default.homeDirectoryForCurrentUser.path
let logPath      = "\(HOME)/.deepseek-harness/logs/dsh-web-watchdog.log"
let cookieJar    = "\(HOME)/.deepseek-harness/runtime/dsh-web-watchdog.cookies"
let statePath    = "\(HOME)/.deepseek-harness/runtime/dsh-web-watchdog.state"
let stdoutLog    = "\(HOME)/.deepseek-harness/logs/dsh-web.stdout.log"
let baseURL      = "http://127.0.0.1:3080"
let serviceLabel = "com.appleoppa.deepseek-harness"
let plistPath    = "\(HOME)/Library/LaunchAgents/com.appleoppa.deepseek-harness.plist"
let appPath      = "\(HOME)/Applications/DSH.app"
let openCooldown: TimeInterval = 30
let loopInterval: TimeInterval = 30

// 读 state 文件（两行：last_open_unix  \n  last_service_pid）
func readState() -> (TimeInterval, String) {
    guard let s = try? String(contentsOfFile: statePath, encoding: .utf8) else { return (.infinity, "") }
    let lines = s.split(separator: "\n").map(String.init)
    let ts = lines.count > 0 ? (TimeInterval(lines[0]) ?? .infinity) : .infinity
    let pid = lines.count > 1 ? lines[1] : ""
    return (ts, pid)
}

// 写 state 文件
func writeState(lastOpen: TimeInterval, pid: String) {
    let s = String(format: "%.0f\n%@", lastOpen, pid)
    try? s.write(toFile: statePath, atomically: true, encoding: .utf8)
}

// 当前 dsh-web 服务进程 PID（launchctl list 首列）
func servicePid() -> String {
    let (_, out) = run("/bin/launchctl", ["list"])
    for line in out.split(separator: "\n") {
        if line.contains("\t\(serviceLabel)") {
            return line.split(separator: "\t").first.map(String.init) ?? ""
        }
    }
    return ""
}

// DSH WebApp 进程是否存活（pgrep 按 bundle 标识）
func appProcessAlive() -> Bool {
    let (rc, _) = run("/usr/bin/pgrep", ["-f", "Web App.*DSH.app"])
    return rc == 0
}

// 服务是否存在于 launchd 域（launchctl print 判定）
// launchctl list 只在服务已加载且曾启动过时显示；print 能显示未启动但已 load 的服务
func serviceInDomain() -> Bool {
    let (_, out) = run("/bin/launchctl", ["print", "gui/\(getuid())/\(serviceLabel)"])
    return !out.contains("Could not find service")
}

// 服务不在域 → launchctl load plist 拉回（兼容 bootstrap 与 load 两种方式）
func loadServiceIntoDomain() -> Bool {
    guard FileManager.default.fileExists(atPath: plistPath) else {
        log("FAIL: plist missing \(plistPath)")
        return false
    }
    // launchctl bootstrap 是新建域等价物；失败则退回 load（老式）
    var (rc, err) = run("/bin/launchctl", ["bootstrap", "gui/\(getuid())", plistPath])
    if rc != 0 {
        (rc, err) = run("/bin/launchctl", ["load", plistPath])
        if rc != 0 {
            log("FAIL: bootstrap \(rc) & load \(rc) failed: \(err)")
            return false
        }
    }
    // 等待服务进入域
    var inDomain = false
    for _ in 0..<10 {
        if serviceInDomain() { inDomain = true; break }
        Thread.sleep(forTimeInterval: 0.3)
    }
    log(inDomain ? "service loaded into launchd domain (was missing)" : "WARN: loaded but not yet visible in domain")
    return inDomain
}

func log(_ msg: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    let line = "[\(ts)] \(msg)\n"
    if !FileManager.default.fileExists(atPath: logPath) {
        FileManager.default.createFile(atPath: logPath, contents: nil)
    }
    if let h = FileHandle(forWritingAtPath: logPath) {
        h.seekToEndOfFile()
        h.write(line.data(using: .utf8)!)
        try? h.close()
    }
}

// 执行外部命令，返回 (exitCode, stdout)
// 注意：stderr 合并进 stdout，避免 launchctl print 的报错（写到 stderr）被丢弃导致误判
@discardableResult
func run(_ bin: String, _ args: [String]) -> (Int32, String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: bin)
    p.arguments = args
    let out = Pipe()
    p.standardOutput = out
    p.standardError = out
    do {
        try p.run()
    } catch {
        return (-1, "spawn error: \(error)")
    }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

func curlStatus(_ args: [String]) -> String {
    var a = ["-s", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "4"]
    a.append(contentsOf: args)
    let (_, s) = run("/usr/bin/curl", a)
    return s.trimmingCharacters(in: .whitespacesAndNewlines)
}

// 服务可达性探测（无 cookie 访问 /，401/200/303 均视为可达）
func serviceReachable() -> Bool {
    let code = curlStatus([baseURL + "/"])
    return code == "200" || code == "401" || code == "303" || code == "302"
}

// 带自持 cookie 探测（200 = 会话健康）
func cookieProbe() -> String {
    return curlStatus(["-b", cookieJar, baseURL + "/"])
}

// 从 stdout.log 取最后一行带 token 的 URL
func lastTokenURL() -> String? {
    guard let content = try? String(contentsOfFile: stdoutLog, encoding: .utf8) else { return nil }
    var last: String? = nil
    content.enumerateLines { line, _ in
        if line.contains("token=") { last = line }
    }
    guard let raw = last,
          let range = raw.range(of: "http://127\\.0\\.0\\.1:3080/\\?token=[A-Za-z0-9_-]+", options: .regularExpression) else {
        return nil
    }
    return String(raw[range])
}

// 用 token 换 cookie 到 jar；返回兑换 HTTP 状态
func exchangeToken(_ url: String) -> String {
    return curlStatus(["-c", cookieJar, url])
}

// 重登 + 拉起 App（若冷却期已过；服务 PID 变化或 cookie 刚刷新时强制重开）
func reloginAndReopen(reason: String) {
    log("relogin triggered: \(reason)")
    var tokenURL = lastTokenURL()
    if tokenURL == nil {
        log("no token found in stdout.log, kickstarting service")
        run("/bin/launchctl", ["kickstart", "-k", "gui/\(getuid())/\(serviceLabel)"])
        _ = waitForService(deadline: 30)
        tokenURL = lastTokenURL()
    }
    guard let url = tokenURL else {
        log("FAIL: still no token after kickstart; retry next round")
        return
    }
    let code = exchangeToken(url)
    if code != "303" && code != "302" {
        log("FAIL: token exchange returned \(code) (expect 303); will kickstart next round if persists")
        // 尝试重启服务后换新 token
        run("/bin/launchctl", ["kickstart", "-k", "gui/\(getuid())/\(serviceLabel)"])
        _ = waitForService(deadline: 30)
        if let url2 = lastTokenURL() {
            let code2 = exchangeToken(url2)
            log("retry after kickstart: exchange \(code2)")
            if code2 == "303" || code2 == "302" {
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cookieJar)
                reopen(url2, force: true)
            }
        }
        return
    }
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cookieJar)
    let verify = cookieProbe()
    if verify == "200" {
        log("re-login ok (cookie probe 200)")
        reopen(url, force: true)  // cookie 刚刷新，强制重开 App
    } else {
        log("WARN: cookie probe after login = \(verify); will retry next round")
    }
}

// 拉起 App（带 token URL；force = 跳过 cooldown）
func reopen(_ url: String, force: Bool = false) {
    let (lastOpen, lastPid) = readState()
    let curPid = servicePid()
    let pidChanged = !lastPid.isEmpty && curPid != lastPid
    let sinceOpen = lastOpen.isFinite ? Date().timeIntervalSince1970 - lastOpen : TimeInterval.infinity
    if !force && !pidChanged && sinceOpen < openCooldown {
        log("open suppressed (cooldown \(Int(sinceOpen))s ago, pid unchanged); cookie refreshed, app reopen deferred")
        return
    }
    // 必须显式指定 DSH.app：裸 open URL 会把 URL 交给默认浏览器（Safari），
    // DSH WebApp 容器永远拿不到带 token 的 URL，导致服务重启后 DSH 窗口卡在失效会话。
    let (rc, _) = run("/usr/bin/open", ["-a", appPath, url])
    if rc == 0 {
        writeState(lastOpen: Date().timeIntervalSince1970, pid: curPid)
        log("app reopened with token URL\(pidChanged ? " (service pid changed \(lastPid)->\(curPid))" : "")\(force ? " [forced]" : "")")
    } else {
        log("FAIL: open returned \(rc)")
    }
}

// 等待服务可达，最多 deadline 秒；返回是否可达
func waitForService(deadline: TimeInterval) -> Bool {
    let start = Date()
    while Date().timeIntervalSince(start) < deadline {
        if serviceReachable() { return true }
        Thread.sleep(forTimeInterval: 1)
    }
    return serviceReachable()
}

// 单轮检查（幂等）
func runOnce() {
    // 1. 服务可达性
    if !serviceReachable() {
        // 根因治理（2026-09-09）：服务可能从 launchd 域消失（load 丢失），此时 kickstart 必失败
        // 先检查域存在性；不在域 → 直接 load plist，而不是盲目 kickstart
        if !serviceInDomain() {
            log("service not in launchd domain, loading \(plistPath)")
            let loaded = loadServiceIntoDomain()
            if loaded {
                // load 后 launchd 会按 KeepAlive 自动拉起服务
                let ok = waitForService(deadline: 30)
                if ok {
                    log("service back after load; ensuring app session fresh")
                    reloginAndReopen(reason: "service loaded from domain gap (token may have rotated)")
                } else {
                    log("FAIL: service still unreachable after load; retry next round")
                }
            } else {
                log("FAIL: could not load service into domain; retry next round")
            }
            return
        }
        // 服务在域但不可达（进程挂了）→ 走原来的 kickstart 逻辑
        log("service unreachable, kickstarting \(serviceLabel)")
        run("/bin/launchctl", ["kickstart", "-k", "gui/\(getuid())/\(serviceLabel)"])
        let ok = waitForService(deadline: 30)
        if ok {
            log("service back after kickstart; ensuring app session fresh")
            // 服务可能已重启 → token 可能已轮换；重登并拉起 App
            reloginAndReopen(reason: "service was restarted (token may have rotated)")
        } else {
            log("FAIL: service still unreachable after kickstart; retry next round")
        }
        return
    }

    // 2. 会话健康检查（cookie）
    let probe = cookieProbe()
    if probe == "401" || probe == "403" {
        reloginAndReopen(reason: "cookie probe returned \(probe)")
        return
    }
    if probe != "200" {
        log("WARN: unexpected probe status \(probe); leave to next round")
        return
    }

    // 3. cookie 有效但 App 进程不在（用户打开失败/窗口被关/服务重启后 App 未刷新）
    if !appProcessAlive() {
        log("service healthy but DSH app process not running; reopening app")
        if let url = lastTokenURL() {
            reopen(url, force: true)
        } else {
            log("WARN: no token URL available; skip reopen")
        }
    }
    // 4. cookie 有效且 App 活着：什么都不做（健康态，静默）
}

// ---------- 主流程：KeepAlive 常驻 + 内部循环 ----------
let myPid = ProcessInfo.processInfo.processIdentifier

// 锁：防止多实例并发（KeepAlive 重启旧实例未完全退出的边缘情况）
let lockPath = "\(HOME)/.deepseek-harness/runtime/dsh-web-watchdog.lock"
let lockFd = open(lockPath, O_CREAT | O_RDWR, 0o600)
if lockFd < 0 {
    log("cannot open lock file \(lockPath)")
    exit(1)
}

// 记录启动
log("watchdog started (pid \(myPid), keepalive loop mode)")

while true {
    let locked = flock(lockFd, LOCK_EX | LOCK_NB)
    if locked != 0 {
        log("another watchdog instance running (pid lock busy), skip round")
        Thread.sleep(forTimeInterval: loopInterval)
        continue
    }
    // 清理陈旧 pid 内容
    ftruncate(lockFd, 0)
    let pidStr = "\(myPid)\n"
    pidStr.withCString { _ = write(lockFd, $0, pidStr.utf8.count) }

    runOnce()

    flock(lockFd, LOCK_UN)
    Thread.sleep(forTimeInterval: loopInterval)
}
