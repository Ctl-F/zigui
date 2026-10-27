#version 450
// One vertex format for every primitive the UI draws (see sdl_gpu.zig).
//   a_pos_local: device-pixel position, then either the shape's center (flat
//                data for shapes) or the texture coordinates (for textured quads)
//   a_shape:     kind, paint mode, half width, half height
//   a_params:    corner radii / ring radius and width / segment end points
//   a_color, a_color2, a_grad: paint
layout(location = 0) in vec4 a_pos_local;
layout(location = 1) in vec4 a_shape;
layout(location = 2) in vec4 a_params;
layout(location = 3) in vec4 a_color;
layout(location = 4) in vec4 a_color2;
layout(location = 5) in vec4 a_grad;

layout(set = 1, binding = 0) uniform Frame {
    vec2 viewport; // target size in device pixels
} u;

layout(location = 0) out vec2 v_local;
layout(location = 1) flat out vec4 v_shape;
layout(location = 2) flat out vec4 v_params;
layout(location = 3) flat out vec4 v_color;
layout(location = 4) flat out vec4 v_color2;
layout(location = 5) flat out vec4 v_grad;

void main() {
    vec2 ndc = vec2(a_pos_local.x / u.viewport.x * 2.0 - 1.0, 1.0 - a_pos_local.y / u.viewport.y * 2.0);
    gl_Position = vec4(ndc, 0.0, 1.0);
    v_local = a_pos_local.zw;
    v_shape = a_shape;
    v_params = a_params;
    v_color = a_color;
    v_color2 = a_color2;
    v_grad = a_grad;
}
