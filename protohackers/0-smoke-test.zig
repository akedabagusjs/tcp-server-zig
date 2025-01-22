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
    defer {
        conn.stream.close();
        print("closed connection from: {}\n", .{conn.address});
    }

    conn.stream.reader().streamUntilDelimiter(conn.stream.writer(), '\n', null) catch |e| {
        print("error reading from or writing to stream: {}\n", .{e});
    };
}
