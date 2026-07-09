#if canImport(Metal)
import CoreGraphics
import Metal
import SleapIO
import simd

/// Approximate GPU-accelerated fast path for large instance counts.
///
/// This renderer draws nodes (instanced quads shaded into filled circles) and
/// CPU-expanded edge quads into an offscreen texture. Unlike ``PoseRenderer``,
/// it currently colors strictly by instance index (ignoring `colorBy`,
/// track, and node coloring), always draws circular markers (ignoring
/// `markerShape`), does not distinguish complete and incomplete points, draws
/// edges aliased, and draws all edges beneath all nodes.
/// Falls back via `init?() == nil` when no compatible Metal device is
/// available.
public struct MetalPoseRenderer {
    public var options: RenderOptions

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let nodePipelineState: MTLRenderPipelineState
    private let edgePipelineState: MTLRenderPipelineState

    public init?(options: RenderOptions = .defaults) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            return nil
        }
        #if os(macOS)
        guard device.hasUnifiedMemory else { return nil }
        #endif

        do {
            let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
            guard let edgeVertex = library.makeFunction(name: "edgeVertex"),
                  let nodeVertex = library.makeFunction(name: "nodeVertex"),
                  let colorFragment = library.makeFunction(name: "colorFragment"),
                  let circleFragment = library.makeFunction(name: "circleFragment") else {
                return nil
            }

            let edgeDescriptor = MTLRenderPipelineDescriptor()
            edgeDescriptor.vertexFunction = edgeVertex
            edgeDescriptor.fragmentFunction = colorFragment
            edgeDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            Self.configureBlending(edgeDescriptor)

            let nodeDescriptor = MTLRenderPipelineDescriptor()
            nodeDescriptor.vertexFunction = nodeVertex
            nodeDescriptor.fragmentFunction = circleFragment
            nodeDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            Self.configureBlending(nodeDescriptor)

            self.nodePipelineState = try device.makeRenderPipelineState(descriptor: nodeDescriptor)
            self.edgePipelineState = try device.makeRenderPipelineState(descriptor: edgeDescriptor)
        } catch {
            return nil
        }

        self.options = options
        self.device = device
        self.commandQueue = commandQueue
    }

    /// Render instances to a new CGImage of the given pixel size.
    /// Background is transparent; composite over your own base image if needed.
    /// Returns nil if command encoding or readback fails.
    /// This blocks until GPU work completes; construct the renderer once and
    /// reuse it, and do not call this on the main actor for every frame.
    public func render(
        instances: [Instance],
        skeleton: Skeleton,
        width: Int,
        height: Int
    ) -> CGImage? {
        guard width > 0, height > 0 else { return nil }

        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        textureDescriptor.usage = [.renderTarget, .shaderRead]
        textureDescriptor.storageMode = .shared

        guard let texture = device.makeTexture(descriptor: textureDescriptor),
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            return nil
        }

        let renderPass = MTLRenderPassDescriptor()
        renderPass.colorAttachments[0].texture = texture
        renderPass.colorAttachments[0].loadAction = .clear
        renderPass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        renderPass.colorAttachments[0].storeAction = .store

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPass) else {
            return nil
        }

        var viewport = SIMD2<Float>(Float(width), Float(height))

        if options.showEdges {
            let edgeVertices = makeEdgeVertices(instances: instances, skeleton: skeleton)
            if !edgeVertices.isEmpty,
               let edgeBuffer = makeBuffer(edgeVertices) {
                encoder.setRenderPipelineState(edgePipelineState)
                encoder.setVertexBuffer(edgeBuffer, offset: 0, index: 0)
                encoder.setVertexBytes(&viewport, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: edgeVertices.count)
            }
        }

        if options.showNodes {
            let nodeInstances = makeNodeInstances(instances: instances)
            if !nodeInstances.isEmpty,
               let nodeBuffer = makeBuffer(nodeInstances) {
                encoder.setRenderPipelineState(nodePipelineState)
                encoder.setVertexBuffer(nodeBuffer, offset: 0, index: 0)
                encoder.setVertexBytes(&viewport, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: nodeInstances.count)
            }
        }

        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        guard commandBuffer.status == .completed else { return nil }
        return makeImage(from: texture, width: width, height: height)
    }

    private func makeBuffer<T>(_ values: [T]) -> MTLBuffer? {
        values.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return nil }
            return device.makeBuffer(
                bytes: baseAddress,
                length: rawBuffer.count,
                options: .storageModeShared
            )
        }
    }

    private func makeEdgeVertices(instances: [Instance], skeleton: Skeleton) -> [EdgeVertex] {
        var vertices: [EdgeVertex] = []
        vertices.reserveCapacity(instances.count * skeleton.edges.count * 6)

        for (instanceIndex, instance) in instances.enumerated() {
            let color = Self.instanceColor(
                at: instanceIndex,
                instance: instance,
                palette: options.palette,
                predictionOpacity: options.predictionOpacity
            )
            let points = instance.points

            for edge in skeleton.edges {
                guard let srcIndex = skeleton.index(of: edge.source),
                      let dstIndex = skeleton.index(of: edge.destination),
                      srcIndex < points.count,
                      dstIndex < points.count else {
                    continue
                }

                let src = points[srcIndex]
                let dst = points[dstIndex]
                guard src.visible, dst.visible,
                      !src.x.isNaN, !src.y.isNaN,
                      !dst.x.isNaN, !dst.y.isNaN else {
                    continue
                }

                let p0 = SIMD2<Float>(src.x, src.y)
                let p1 = SIMD2<Float>(dst.x, dst.y)
                let dir = p1 - p0
                let length = simd_length(dir)
                guard length >= 1e-6 else { continue }

                let d = dir / length
                let n = SIMD2<Float>(-d.y, d.x)
                let h = Float(options.edgeWidth) / 2
                let a = p0 + n * h
                let b = p0 - n * h
                let c = p1 + n * h
                let e = p1 - n * h

                vertices.append(EdgeVertex(position: a, color: color))
                vertices.append(EdgeVertex(position: b, color: color))
                vertices.append(EdgeVertex(position: c, color: color))
                vertices.append(EdgeVertex(position: c, color: color))
                vertices.append(EdgeVertex(position: b, color: color))
                vertices.append(EdgeVertex(position: e, color: color))
            }
        }

        return vertices
    }

    private func makeNodeInstances(instances: [Instance]) -> [NodeInstance] {
        var nodeInstances: [NodeInstance] = []
        let radius = Float(options.nodeRadius)

        for (instanceIndex, instance) in instances.enumerated() {
            let color = Self.instanceColor(
                at: instanceIndex,
                instance: instance,
                palette: options.palette,
                predictionOpacity: options.predictionOpacity
            )
            let points = instance.points

            for index in 0..<points.count {
                let point = points[index]
                guard point.visible, !point.x.isNaN, !point.y.isNaN else { continue }
                nodeInstances.append(
                    NodeInstance(
                        center: SIMD2(point.x, point.y),
                        radius: radius,
                        padding: 0,
                        color: color
                    )
                )
            }
        }

        return nodeInstances
    }

    private static func configureBlending(_ descriptor: MTLRenderPipelineDescriptor) {
        guard let attachment = descriptor.colorAttachments[0] else { return }
        attachment.isBlendingEnabled = true
        attachment.rgbBlendOperation = .add
        attachment.alphaBlendOperation = .add
        attachment.sourceRGBBlendFactor = .sourceAlpha
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
    }

    private static func rgbaColor(at index: Int, palette: String) -> SIMD4<Float> {
        rgba(ColorPalette.color(at: index, palette: palette))
    }

    private static func instanceColor(
        at index: Int,
        instance: Instance,
        palette: String,
        predictionOpacity: CGFloat
    ) -> SIMD4<Float> {
        var color = rgbaColor(at: index, palette: palette)
        if instance is PredictedInstance {
            color.w *= Float(predictionOpacity)
        }
        return color
    }

    private static func rgba(_ color: CGColor) -> SIMD4<Float> {
        let converted = color.converted(
            to: CGColorSpaceCreateDeviceRGB(),
            intent: .defaultIntent,
            options: nil
        ) ?? color
        let components = converted.components ?? []

        switch components.count {
        case 2:
            let gray = Float(components[0])
            return SIMD4(gray, gray, gray, Float(components[1]))
        case 4...:
            return SIMD4(
                Float(components[0]),
                Float(components[1]),
                Float(components[2]),
                Float(components[3])
            )
        default:
            return SIMD4(0, 0, 0, 1)
        }
    }

    private func makeImage(from texture: MTLTexture, width: Int, height: Int) -> CGImage? {
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)

        texture.getBytes(
            &bytes,
            bytesPerRow: bytesPerRow,
            from: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0
        )

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue

        return bytes.withUnsafeMutableBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress,
                  let context = CGContext(
                    data: baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: colorSpace,
                    bitmapInfo: bitmapInfo
                  ) else {
                return nil
            }
            return context.makeImage()
        }
    }

    private struct EdgeVertex {
        var position: SIMD2<Float>
        var color: SIMD4<Float>
    }

    private struct NodeInstance {
        var center: SIMD2<Float>
        var radius: Float
        var padding: Float
        var color: SIMD4<Float>
    }

    static var edgeVertexStride: Int {
        MemoryLayout<EdgeVertex>.stride
    }

    static var edgeVertexColorOffset: Int {
        MemoryLayout<EdgeVertex>.offset(of: \.color) ?? -1
    }

    static var nodeInstanceStride: Int {
        MemoryLayout<NodeInstance>.stride
    }

    static var nodeInstanceColorOffset: Int {
        MemoryLayout<NodeInstance>.offset(of: \.color) ?? -1
    }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct EdgeVertexIn {
        float2 position;
        float4 color;
    };

    struct NodeInstanceIn {
        float2 center;
        float radius;
        float padding;
        float4 color;
    };

    struct VertexOut {
        float4 position [[position]];
        float4 color;
        float2 uv;
    };

    static float2 pixelToNDC(float2 pixel, float2 viewport) {
        return float2(pixel.x / viewport.x * 2.0 - 1.0,
                      1.0 - pixel.y / viewport.y * 2.0);
    }

    vertex VertexOut edgeVertex(
        const device EdgeVertexIn *vertices [[buffer(0)]],
        constant float2 &viewport [[buffer(1)]],
        uint vertexID [[vertex_id]]
    ) {
        EdgeVertexIn vertexIn = vertices[vertexID];
        VertexOut out;
        out.position = float4(pixelToNDC(vertexIn.position, viewport), 0.0, 1.0);
        out.color = vertexIn.color;
        out.uv = float2(0.0);
        return out;
    }

    vertex VertexOut nodeVertex(
        const device NodeInstanceIn *instances [[buffer(0)]],
        constant float2 &viewport [[buffer(1)]],
        uint vertexID [[vertex_id]],
        uint instanceID [[instance_id]]
    ) {
        constexpr float2 corners[6] = {
            float2(-1.0, -1.0), float2( 1.0, -1.0), float2(-1.0,  1.0),
            float2( 1.0, -1.0), float2( 1.0,  1.0), float2(-1.0,  1.0)
        };

        NodeInstanceIn instance = instances[instanceID];
        float2 corner = corners[vertexID];
        float2 pixel = instance.center + corner * instance.radius;

        VertexOut out;
        out.position = float4(pixelToNDC(pixel, viewport), 0.0, 1.0);
        out.color = instance.color;
        out.uv = corner;
        return out;
    }

    fragment float4 colorFragment(VertexOut in [[stage_in]]) {
        return in.color;
    }

    fragment float4 circleFragment(VertexOut in [[stage_in]]) {
        float d = length(in.uv);
        float aa = fwidth(d);
        float alpha = 1.0 - smoothstep(1.0 - aa, 1.0, d);
        if (alpha <= 0.0) { discard_fragment(); }
        return float4(in.color.rgb, in.color.a * alpha);
    }
    """
}
#endif
