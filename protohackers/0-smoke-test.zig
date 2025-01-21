const std = @import("std");
const print = std.debug.print;
const Connection = std.net.Server.Connection;
const Thread = std.Thread;

pub fn main() !void {
    print("starting server\n", .{});

    const addr = try std.net.Address.resolveIp("127.0.0.1", 9999);
    var server = try addr.listen(.{ .reuse_address = true });
    print("listening on {}\n", .{addr});

    while (true) {
        if (server.accept()) |conn| {
            const thread = try Thread.spawn(.{}, handleConn, .{conn});
            thread.detach();
        } else |e| {
            print("error accpeting connection: {}\n", .{e});
        }
    }
}

pub fn handleConn(conn: Connection) !void {
    print("accepted connection from: {}\n", .{conn.address});
    _ = try conn.stream.write("welcome to echo server.\n");

    var buffer: [4096]u8 = undefined;
    while (true) {
        const bytes_recv = try conn.stream.read(&buffer);
        const chunk = buffer[0..bytes_recv];
        if (chunk.len == 0) break;
        print("message: {s}", .{chunk});
        _ = try conn.stream.writer().print("{any}", .{chunk});
    }
}
