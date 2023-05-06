const fragment_shader_path = "generic.frag.spv";
const vertex_shader_path = "generic.vert.spv";

pub const fragment_spv align(4) = @embedFile(fragment_shader_path);
pub const vertex_spv align(4) = @embedFile(vertex_shader_path);

const color_fragment_shader_path = "color.frag.spv";
const color_vertex_shader_path = "color.vert.spv";

pub const color_fragment_spv align(4) = @embedFile(color_fragment_shader_path);
pub const color_vertex_spv align(4) = @embedFile(color_vertex_shader_path);

const icon_fragment_shader_path = "icon.frag.spv";
const icon_vertex_shader_path = "icon.vert.spv";

pub const icon_fragment_spv align(4) = @embedFile(icon_fragment_shader_path);
pub const icon_vertex_spv align(4) = @embedFile(icon_vertex_shader_path);

const texture_fragment_shader_path = "texture.frag.spv";
const texture_vertex_shader_path = "texture.vert.spv";

pub const texture_fragment_spv align(4) = @embedFile(texture_fragment_shader_path);
pub const texture_vertex_spv align(4) = @embedFile(texture_vertex_shader_path);