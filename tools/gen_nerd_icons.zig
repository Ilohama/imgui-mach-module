const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var args_it = try init.minimal.args.iterateAllocator(allocator);
    defer args_it.deinit();
    _ = args_it.next();
    const json_path = args_it.next() orelse return error.InvalidArgs;
    const out_path = args_it.next() orelse return error.InvalidArgs;

    const json_bytes = try std.Io.Dir.cwd().readFileAlloc(
        io,
        json_path,
        allocator,
        .limited(20 * 1024 * 1024),
    );
    defer allocator.free(json_bytes);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_bytes, .{});
    defer parsed.deinit();

    var out_buf: std.ArrayList(u8) = .empty;
    defer out_buf.deinit(allocator);
    try out_buf.appendSlice(allocator,
        \\// Auto generated from Nerd Fonts glyphnames.json
        \\pub const font_ttf = @embedFile("nerd_symbols");
        \\
        \\pub const Icons = struct {
        \\
    );

    const root_obj = parsed.value.object;
    var it = root_obj.iterator();
    while (it.next()) |entry| {
        const icon_name = entry.key_ptr.*;
        // Ignorer l'objet METADATA
        if (std.mem.eql(u8, icon_name, "METADATA")) continue;

        if (entry.value_ptr.* == .object) {
            if (entry.value_ptr.*.object.get("code")) |code_val| {
                if (code_val == .string) {
                    try out_buf.print(allocator, "    pub const @\"{s}\" = \"\\u{{{s}}}\";\n", .{
                        icon_name,
                        code_val.string,
                    });
                }
            }
        }
    }

    try out_buf.appendSlice(allocator, "};\n");

    std.Io.Dir.cwd().deleteTree(io, out_path) catch {};
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = out_path,
        .data = out_buf.items,
    });
}
