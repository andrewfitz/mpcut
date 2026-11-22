import CoreGraphics
import CoreVideo
import Foundation

struct StillImageTarget: Sendable {
    enum Transfer: Sendable { case bt709, sRGB, pq, hlg, gamma22, gamma28, bt2020, smpte240m }
    enum Primaries: Sendable { case bt709, bt2020, displayP3 }

    let transfer: Transfer
    let primaries: Primaries
    let diffuseWhite: Float

    init(canvas: StillImageCanvas, forceSDR: Bool) throws {
        guard (1...1_000).contains(canvas.diffuseWhiteNits) else {
            throw StillImage.error("still_color", "Still program reference white is invalid.")
        }
        diffuseWhite = Float(canvas.diffuseWhiteNits)
        if forceSDR {
            transfer = .sRGB
            primaries = .bt709
            return
        }
        switch canvas.transfer.lowercased() {
        case "bt709", "rec709", "smpte170m", "sdr": transfer = .bt709
        case "smpte240m": transfer = .smpte240m
        case "srgb", "iec61966-2-1": transfer = .sRGB
        case "smpte2084", "pq": transfer = .pq
        case "arib-std-b67", "hlg": transfer = .hlg
        case "gamma22": transfer = .gamma22
        case "gamma28": transfer = .gamma28
        case "bt2020-10", "bt2020-12": transfer = .bt2020
        default: throw StillImage.error("still_color", "Unsupported still program transfer \(canvas.transfer).")
        }
        switch canvas.primaries.lowercased() {
        case "bt709", "rec709", "srgb": primaries = .bt709
        case "bt2020", "rec2020", "bt2100": primaries = .bt2020
        case "display-p3", "displayp3", "p3", "smpte432": primaries = .displayP3
        default: throw StillImage.error("still_color", "Unsupported still program primaries \(canvas.primaries).")
        }
        if transfer == .hlg && primaries != .bt2020 {
            throw StillImage.error("still_color", "HLG rendering requires BT.2020 primaries.")
        }
    }

    var isHDR: Bool { transfer == .hlg || transfer == .pq }

    var linearColorSpace: CGColorSpace {
        switch primaries {
        case .bt709: return StillImage.linear709
        case .bt2020: return StillImage.linear2020
        case .displayP3: return StillImage.linearP3
        }
    }

    var displayColorSpace: CGColorSpace? {
        let name: CFString
        switch (transfer, primaries) {
        case (.pq, .bt709): name = CGColorSpace.itur_709_PQ
        case (.pq, .bt2020): name = CGColorSpace.itur_2100_PQ
        case (.pq, .displayP3): name = CGColorSpace.displayP3_PQ
        case (.hlg, .bt2020): name = CGColorSpace.itur_2100_HLG
        case (.sRGB, .bt709): name = CGColorSpace.sRGB
        case (.sRGB, .displayP3): name = CGColorSpace.displayP3
        case (.bt709, .bt709): name = CGColorSpace.itur_709
        case (.bt2020, .bt2020): name = CGColorSpace.itur_2020
        default: return nil
        }
        return CGColorSpace(name: name)
    }

    var primariesAttachment: CFString {
        switch primaries {
        case .bt709: return kCVImageBufferColorPrimaries_ITU_R_709_2
        case .bt2020: return kCVImageBufferColorPrimaries_ITU_R_2020
        case .displayP3: return kCVImageBufferColorPrimaries_P3_D65
        }
    }

    var transferAttachment: CFString {
        switch transfer {
        case .bt709: return kCVImageBufferTransferFunction_ITU_R_709_2
        case .bt2020: return kCVImageBufferTransferFunction_ITU_R_2020
        case .smpte240m: return kCVImageBufferTransferFunction_SMPTE_240M_1995
        case .sRGB: return kCVImageBufferTransferFunction_sRGB
        case .hlg: return kCVImageBufferTransferFunction_ITU_R_2100_HLG
        case .pq: return kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ
        case .gamma22, .gamma28: return kCVImageBufferTransferFunction_UseGamma
        }
    }

    private var luminanceWeights: SIMD3<Float> {
        switch primaries {
        case .bt709: return SIMD3(0.2126, 0.7152, 0.0722)
        case .bt2020: return SIMD3(0.2627, 0.6780, 0.0593)
        case .displayP3: return SIMD3(0.2290, 0.6917, 0.0793)
        }
    }

    private func luminance(_ value: SIMD3<Float>) -> Float {
        let weighted = value * luminanceWeights
        return weighted.x + weighted.y + weighted.z
    }

    private func sdrRendition(_ value: SIMD3<Float>) -> SIMD3<Float> {
        // Retain blacks and midtones through half reference white. Map
        // brighter HDR luminance through a continuous, asymptotic shoulder.
        let light = luminance(value)
        let mapped: Float = light > 0.5 ? 1 - 0.25 / light : max(0, light)
        var result = light > 0 ? value * (mapped / light) : SIMD3(repeating: 0)
        // Bring out-of-gamut values toward neutral at a constant luminance.
        let low = min(result.x, result.y, result.z)
        let high = max(result.x, result.y, result.z)
        let lowScale = low < 0 ? mapped / (mapped - low) : 1
        let highScale = high > 1 ? (1 - mapped) / (high - mapped) : 1
        let grey = SIMD3<Float>(repeating: mapped)
        result = grey + (result - grey) * min(lowScale, highScale)
        return result
    }

    func encode(
        _ linear: SIMD3<Float>, alpha: Float, background: SIMD3<Float>, isHDRSource: Bool
    ) -> SIMD3<UInt16> {
        let opacity = alpha.isFinite ? min(max(alpha, 0), 1) : 0
        let backdrop = background * (1 - opacity)
        let value: SIMD3<Float>
        if isHDR {
            // Image I/O and ColorSync's linear HDR reference is 203 cd/m².
            // SDR artwork is assigned the configured program diffuse white.
            let white: Float = isHDRSource ? 203 : diffuseWhite
            let nits = linear * white + backdrop * diffuseWhite
            if transfer == .hlg {
                // Inverse BT.2100 OOTF for a 1,000 cd/m² monitor at gamma 1.2.
                let normalized = nits / 1_000
                let light = max(luminance(normalized), 0)
                value = light > 0 ? normalized * powf(light, -1 / 6) : SIMD3(repeating: 0)
            } else {
                value = nits / 10_000
            }
        } else {
            let foreground = isHDRSource && opacity > 0 ? sdrRendition(linear / opacity) * opacity : linear
            value = foreground + backdrop
        }
        return SIMD3(quantize(value.x), quantize(value.y), quantize(value.z))
    }

    private func quantize(_ linear: Float) -> UInt16 {
        guard linear.isFinite else { return 0 }
        let x = min(max(linear, 0), 1)
        let encoded: Float
        switch transfer {
        case .sRGB:
            encoded = x <= 0.0031308 ? 12.92 * x : 1.055 * powf(x, 1 / 2.4) - 0.055
        case .bt709:
            encoded = x < 0.018 ? 4.5 * x : 1.099 * powf(x, 0.45) - 0.099
        case .bt2020:
            encoded = x < 0.0181 ? 4.5 * x : 1.0993 * powf(x, 0.45) - 0.0993
        case .smpte240m:
            encoded = x < 0.0228 ? 4 * x : 1.1115 * powf(x, 0.45) - 0.1115
        case .gamma22:
            encoded = powf(x, 1 / 2.2)
        case .gamma28:
            encoded = powf(x, 1 / 2.8)
        case .pq:
            let power = powf(x, 2610 / 16384)
            encoded = powf((3424 / 4096 + (2413 / 128) * power) / (1 + (2392 / 128) * power), 2523 / 32)
        case .hlg:
            encoded = x <= 1 / 12 ? sqrtf(3 * x) : 0.17883277 * logf(12 * x - 0.28466892) + 0.55991073
        }
        return UInt16((min(max(encoded, 0), 1) * 65535).rounded())
    }
}
