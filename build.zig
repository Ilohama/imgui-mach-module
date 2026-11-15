const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mach_dep = b.dependency("mach", .{
        .target = target,
        .optimize = optimize,
    });
    const imgui_dep = b.dependency("imgui", .{});
    const cimgui_dep = b.dependency("cimgui", .{});

    addGenBindingsStep(
        b,
        target,
        optimize,
        imgui_dep,
        cimgui_dep,
    );
    const cimgui_lib = buildModuleLib(
        b,
        target,
        optimize,
        imgui_dep,
        cimgui_dep,
        mach_dep,
    );
    _ = buildExample(
        b,
        target,
        optimize,
        cimgui_lib,
        mach_dep,
    );
}

fn buildModuleLib(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    imgui_dep: *std.Build.Dependency,
    cimgui_dep: *std.Build.Dependency,
    mach_dep: *std.Build.Dependency,
) *std.Build.Step.Compile {
    const cimgui_tree = b.addWriteFiles();
    _ = cimgui_tree.addCopyFile(b.path("src/generated/cimgui.cpp"), "cimgui.cpp");
    _ = cimgui_tree.addCopyFile(b.path("src/generated/cimgui.h"), "cimgui.h");
    _ = cimgui_tree.addCopyDirectory(imgui_dep.path(""), "imgui", .{});

    const cimgui_mod = b.addModule("imgui", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
    });
    cimgui_mod.addImport("mach", mach_dep.module("mach"));

    const flags = &.{
        "-fno-exceptions",
        "-fno-rtti",
        "-std=c++17",
        "-Wno-return-type-c-linkage",
    };

    cimgui_mod.addCSourceFiles(.{
        .root = imgui_dep.path(""),
        .files = &.{
            "imgui.cpp",
            "imgui_draw.cpp",
            "imgui_widgets.cpp",
            "imgui_tables.cpp",
            "imgui_demo.cpp",
        },
        .flags = flags,
    });

    cimgui_mod.addCSourceFiles(.{
        .root = cimgui_tree.getDirectory(),
        .files = &.{"cimgui.cpp"},
        .flags = flags,
    });

    cimgui_mod.addIncludePath(imgui_dep.path(""));
    cimgui_mod.addIncludePath(cimgui_dep.path(""));
    cimgui_mod.addCMacro("IMGUI_HAS_DOCK", "");

    const cimgui_lib = b.addLibrary(.{
        .name = "cimgui",
        .linkage = .static,
        .root_module = cimgui_mod,
        .use_lld = true,
        .use_llvm = true,
    });
    b.installArtifact(cimgui_lib);

    return cimgui_lib;
}

fn buildExample(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    imgui_lib: *std.Build.Step.Compile,
    mach_dep: *std.Build.Dependency,
) *std.Build.Module {
    const font_awesome_mod = buildFontAwesome(b);
    const app_mod = b.createModule(.{
        .root_source_file = b.path("example/App.zig"),
        .optimize = optimize,
        .target = target,
    });
    app_mod.addImport("mach", mach_dep.module("mach"));
    app_mod.addImport("imgui", imgui_lib.root_module);
    app_mod.addImport("font-awesome", font_awesome_mod);

    // Have Mach create the executable for us
    const exe = @import("mach").addExecutable(mach_dep.builder, .{
        .name = "imgui_mach_module",
        .app = app_mod,
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(exe);

    // Run the app when `zig build run` is invoked
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    const run_step = b.step("run", "Run the app");

    const imgui_tests = b.addTest(.{
        .root_module = imgui_lib.root_module,
    });
    const run_imgui_tests = b.addRunArtifact(imgui_tests);
    const imgui_test_step = b.step("test-module", "Run module tests");
    imgui_test_step.dependOn(&run_imgui_tests.step);
    run_step.dependOn(&run_cmd.step);

    // Run tests when `zig build test` is run
    const app_unit_tests = b.addTest(.{
        .root_module = app_mod,
    });
    const run_app_unit_tests = b.addRunArtifact(app_unit_tests);
    const test_step = b.step("test-example", "Run example's unit tests");
    test_step.dependOn(&run_app_unit_tests.step);
    return app_mod;
}

fn addGenBindingsStep(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    imgui_dep: *std.Build.Dependency,
    cimgui_dep: *std.Build.Dependency,
) void {
    const gen_ws = b.addWriteFiles();
    _ = gen_ws.addCopyDirectory(imgui_dep.path(""), "imgui", .{});
    _ = gen_ws.addCopyDirectory(cimgui_dep.path("generator"), "generator", .{});
    const fake_clang = b.fmt("@echo off\r\n\"{s}\" cc %*\r\n", .{b.graph.zig_exe});
    _ = gen_ws.add("generator/clang.cmd", fake_clang);

    const run_luajit = b.addSystemCommand(&.{
        "luajit.exe",
        "generator.lua",
        "clang",
        "internal noimstrv",
    });
    run_luajit.setCwd(gen_ws.getDirectory().path(b, "generator"));
    run_luajit.step.dependOn(&gen_ws.step);

    const generated_h = gen_ws.getDirectory().path(b, "cimgui.h");
    const generated_cpp = gen_ws.getDirectory().path(b, "cimgui.cpp");

    const translate_c = b.addTranslateC(.{
        .root_source_file = generated_h,
        .target = target,
        .optimize = optimize,
    });
    translate_c.addIncludePath(gen_ws.getDirectory());
    translate_c.addIncludePath(imgui_dep.path(""));
    translate_c.defineCMacro("CIMGUI_DEFINE_ENUMS_AND_STRUCTS", "1");
    translate_c.defineCMacro("IMGUI_HAS_DOCK", "1");
    translate_c.step.dependOn(&run_luajit.step);

    // Compilation et exécution de l'outil pur Zig `tools/fix_cimgui.zig`
    const fixer_exe = b.addExecutable(.{
        .name = "fix_cimgui",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/fix_cimgui.zig"),
            .target = b.graph.host,
        }),
    });
    const run_fixer = b.addRunArtifact(fixer_exe);
    run_fixer.addFileArg(translate_c.getOutput());
    const fixed_cimgui_zig = run_fixer.addOutputFileArg("cimgui.zig");

    // Copie des fichiers finaux vers src/ en une seule étape propre
    const update_src = b.addUpdateSourceFiles();
    update_src.addCopyFileToSource(generated_h, "src/generated/cimgui.h");
    update_src.addCopyFileToSource(generated_cpp, "src/generated/cimgui.cpp");
    update_src.addCopyFileToSource(fixed_cimgui_zig, "src/cimgui.zig");

    const gen_step = b.step("gen-bindings", "Regen cimgui bindings (cimgui.h, cimgui.cpp, src/cimgui.zig)");
    gen_step.dependOn(&update_src.step);
}

fn buildFontAwesome(b: *std.Build) *std.Build.Module {
    const fa_dep = b.dependency("font_awesome", .{});
    const gen_fa_exe = b.addExecutable(.{
        .name = "gen_fa_icons",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/gen_fa_icons.zig"),
            .target = b.graph.host,
        }),
    });

    const run_gen_fa = b.addRunArtifact(gen_fa_exe);
    run_gen_fa.addFileArg(fa_dep.path("metadata/icons.json"));
    const generated_fa_zig = run_gen_fa.addOutputDirectoryArg("font_awesome.zig");

    const fa_mod = b.addModule("font_awesome", .{
        .root_source_file = generated_fa_zig,
    });
    fa_mod.addAnonymousImport("fa_solid_otf", .{
        .root_source_file = fa_dep.path("otfs/Font Awesome 7 Free-Solid-900.otf"),
    });
    fa_mod.addAnonymousImport("fa_regular_otf", .{
        .root_source_file = fa_dep.path("otfs/Font Awesome 7 Free-Regular-400.otf"),
    });
    fa_mod.addAnonymousImport("fa_brands_otf", .{
        .root_source_file = fa_dep.path("otfs/Font Awesome 7 Brands-Regular-400.otf"),
    });
    return fa_mod;
}
