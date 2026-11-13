const std = @import("std");

const Rule = struct {
    needle: []const u8,
    replacement: []const u8,
};

const rules = [_]Rule{
    .{ .needle = "?*ImGuiWindow", .replacement = "?*struct_ImGuiWindow" },
    .{ .needle = "[*c]ImGuiContext", .replacement = "?*struct_ImGuiContext" },
    .{ .needle = "[*]ImGuiContext", .replacement = "?*struct_ImGuiContext" },
    .{ .needle = "?*ImGuiContext", .replacement = "?*struct_ImGuiContext" },
    .{ .needle = "?*ImGuiDockNode", .replacement = "?*struct_ImGuiDockNode" },
    .{ .needle = "?*ImGuiViewport", .replacement = "?*struct_ImGuiViewport" },
};

fn isWordChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(allocator);
    if (args.len < 3) return error.InvalidArgs;
    const input_path = args[1];
    const output_path = args[2];

    const content = try std.Io.Dir.cwd().readFileAlloc(io, input_path, allocator, .limited(64 * 1024 * 1024));

    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < content.len) {
        var matched = false;
        for (rules) |rule| {
            if (std.mem.startsWith(u8, content[i..], rule.needle)) {
                const after_idx = i + rule.needle.len;
                if (after_idx == content.len or !isWordChar(content[after_idx])) {
                    try out.appendSlice(allocator, rule.replacement);
                    i = after_idx;
                    matched = true;
                    break;
                }
            }
        }
        if (!matched) {
            try out.append(allocator, content[i]);
            i += 1;
        }
    }

    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = output_path,
        .data = out.items,
    });
}
