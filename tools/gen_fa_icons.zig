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
        \\// Auto generated file during build - Don't modify it by hand
        \\pub const solid_otf = @embedFile("fa_solid_otf");
        \\pub const regular_otf = @embedFile("fa_regular_otf");
        \\pub const brands_otf = @embedFile("fa_brands_otf");
        \\
        \\pub const Icons = struct {
        \\
    );

    const root_obj = parsed.value.object;
    var it = root_obj.iterator();
    while (it.next()) |entry| {
        const icon_name = entry.key_ptr.*;
        const icon_data = entry.value_ptr.*.object;
        if (icon_data.get("unicode")) |unicode_val| {
            if (unicode_val == .string) {
                // 1. Nom principal (ex: "house")
                try out_buf.print(allocator, "    pub const @\"{s}\" = \"\\u{{{s}}}\";\n", .{
                    icon_name,
                    unicode_val.string,
                });

                // 2. Alias officiels (ex: "home")
                if (icon_data.get("aliases")) |aliases_val| {
                    if (aliases_val == .object) {
                        if (aliases_val.object.get("names")) |names_val| {
                            if (names_val == .array) {
                                for (names_val.array.items) |alias_item| {
                                    if (alias_item == .string) {
                                        try out_buf.print(allocator, "    pub const @\"{s}\" = \"\\u{{{s}}}\";\n", .{
                                            alias_item.string,
                                            unicode_val.string,
                                        });
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    try out_buf.appendSlice(allocator, "};\n");

    // Supprimer l'entrée existante au cas où un dossier porterait ce nom
    std.Io.Dir.cwd().deleteTree(io, out_path) catch {};

    // 5. Écrire le fichier final demandé par le système de build
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = out_path,
        .data = out_buf.items,
    });
}
