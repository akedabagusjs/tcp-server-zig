const std = @import("std");
const net = std.net;
const print = std.debug.print;

pub fn main() !void {
    print("starting server\n", .{});

    const addr = try net.Address.resolveIp("127.0.0.1", 9999);
    var server = try addr.listen(.{ .reuse_address = true });
    print("listening on port {}\n", .{ addr });

    while (server.accept()) |conn| {
        try handleConn(conn);
    } else |err| {
        print("error accepting connection: {}\n", .{ err });
    }
}

fn handleConn(conn: net.Server.Connection) !void {
    print("accepting connection from {}\n", .{ conn.address });

    var buffer: [2]u8 = undefined;
    while (true) {
        _ = try conn.stream.write("type operation (+, -, /) or q to exit: ");
        const received = try conn.stream.read(&buffer);
        const chunk = buffer[0..received];
        if (chunk.len == 0) break;

        switch (chunk[0]) {
            '+' => _ = try doNumbersOp(conn, '+'),
            '-' => _ = try doNumbersOp(conn, '-'),
            '/' => _ = try doNumbersOp(conn, '/'),
            'q' => {
                _ = try conn.stream.write("bye\n");
                conn.stream.close();
                print("closed connection from {}\n", .{ conn.address });
                break;
            },
            else => _ = try conn.stream.write("unknown operation\n"),
        }
    }
}

fn doNumbersOp(conn: net.Server.Connection, op: u8) !void {
    var total: f32 = 0;
    var buffer: [4096]u8 = undefined;

    _ = try conn.stream.write("enter numbers to add:\n");
    while (true) {
        const received = try conn.stream.read(&buffer);
        const chunk = buffer[0..received];
        if (chunk.len == 0) break;

        const line = std.mem.trim(u8, chunk, "\n");
        if (line.len == 0) break;

        const num = std.fmt.parseFloat(f32, line) catch {
            _ = try conn.stream.write("invalid number\n");
            continue;
        };

        switch (op) {
            '+' => total += num,
            '-' => total -= num,
            '/' => total /= num,
            else => unreachable,
        }
    }
    _ = try conn.stream.writer().print("total: {d}\n", .{ total });
}
