const std = @import("std");
const mach = @import("mach");
const gpu = mach.gpu;
const ImGui = @import("cimgui.zig");

// Binding structs
const Buffer = struct {
    ptr: ?*gpu.Buffer = null,
    size: u64 = 0,
    cpu_staging: std.ArrayList(u8) = .empty,
};
const ViewportInfos = struct {
    enabled: bool = false,
    texture: ?*gpu.Texture = null,
    view: ?*gpu.TextureView = null,
    bind_group: ?*gpu.BindGroup = null,
    size: [2]u32 = .{ 0, 0 },
    desired_size: [2]u32 = .{ 1920, 1080 },
    hovered: bool = false,
    bounds_min: mach.math.Vec2 = mach.math.vec2(0.0, 0.0),
    bounds_max: mach.math.Vec2 = mach.math.vec2(0.0, 0.0),
};
const FontInfos = struct {
    has_font_tex: bool = false,
    bind_group: *gpu.BindGroup = undefined,
    texture: *gpu.Texture = undefined,
    view: *gpu.TextureView = undefined,
};
const ImGuiImpl = struct {
    vertex_buf: Buffer = .{},
    index_buf: Buffer = .{},
    sampler: *gpu.Sampler = undefined,
    pipeline: *gpu.RenderPipeline = undefined,
    bgl1: *gpu.BindGroupLayout = undefined,
    uniform_buffer: *gpu.Buffer = undefined,
    common_bind_group: *gpu.BindGroup = undefined,
    font_infos: FontInfos = .{},
};

pub const ImGuiModule = @This();

pub const mach_module = .imgui;
pub const mach_systems = .{
    .init,
    .startTick,
    .endTick,
    .deinit,
};
const VIEWPORT_TEX_ID: ImGui.ImTextureID = 0xFFFF_FFFF_FFFF_FFFE;
var imgui_mutex: std.Io.Mutex = .init;
var window_id: ?mach.ObjectID = null;

allocator: std.mem.Allocator,
initialized: bool = false,
in_frame: bool = false,
want_capture_mouse: bool = false,
want_capture_keyboard: bool = false,
want_text_input: bool = false,
last_time: ?std.Io.Timestamp = null,
viewport: ViewportInfos = .{},
imgui_impl: ImGuiImpl = .{},

pub fn init(
    self: *ImGuiModule,
    allocator: std.mem.Allocator,
) !void {
    self.* = .{
        .allocator = allocator,
    };
    const ctx = ImGui.igCreateContext(null) orelse return error.ContextFailed;
    ImGui.igSetCurrentContext(ctx);
    const io = ImGui.igGetIO_Nil().?;
    io.*.ConfigFlags |= ImGui.ImGuiConfigFlags_DockingEnable;
    io.*.ConfigFlags &= ~ImGui.ImGuiConfigFlags_ViewportsEnable;
    io.*.BackendFlags |= ImGui.ImGuiBackendFlags_RendererHasTextures;
    ImGui.igStyleColorsDark(null);
}

pub fn deinit(self: *ImGuiModule) void {
    if (self.initialized) {
        if (self.imgui_impl.vertex_buf.ptr) |vb| vb.release();
        if (self.imgui_impl.index_buf.ptr) |ib| ib.release();

        if (self.imgui_impl.font_infos.has_font_tex) {
            self.imgui_impl.font_infos.bind_group.release();
            self.imgui_impl.font_infos.view.release();
            self.imgui_impl.font_infos.texture.release();
        }

        self.imgui_impl.common_bind_group.release();
        self.imgui_impl.uniform_buffer.release();
        self.imgui_impl.sampler.release();
        self.imgui_impl.bgl1.release();
        self.imgui_impl.pipeline.release();

        if (self.viewport.bind_group) |bg| bg.release();
        if (self.viewport.view) |v| v.release();
        if (self.viewport.texture) |t| t.release();

        self.imgui_impl.vertex_buf.cpu_staging.deinit(self.allocator);
        self.imgui_impl.index_buf.cpu_staging.deinit(self.allocator);
    }
    ImGui.igDestroyContext(null);
}

pub fn processEvent(
    self: *ImGuiModule,
    event: *const mach.Core.Event,
    main_io: std.Io,
) !void {
    if (!self.initialized) return;
    try imgui_mutex.lock(main_io);
    defer imgui_mutex.unlock(main_io);

    const io = ImGui.igGetIO_Nil().?;
    switch (event.*) {
        .mouse_motion => |ev| {
            const mx: f32 = @floatCast(ev.pos.x);
            const my: f32 = @floatCast(ev.pos.y);
            if (!std.math.isNan(mx) and !std.math.isNan(my)) {
                ImGui.ImGuiIO_AddMousePosEvent(io, mx, my);
            }
        },
        .mouse_press => |ev| {
            const button_index: c_int = switch (ev.button) {
                .left => 0,
                .right => 1,
                .middle => 2,
                else => return,
            };
            ImGui.ImGuiIO_AddMouseButtonEvent(io, button_index, true);
        },
        .mouse_release => |ev| {
            const button_index: c_int = switch (ev.button) {
                .left => 0,
                .right => 1,
                .middle => 2,
                else => return,
            };
            ImGui.ImGuiIO_AddMouseButtonEvent(io, button_index, false);
        },
        .mouse_scroll => |ev| {
            ImGui.ImGuiIO_AddMouseWheelEvent(io, @floatCast(ev.xoffset), @floatCast(ev.yoffset));
        },
        .key_press => |ev| {
            sendKeyWithMods(io, ev.key, true);
        },
        .key_release => |ev| {
            sendKeyWithMods(io, ev.key, false);
        },
        .char_input => |ev| {
            ImGui.ImGuiIO_AddInputCharacter(io, ev.codepoint);
        },
        .focus_gained => {
            ImGui.ImGuiIO_AddFocusEvent(io, true);
        },
        .focus_lost => {
            ImGui.ImGuiIO_AddFocusEvent(io, false);
        },
        else => {},
    }
}

pub fn startTick(
    self: *ImGuiModule,
    main_io: std.Io,
    core: *mach.Core,
) !void {
    if (!self.initialized or self.in_frame) return;
    try imgui_mutex.lock(main_io);
    defer imgui_mutex.unlock(main_io);

    const window = core.windows.getValue(window_id.?);
    if (window.width == 0 or window.height == 0) return;
    self.ensureViewportTexture(window.device, window.swap_chain_descriptor.format);

    const now = std.Io.Clock.awake.now(main_io);
    const dt: f32 = if (self.last_time) |last| blk: {
        const elapsed = last.durationTo(now);
        const seconds = @as(f32, @floatFromInt(elapsed.toNanoseconds())) / std.time.ns_per_s;
        break :blk @max(0.0001, seconds);
    } else 1.0 / 60.0;
    self.last_time = now;

    const win_w: f32 = @floatFromInt(window.width);
    const win_h: f32 = @floatFromInt(window.height);
    const fb_w: f32 = @floatFromInt(window.framebuffer_width);
    const fb_h: f32 = @floatFromInt(window.framebuffer_height);
    const io = ImGui.igGetIO_Nil().?;
    io.*.DeltaTime = dt;
    io.*.DisplaySize = .{ .x = win_w, .y = win_h };
    io.*.DisplayFramebufferScale = .{
        .x = if (win_w > 0) fb_w / win_w else 1.0,
        .y = if (win_h > 0) fb_h / win_h else 1.0,
    };

    ImGui.igNewFrame();
    self.in_frame = true;
    if (self.viewport.enabled) {
        const viewport = ImGui.igGetMainViewport();
        _ = ImGui.igDockSpaceOverViewport(
            0,
            viewport,
            ImGui.ImGuiDockNodeFlags_None,
            null,
        );
    }
}

pub fn endTick(
    self: *ImGuiModule,
    io: std.Io,
) !void {
    if (!self.initialized or !self.in_frame) return;
    try imgui_mutex.lock(io);
    defer imgui_mutex.unlock(io);

    if (self.viewport.enabled) {
        self.drawViewportWindow();
    }
    ImGui.igRender();

    const imgui_io = ImGui.igGetIO_Nil().?;
    self.want_capture_mouse = imgui_io.*.WantCaptureMouse;
    self.want_capture_keyboard = imgui_io.*.WantCaptureKeyboard;
    self.want_text_input = imgui_io.*.WantTextInput;
    self.in_frame = false;
}

pub fn screenToViewport(
    self: *const ImGuiModule,
    screen_pos: mach.math.Vec2,
) ?mach.math.Vec2 {
    if (!self.viewport.enabled) return screen_pos;

    const view_dim = mach.math.vec4(
        screen_pos.x() - self.viewport.bounds_min.x(),
        screen_pos.y() - self.viewport.bounds_min.y(),
        self.viewport.bounds_max.x() - self.viewport.bounds_min.x(),
        self.viewport.bounds_max.y() - self.viewport.bounds_min.y(),
    );

    if (view_dim.z() <= 0.0 or view_dim.w() <= 0.0 or
        view_dim.x() < 0.0 or view_dim.y() < 0.0 or
        view_dim.x() > view_dim.z() or
        view_dim.y() > view_dim.w())
    {
        return null;
    }

    const local = mach.math.vec2(view_dim.x(), view_dim.y());
    const view_size = mach.math.vec2(
        self.viewport.bounds_max.x() - self.viewport.bounds_min.x(),
        self.viewport.bounds_max.y() - self.viewport.bounds_min.y(),
    );
    const centered = mach.math.vec2(
        local.x() - (view_size.x() * 0.5),
        (view_size.y() * 0.5) - local.y(),
    );
    return centered;
}

pub fn addImguiRenderPass(
    self: *ImGuiModule,
    core: *mach.Core,
    encoder: *gpu.CommandEncoder,
    back_buffer_view: *gpu.TextureView,
    io: std.Io,
) !void {
    try imgui_mutex.lock(io);
    defer imgui_mutex.unlock(io);

    const window = core.windows.getValue(window_id.?);
    if (!self.initialized) {
        self.initGpuResources(window.device, window.swap_chain_descriptor.format);
        return;
    }

    const draw_data = ImGui.igGetDrawData();
    if (draw_data == null or draw_data.*.CmdLists.Size == 0) return;
    const fb_width = draw_data.*.DisplaySize.x * draw_data.*.FramebufferScale.x;
    const fb_height = draw_data.*.DisplaySize.y * draw_data.*.FramebufferScale.y;
    if (fb_width <= 0 or fb_height <= 0) return;

    if (draw_data.*.Textures) |textures_vec| {
        const textures = textures_vec.*.Data[0..@intCast(textures_vec.*.Size)];
        for (textures) |tex| {
            if (tex.*.Status == ImGui.ImTextureStatus_WantCreate or
                tex.*.Status == ImGui.ImTextureStatus_WantUpdates)
            {
                const tex_w: u32 = @intCast(tex.*.Width);
                const tex_h: u32 = @intCast(tex.*.Height);
                if (tex.*.Status == ImGui.ImTextureStatus_WantCreate) {
                    if (self.imgui_impl.font_infos.has_font_tex) {
                        self.imgui_impl.font_infos.bind_group.release();
                        self.imgui_impl.font_infos.view.release();
                        self.imgui_impl.font_infos.texture.release();
                    }

                    const gpu_tex = window.device.createTexture(&.{
                        .label = "imgui_dynamic_tex",
                        .usage = .{
                            .texture_binding = true,
                            .copy_dst = true,
                        },
                        .dimension = .dimension_2d,
                        .size = .{
                            .width = tex_w,
                            .height = tex_h,
                            .depth_or_array_layers = 1,
                        },
                        .format = .rgba8_unorm,
                        .mip_level_count = 1,
                        .sample_count = 1,
                    });
                    const view = gpu_tex.createView(null);
                    const bg = window.device.createBindGroup(&.{
                        .layout = self.imgui_impl.bgl1,
                        .entry_count = 1,
                        .entries = &[_]gpu.BindGroup.Entry{
                            .{
                                .binding = 0,
                                .texture_view = view,
                                .size = 0,
                            },
                        },
                    });

                    self.imgui_impl.font_infos.texture = gpu_tex;
                    self.imgui_impl.font_infos.view = view;
                    self.imgui_impl.font_infos.bind_group = bg;
                    self.imgui_impl.font_infos.has_font_tex = true;
                    ImGui.ImTextureData_SetTexID(tex, @intFromPtr(bg));
                }

                const pixels: [*]const u8 = @ptrCast(ImGui.ImTextureData_GetPixels(tex));
                const data_len = @as(usize, tex_w) * @as(usize, tex_h) * 4;
                window.queue.writeTexture(
                    &.{ .texture = self.imgui_impl.font_infos.texture },
                    &.{
                        .bytes_per_row = tex_w * 4,
                        .rows_per_image = tex_h,
                    },
                    &.{
                        .width = tex_w,
                        .height = tex_h,
                        .depth_or_array_layers = 1,
                    },
                    pixels[0..data_len],
                );
                ImGui.ImTextureData_SetStatus(tex, ImGui.ImTextureStatus_OK);
            }
        }
    }

    if (!self.imgui_impl.font_infos.has_font_tex) return;

    const L = draw_data.*.DisplayPos.x;
    const R = draw_data.*.DisplayPos.x + draw_data.*.DisplaySize.x;
    const T = draw_data.*.DisplayPos.y;
    const B = draw_data.*.DisplayPos.y + draw_data.*.DisplaySize.y;
    const mvp = [16]f32{
        2.0 / (R - L),     0.0,               0.0, 0.0,
        0.0,               2.0 / (T - B),     0.0, 0.0,
        0.0,               0.0,               0.5, 0.0,
        (R + L) / (L - R), (T + B) / (B - T), 0.5, 1.0,
    };
    window.queue.writeBuffer(self.imgui_impl.uniform_buffer, 0, std.mem.asBytes(&mvp));

    const max_padding_bytes: u64 = @as(u64, @intCast(draw_data.*.CmdLists.Size)) * 4;
    const total_vtx_size: u64 = @as(u64, @intCast(draw_data.*.TotalVtxCount)) * @sizeOf(ImGui.ImDrawVert);
    const total_idx_size: u64 = @as(u64, @intCast(draw_data.*.TotalIdxCount)) * @sizeOf(ImGui.ImDrawIdx) + max_padding_bytes;
    if (total_vtx_size == 0 or total_idx_size == 0) return;

    const aligned_vtx_size = std.mem.alignForward(u64, total_vtx_size, 256);
    const aligned_idx_size = std.mem.alignForward(u64, total_idx_size, 256);

    if (self.imgui_impl.vertex_buf.ptr == null or self.imgui_impl.vertex_buf.size < aligned_vtx_size) {
        if (self.imgui_impl.vertex_buf.ptr) |vb| vb.release();
        self.imgui_impl.vertex_buf.size = aligned_vtx_size + 4096;
        self.imgui_impl.vertex_buf.ptr = window.device.createBuffer(&.{
            .label = "imgui_vtx_buf",
            .usage = .{ .vertex = true, .copy_dst = true },
            .size = self.imgui_impl.vertex_buf.size,
        });
    }
    if (self.imgui_impl.index_buf.ptr == null or self.imgui_impl.index_buf.size < aligned_idx_size) {
        if (self.imgui_impl.index_buf.ptr) |ib| ib.release();
        self.imgui_impl.index_buf.size = aligned_idx_size + 4096;
        self.imgui_impl.index_buf.ptr = window.device.createBuffer(&.{
            .label = "imgui_idx_buf",
            .usage = .{ .index = true, .copy_dst = true },
            .size = self.imgui_impl.index_buf.size,
        });
    }

    self.imgui_impl.vertex_buf.cpu_staging.clearRetainingCapacity();
    self.imgui_impl.index_buf.cpu_staging.clearRetainingCapacity();

    const cmd_lists = draw_data.*.CmdLists.Data[0..@intCast(draw_data.*.CmdLists.Size)];
    for (cmd_lists) |cmd_list| {
        const vtx_count: usize = @intCast(cmd_list.*.VtxBuffer.Size);
        const idx_count: usize = @intCast(cmd_list.*.IdxBuffer.Size);
        if (vtx_count > 0) {
            const vtx_bytes = vtx_count * @sizeOf(ImGui.ImDrawVert);
            const raw_vtx_ptr: [*]const u8 = @ptrCast(cmd_list.*.VtxBuffer.Data);
            try self.imgui_impl.vertex_buf.cpu_staging.appendSlice(self.allocator, raw_vtx_ptr[0..vtx_bytes]);
        }
        if (idx_count > 0) {
            const raw_idx_bytes = idx_count * @sizeOf(ImGui.ImDrawIdx);
            const raw_idx_ptr: [*]const u8 = @ptrCast(cmd_list.*.IdxBuffer.Data);
            try self.imgui_impl.index_buf.cpu_staging.appendSlice(self.allocator, raw_idx_ptr[0..raw_idx_bytes]);
            const aligned_idx_bytes = std.mem.alignForward(usize, raw_idx_bytes, 4);
            const padding = aligned_idx_bytes - raw_idx_bytes;
            if (padding > 0) {
                try self.imgui_impl.index_buf.cpu_staging.appendNTimes(self.allocator, 0, padding);
            }
        }
    }

    if (self.imgui_impl.vertex_buf.cpu_staging.items.len > 0) {
        window.queue.writeBuffer(
            self.imgui_impl.vertex_buf.ptr.?,
            0,
            self.imgui_impl.vertex_buf.cpu_staging.items,
        );
    }
    if (self.imgui_impl.index_buf.cpu_staging.items.len > 0) {
        window.queue.writeBuffer(
            self.imgui_impl.index_buf.ptr.?,
            0,
            self.imgui_impl.index_buf.cpu_staging.items,
        );
    }

    const color_attachments = [_]gpu.RenderPassColorAttachment{.{
        .view = back_buffer_view,
        .clear_value = .{ .r = 0.01, .g = 0.01, .b = 0.01, .a = 1.0 },
        .load_op = if (self.viewport.enabled) .clear else .load,
        .store_op = .store,
    }};
    const pass = encoder.beginRenderPass(&gpu.RenderPassDescriptor.init(.{
        .label = "imgui_shared_pass",
        .color_attachments = &color_attachments,
    }));

    pass.setViewport(
        0,
        0,
        fb_width,
        fb_height,
        0.0,
        1.0,
    );
    pass.setPipeline(self.imgui_impl.pipeline);
    pass.setBindGroup(0, self.imgui_impl.common_bind_group, null);
    pass.setBindGroup(1, self.imgui_impl.font_infos.bind_group, null);
    pass.setVertexBuffer(0, self.imgui_impl.vertex_buf.ptr.?, 0, self.imgui_impl.vertex_buf.size);
    const idx_format: gpu.IndexFormat = if (@sizeOf(ImGui.ImDrawIdx) == 2) .uint16 else .uint32;
    pass.setIndexBuffer(self.imgui_impl.index_buf.ptr.?, idx_format, 0, self.imgui_impl.index_buf.size);
    var global_vtx_offset: i32 = 0;
    var global_idx_offset: u32 = 0;
    const clip_off = draw_data.*.DisplayPos;
    const clip_scale = draw_data.*.FramebufferScale;

    for (cmd_lists) |cmd_list| {
        const cmds = cmd_list.*.CmdBuffer.Data[0..@intCast(cmd_list.*.CmdBuffer.Size)];
        for (cmds) |cmd| {
            if (cmd.UserCallback) |cb| {
                cb(cmd_list, &cmd);
                continue;
            }

            const tex_id = ImGui.ImDrawCmd_GetTexID(@constCast(&cmd));
            if (tex_id == VIEWPORT_TEX_ID) {
                if (self.viewport.bind_group) |vp_bg| {
                    pass.setBindGroup(1, vp_bg, null);
                } else {
                    continue;
                }
            } else if (tex_id != 0) {
                const target_bg: *gpu.BindGroup = @ptrFromInt(tex_id);
                pass.setBindGroup(1, target_bg, null);
            } else {
                pass.setBindGroup(1, self.imgui_impl.font_infos.bind_group, null);
            }

            const clip_min_x = @max(0.0, (cmd.ClipRect.x - clip_off.x) * clip_scale.x);
            const clip_min_y = @max(0.0, (cmd.ClipRect.y - clip_off.y) * clip_scale.y);
            const clip_max_x = @min(fb_width, (cmd.ClipRect.z - clip_off.x) * clip_scale.x);
            const clip_max_y = @min(fb_height, (cmd.ClipRect.w - clip_off.y) * clip_scale.y);
            if (clip_max_x <= clip_min_x or clip_max_y <= clip_min_y) continue;

            pass.setScissorRect(
                @intFromFloat(clip_min_x),
                @intFromFloat(clip_min_y),
                @intFromFloat(clip_max_x - clip_min_x),
                @intFromFloat(clip_max_y - clip_min_y),
            );
            pass.drawIndexed(
                cmd.ElemCount,
                1,
                cmd.IdxOffset + global_idx_offset,
                @as(i32, @intCast(cmd.VtxOffset)) + global_vtx_offset,
                0,
            );
        }

        const raw_idx_count: u32 = @intCast(cmd_list.*.IdxBuffer.Size);
        const aligned_idx_count: u32 = if (@sizeOf(ImGui.ImDrawIdx) == 2) std.mem.alignForward(u32, raw_idx_count, 2) else raw_idx_count;
        global_idx_offset += aligned_idx_count;
        global_vtx_offset += cmd_list.*.VtxBuffer.Size;
    }
    pass.end();
    pass.release();
}

fn ensureViewportTexture(
    self: *ImGuiModule,
    device: *gpu.Device,
    format: gpu.Texture.Format,
) void {
    if (!self.initialized) return;

    const w = self.viewport.desired_size[0];
    const h = self.viewport.desired_size[1];
    if (w == 0 or h == 0) return;

    if (self.viewport.texture != null and
        self.viewport.size[0] == w and
        self.viewport.size[1] == h)
    {
        return;
    }

    if (self.viewport.bind_group) |bg| bg.release();
    if (self.viewport.view) |v| v.release();
    if (self.viewport.texture) |t| t.release();

    const tex = device.createTexture(&.{
        .label = "editor_viewport_tex",
        .usage = .{
            .render_attachment = true,
            .texture_binding = true,
        },
        .dimension = .dimension_2d,
        .size = .{
            .width = w,
            .height = h,
            .depth_or_array_layers = 1,
        },
        .format = format,
        .mip_level_count = 1,
        .sample_count = 1,
    });
    const view = tex.createView(null);
    const bg = device.createBindGroup(&.{
        .layout = self.imgui_impl.bgl1,
        .entry_count = 1,
        .entries = &[_]gpu.BindGroup.Entry{
            .{
                .binding = 0,
                .texture_view = view,
                .size = 0,
            },
        },
    });

    self.viewport.texture = tex;
    self.viewport.view = view;
    self.viewport.bind_group = bg;
    self.viewport.size = .{ w, h };
}

pub fn setWindowId(id: mach.ObjectID) void {
    window_id = id;
}

pub fn isFrameOpened(self: *ImGuiModule) bool {
    return self.initialized and self.in_frame;
}

pub fn capturesMouse(self: *const ImGuiModule) bool {
    return self.initialized and self.want_capture_mouse;
}

pub fn capturesKeyboard(self: *const ImGuiModule) bool {
    return self.initialized and self.want_capture_keyboard;
}

pub fn wantsTextInput(self: *const ImGuiModule) bool {
    return self.initialized and self.want_text_input;
}

pub fn addFrontFromFile(
    self: *ImGuiModule,
    path: [:0]const u8,
    size_pixels: f32,
) ?*ImGui.ImFont {
    _ = self;
    const io = ImGui.igGetIO_Nil();
    if (io.*.Fonts.*.Fonts.Size == 0) {
        _ = ImGui.ImFontAtlas_AddFontDefault(io.*.Fonts, null);
    }
    return ImGui.ImFontAtlas_AddFontFromFileTTF(
        io.*.Fonts,
        path.ptr,
        size_pixels,
        null,
        null,
    );
}

pub fn addFontFromMemory(
    self: *ImGuiModule,
    font_data: []const u8,
    size_pixels: f32,
) ?*ImGui.ImFont {
    _ = self;
    const io = ImGui.igGetIO_Nil();
    if (io.*.Fonts.*.Fonts.Size == 0) {
        _ = ImGui.ImFontAtlas_AddFontDefault(io.*.Fonts, null);
    }
    const config = ImGui.ImFontConfig_ImFontConfig();
    config.*.FontDataOwnedByAtlas = false;
    return ImGui.ImFontAtlas_AddFontFromMemoryTTF(
        io.*.Fonts,
        @ptrCast(@constCast(font_data.ptr)),
        @intCast(font_data.len),
        size_pixels,
        config,
        null,
    );
}

pub fn mergeIconsFromFile(
    self: *ImGuiModule,
    path: [:0]const u8,
    size_pixels: f32,
    glyph_ranges: ?[*]const ImGui.ImWchar,
) ?*ImGui.Font {
    _ = self;
    const io = ImGui.igGetIO_Nil();
    if (io.*.Fonts.*.Fonts.Size == 0) {
        _ = ImGui.ImFontAtlas_AddFontDefault(io.*.Fonts, null);
    }
    const config = ImGui.ImFontConfig_ImFontConfig();
    config.*.MergeMode = true;
    config.*.PixelSnapH = true;
    config.*.GlyphMinAdvanceX = size_pixels;

    return ImGui.ImFontAtlas_AddFontFromFileTTF(
        io.*.Fonts,
        path.ptr,
        size_pixels,
        config,
        glyph_ranges,
    );
}

pub fn mergeIconsFromMemory(
    self: *ImGuiModule,
    font_data: []const u8,
    size_pixels: f32,
    glyph_ranges: ?[*]const ImGui.ImWchar,
) ?*ImGui.ImFont {
    _ = self;
    const io = ImGui.igGetIO_Nil();
    if (io.*.Fonts.*.Fonts.Size == 0) {
        _ = ImGui.ImFontAtlas_AddFontDefault(io.*.Fonts, null);
    }

    const config = ImGui.ImFontConfig_ImFontConfig();
    config.*.MergeMode = true;
    config.*.PixelSnapH = true;
    config.*.FontDataOwnedByAtlas = false;
    config.*.GlyphMinAdvanceX = size_pixels;

    return ImGui.ImFontAtlas_AddFontFromMemoryTTF(
        io.*.Fonts,
        @ptrCast(@constCast(font_data.ptr)),
        @intCast(font_data.len),
        size_pixels,
        config,
        glyph_ranges,
    );
}

pub fn setDefaultFont(self: *ImGuiModule, font: *ImGui.ImFont) void {
    _ = self;
    const io = ImGui.igGetIO_Nil();
    io.*.FontDefault = font;
}

fn initGpuResources(
    self: *ImGuiModule,
    device: *gpu.Device,
    target_format: gpu.Texture.Format,
) void {
    const shader_module = device.createShaderModuleWGSL("imgui_native_shader", @embedFile("imgui_shader.wgsl"));
    defer shader_module.release();
    const io = ImGui.igGetIO_Nil().?;
    io.*.BackendFlags |= ImGui.ImGuiBackendFlags_RendererHasTextures;
    const sampler = device.createSampler(&.{
        .mag_filter = .linear,
        .min_filter = .linear,
        .mipmap_filter = .linear,
        .address_mode_u = .clamp_to_edge,
        .address_mode_v = .clamp_to_edge,
        .address_mode_w = .clamp_to_edge,
    });
    const uniform_buffer = device.createBuffer(&.{
        .label = "imgui_uniform_buf",
        .usage = .{ .uniform = true, .copy_dst = true },
        .size = 256,
    });

    const bgl0_entries = [_]gpu.BindGroupLayout.Entry{
        .{
            .binding = 0,
            .visibility = .{ .vertex = true },
            .buffer = .{ .type = .uniform },
        },
        .{
            .binding = 1,
            .visibility = .{ .fragment = true },
            .sampler = .{ .type = .filtering },
        },
    };
    const bgl0 = device.createBindGroupLayout(&.{
        .entry_count = bgl0_entries.len,
        .entries = &bgl0_entries,
    });
    defer bgl0.release();

    const bgl1_entries = [_]gpu.BindGroupLayout.Entry{
        .{
            .binding = 0,
            .visibility = .{ .fragment = true },
            .texture = .{
                .sample_type = .float,
                .view_dimension = .dimension_2d,
            },
        },
    };
    const bgl1 = device.createBindGroupLayout(&.{
        .entry_count = bgl1_entries.len,
        .entries = &bgl1_entries,
    });

    const pipeline_layout = device.createPipelineLayout(&.{
        .bind_group_layout_count = 2,
        .bind_group_layouts = &[_]*gpu.BindGroupLayout{ bgl0, bgl1 },
    });
    defer pipeline_layout.release();

    const common_bind_group = device.createBindGroup(&.{
        .layout = bgl0,
        .entry_count = 2,
        .entries = &[_]gpu.BindGroup.Entry{
            .{
                .binding = 0,
                .buffer = uniform_buffer,
                .offset = 0,
                .size = 256,
            },
            .{
                .binding = 1,
                .sampler = sampler,
                .size = 0,
            },
        },
    });

    const vertex_attributes = [_]gpu.VertexAttribute{
        .{
            .format = .float32x2,
            .offset = 0,
            .shader_location = 0,
        },
        .{
            .format = .float32x2,
            .offset = 8,
            .shader_location = 1,
        },
        .{
            .format = .unorm8x4,
            .offset = 16,
            .shader_location = 2,
        },
    };
    const vertex_buffer_layout = gpu.VertexBufferLayout{
        .array_stride = @sizeOf(ImGui.ImDrawVert),
        .step_mode = .vertex,
        .attribute_count = vertex_attributes.len,
        .attributes = &vertex_attributes,
    };

    const blend_state = gpu.BlendState{
        .color = .{
            .operation = .add,
            .src_factor = .src_alpha,
            .dst_factor = .one_minus_src_alpha,
        },
        .alpha = .{
            .operation = .add,
            .src_factor = .one,
            .dst_factor = .one_minus_src_alpha,
        },
    };
    const color_target = gpu.ColorTargetState{
        .format = target_format,
        .blend = &blend_state,
        .write_mask = gpu.ColorWriteMaskFlags.all,
    };

    self.imgui_impl.pipeline = device.createRenderPipeline(&.{
        .label = "imgui_native_pipeline",
        .layout = pipeline_layout,
        .vertex = .{
            .module = shader_module,
            .entry_point = "vs_main",
            .buffer_count = 1,
            .buffers = &[_]gpu.VertexBufferLayout{
                vertex_buffer_layout,
            },
        },
        .primitive = .{
            .topology = .triangle_list,
            .front_face = .ccw,
            .cull_mode = .none,
        },
        .multisample = .{ .count = 1, .mask = 0xFFFFFFFF },
        .fragment = &.{
            .module = shader_module,
            .entry_point = "fs_main",
            .target_count = 1,
            .targets = &[_]gpu.ColorTargetState{color_target},
        },
    });
    self.imgui_impl.bgl1 = bgl1;
    self.imgui_impl.uniform_buffer = uniform_buffer;
    self.imgui_impl.common_bind_group = common_bind_group;
    self.imgui_impl.sampler = sampler;
    self.initialized = true;
}

fn mapMachKey(key: mach.Core.KeyButtonID) ImGui.ImGuiKey {
    return switch (key) {
        .a => ImGui.ImGuiKey_A,
        .b => ImGui.ImGuiKey_B,
        .c => ImGui.ImGuiKey_C,
        .d => ImGui.ImGuiKey_D,
        .e => ImGui.ImGuiKey_E,
        .f => ImGui.ImGuiKey_F,
        .g => ImGui.ImGuiKey_G,
        .h => ImGui.ImGuiKey_H,
        .i => ImGui.ImGuiKey_I,
        .j => ImGui.ImGuiKey_J,
        .k => ImGui.ImGuiKey_K,
        .l => ImGui.ImGuiKey_L,
        .m => ImGui.ImGuiKey_M,
        .n => ImGui.ImGuiKey_N,
        .o => ImGui.ImGuiKey_O,
        .p => ImGui.ImGuiKey_P,
        .q => ImGui.ImGuiKey_Q,
        .r => ImGui.ImGuiKey_R,
        .s => ImGui.ImGuiKey_S,
        .t => ImGui.ImGuiKey_T,
        .u => ImGui.ImGuiKey_U,
        .v => ImGui.ImGuiKey_V,
        .w => ImGui.ImGuiKey_W,
        .x => ImGui.ImGuiKey_X,
        .y => ImGui.ImGuiKey_Y,
        .z => ImGui.ImGuiKey_Z,
        .zero => ImGui.ImGuiKey_0,
        .one => ImGui.ImGuiKey_1,
        .two => ImGui.ImGuiKey_2,
        .three => ImGui.ImGuiKey_3,
        .four => ImGui.ImGuiKey_4,
        .five => ImGui.ImGuiKey_5,
        .six => ImGui.ImGuiKey_6,
        .seven => ImGui.ImGuiKey_7,
        .eight => ImGui.ImGuiKey_8,
        .nine => ImGui.ImGuiKey_9,
        .enter, .kp_enter => ImGui.ImGuiKey_Enter,
        .escape => ImGui.ImGuiKey_Escape,
        .backspace => ImGui.ImGuiKey_Backspace,
        .tab => ImGui.ImGuiKey_Tab,
        .space => ImGui.ImGuiKey_Space,
        .left => ImGui.ImGuiKey_LeftArrow,
        .right => ImGui.ImGuiKey_RightArrow,
        .up => ImGui.ImGuiKey_UpArrow,
        .down => ImGui.ImGuiKey_DownArrow,
        .delete => ImGui.ImGuiKey_Delete,
        .home => ImGui.ImGuiKey_Home,
        .end => ImGui.ImGuiKey_End,
        .page_up => ImGui.ImGuiKey_PageUp,
        .page_down => ImGui.ImGuiKey_PageDown,
        .left_control => ImGui.ImGuiKey_LeftCtrl,
        .left_shift => ImGui.ImGuiKey_LeftShift,
        .left_alt => ImGui.ImGuiKey_LeftAlt,
        .left_super => ImGui.ImGuiKey_LeftSuper,
        .right_control => ImGui.ImGuiKey_RightCtrl,
        .right_shift => ImGui.ImGuiKey_RightShift,
        .right_alt => ImGui.ImGuiKey_RightAlt,
        .right_super => ImGui.ImGuiKey_RightSuper,
        else => ImGui.ImGuiKey_None,
    };
}

fn sendKeyWithMods(
    io: *ImGui.ImGuiIO,
    mach_key: mach.Core.KeyButtonID,
    down: bool,
) void {
    const key = mapMachKey(mach_key);
    if (key != ImGui.ImGuiKey_None) {
        ImGui.ImGuiIO_AddKeyEvent(io, key, down);
    }
    switch (mach_key) {
        .left_control, .right_control => ImGui.ImGuiIO_AddKeyEvent(io, ImGui.ImGuiMod_Ctrl, down),
        .left_shift, .right_shift => ImGui.ImGuiIO_AddKeyEvent(io, ImGui.ImGuiMod_Shift, down),
        .left_alt, .right_alt => ImGui.ImGuiIO_AddKeyEvent(io, ImGui.ImGuiMod_Alt, down),
        .left_super, .right_super => ImGui.ImGuiIO_AddKeyEvent(io, ImGui.ImGuiMod_Super, down),
        else => {},
    }
}

fn drawViewportWindow(self: *ImGuiModule) void {
    if (!self.in_frame) return;

    ImGui.igPushStyleVar_Vec2(ImGui.ImGuiStyleVar_WindowPadding, .{ .x = 0.0, .y = 0.0 });
    defer ImGui.igPopStyleVar(1);

    if (ImGui.igBegin("Game View", null, ImGui.ImGuiWindowFlags_None)) {
        const pos = ImGui.igGetCursorScreenPos();
        const avail = ImGui.igGetContentRegionAvail();
        self.viewport.bounds_min = mach.math.vec2(pos.x, pos.y);
        self.viewport.bounds_max = mach.math.vec2(pos.x + avail.x, pos.y + avail.y);
        self.viewport.hovered = ImGui.igIsWindowHovered(ImGui.ImGuiHoveredFlags_None);

        if (avail.x > 1.0 and avail.y > 1.0) {
            const io = ImGui.igGetIO_Nil();
            const scale = mach.math.vec2(io.*.DisplayFramebufferScale.x, io.*.DisplayFramebufferScale.y);
            const target_w = @max(1, @as(u32, @intFromFloat(@round(avail.x * scale.x()))));
            const target_h = @max(1, @as(u32, @intFromFloat(@round(avail.y * scale.y()))));
            if (self.viewport.desired_size[0] != target_w or
                self.viewport.desired_size[1] != target_h)
            {
                self.viewport.desired_size = .{ target_w, target_h };
            }
            if (self.viewport.bind_group != null) {
                const tex_ref = ImGui.ImTextureRef{
                    ._TexData = null,
                    ._TexID = VIEWPORT_TEX_ID,
                };
                ImGui.igImage(
                    tex_ref,
                    avail,
                    .{ .x = 0.0, .y = 0.0 },
                    .{ .x = 1.0, .y = 1.0 },
                );
            }
        }
    } else {
        self.viewport.hovered = false;
    }
    ImGui.igEnd();
}
