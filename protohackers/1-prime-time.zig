const std = @import("std");
const Connection = std.net.Server.Connection;
const Thread = std.Thread;
const Allocator = std.mem.Allocator;
const eql = std.mem.eql;
const print = std.debug.print;
const sqrt = std.math.sqrt;
const modf = std.math.modf;

const Request = struct {
    method: []const u8,
    number: f64,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const addr = try std.net.Address.resolveIp("127.0.0.1", 9999);
    var server = try addr.listen(.{ .reuse_address = true });
    print("listening on {}\n", .{addr});

    while (true) {
        if (server.accept()) |conn| {
            const thread = try Thread.spawn(.{}, serve, .{allocator, conn});
            thread.detach();
        } else |e| {
            print("error accepting connection: {}\n", .{e});
        }
    }
}

fn serve(allocator: Allocator, conn: Connection) !void {
    print("accepting connection from {}\n", .{conn.address});
    defer {
        print("closing connection from {}\n", .{conn.address});
        conn.stream.close();
    }

    var arr = std.ArrayList(u8).init(allocator);
    defer arr.deinit();

    while (true) {
        conn.stream.reader().streamUntilDelimiter(arr.writer(), '\n', null) catch |e| switch (e) {
            error.EndOfStream => break,
            else => unreachable,
        };

        const parsed = std.json.parseFromSlice(Request, allocator, arr.items, .{ .ignore_unknown_fields = true }) catch |e| {
            print("failed to parse json: {}\n", .{e});
            try handleMalformedRequest(conn);
            break;
        };

        if (!eql(u8, parsed.value.method, "isPrime")) {
            print("method is not 'isPrime'\n", .{});
            try handleMalformedRequest(conn);
            break;
        }

        const num = parsed.value.number;
        const has_frac = modf(num).fpart != 0.0;
        if ( num < 0 or has_frac) {
            try handleConformingRequest(conn, false);
            continue;
        }

        try handleConformingRequest(conn, isNumPrime(@as(u64, @intFromFloat(parsed.value.number))));

        arr.clearRetainingCapacity();
    }
}

fn handleMalformedRequest(conn: Connection) !void {
    _ = try conn.stream.write("\n");
}

fn handleConformingRequest(conn: Connection, isPrime: bool) !void {
    _ = try conn.stream.writer().print("{{\"method\":\"isPrime\",\"prime\":{}}}\n", .{isPrime});
}

fn isNumPrime(n: u64) bool {
    if (n <= 1) return false;
    if (n == 2 or n == 3) return true;
    if (n % 2 == 0 or n % 3 == 0) return false;

    var i: u64 = 5;
    while (i <= sqrt(n)) : (i += 6) {
        if (n % i == 0 or n % (i + 2) == 0) return false;
    }

    return true;
}
