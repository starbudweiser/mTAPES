import CoreGraphics
import Foundation
import VideoToolbox

/// Diagnostic de la machine : autorisations, encodeur matériel, propriétés d'encodage disponibles.
public struct DoctorReport: Codable {
    public var macOS: String
    public var chip: String
    public var cores: Int
    public var screenRecording: Bool
    public var inputMonitoring: Bool
    public var accessibility: Bool
    public var hevcHardwareEncoder: Bool
    public var constantQualitySupported: Bool
    public var hevc10bitHardwareEncoder: Bool
    public var displays: Int
}

public enum Doctor {
    public static func run() async -> DoctorReport {
        var chip = [CChar](repeating: 0, count: 128)
        var size = chip.count
        sysctlbyname("machdep.cpu.brand_string", &chip, &size, nil, 0)
        let (hw8, quality8) = probeHEVC(tenBit: false)
        let (hw10, _) = probeHEVC(tenBit: true)
        let displays = (try? await TargetCatalog.content().displays.count) ?? 0
        return DoctorReport(
            macOS: ProcessInfo.processInfo.operatingSystemVersionString,
            chip: String(cString: chip), cores: ProcessInfo.processInfo.activeProcessorCount,
            screenRecording: Permissions.screenRecording, inputMonitoring: Permissions.inputMonitoring,
            accessibility: Permissions.accessibility, hevcHardwareEncoder: hw8, constantQualitySupported: quality8,
            hevc10bitHardwareEncoder: hw10, displays: displays)
    }

    /// Crée une session d'encodage HEVC qui EXIGE le matériel ; indique aussi si la qualité constante est acceptée.
    static func probeHEVC(tenBit: Bool) -> (hardware: Bool, constantQuality: Bool) {
        var session: VTCompressionSession?
        let spec: [String: Any] = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true]
        let status = VTCompressionSessionCreate(
            allocator: nil, width: 1920, height: 1080, codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: spec as CFDictionary, imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &session)
        guard status == noErr, let session else { return (false, false) }
        defer { VTCompressionSessionInvalidate(session) }
        if tenBit {
            let level = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel,
                                             value: kVTProfileLevel_HEVC_Main10_AutoLevel)
            return (level == noErr, false)
        }
        let q = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_Quality, value: 0.65 as CFNumber)
        return (true, q == noErr)
    }
}
