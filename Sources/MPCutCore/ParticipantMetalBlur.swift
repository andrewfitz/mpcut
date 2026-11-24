import CoreImage
import Foundation
import Metal

/// Dense region blur at the shared picture boundary. Each region has its own sampling domain,
/// including where a nameplate overlaps another region or touches the source edge.
final class ParticipantMetalBlur {
    static let shared = MTLCreateSystemDefaultDevice().flatMap(ParticipantMetalBlur.init(device:))
    private static let blockSize = 32
    private static let tapCount = 15
    private static let cachedBufferBytes = 1_048_576

    private struct Region {
        var source: SIMD4<UInt32>
        var atlas: SIMD4<UInt32>
        var step: UInt32
    }

    private struct Layout {
        let extent: CGRect
        let areas: [CGRect]
        let atlasWidth: Int
        let atlasHeight: Int
        let regionBuffer: MTLBuffer
        let rowRegions: MTLBuffer
        let weightBuffer: MTLBuffer
        let rangeBuffer: MTLBuffer
        let indexBuffer: MTLBuffer
    }

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let context: CIContext
    private let reduce: MTLComputePipelineState
    private let horizontal: MTLComputePipelineState
    private let vertical: MTLComputePipelineState
    private let composite: MTLComputePipelineState
    private let layoutLock = NSLock()
    private var lastLayout: Layout?

    init?(device: MTLDevice) {
        guard let queue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: Self.kernels, options: nil) else { return nil }
        func pipeline(_ name: String) -> MTLComputePipelineState? {
            guard let function = library.makeFunction(name: name) else { return nil }
            return try? device.makeComputePipelineState(function: function)
        }
        guard let reduce = pipeline("reduceRegion"), let horizontal = pipeline("horizontalBlur"),
              let vertical = pipeline("verticalBlur"), let composite = pipeline("compositeRegions") else { return nil }
        self.device = device
        self.queue = queue
        self.reduce = reduce
        self.horizontal = horizontal
        self.vertical = vertical
        self.composite = composite
        context = CIContext(mtlCommandQueue: queue, options: [
            .cacheIntermediates: false, .name: "MPCut Dense Blur",
            .workingColorSpace: StillImage.linear2020, .workingFormat: CIFormat.RGBAh
        ])
    }

    func apply(to original: CIImage, areas: [CGRect]) -> CIImage? {
        let extent = original.extent
        guard let layout = layout(for: extent, areas: areas) else { return nil }
        let width = Int(extent.width)
        let height = Int(extent.height)
        guard let source = texture(width: width, height: height),
              let atlas = texture(width: layout.atlasWidth, height: layout.atlasHeight),
              let temporary = texture(width: layout.atlasWidth, height: layout.atlasHeight),
              let command = queue.makeCommandBuffer() else { return nil }
        let localBounds = CGRect(origin: .zero, size: extent.size)
        let localImage = original.transformed(by: .init(translationX: -extent.minX, y: -extent.minY))
        context.render(localImage, to: source, commandBuffer: command, bounds: localBounds, colorSpace: StillImage.linear2020)

        func encodeRegions(_ pipeline: MTLComputePipelineState, from input: MTLTexture, to output: MTLTexture) -> Bool {
            guard let encoder = command.makeComputeCommandEncoder() else { return false }
            encoder.setComputePipelineState(pipeline)
            encoder.setTexture(input, index: 0)
            encoder.setTexture(output, index: 1)
            encoder.setBuffer(layout.regionBuffer, offset: 0, index: 0)
            encoder.setBuffer(layout.rowRegions, offset: 0, index: 1)
            encoder.setBuffer(layout.weightBuffer, offset: 0, index: 2)
            dispatch(encoder, pipeline, width: layout.atlasWidth, height: layout.atlasHeight)
            encoder.endEncoding()
            return true
        }
        guard encodeRegions(reduce, from: source, to: atlas),
              encodeRegions(horizontal, from: atlas, to: temporary),
              encodeRegions(vertical, from: temporary, to: atlas),
              let encoder = command.makeComputeCommandEncoder() else { return nil }
        // Reduction has already read the original pixels. Replace covered pixels in this
        // frame's private texture, which becomes the returned image after completion.
        encoder.setComputePipelineState(composite)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(atlas, index: 1)
        encoder.setBuffer(layout.regionBuffer, offset: 0, index: 0)
        encoder.setBuffer(layout.rangeBuffer, offset: 0, index: 1)
        encoder.setBuffer(layout.indexBuffer, offset: 0, index: 2)
        dispatch(encoder, composite, width: width, height: height)
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed,
              let picture = CIImage(mtlTexture: source, options: [.colorSpace: StillImage.linear2020]) else { return nil }
        return picture.transformed(by: .init(translationX: extent.minX, y: extent.minY))
    }

    private func layout(for extent: CGRect, areas: [CGRect]) -> Layout? {
        let cached = layoutLock.withLock { lastLayout }
        if let cached, cached.extent == extent, cached.areas == areas { return cached }
        guard let layout = makeLayout(extent: extent, areas: areas) else { return nil }
        // Layout buffers only describe geometry and are read-only in every command. The
        // ordered areas are part of the key because the last blur wins at an overlap.
        let buffers = [layout.regionBuffer, layout.rowRegions, layout.weightBuffer, layout.rangeBuffer, layout.indexBuffer]
        if buffers.reduce(0, { $0 + $1.length }) <= Self.cachedBufferBytes {
            layoutLock.withLock { lastLayout = layout }
        }
        return layout
    }

    private func makeLayout(extent: CGRect, areas: [CGRect]) -> Layout? {
        guard !areas.isEmpty, !extent.isEmpty, !extent.isInfinite, extent == extent.integral,
              extent.width <= 16384, extent.height <= 16384,
              areas.allSatisfy({ !$0.isEmpty && $0 == $0.integral && extent.contains($0) }) else { return nil }
        let width = Int(extent.width)
        let height = Int(extent.height)
        let columns = (width + Self.blockSize - 1) / Self.blockSize
        let rows = (height + Self.blockSize - 1) / Self.blockSize
        var ranges = [SIMD2<UInt32>](repeating: .zero, count: columns * rows)
        var regions: [Region] = []
        var weights: [Float] = []
        // Regions occupy disjoint rows. A row lookup lets each pass process the entire atlas at once.
        var rowRegions: [UInt32] = []
        var atlasWidth = 0
        var atlasHeight = 0

        func forEachBucket(_ source: SIMD4<UInt32>, _ visit: (Int) -> Void) {
            let x = Int(source.x)
            let y = Int(source.y)
            let w = Int(source.z)
            let h = Int(source.w)
            for row in (y / Self.blockSize)...((y + h - 1) / Self.blockSize) {
                for col in (x / Self.blockSize)...((x + w - 1) / Self.blockSize) {
                    visit(row * columns + col)
                }
            }
        }

        for area in areas {
            let x = Int(area.minX - extent.minX)
            // Core Image's texture render puts the bottom scanline at texture row zero.
            let y = Int(area.minY - extent.minY)
            let w = Int(area.width)
            let h = Int(area.height)
            let sigma = max(10, Double(max(w, h)) / 10)
            let step = Int(ceil(sigma / 4))
            // Keep a border texel made from the original edge, so the filter's repeated
            // samples use the edge pixel rather than the first or last interior average.
            let reducedWidth = (w + step - 1) / step + 2
            let reducedHeight = (h + step - 1) / step + 2
            let source = SIMD4(UInt32(x), UInt32(y), UInt32(w), UInt32(h))
            forEachBucket(source) { ranges[$0].y += 1 }
            regions.append(Region(source: source,
                                  atlas: .init(0, UInt32(atlasHeight), UInt32(reducedWidth), UInt32(reducedHeight)),
                                  step: UInt32(step)))
            atlasWidth = max(atlasWidth, reducedWidth)
            atlasHeight += reducedHeight
            guard atlasHeight <= 16384 else { return nil }
            rowRegions.append(contentsOf: repeatElement(UInt32(regions.count - 1), count: reducedHeight))

            // Compensate for the blur already introduced by box reduction and linear reconstruction.
            let stepSquared = Double(step * step)
            let variance = (sigma * sigma - (stepSquared - 1) / 12 - stepSquared / 6) / stepSquared
            let raw = (0..<Self.tapCount).map { exp(-Double($0 * $0) / (2 * variance)) }
            let sum = raw[0] + 2 * raw.dropFirst().reduce(0, +)
            weights.append(contentsOf: raw.map { Float($0 / sum) })
        }

        // Allocate the index table once. Count bucket membership, assign each bucket an
        // offset, then fill its indices in the same order as the input regions.
        var count: UInt32 = 0
        for bucket in ranges.indices {
            let size = ranges[bucket].y
            ranges[bucket] = .init(count, 0)
            count += size
        }
        var indices = [UInt32](repeating: 0, count: Int(count))
        for (index, region) in regions.enumerated() {
            forEachBucket(region.source) { bucket in
                let slot = ranges[bucket].x + ranges[bucket].y
                indices[Int(slot)] = UInt32(index)
                ranges[bucket].y += 1
            }
        }
        guard let regionBuffer = makeBuffer(regions), let rangeBuffer = makeBuffer(ranges),
              let indexBuffer = makeBuffer(indices), let rowBuffer = makeBuffer(rowRegions),
              let weightBuffer = makeBuffer(weights) else { return nil }
        return Layout(extent: extent, areas: areas, atlasWidth: atlasWidth, atlasHeight: atlasHeight,
                      regionBuffer: regionBuffer, rowRegions: rowBuffer, weightBuffer: weightBuffer,
                      rangeBuffer: rangeBuffer, indexBuffer: indexBuffer)
    }

    private func makeBuffer<T>(_ values: [T]) -> MTLBuffer? {
        values.withUnsafeBytes { bytes in
            guard let address = bytes.baseAddress, !bytes.isEmpty else { return nil }
            return device.makeBuffer(bytes: address, length: bytes.count, options: .storageModeShared)
        }
    }

    private func texture(width: Int, height: Int) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width, height: height,
                                                                 mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        descriptor.storageMode = .private
        return device.makeTexture(descriptor: descriptor)
    }

    private func dispatch(_ encoder: MTLComputeCommandEncoder, _ pipeline: MTLComputePipelineState,
                          width: Int, height: Int) {
        let lanes = pipeline.threadExecutionWidth
        encoder.dispatchThreads(.init(width: width, height: height, depth: 1),
                                threadsPerThreadgroup: .init(width: lanes, height: 4, depth: 1))
    }

    private static let kernels = """
    #include <metal_stdlib>
    using namespace metal;

    struct Region {
        uint4 source;
        uint4 atlas;
        uint step;
    };

    kernel void reduceRegion(texture2d<half, access::read> source [[texture(0)]],
                             texture2d<half, access::write> atlas [[texture(1)]],
                             device const Region *regions [[buffer(0)]], device const uint *rows [[buffer(1)]],
                             uint2 position [[thread_position_in_grid]]) {
        device const Region &region = regions[rows[position.y]];
        if (position.x >= region.atlas.z) return;
        uint2 p = position - region.atlas.xy;
        float4 sum = 0;
        int2 start = (int2(p) - 1) * int(region.step);
        int2 last = int2(region.source.zw) - 1;
        for (uint y = 0; y < region.step; ++y) {
            for (uint x = 0; x < region.step; ++x) {
                uint2 sample = uint2(clamp(start + int2(x, y), int2(0), last));
                sum += float4(source.read(region.source.xy + sample));
            }
        }
        atlas.write(half4(sum / float(region.step * region.step)), position);
    }

    template<bool horizontal>
    void blur(texture2d<half, access::read> input, texture2d<half, access::write> output,
              device const Region *regions, device const uint *rows, device const float *allWeights, uint2 position) {
        uint index = rows[position.y];
        device const Region &region = regions[index];
        if (position.x >= region.atlas.z) return;
        device const float *weights = allWeights + index * \(ParticipantMetalBlur.tapCount);
        uint2 p = position - region.atlas.xy;
        uint along = horizontal ? p.x : p.y;
        uint last = (horizontal ? region.atlas.z : region.atlas.w) - 1;
        uint2 direction = horizontal ? uint2(1, 0) : uint2(0, 1);
        float4 sum = float4(input.read(position)) * weights[0];
        for (uint i = 1; i < \(ParticipantMetalBlur.tapCount); ++i) {
            uint lower = min(i, along);
            uint upper = min(i, last - along);
            sum += weights[i] * (float4(input.read(position - direction * lower))
                               + float4(input.read(position + direction * upper)));
        }
        output.write(half4(sum), position);
    }

    kernel void horizontalBlur(texture2d<half, access::read> input [[texture(0)]],
                               texture2d<half, access::write> output [[texture(1)]],
                               device const Region *regions [[buffer(0)]], device const uint *rows [[buffer(1)]],
                               device const float *weights [[buffer(2)]],
                               uint2 p [[thread_position_in_grid]]) {
        blur<true>(input, output, regions, rows, weights, p);
    }

    kernel void verticalBlur(texture2d<half, access::read> input [[texture(0)]],
                             texture2d<half, access::write> output [[texture(1)]],
                             device const Region *regions [[buffer(0)]], device const uint *rows [[buffer(1)]],
                             device const float *weights [[buffer(2)]],
                             uint2 p [[thread_position_in_grid]]) {
        blur<false>(input, output, regions, rows, weights, p);
    }

    kernel void compositeRegions(texture2d<half, access::write> destination [[texture(0)]],
                                 texture2d<half, access::sample> atlas [[texture(1)]],
                                 device const Region *regions [[buffer(0)]], device const uint2 *ranges [[buffer(1)]],
                                 device const uint *indices [[buffer(2)]], uint2 p [[thread_position_in_grid]]) {
        constexpr sampler linear(coord::pixel, address::clamp_to_edge, filter::linear);
        constexpr uint blockSize = \(ParticipantMetalBlur.blockSize);
        uint cols = (destination.get_width() + blockSize - 1) / blockSize;
        uint2 bucket = ranges[(p.y / blockSize) * cols + p.x / blockSize];
        for (uint i = bucket.y; i > 0; --i) {
            device const Region &region = regions[indices[bucket.x + i - 1]];
            if (any(p < region.source.xy) || any(p >= region.source.xy + region.source.zw)) continue;
            float2 local = 1.f + (float2(p - region.source.xy) + 0.5f) / float(region.step);
            float2 location = clamp(local, 0.5f, float2(region.atlas.zw) - 0.5f) + float2(region.atlas.xy);
            destination.write(atlas.sample(linear, location), p);
            return;
        }
    }
    """
}
