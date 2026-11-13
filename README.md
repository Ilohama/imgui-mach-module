# Dear ImGui as a Mach module

Light integration of **Dear ImGui** (using `cimgui` and **Docking**) for **Mach v0.5** using the native WebGPU writen in zig on top of `mach.gpu`.

## Prerequisites

* **Mach v0.5** (Zig `2026.10.22-mach`)

## Installation

1. Add the package to your `build.zig.zon` via `zig fetch`:

   ```sh
   zig fetch --save git+https://codeberg.org/iLohama/imgui-mach-module
   ```

2. Import the `imgui` module in your `build.zig`:

   ```zig
   const imgui_dep = b.dependency("imgui_mach_module", .{
       .target = target,
       .optimize = optimize,
   });
   app_mod.addImport("imgui", imgui_dep.module("imgui"));
   ```

## Quick Start Example

``@import("imgui")`` contains the ``MachModule`` for mach and the ``CLib`` to call any cimgui function.

Here's the main modifications you have to do to integrate the module in your project:

```zig
const ImGui = @import("imgui");
const ImGuiModule = ImGui.MachModule;

[...]

// Update Mach Modules list used
pub const Modules = mach.Modules(.{
    mach.Core,
    ImGuiModule, // Notice we have included our ImGui Mach Module Here
    App,
});

[...]

// Add ImGui init to the schedule
pub const main = mach.schedule(.{
    .{ mach.Core, .init },
    .{ ImGuiModule, .init }, // Adding ImGui initialisation, it just need the window ObjectID to be set (generally, right after window creation)
    .{ App, .init },
    .{ mach.Core, .main },
});

[...]

// Give the created window to ImGui for rendering
pub fn init(
    core: *mach.Core,
    app: *App,
    app_mod: mach.Mod(App),
    core_mod: mach.Mod(mach.Core),
) !void {
    // ...

    const window = try core.windows.new(.{
        .title = WINDOW_TITLE,
        .on_render = app_mod.id.render,
    });
    // We give our window id to ImGui Here
    ImGuiModule.setWindowId(window);

    // ...
}

[...]

// We add to our tick schedule ImGui startTick and endTick
// By having startTick and endTick like this,
// you can then call any imgui functions from CLib to draw your gui in tickApp.
// startTick will start the ImGui Frame
// endTick will close the frame and call igRender
pub const tick = mach.schedule(.{
    .{ ImGuiModule, .startTick },
    .{ App, .tickApp },
    .{ ImGuiModule, .endTick },
    .{ mach.Core, .snapshotStart },
    .{ mach.Core, .snapshotEnd },
});

[...]

// When processing events,
// I recommend to give it to ImGui first
// before passing it to anything else
// so we don't propagate the event if imgui already handled it
pub fn tickApp(
    self: *App,
    core: *mach.Core,
    io: std.Io,
    imgui: *ImGuiModule,
) !void {
    var iter = core.events(.default);
    while (iter.next()) |event| {
        // ImGui processEvent HERE
        try imgui.processEvent(&event, io);
        switch (event) {
            .mouse_motion, .mouse_press, .mouse_release, .mouse_scroll => {
                if (imgui.viewport.enabled) {
                    if (!imgui.viewport.hovered) continue;
                } else if (imgui.capturesMouse()) {
                    continue;
                }
            },
            .key_press => |ev| {
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
}

[...]

// For rendering ImGui, we just need then to add it to the render pass
// I've integrated a small editor mode that binds the output to a viewport
pub fn render(
    app: *App,
    io: std.Io,
    core: *mach.Core,
    imgui: *ImGuiModule,
) !void {
    // ...

    // Here we switch the scene target to send our app rendering into imgui viewport
    // By default, viewport is disabled,
    // Enable it anywhere you want by setting the imgui.viewport.enbaled to true
    const maybe_scene_target: ?*gpu.TextureView = if (imgui.viewport.enabled)
        imgui.viewport.view
    else
        back_buffer_view;

    if (maybe_scene_target) |target_view| {
        // Your game rendering
    }

    // And then, add ImGui to the render pass
    try imgui.addImguiRenderPass(
        core,
        encoder,
        back_buffer_view,
        io,
    );

    // Then the command call etc..
}

[...]

// Finally, don't forget to deinit it at the end
pub const deinit = mach.schedule(.{
    .{ App, .deinitApp },
    .{ ImGuiModule, .deinit }, // We don't forget to deinit our ImGui Module
});
```

## Running the Included Example

```sh
zig build run
```

* F1: Switch between editor mode and game mode
* F2: Show/Hide ImGui demo window

## Regenerate cimgui bindings

```sh
zig build gen-bindings
```

## Extra tool-tip

When using the editor mode, you can use  the function `imgui_module.screenToViewport` to get the real position mouse position in viewport.
