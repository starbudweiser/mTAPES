import AVFoundation
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

    static let tracked = ["mtapes", "mTAPES", "VTEncoderXPCService", "replayd", "WindowServer", "screencaptureui"]

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

        // Processus que proc_pidinfo ne peut pas lire (WindowServer, propriété du système) : on passe par ps (précision 10 ms).
        for (name, seconds) in psCPU() where cpu[name] == nil { cpu[name] = seconds }

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

    /// Secondes de processeur cumulées par nom de processus suivi, lues par `ps -axo cputime=,comm=`.
    static func psCPU() -> [String: Double] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "cputime=,comm="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return [:] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        var out = [String: Double]()
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let name = (String(parts[1]) as NSString).lastPathComponent
            guard tracked.contains(name) else { continue }
            var seconds = 0.0
            for field in parts[0].split(separator: ":") { seconds = seconds * 60 + (Double(field) ?? 0) }
            out[name, default: 0] += seconds
        }
        return out
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

/// Qualité visuelle du brut par rapport à la référence quasi sans perte (mêmes images), mesurée avec ffmpeg.
public struct QualityResult: Codable {
    public var ssim: Double          // 1,0 = identique
    public var psnr: Double          // dB
    public var rawMegabytes: Double
    public var referenceMegabytes: Double
}

public enum QualityCheck {
    public static func measure(raw: URL, reference: URL) throws -> QualityResult {
        let candidates = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
        guard let ffmpeg = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw EngineError.writerFailed("ffmpeg introuvable (nécessaire pour mesurer la qualité)")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = ["-hide_banner", "-nostats", "-i", raw.path, "-i", reference.path,
                             "-lavfi", "[0:v]format=yuv420p[a];[1:v]format=yuv420p[b];[a]split[a1][a2];[b]split[b1][b2];[a1][b1]ssim;[a2][b2]psnr",
                             "-f", "null", "-"]
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = Pipe()
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        func number(after marker: String, in line: String) -> Double? {
            guard let r = line.range(of: marker) else { return nil }
            let tail = line[r.upperBound...].prefix { "0123456789.inf".contains($0) }
            return Double(tail)
        }
        var ssim = 0.0, psnr = 0.0
        for line in text.split(separator: "\n").map(String.init) {
            if line.contains("SSIM"), let v = number(after: "All:", in: line) { ssim = v }
            if line.contains("PSNR"), let v = number(after: "average:", in: line) { psnr = v }
        }
        func mb(_ u: URL) -> Double {
            Double((try? FileManager.default.attributesOfItem(atPath: u.path)[.size] as? NSNumber)??.int64Value ?? 0) / 1_000_000
        }
        return QualityResult(ssim: ssim, psnr: psnr, rawMegabytes: mb(raw), referenceMegabytes: mb(reference))
    }
}

/// Banc d'essai de l'encodeur seul, sur une séquence source fixe (reproductible, sans écran ni autorisation) :
/// relit un fichier vidéo (cadence variable conservée) et le réencode avec les réglages d'un profil.
public struct EncoderBenchResult: Codable {
    public var profile: String
    public var pixelFormat: String
    public var frames: Int
    public var sourceSeconds: Double
    public var encodeWallSeconds: Double
    public var realtimeFactor: Double      // secondes de vidéo encodées par seconde réelle (≥ 1 : plus rapide que le temps réel)
    public var megabytes: Double
    public var megabytesPerMinute: Double
}

public enum EncoderBench {
    public static func run(input: URL, output: URL, profile: QualityProfile, pixelFormat: PixelFormatChoice, quality: Double? = nil, keyFrameInterval: Double? = nil) async throws -> EncoderBenchResult {
        let asset = AVURLAsset(url: input)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw EngineError.noFrames }
        let size = try await track.load(.naturalSize)
        let duration = try await asset.load(.duration)
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat.cvFormat,
        ])
        reader.add(out)
        guard reader.startReading() else { throw EngineError.writerFailed(reader.error?.localizedDescription ?? "lecture impossible") }

        try? FileManager.default.removeItem(at: output)
        let writer = try VideoWriter(url: output, width: Int(size.width), height: Int(size.height), profile: profile,
                                     fps: profile.maxFPS, tenBit: pixelFormat.isTenBit, quality: quality, keyFrameInterval: keyFrameInterval)
        let start = Date()
        var frames = 0
        var lastPTS = CMTime.zero
        while let sample = out.copyNextSampleBuffer() {
            guard writer.appendWaiting(sample) else { throw EngineError.writerFailed(writer.failure ?? "image refusée") }
            lastPTS = CMSampleBufferGetPresentationTimeStamp(sample)
            frames += 1
        }
        try await writer.finish(endTime: duration)
        let wall = Date().timeIntervalSince(start)
        let seconds = max(CMTimeGetSeconds(duration), CMTimeGetSeconds(lastPTS))
        let bytes = (try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? NSNumber)??.int64Value ?? 0
        let mb = Double(bytes) / 1_000_000
        return EncoderBenchResult(profile: profile.rawValue, pixelFormat: pixelFormat.rawValue, frames: frames, sourceSeconds: seconds,
                                  encodeWallSeconds: wall, realtimeFactor: seconds / max(wall, 0.001), megabytes: mb,
                                  megabytesPerMinute: seconds > 0 ? mb / seconds * 60 : 0)
    }
}
