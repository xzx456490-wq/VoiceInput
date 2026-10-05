// Metal adaptation of neeldedkawala/ios-siri-animation (MIT).
// Original copyright and license are distributed in Resources/THIRD_PARTY_LICENSE.
#include <metal_stdlib>
using namespace metal;
struct SiriUniforms { float4 values[64]; };
struct SiriVertex { float4 position [[position]]; float2 uv; };
constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge, filter::linear);
float siriSpine(float coord, float envelope, float seconds, float energy) {
    float drift = sin(seconds * 0.43 + coord * 1.75);
    float bend = cos(seconds * 0.21 - coord * 2.1);
    return envelope * ((0.010 + 0.022 * energy) * drift + 0.009 * energy * bend);
}
float siriLightHeight(float coord, float envelope, float amplitude, float phase, float seconds, float energy, float spatialScale) {
    float layerDrift = 0.25 * sin(seconds * 0.18 + phase * 0.63);
    return siriSpine(coord, envelope, seconds, energy)
        + sin(coord * spatialScale + seconds * 0.78 + phase + layerDrift) * amplitude * 0.72;
}

// Common sheet geometry: light, transmitted surface and side reflection use it.
float sheetEnvelope(float x) { return pow(max(1.0 - x*x, 0.0), 1.10); }
float sheetCenter(float x, float time, float energy) {
    float e = sheetEnvelope(x);
    return e * (0.024 * sin(time * 0.68) + 0.025 * sin(x * 2.4 + time * 0.47)
        + 0.036 * energy * sin(x * 2.8 - time * 0.91));
}
float sheetSpan(float x, float time, float energy) {
    float e = sheetEnvelope(x);
    float breath = 0.85 + 0.15 * sin(time * 0.83 + 0.9);
    return e * (0.055 + 0.120 * energy) * breath;
}
float3 sheetSpectrum(float angle) {
    float cycle = fract(angle / (2.0 * 3.14159265359)) * 5.0;
    int index = int(floor(cycle));
    float f = fract(cycle); f = f*f*(3.0-2.0*f);
    const float3 palette[6] = {float3(0.04,0.24,1.0), float3(0.04,0.88,1.0),
        float3(0.80,0.56,1.0),float3(1.0,0.77,0.23),float3(1.0,0.20,0.22),float3(0.04,0.24,1.0)};
    return mix(palette[index],palette[index+1],f);
}

vertex SiriVertex siriVertex(uint id [[vertex_id]]) {
 const float2 points[] = {float2(-1,-1),float2(3,-1),float2(-1,3)};
 SiriVertex out; out.position=float4(points[id],0,1); out.uv=(points[id]+1)*0.5; return out;
}
#define u_time (_u.values[0].x)
#define u_progress (_u.values[1].x)
#define u_waveFade (_u.values[2].x)
#define u_waveIntro (_u.values[3].x)
#define u_introStartAmp (_u.values[4].x)
#define u_resolution (_u.values[5].xy)
#define u_pixelRatio (_u.values[6].x)
#define u_bgScale (_u.values[7].xy)
#define u_bgOffset (_u.values[8].xy)
#define u_bgNextScale (_u.values[9].xy)
#define u_bgNextOffset (_u.values[10].xy)
#define u_bgCrossFade (_u.values[11].x)
#define u_scaleRatio (_u.values[12].x)
#define u_bezelWidth (_u.values[13].x)
#define u_glassThickness (_u.values[14].x)
#define u_ior (_u.values[15].x)
#define u_dispersionScale (_u.values[16].x)
#define u_surfaceCurvature (_u.values[17].x)
#define u_glassTint (_u.values[18].xyz)
#define u_absorption (_u.values[19].x)
#define u_showBackground (_u.values[20].x)
#define u_shapeParams (_u.values[21].xyzw)
#define u_topMorphUp (_u.values[22].x)
#define u_waveRefract (_u.values[23].x)
#define u_waveDispersion (_u.values[24].x)
#define u_waveEdgeBand (_u.values[25].x)
#define u_wavePower (_u.values[26].x)
#define u_bottomRimIntensity (_u.values[27].x)
#define u_bottomRimWidth (_u.values[28].x)
#define xScale (_u.values[29].x)
#define yScale (_u.values[30].x)
#define phaseDistance (_u.values[31].x)
#define lineThickness (_u.values[32].x)
#define pinTaper (_u.values[33].x)
#define spindleWidth (_u.values[34].x)
#define glowFalloff (_u.values[35].x)
#define glowIntensity (_u.values[36].x)
#define edgeFade (_u.values[37].x)
#define hotCoreThreshold (_u.values[38].x)
#define hotCoreIntensity (_u.values[39].x)
#define fillOpacity (_u.values[40].x)
#define activeWaves (int(_u.values[41].x))











            // Dual Texture Background Cross-Fade Uniforms








            // Snell's Law Liquid Glass Physical Optics Uniforms












            // Wave Edge Refraction Uniforms





            // Physical Bottom Edge Rim Highlight



            // Volumetric Spindle Wave Uniforms

















            #define PI 3.14159265359

            float sdPill(float2 p, float2 b, float r) {
                float2 d = abs(p) - b + float2(r);
                return min(max(d.x, d.y), 0.0) + length(max(d, 0.0)) - r;
            }

            float sdBulbousSquircle(float2 p, float2 dim, float topArch, float botArch) {
                float2 np = p / dim;

                float yWeight = smoothstep(-dim.y * 0.35, dim.y * 0.35, p.y);
                float archTop = 1.0 - (np.x * np.x) * 0.45 * topArch;
                float archBot = 1.0 - (np.x * np.x) * 0.70 * botArch;
                float arch = mix(archTop, archBot, yWeight);

                float2 scaledP = p;
                scaledP.y /= max(arch, 0.15);

                float px = abs(scaledP.x) / max(dim.x, 0.1);
                float py = abs(scaledP.y) / max(dim.y, 0.1);
                float exponent = 2.38;

                float dist = pow(pow(px, exponent) + pow(py, exponent), 1.0 / exponent) - 1.0;
                return dist * min(dim.x, dim.y);
            }

            float getIslandSDF(constant SiriUniforms &_u, float2 p, float prog) {
                float2 pillDim = float2(40.0, 11.5);
                float pillRad = 11.5;
                float d1 = sdPill(p, pillDim, pillRad);

                float2 expDim = u_shapeParams.xy;
                float topArch = u_shapeParams.z;
                float botArch = u_shapeParams.w;
                float d2 = sdBulbousSquircle(p, expDim, topArch, botArch);

                return mix(d1, d2, prog);
            }

            float2 calcNormal2D(constant SiriUniforms &_u, float2 p, float prog) {
                float h = 0.50;
                float2 k = float2(1.0, -1.0);
                return normalize(
                    k.xy * getIslandSDF(_u, p + k.xy * h, prog) +
                    k.yy * getIslandSDF(_u, p + k.yy * h, prog) +
                    k.yx * getIslandSDF(_u, p + k.yx * h, prog) +
                    k.xx * getIslandSDF(_u, p + k.xx * h, prog)
                );
            }

            float computeSnellDisplacement(float d, float bWidth, float thickness, float nMedium, float curveExp, thread float &outH) {
                if (d >= bWidth || d <= 0.0) {
                    outH = (d <= 0.0) ? 0.0 : thickness;
                    return 0.0;
                }

                float u = clamp(d / max(bWidth, 1.0), 0.0, 1.0);
                float innerArc = clamp(1.0 - pow(1.0 - u, curveExp), 0.0, 1.0);
                outH = thickness * sqrt(innerArc);

                float denom = max(sqrt(innerArc), 0.05);
                float dh_dd = (thickness / max(bWidth, 1.0)) * (pow(1.0 - u, max(curveExp - 1.0, 0.0)) / denom);

                float theta1 = atan(dh_dd);
                float sinTheta2 = sin(theta1) / max(nMedium, 1.001);
                sinTheta2 = clamp(sinTheta2, -0.999, 0.999);
                float theta2 = asin(sinTheta2);

                float thetaDev = theta1 - theta2;
                return outH * tan(thetaDev);
            }

            float3 sampleRefractedBackground(texture2d<float> tex, float2 scale, float2 offset, float2 uvR, float2 uvG, float2 uvB) {
                float2 fUvR = uvR * scale + offset;
                float2 fUvG = uvG * scale + offset;
                float2 fUvB = uvB * scale + offset;
                return float3(tex.sample(linearSampler, fUvR).r, tex.sample(linearSampler, fUvG).g, tex.sample(linearSampler, fUvB).b);
            }

            fragment float4 siriFragment(SiriVertex in [[stage_in]], constant SiriUniforms &_u [[buffer(0)]], texture2d<float> u_bgTexture [[texture(0)]], texture2d<float> u_bgTextureNext [[texture(1)]]) {
 float2 vUv = in.uv;
                float2 uv = float2(vUv.x, 1.0 - vUv.y) * u_resolution;
                float cx = u_resolution.x * 0.5;
                float cy = u_resolution.y * 0.43;
                float2 p = uv - float2(cx, cy);

                float yShiftDown = mix(0.0, (u_shapeParams.y - 11.5) - u_topMorphUp, u_progress);
                // Desktop glass expands around its center; the phone island anchor is omitted.

                float dIsland = getIslandSDF(_u, p, u_progress);

                float afwidth = length(float2(dfdx(dIsland), dfdy(dIsland))) * 0.7071;
                float edgeIsland = smoothstep(afwidth, -afwidth, dIsland);

                float2 norm2D = calcNormal2D(_u, p, u_progress);
                float distFromBorder = max(0.0, -dIsland);

                float glassH = 0.0;
                float nBase = u_ior;
                float dispFactor = u_dispersionScale * 0.15;
                float nR = nBase - dispFactor * 0.04;
                float nG = nBase;
                float nB = nBase + dispFactor * 0.07;

                float dispMagR = computeSnellDisplacement(distFromBorder, u_bezelWidth, u_glassThickness, nR, u_surfaceCurvature, glassH);
                float dispMagG = computeSnellDisplacement(distFromBorder, u_bezelWidth, u_glassThickness, nG, u_surfaceCurvature, glassH);
                float dispMagB = computeSnellDisplacement(distFromBorder, u_bezelWidth, u_glassThickness, nB, u_surfaceCurvature, glassH);

                float scaleMul = u_scaleRatio * u_progress;
                float2 uvR = vUv + float2(-norm2D.x * dispMagR * scaleMul / u_resolution.x, norm2D.y * dispMagR * scaleMul / u_resolution.y);
                float2 uvG = vUv + float2(-norm2D.x * dispMagG * scaleMul / u_resolution.x, norm2D.y * dispMagG * scaleMul / u_resolution.y);
                float2 uvB = vUv + float2(-norm2D.x * dispMagB * scaleMul / u_resolution.x, norm2D.y * dispMagB * scaleMul / u_resolution.y);

                float3 bgCurrent = sampleRefractedBackground(u_bgTexture, u_bgScale, u_bgOffset, uvR, uvG, uvB);
                float3 bgNext = sampleRefractedBackground(u_bgTextureNext, u_bgNextScale, u_bgNextOffset, uvR, uvG, uvB);
                float3 refractedBg = mix(bgCurrent, bgNext, u_bgCrossFade);

                float opticalDepth = (glassH / max(u_glassThickness, 1.0)) * u_absorption;
                float3 transmission = exp(-opticalDepth * (float3(1.0) - u_glassTint));
                refractedBg *= transmission;

                float currentH = mix(11.5, u_shapeParams.y, u_progress);
                float bodyWidth = mix(40.0, u_shapeParams.x, u_progress);
                float bodyX = clamp(p.x / max(bodyWidth, 1.0), -1.0, 1.0);
                float lensBow = 0.13 * currentH * bodyX * bodyX;
                float yRatio = clamp((p.y + currentH * 0.15 - lensBow) / (currentH * 1.02), 0.0, 1.0);
                float glassTranslucency = smoothstep(0.08, 0.88, yRatio) * (0.84 + 0.16 * sqrt(max(0.0, 1.0 - bodyX * bodyX))) * u_progress;

                float3 glassBody = mix(float3(0.0), refractedBg * u_showBackground, glassTranslucency);

                float3 accumulatedWave = float3(0.0);
                float energy = clamp(_u.values[48].x, 0.0, 1.0);
                float seconds = -u_time / 2.7;
                float currentW = mix(40.0, u_shapeParams.x, u_progress);
                float lightX = p.x / max(currentW, 1.0);
                float lightY = (p.y + 0.5 * u_progress) / max(currentW, 1.0);
                float envelope = sheetEnvelope(lightX);
                float spine = sheetCenter(lightX, seconds, energy);
                float span = sheetSpan(lightX, seconds, energy) * _u.values[50].x;

                if (u_waveFade > 0.001) {
                    float3 sheets = float3(0.0);
                    float3 sheetScatter = float3(0.0);
                    float density = 0.0;
                    float lowSheet = 10.0, highSheet = -10.0;
                    for (int i = 0; i < 4; i++) {
                        float phase = float(i) * 1.65;
                        // Sheets cross and roll: all end gently on the same curved surface.
                        float roll = sin(seconds * 0.91 + phase + lightX * 1.8);
                        float layerY = spine + span * roll;
                        lowSheet = min(lowSheet, layerY); highSheet = max(highSheet, layerY);
                        float layerWidth = envelope * mix(0.021, 0.044, energy) * _u.values[50].x
                            * (0.75 + 0.25 * cos(seconds * 0.76 + phase));
                        float d = lightY - layerY;
                        float inside = exp(-0.5 * pow(d / max(layerWidth, 0.0008), 2.0));
                        float taper = pow(envelope, 0.40) * (1.0 - smoothstep(0.65, 0.96, abs(lightX)));
                        float3 tint = sheetSpectrum(phase + lightX * 1.25 + seconds * 0.49);
                        float w = inside * taper;
                        sheets += tint * w;
                        density += w;
                        float scatter = exp(-0.5 * pow(d / max(layerWidth*2.6, 0.002),2.0));
                        sheetScatter += tint * scatter * taper * 0.036;
                    }
                    // Connect overlapping layers into a translucent membrane, not separated neon wires.
                    float softEdge = max(envelope * 0.014, 0.001);
                    float membrane = smoothstep(lowSheet-softEdge, lowSheet+softEdge, lightY)
                        * (1.0-smoothstep(highSheet-softEdge,highSheet+softEdge,lightY))
                        * pow(envelope,0.40) * (1.0-smoothstep(0.65,0.96,abs(lightX)));
                    float vertical = clamp((lightY-lowSheet)/max(highSheet-lowSheet,0.002),0.0,1.0);
                    sheets += sheetSpectrum(seconds*0.49 + lightX*1.25 + vertical*4.6) * membrane * 0.52;
                    density += membrane * 0.52;
                    float3 spectral = sheets / max(density, 0.001);
                    float3 light = spectral * (1.0-exp(-density*0.88)) * 1.40;
                    // Shared curved fold creates the white overlap; no ruler-straight beam.
                    float foldY = spine + span * 0.18 * sin(seconds*0.91 + lightX*1.8);
                    float foldWidth = envelope * mix(0.012, 0.026, energy) * _u.values[50].x;
                    float fold = exp(-0.5*pow((lightY-foldY)/max(foldWidth,0.0008),2.0));
                    float overlap = smoothstep(0.25, 1.4, density);
                    light += float3(1.0,0.98,0.92) * fold * overlap * mix(0.32,0.75,energy) * envelope;
                    light += sheetScatter * _u.values[49].x;

                    // Map the same incident sheet onto the local rim; concentrate in normal direction.
                    float2 border = p + norm2D * distFromBorder;
                    float probeX = clamp((border.x - norm2D.x*4.0)/currentW,-0.99,0.99);
                    float probeCenter = sheetCenter(probeX,seconds,energy);
                    float probeSpan = sheetSpan(probeX,seconds,energy) * _u.values[50].x;
                    float borderY = (border.y+0.5*u_progress)/currentW;
                    float3 reflected = float3(0.0);
                    for (int i=0;i<4;i++) {
                        float phase = float(i)*1.65;
                        float incidentY = probeCenter + probeSpan * sin(seconds*0.91+phase+probeX*1.8);
                        float along = (borderY-incidentY)/mix(0.052,0.068,energy);
                        float3 tint = sheetSpectrum(phase+probeX*1.25+seconds*0.49);
                        reflected += tint * exp(-0.5*along*along);
                    }
                    float normalBand = exp(-0.5*pow(distFromBorder/1.15,2.0));
                    float side = pow(abs(norm2D.x),3.0)*smoothstep(0.60,0.90,abs(lightX));
                    float grazing = pow(1.0-clamp(glassH/max(u_glassThickness,1.0),0.0,1.0),0.65);
                    light += reflected * normalBand * side * grazing * 0.13 * _u.values[49].x;
                    light = light / (1.0 + light*0.12);
                    accumulatedWave = light * u_waveFade * u_waveIntro * glowIntensity;

                    // The transmitted boundary follows the fold rather than a horizontal split.
                    float foldInPoints = (spine + 0.25*span) * currentW;
                    float transmissionY = (p.y - foldInPoints + currentH*0.03) / max(currentH,1.0);
                    float bodyTransmission = smoothstep(-0.11,0.83,transmissionY) * u_progress;
                    float3 tintWash = sheetSpectrum(seconds*0.49 + lightX*1.25) * 0.012
                        * exp(-0.5*pow((lightY-spine)/0.25,2.0)) * _u.values[49].x;
                    glassBody = refractedBg * u_showBackground * bodyTransmission * 0.84 + tintWash*u_waveFade;
                }

                // Apple Physical Glass Bottom Edge White Meniscus Sheen
                float bottomFactor = clamp((p.y + currentH * 0.25) / (currentH * 1.25), 0.0, 1.0);
                float rimGlow = smoothstep(max(u_bottomRimWidth, 0.1), 0.0, distFromBorder) * bottomFactor * u_progress;
                float rimAngle = atan2(norm2D.y, norm2D.x);
                float reflectionTravel = 0.76 + 0.24 * cos(rimAngle * 1.4 + u_time * 0.31);
                float3 bottomRimHighlight = mix(float3(0.96, 0.98, 1.0), sheetSpectrum(seconds * 0.49 + lightX * 1.25), 0.06) * (rimGlow * u_bottomRimIntensity * reflectionTravel * 0.78);
                float lowerFacing = pow(max(norm2D.y, 0.0), 2.0);
                float lowerBounce = exp(-distFromBorder / 9.0) * lowerFacing * u_progress * u_waveFade;
                float bounceTint = 0.5 + 0.5 * sin(u_time * 0.43 + p.x / max(bodyWidth, 1.0));
                float3 bounceColor = sheetSpectrum(seconds * 0.49 + lightX * 1.25);
                bottomRimHighlight += bounceColor * lowerBounce * mix(0.014, 0.035, _u.values[48].x) * _u.values[49].x;

                float3 finalRGB = glassBody + accumulatedWave + bottomRimHighlight;
                return float4(clamp(finalRGB, 0.0, 1.0), edgeIsland * _u.values[51].x);
            }
