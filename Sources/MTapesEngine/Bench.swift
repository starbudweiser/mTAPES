import Darwin
import Foundation

/// Mesure honnête du coût d'une prise : le travail de capture se répartit entre mtapes, le service d'encodage
/// (VTEncoderXPCService), replayd (ScreenCaptureKit) et WindowServer ; on mesure chacun, puis la charge de toute la machine.
public enum ResourceMeter {
    public struct Snapshot {
        var wall: Double
        var perProcess: [String: Double]      // secondes de processeur cumulées par nom de processus suivi
        var systemBusyTicks: UInt64
        var systemTotalTicks: UInt64
    }

    static let tracked = ["mtapes", "VTEncoderXPCService", "replayd", "WindowServer", "screencaptureui"]

    public static func snapshot() -> Snapshot {
        var cpu = [String: Double]()
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let toSeconds = Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000

        let count = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        if count > 0 {
            var pids = [pid_t](repeating: 0, count: Int(count) / MemoryLayout<pid_t>.size + 16)
            let bytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
            for pid in pids.prefix(Int(bytes) / MemoryLayout<pid_t>.size) where pid > 0 {
                var name = [CChar](repeating: 0, count: 256)
                guard proc_name(pid, &name, 256) > 0 else { continue }
                let n = String(cString: name)
                guard tracked.contains(n) else { continue }
                var info = proc_taskinfo()
                let size = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, Int32(MemoryLayout<proc_taskinfo>.size))
                guard size == Int32(MemoryLayout<proc_taskinfo>.size) else { continue }
                cpu[n, default: 0] += Double(info.pti_total_user + info.pti_total_system) * toSeconds
            }
        }

        var load = host_cpu_load_info()
        var size = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &load) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &size)
            }
        }
        var busy: UInt64 = 0, total: UInt64 = 0
        if result == KERN_SUCCESS {
            let u = UInt64(load.cpu_ticks.0), s = UInt64(load.cpu_ticks.1), i = UInt64(load.cpu_ticks.2), n = UInt64(load.cpu_ticks.3)
            busy = u + s + n; total = u + s + i + n
        }
        return Snapshot(wall: HostClock.now(), perProcess: cpu, systemBusyTicks: busy, systemTotalTicks: total)
    }

    public static func peakResidentBytes() -> Int64 {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Int64(usage.ru_maxrss)             // en octets sur macOS
    }
}

public struct BenchResult: Codable {
    public var seconds: Double
    public var width: Int
    public var height: Int
    public var profile: String
    public var pixelFormat: String
    public var framesComplete: Int
    public var framesIdle: Int
    public var framesWritten: Int
    public var framesDropped: Int
    public var megabytes: Double
    public var megabytesPerMinute: Double
    public var averageMegabitsPerSecond: Double
    public var firstFrameLatency: Double
    public var stopLatency: Double
    /// Charge moyenne en « cœurs » par processus (1,0 = un cœur entier occupé).
    public var cpuCoresByProcess: [String: Double]
    /// Somme des processus suivis, en cœurs.
    public var cpuCoresTracked: Double
    /// Occupation de toute la machine pendant la prise, en cœurs (inclut le bruit des autres programmes).
    public var cpuCoresSystem: Double
    public var peakResidentMegabytes: Double
}

public enum Bench {
    public static func run(target: CaptureTarget, options: CaptureOptions, seconds: Double, outputDirectory: URL,
                           onStart: (() -> Void)? = nil) async throws -> (BenchResult, TapePackage) {
        let before = ResourceMeter.snapshot()
        let session = try await Recorder.start(target: target, options: options, outputDirectory: outputDirectory)
        onStart?()
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        let (package, meta) = try await session.stop()
        let after = ResourceMeter.snapshot()

        let wall = max(0.001, after.wall - before.wall)
        var byProcess = [String: Double]()
        for (name, cpu) in after.perProcess { byProcess[name] = max(0, cpu - (before.perProcess[name] ?? 0)) / wall }
        let tracked = byProcess.values.reduce(0, +)
        let cores = Double(ProcessInfo.processInfo.activeProcessorCount)
        let dTotal = Double(after.systemTotalTicks &- before.systemTotalTicks)
        let dBusy = Double(after.systemBusyTicks &- before.systemBusyTicks)
        let system = dTotal > 0 ? dBusy / dTotal * cores : 0

        let mb = Double(meta.stats.bytes) / 1_000_000
        let result = BenchResult(
            seconds: meta.durationSeconds, width: meta.width, height: meta.height, profile: meta.profile,
            pixelFormat: meta.pixelFormat, framesComplete: meta.stats.framesComplete, framesIdle: meta.stats.framesIdle,
            framesWritten: meta.stats.framesWritten, framesDropped: meta.stats.framesDropped, megabytes: mb,
            megabytesPerMinute: meta.durationSeconds > 0 ? mb / meta.durationSeconds * 60 : 0,
            averageMegabitsPerSecond: meta.durationSeconds > 0 ? mb * 8 / meta.durationSeconds : 0,
            firstFrameLatency: meta.stats.firstFrameLatency, stopLatency: meta.stats.stopLatency,
            cpuCoresByProcess: byProcess, cpuCoresTracked: tracked, cpuCoresSystem: system,
            peakResidentMegabytes: Double(ResourceMeter.peakResidentBytes()) / 1_000_000)
        return (result, package)
    }
}
