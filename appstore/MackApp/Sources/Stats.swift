// Native replacement for server.py: samples the Mac once a second with sandbox-safe APIs only
// (host_statistics, getifaddrs, IORegistry reads, statfs, sysctl, proc_pidinfo) and serves the same JSON the pages expect.
import Foundation
import IOKit
import Darwin

private func registryProps(_ cls: String) -> [[String: Any]] {
    var it: io_iterator_t = 0; var out: [[String: Any]] = []
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(cls), &it) == KERN_SUCCESS else { return out }
    while case let e = IOIteratorNext(it), e != 0 {
        var props: Unmanaged<CFMutableDictionary>?
        if IORegistryEntryCreateCFProperties(e, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS, let d = props?.takeRetainedValue() as? [String: Any] { out.append(d) }
        IOObjectRelease(e)
    }
    IOObjectRelease(it); return out
}

private func sysctlString(_ key: String) -> String? {
    var size = 0; guard sysctlbyname(key, nil, &size, nil, 0) == 0, size > 0 else { return nil }
    var buf = [CChar](repeating: 0, count: size); sysctlbyname(key, &buf, &size, nil, 0); return String(cString: buf)
}

private func marketingModel() -> String {   // "MacBook Pro (14-inch, M5 Pro)" -> "MacBook Pro"
    let entry = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/product")
    if entry != 0 { defer { IOObjectRelease(entry) }
        if let p = IORegistryEntryCreateCFProperty(entry, "product-name" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Data,
           let s = String(data: p, encoding: .utf8)?.trimmingCharacters(in: .controlCharacters) { return s.components(separatedBy: " (").first ?? s } }
    return "Mac"
}

final class Stats {
    static let shared = Stats()
    private let historyMax = 3600
    private let lock = NSLock()
    private var history: [[String: Any]] = []
    private var nowSample: [String: Any] = [:]
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "mack.stats")
    private var prevTicks: [UInt32] = [], prevNet: (UInt64, UInt64) = (0, 0), prevDisk: (UInt64, UInt64) = (0, 0), prevTime = Date().timeIntervalSince1970
    private var prevProcs: [pid_t: UInt64] = [:], prevProcTime = Date().timeIntervalSince1970
    private var procs: [[String: Any]] = [], procsMem: [[String: Any]] = []
    private var tickCount = 0
    private var timebase = mach_timebase_info()
    let staticInfo: [String: Any]
    private let saveURL: URL

    init() {
        mach_timebase_info(&timebase)
        let override = UserDefaults.standard.string(forKey: "hostOverride")   // defaults write <bundle id> hostOverride demo-mac  (hides the real name in screenshots)
        var hn = [CChar](repeating: 0, count: 256); gethostname(&hn, 255)
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let accel = registryProps("IOAccelerator").first
        staticInfo = [
            "host": override ?? String(cString: hn).replacingOccurrences(of: ".local", with: ""),
            "os": "macOS \(v.majorVersion).\(v.minorVersion)" + (v.patchVersion > 0 ? ".\(v.patchVersion)" : ""),
            "chip": sysctlString("machdep.cpu.brand_string") ?? "Apple silicon",
            "model": marketingModel(),
            "cores": ProcessInfo.processInfo.processorCount,
            "gpu_cores": accel?["gpu-core-count"] as? Int ?? 0,
        ]
        let dir = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))?.appendingPathComponent("MacMon", isDirectory: true)
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        saveURL = dir.appendingPathComponent("history.json")
        if let d = try? Data(contentsOf: saveURL), let arr = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] {
            let cutoff = Date().timeIntervalSince1970 - Double(historyMax)
            history = arr.filter { ($0["t"] as? Double ?? Double($0["t"] as? Int ?? 0)) > cutoff }
        }
    }

    func start() {
        prevTicks = cpuTicks() ?? [0, 0, 0, 0]; prevNet = netBytes(); prevDisk = diskBytes(); prevTime = Date().timeIntervalSince1970
        _ = sampleProcesses()   // prime the CPU-time baseline
        let t = DispatchSource.makeTimerSource(queue: queue); t.schedule(deadline: .now() + 1, repeating: 1); t.setEventHandler { [weak self] in self?.tick() }; t.resume(); timer = t
    }
    func save() {
        lock.lock(); let data = try? JSONSerialization.data(withJSONObject: history); lock.unlock()
        if let data { try? data.write(to: saveURL, options: .atomic) }
    }

    // MARK: sources
    private func cpuTicks() -> [UInt32]? {
        var info = host_cpu_load_info(); var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count) } }
        return r == KERN_SUCCESS ? [info.cpu_ticks.0, info.cpu_ticks.1, info.cpu_ticks.2, info.cpu_ticks.3] : nil
    }
    private func memory() -> (used: UInt64, total: UInt64) {
        var vm = vm_statistics64(); var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &vm) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) } }
        let total = ProcessInfo.processInfo.physicalMemory
        guard r == KERN_SUCCESS else { return (0, total) }
        return (min((UInt64(vm.active_count) + UInt64(vm.wire_count) + UInt64(vm.compressor_page_count)) * UInt64(vm_kernel_page_size), total), total)
    }
    private func netBytes() -> (UInt64, UInt64) {
        var ifa: UnsafeMutablePointer<ifaddrs>?; var rx: UInt64 = 0, tx: UInt64 = 0
        guard getifaddrs(&ifa) == 0 else { return (0, 0) }
        var p = ifa; while let c = p {
            if String(cString: c.pointee.ifa_name).hasPrefix("en"), c.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_LINK), let d = c.pointee.ifa_data {
                let s = d.assumingMemoryBound(to: if_data.self).pointee; rx += UInt64(s.ifi_ibytes); tx += UInt64(s.ifi_obytes) }
            p = c.pointee.ifa_next
        }
        freeifaddrs(ifa); return (rx, tx)
    }
    private func diskBytes() -> (UInt64, UInt64) {
        var r: UInt64 = 0, w: UInt64 = 0
        for d in registryProps("IOBlockStorageDriver") { if let s = d["Statistics"] as? [String: Any] { r += (s["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0; w += (s["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0 } }
        return (r, w)
    }
    private func gpu() -> (util: Int, mem: Int) {
        guard let ps = registryProps("IOAccelerator").first?["PerformanceStatistics"] as? [String: Any] else { return (0, 0) }
        return ((ps["Device Utilization %"] as? NSNumber)?.intValue ?? 0, (ps["In use system memory"] as? NSNumber)?.intValue ?? 0)
    }
    private func diskUsage() -> (used: UInt64, total: UInt64) {
        var s = statfs(); if statfs("/System/Volumes/Data", &s) != 0 { statfs("/", &s) }
        let bs = UInt64(s.f_bsize); return ((UInt64(s.f_blocks) - UInt64(s.f_bfree)) * bs, UInt64(s.f_blocks) * bs)
    }
    private func bootTime() -> TimeInterval {
        var bt = timeval(); var sz = MemoryLayout<timeval>.size
        return sysctlbyname("kern.boottime", &bt, &sz, nil, 0) == 0 ? TimeInterval(bt.tv_sec) : Date().timeIntervalSince1970
    }

    /// Top processes. The process list comes from sysctl(KERN_PROC_ALL); per-process CPU time and memory from proc_pidinfo,
    /// which still work inside the App Sandbox (proc_listpids and proc_pid_rusage do not).
    private func sampleProcesses() -> [(pid: pid_t, name: String, cpuNs: UInt64, mem: UInt64)] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]; var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        var buf = [UInt8](repeating: 0, count: size * 2); var s2 = buf.count
        guard sysctl(&mib, 4, &buf, &s2, nil, 0) == 0 else { return [] }
        let n = s2 / MemoryLayout<kinfo_proc>.stride; var out: [(pid_t, String, UInt64, UInt64)] = []
        buf.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: kinfo_proc.self)
            for i in 0..<n {
                let pid = p[i].kp_proc.p_pid; if pid <= 0 { continue }
                var ti = proc_taskinfo()
                guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &ti, Int32(MemoryLayout<proc_taskinfo>.size)) > 0 else { continue }
                var long = [CChar](repeating: 0, count: 64)
                let name = proc_name(pid, &long, 64) > 0 ? String(cString: long)
                    : withUnsafePointer(to: p[i].kp_proc.p_comm) { $0.withMemoryRebound(to: CChar.self, capacity: 17) { String(cString: $0) } }
                let cpu = (ti.pti_total_user &+ ti.pti_total_system) * UInt64(timebase.numer) / UInt64(timebase.denom)
                out.append((pid, name, cpu, ti.pti_resident_size))
            }
        }
        return out
    }
    private func updateProcesses() {
        let now = Date().timeIntervalSince1970, dt = max(now - prevProcTime, 0.001)
        let cur = sampleProcesses(); var rows: [[String: Any]] = []; var next: [pid_t: UInt64] = [:]
        for p in cur {
            next[p.pid] = p.cpuNs
            let cpu = prevProcs[p.pid].map { Double(p.cpuNs &- $0) / 1e9 / dt * 100 } ?? 0
            rows.append(["pid": Int(p.pid), "cpu": (cpu * 10).rounded() / 10, "mem": p.mem, "name": p.name])
        }
        prevProcs = next; prevProcTime = now
        procs = Array(rows.sorted { ($0["cpu"] as! Double) > ($1["cpu"] as! Double) }.prefix(8))
        procsMem = Array(rows.sorted { ($0["mem"] as! UInt64) > ($1["mem"] as! UInt64) }.prefix(8))
    }

    // MARK: sampling
    private func tick() {
        let now = Date().timeIntervalSince1970, dt = max(now - prevTime, 0.001)
        let t = cpuTicks() ?? prevTicks; let d = (0..<4).map { Double(t[$0] &- prevTicks[$0]) }
        let cpu = 100 * (d[0] + d[1] + d[3]) / max(d.reduce(0, +), 1)
        let net = netBytes(), dk = diskBytes(), g = gpu(), m = memory(), du = diskUsage()
        if tickCount % 3 == 0 { updateProcesses() }
        var load = [Double](repeating: 0, count: 3); getloadavg(&load, 3)
        let r1 = { (x: Double) in (x * 10).rounded() / 10 }
        let sample: [String: Any] = [
            "t": Int(now), "cpu": r1(cpu), "gpu": g.util, "mem": r1(100 * Double(m.used) / Double(max(m.total, 1))),
            "mem_used": m.used, "mem_total": m.total, "gpu_mem": g.mem, "disk_used": du.used, "disk_total": du.total,
            "net_down": Double(net.0 >= prevNet.0 ? net.0 - prevNet.0 : 0) / dt, "net_up": Double(net.1 >= prevNet.1 ? net.1 - prevNet.1 : 0) / dt,
            "disk_read": Double(dk.0 >= prevDisk.0 ? dk.0 - prevDisk.0 : 0) / dt, "disk_write": Double(dk.1 >= prevDisk.1 ? dk.1 - prevDisk.1 : 0) / dt,
            "load": load, "uptime": Int(now - bootTime()), "procs": procs, "procs_mem": procsMem,
        ]
        prevTicks = t; prevNet = net; prevDisk = dk; prevTime = now; tickCount += 1
        lock.lock(); nowSample = sample; history.append(["t": Int(now), "cpu": sample["cpu"]!, "gpu": g.util, "mem": sample["mem"]!])
        if history.count > historyMax { history.removeFirst(history.count - historyMax) }; lock.unlock()
        if tickCount % 30 == 0 { save() }
    }

    // MARK: API
    var latest: (cpu: Double, gpu: Double, mem: Double)? {
        lock.lock(); defer { lock.unlock() }
        guard let c = nowSample["cpu"] as? Double, let m = nowSample["mem"] as? Double else { return nil }
        return (c, Double(nowSample["gpu"] as? Int ?? 0), m)
    }
    func apiStats(since: Int) -> Data {
        lock.lock()
        let hist = history.filter { ($0["t"] as? Int ?? 0) > since }
        let body: [String: Any] = ["static": staticInfo, "now": nowSample, "history": hist]
        lock.unlock()
        return (try? JSONSerialization.data(withJSONObject: body)) ?? Data("{}".utf8)
    }

    // YouTube no longer embeds a channel's "live" directly, so ask which video the channel is streaming right now.
    private var liveCache: [String: (Date, String?)] = [:]
    func liveVideo(channel: String, completion: @escaping (String?) -> Void) {
        if let hit = liveCache[channel], Date().timeIntervalSince(hit.0) < (hit.1 != nil ? 300 : 60) { completion(hit.1); return }
        var req = URLRequest(url: URL(string: "https://www.youtube.com/channel/\(channel)/live?hl=en")!); req.timeoutInterval = 8
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        req.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        URLSession.shared.dataTask(with: req) { data, _, _ in
            var id: String?
            if let data, let html = String(data: data.prefix(3_000_000), encoding: .utf8), html.contains("\"isLive\":true"),
               let r = html.range(of: #"<link rel="canonical" href="https://www\.youtube\.com/watch\?v=[\w-]{11}""#, options: .regularExpression) { id = String(html[r].suffix(12).dropLast()) }
            DispatchQueue.main.async { self.liveCache[channel] = (Date(), id); completion(id) }
        }.resume()
    }
}
