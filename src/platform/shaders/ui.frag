#version 450
// Shapes are signed distance fields evaluated at pixel centers, like the
// software rasterizer, so both draw the same edges.
//   kind 0 plain rect (exact area coverage)   1 rounded box   2 border ring
//        3 line segment   4 glyph (R8 atlas)   5 image (RGBA)   6 image (R8 mask)
//   mode 0 solid   1 linear gradient   2 radial gradient
layout(set = 2, binding = 0) uniform sampler2D u_tex;

layout(location = 0) in vec2 v_local;
layout(location = 1) flat in vec4 v_shape;
layout(location = 2) flat in vec4 v_params;
layout(location = 3) flat in vec4 v_color;
layout(location = 4) flat in vec4 v_color2;
layout(location = 5) flat in vec4 v_grad;

layout(location = 0) out vec4 out_color;

float edgeCoverage(float d) {
    return clamp(0.5 - d, 0.0, 1.0);
}

// Radii order: top-left, top-right, bottom-right, bottom-left (y grows down).
float sdRoundBox(vec2 p, vec2 h, vec4 radii) {
    float r0 = p.x < 0.0 ? (p.y < 0.0 ? radii.x : radii.w) : (p.y < 0.0 ? radii.y : radii.z);
    float r = min(max(r0, 0.0), min(h.x, h.y));
    vec2 d = abs(p) - h + r;
    return length(max(d, vec2(0.0))) + min(max(d.x, d.y), 0.0) - r;
}

vec4 paintAt(vec2 p) {
    int mode = int(v_shape.y + 0.5);
    if (mode == 0) return v_color;
    vec2 a = v_grad.xy;
    if (mode == 1) {
        vec2 d = v_grad.zw - a;
        float len2 = dot(d, d);
        float t = len2 > 0.0 ? clamp(dot(p - a, d) / len2, 0.0, 1.0) : 0.0;
        return mix(v_color, v_color2, t);
    }
    float radius = length(v_grad.zw - a);
    float t = radius > 0.0 ? clamp(length(p - a) / radius, 0.0, 1.0) : 0.0;
    return mix(v_color, v_color2, t);
}

void main() {
    int kind = int(v_shape.x + 0.5);
    vec2 p = gl_FragCoord.xy;
    float cov = 1.0;
    vec4 col = v_color;

    if (kind == 0) {
        vec2 q = p - v_local;
        vec2 h = v_shape.zw;
        float cx = clamp(min(q.x + 0.5, h.x) - max(q.x - 0.5, -h.x), 0.0, 1.0);
        float cy = clamp(min(q.y + 0.5, h.y) - max(q.y - 0.5, -h.y), 0.0, 1.0);
        cov = cx * cy;
        col = paintAt(p);
    } else if (kind == 1) {
        cov = edgeCoverage(sdRoundBox(p - v_local, v_shape.zw, v_params));
        col = paintAt(p);
    } else if (kind == 2) {
        float d = sdRoundBox(p - v_local, v_shape.zw, vec4(v_params.x));
        cov = max(edgeCoverage(d) - edgeCoverage(d + v_params.y), 0.0);
        col = paintAt(p);
    } else if (kind == 3) {
        vec2 a = v_params.xy;
        vec2 ab = v_params.zw - a;
        vec2 ap = p - a;
        float len2 = dot(ab, ab);
        float t = len2 > 0.0 ? clamp(dot(ap, ab) / len2, 0.0, 1.0) : 0.0;
        cov = edgeCoverage(length(ap - ab * t) - v_shape.z);
        col = paintAt(p);
    } else if (kind == 4) {
        cov = texture(u_tex, v_local).r;
    } else if (kind == 5) {
        col = texture(u_tex, v_local) * v_color;
    } else {
        cov = texture(u_tex, v_local).r;
    }
    out_color = vec4(col.rgb, col.a * cov);
}
