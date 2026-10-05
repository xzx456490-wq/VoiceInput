import AppKit
import CoreImage

// Public Metal/Core Image optics. Background rays pass through a curved
// glass surface; foreground labels are composed separately by AppKit.
final class CapsuleRefraction {
    static let shared = CapsuleRefraction()
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let warp: CIWarpKernel?
    private let glass: CIKernel?

    init() {
        let source = """
        #include <CoreImage/CoreImage.h>
        using namespace metal;

        float2 glassRay(float2 p, float2 center, float halfSegment, float radius, float amount) {
            float2 relative = p - center;
            float2 radial = relative - float2(clamp(relative.x, -halfSegment, halfSegment), 0.0);
            float distance = length(radial);
            if (distance > radius || distance < 0.001 || amount < 0.001) { return p; }
            float t = min(0.9997, distance / radius);
            float z = sqrt(max(0.0006, 1.0 - t * t));
            float3 normal = float3(radial / radius, z);
            // Air-to-glass Snell refraction. A finite distance to the backdrop
            // makes the near-tangent rays at the edge visibly stretch content.
            float3 ray = refract(float3(0.0, 0.0, -1.0), normal, 1.0 / 1.46);
            float depth = radius * (z + 0.82);
            float2 offset = ray.xy * depth / max(0.20, -ray.z);
            // Do not return to identity at the rim: that erased edge lensing.
            // The approved thick-glass profile concentrates refraction at the
            // curved rim while keeping the center substantially undistorted.
            return p + offset * (amount / 20.0) * pow(t, 2.4);
        }

        [[stitchable]] float2 capsuleLens(float2 center, float halfSegment, float radius,
                                         float amount, coreimage::destination dest) {
            return glassRay(dest.coord(), center, halfSegment, radius, amount);
        }

        [[stitchable]] float4 capsuleBody(coreimage::sampler background, float2 center,
            float halfSegment, float radius, float amount, float concentration,
            float tone, float feather, coreimage::destination dest) {
            float2 p = dest.coord();
            float2 relative = p - center;
            float2 radial = relative - float2(clamp(relative.x, -halfSegment, halfSegment), 0.0);
            float distance = length(radial);
            float coverage = 1.0 - smoothstep(radius - feather, radius + feather, distance);
            if (coverage <= 0.0) { return float4(0.0); }
            // Clamp AA samples onto the physical surface, without an outline.
            float2 surface = center + relative;
            if (distance > radius) { surface -= radial * ((distance - radius) / max(distance, 0.001)); }
            float2 samplePosition = glassRay(surface, center, halfSegment, radius, amount);
            float4 color = background.sample(background.transform(samplePosition));
            // Match the approved transparent-center prototype. The curved body
            // is quiet; localized light comes from the actual text and waveform
            // above this surface rather than a permanent broad white wash.
            float t = min(0.9997, distance / radius);
            float z = sqrt(max(0.0006, 1.0 - t * t));
            float ny = -radial.y / radius;
            float centerClearance = 1.0 - t * t;
            float body = (0.11 + 0.027 * z - 0.013 * max(0.0, ny))
                * (1.0 - 0.42 * centerClearance) * (0.65 + concentration * 1.842105);
            float transmission = clamp((0.46 + 0.24 * centerClearance)
                * (1.0 - (concentration - 0.19) * 0.30), 0.0, 1.0);
            float3 perceived = coreimage::linear_to_srgb(color.rgb);
            perceived = tone < 0.5 ? clamp(float3(body) + perceived * transmission, 0.0, 1.0)
                : mix(float3(1.0 - body), perceived, transmission);
            float3 transmitted = coreimage::srgb_to_linear(perceived);
            return float4(transmitted * coverage, coverage);
        }
        """
        let kernels = (try? CIKernel.kernels(withMetalString: source)) ?? []
        warp = kernels.first(where: { $0.name == "capsuleLens" }) as? CIWarpKernel
        glass = kernels.first(where: { $0.name == "capsuleBody" })
    }

    private func input(background: CGImage, rect: CGRect, scale: CGFloat) -> CIImage {
        CIImage(cgImage: background)
            .transformed(by: CGAffineTransform(scaleX: rect.width * scale / CGFloat(background.width),
                                               y: rect.height * scale / CGFloat(background.height)))
            .transformed(by: CGAffineTransform(translationX: rect.minX * scale, y: rect.minY * scale))
            .clampedToExtent()
    }

    private func parameters(bounds: CGRect, capsule: CGRect, scale: CGFloat, amount: CGFloat)
        -> (extent: CGRect, scale: CGFloat, radius: CGFloat, amount: CGFloat, arguments: [Any])? {
        guard scale.isFinite, scale > 0, bounds.width > 0, bounds.height > 0,
              capsule.width > 0, capsule.height > 0 else { return nil }
        let s = min(3, scale), radius = capsule.height * s / 2
        let strength = min(32, max(0, amount.isFinite ? amount : 0))
        return (CGRect(x: bounds.minX * s, y: bounds.minY * s, width: bounds.width * s, height: bounds.height * s),
                s, radius, strength,
                [CIVector(x: capsule.midX * s, y: capsule.midY * s), max(0, capsule.width * s / 2 - radius), radius, strength])
    }

    func render(background: CGImage, backgroundRect: CGRect, bounds: CGRect,
                capsule: CGRect, scale: CGFloat, amount: CGFloat = 14) -> CGImage? {
        guard let warp, backgroundRect.width > 0, backgroundRect.height > 0,
              let p = parameters(bounds: bounds, capsule: capsule, scale: scale, amount: amount) else { return nil }
        let padding = p.radius * 2 + 4
        guard let output = warp.apply(extent: p.extent,
            roiCallback: { _, rect in rect.insetBy(dx: -padding, dy: -padding) },
            image: input(background: background, rect: backgroundRect, scale: p.scale), arguments: p.arguments) else { return nil }
        return context.createCGImage(output, from: p.extent)
    }

    func renderGlass(background: CGImage, backgroundRect: CGRect, bounds: CGRect,
                     capsule: CGRect, scale: CGFloat, amount: CGFloat,
                     concentration: Double, dark: Bool, softened: Bool) -> CGImage? {
        guard let glass, backgroundRect.width > 0, backgroundRect.height > 0,
              let p = parameters(bounds: bounds, capsule: capsule, scale: scale, amount: amount) else { return nil }
        var image = input(background: background, rect: backgroundRect, scale: p.scale)
        if softened { image = image.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 1.8 * p.scale]) }
        let density = concentration.isFinite ? min(1, max(0, concentration)) : 0.18
        let padding = p.radius * 2 + 8
        guard let output = glass.apply(extent: p.extent,
            roiCallback: { _, rect in rect.insetBy(dx: -padding, dy: -padding) },
            arguments: [image] + p.arguments + [density, dark ? 0.08 : 0.94, 0.65 * p.scale]) else { return nil }
        return context.createCGImage(output, from: p.extent)
    }
}
