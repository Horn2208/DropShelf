#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

/// Genie-Verformung: Inhalt wird zum Ziel (`target`, in Punkten) hin gestaucht und an der Zielseite schmal gezogen,
/// die ferne Seite bleibt breit – geschwungene Kanten über `smoothstep`. `progress` 0 = normal, 1 = eingesaugt.
[[ stitchable ]] float2 liquidGenie(float2 pos, float2 size, float2 target, float progress) {
    float p = clamp(progress, -0.1, 1.0);  // leichtes Überschwingen der Feder erlaubt
    float far = max(max(target.y, size.y - target.y), 1.0);
    float srcY = target.y + (pos.y - target.y) / (1.0 - 0.45 * p);
    float d = clamp(abs(srcY - target.y) / far, 0.0, 1.0);
    float w = max(1.0 - 0.8 * p * (1.0 - smoothstep(0.0, 1.0, d)), 0.05);
    return float2(target.x + (pos.x - target.x) / w, srcY);
}

/// Chromatische Aberration: Rot nach außen, Blau nach innen versetzt (radial vom Ziel), `amount` in Punkten.
[[ stitchable ]] half4 liquidAberration(float2 pos, SwiftUI::Layer layer, float2 target, float amount) {
    float2 dir = pos - target;
    float len = length(dir);
    float2 o = (len > 0.001 ? dir / len : float2(0.0)) * amount;
    half4 c = layer.sample(pos), r = layer.sample(pos + o), b = layer.sample(pos - o);
    return half4(r.r, c.g, b.b, max(c.a, max(r.a, b.a)));
}
