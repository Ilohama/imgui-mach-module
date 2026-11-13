const std = @import("std");
const mach = @import("mach");
const gpu = mach.gpu;
const ImGui = @import("imgui");
const ImGuiModule = ImGui.MachModule;

const App = @This();

// The set of Mach modules our application may use.
pub const Modules = mach.Modules(.{
    mach.Core,
    ImGuiModule, // Notice we have included our ImGui Mach Module Here
    App,
});

const WINDOW_TITLE = "Hello, Mach with ImGui (docking) native support!";
pub const mach_module = .app;
pub const mach_systems = .{
    .main,
    .init,
    .tick,
    .tickApp,
    .render,
    .deinit,
    .deinitApp,
};
pub const main = mach.schedule(.{
    .{ mach.Core, .init },
    .{ ImGuiModule, .init }, // Adding ImGui initialisation, it just need the window ObjectID to be set (generally, right after window creation)
    .{ App, .init },
    .{ mach.Core, .main },
});
pipeline: ?*gpu.RenderPipeline = null,
app_thread: mach.Thread,
window: mach.ObjectID,
show_demo: bool = true,

pub fn init(
    core: *mach.Core,
    app: *App,
    app_mod: mach.Mod(App),
    core_mod: mach.Mod(mach.Core),
) !void {
    core.on_exit = app_mod.id.deinit;

    const window = try core.windows.new(.{
        .title = WINDOW_TITLE,
        .on_render = app_mod.id.render,
    });
    // We give our window id to ImGui Here
    ImGuiModule.setWindowId(window);

    app.* = .{
        .app_thread = try mach.startThread(core, app_mod.id.tick, core_mod, .app),
        .window = window,
    };
}

fn setupPipeline(core: *mach.Core, app: *App) !void {
    var window = core.windows.getValue(core.window);
    defer core.windows.setValueRaw(core.window, window);

    // Create our shader module
    const shader_module = window.device.createShaderModuleWGSL("shader.wgsl", @embedFile("shader.wgsl"));
    defer shader_module.release();

    // Blend state describes how rendered colors get blended
    const blend = gpu.BlendState{};

    // Color target describes e.g. the pixel format of the window we are rendering to.
    const color_target = gpu.ColorTargetState{
        .format = window.framebuffer_format,
        .blend = &blend,
    };

    // Fragment state describes which shader and entrypoint to use for rendering fragments.
    const fragment = gpu.FragmentState.init(.{
        .module = shader_module,
        .entry_point = "frag_main",
        .targets = &.{color_target},
    });

    // Create our render pipeline that will ultimately get pixels onto the screen.
    const label = @tagName(mach_module) ++ ".init";
    const pipeline_descriptor = gpu.RenderPipeline.Descriptor{
        .label = label,
        .fragment = &fragment,
        .vertex = gpu.VertexState{
            .module = shader_module,
            .entry_point = "vertex_main",
        },
    };
    app.pipeline = window.device.createRenderPipeline(&pipeline_descriptor);
}

// We add to our tick schedule ImGui startTick and endTick
// By having startTick and endTick like this,
// you can then call imgui to draw your gui in tickApp as you want.
// startTick will start the ImGui Frame
// endTick will close the frame and call igRender
pub const tick = mach.schedule(.{
    .{ ImGuiModule, .startTick },
    .{ App, .tickApp },
    .{ ImGuiModule, .endTick },
    .{ mach.Core, .snapshotStart },
    .{ mach.Core, .snapshotEnd },
});

pub fn tickApp(
    self: *App,
    core: *mach.Core,
    io: std.Io,
    imgui: *ImGuiModule,
) !void {
    // Processing events
    var iter = core.events(.default);
    while (iter.next()) |event| {
        // We give the event to imgui for it to process it
        try imgui.processEvent(&event, io);
        switch (event) {
            // We make sure that imgui process event first
            // So we don't propagate the event if imgui already handled it
            .mouse_motion, .mouse_press, .mouse_release, .mouse_scroll => {
                if (imgui.editor_mode) {
                    if (!imgui.viewport.hovered) continue;
                } else if (imgui.capturesMouse()) {
                    continue;
                }
            },
            .key_press => |ev| {
                if (ev.key == .f1) {
                    // Switch between imgui mode (using viewport for game)
                    imgui.editor_mode = !imgui.editor_mode;
                    continue;
                } else if (ev.key == .f2) {
                    // Toggle demo window
                    self.show_demo = !self.show_demo;
                }
                if (imgui.wantsTextInput()) continue;
            },
            .key_release, .char_input => {
                if (imgui.wantsTextInput()) continue;
            },
            .close => {
                core.exit();
                continue;
            },
            else => {},
        }
    }

    if (imgui.isFrameOpened() and self.show_demo) {
        // We can call anything of cimgui lib as we want
        ImGui.CLib.igShowDemoWindow(null);
    }
}

pub fn render(
    app: *App,
    io: std.Io,
    core: *mach.Core,
    imgui: *ImGuiModule,
) !void {
    const pipeline = app.pipeline orelse {
        try setupPipeline(core, app);
        return;
    };
    const label = @tagName(mach_module) ++ ".render";
    const window = core.windows.getValue(core.window);

    const back_buffer_view = window.swap_chain.getCurrentTextureView() orelse return;
    defer back_buffer_view.release();
    const encoder = window.device.createCommandEncoder(&.{ .label = label });
    defer encoder.release();
    // Here we switch the scene target to send our app rendering to imgui viewport
    const maybe_scene_target: ?*gpu.TextureView = if (imgui.editor_mode)
        imgui.viewport.view
    else
        back_buffer_view;

    if (maybe_scene_target) |target_view| {
        const sky_blue_background = gpu.Color{ .r = 0.776, .g = 0.988, .b = 1, .a = 1 };
        const color_attachments = [_]gpu.RenderPassColorAttachment{.{
            .view = target_view,
            .clear_value = sky_blue_background,
            .load_op = .clear,
            .store_op = .store,
        }};
        const render_pass = encoder.beginRenderPass(&gpu.RenderPassDescriptor.init(.{
            .label = label,
            .color_attachments = &color_attachments,
        }));
        defer render_pass.release();

        render_pass.setPipeline(pipeline);
        render_pass.draw(3, 1, 0, 0);
        render_pass.end();
    }

    // And then, add ImGui to the render pass
    try imgui.renderIntoPass(
        core,
        encoder,
        back_buffer_view,
        io,
    );

    var command = encoder.finish(&.{ .label = label });
    defer command.release();
    window.queue.submit(&[_]*gpu.CommandBuffer{command});

    {
        core.windows.lock();
        defer core.windows.unlock();
        try core.fmtTitle(app.window, WINDOW_TITLE ++ " [ {d}fps ] [ Input {d}hz ]", .{
            core.windows.get(app.window, .frame).rate, core.input.rate,
        });
    }
}

pub const deinit = mach.schedule(.{
    .{ App, .deinitApp },
    .{ ImGuiModule, .deinit }, // We don't forget to deinit our ImGui Module
});

pub fn deinitApp(app: *App) void {
    app.app_thread.join();
    if (app.pipeline) |p| p.release();
}
