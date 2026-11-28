//
//  StreamShaders.swift
//  dz
//
//  The one shader the renderer uses. It lives here so the self test can compile
//  and run the exact same source the window runs, rather than a copy that can
//  drift from it.
//

enum StreamShaders {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct VertexOut {
        float4 position [[position]];
        float2 uv;
    };

    // One triangle that covers the view; uv is derived from the clip position,
    // so there is no vertex buffer to keep in sync with the drawable.
    vertex VertexOut vertex_main(uint vid [[vertex_id]]) {
        float2 corners[3] = { float2(-1.0, -3.0), float2(-1.0, 1.0), float2(3.0, 1.0) };
        float2 p = corners[vid];
        VertexOut out;
        out.position = float4(p, 0.0, 1.0);
        out.uv = float2((p.x + 1.0) * 0.5, (1.0 - p.y) * 0.5);
        return out;
    }

    fragment float4 fragment_main(VertexOut in [[stage_in]],
                                  texture2d<float> tex [[texture(0)]]) {
        constexpr sampler s(coord::normalized, filter::linear, address::clamp_to_edge);
        return tex.sample(s, in.uv);
    }
    """
}
