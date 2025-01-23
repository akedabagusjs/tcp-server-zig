const std = @import("std");
const Connection = std.net.Server.Connection;
const Thread = std.Thread;
const Allocator = std.mem.Allocator;
const eql = std.mem.eql;
const print = std.debug.print;
const sqrt = std.math.sqrt;
const modf = std.math.modf;
const json = std.json;
const BigInt = i256;

const Request = struct {
    method: []const u8,
    number: BigInt,
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
    print("{}> start serving..\n", .{conn.address});
    defer {
        print("{}> closed connection\n", .{conn.address});
        conn.stream.close();
    }

    var arr = std.ArrayList(u8).init(allocator);
    defer arr.deinit();

    while (true) {
        conn.stream.reader().streamUntilDelimiter(arr.writer(), '\n', null) catch |e| switch (e) {
            error.EndOfStream => break,
            else => unreachable,
        };
        print("{}> received request: {s}\n", .{conn.address, arr.items});
        const request = parseRequest(allocator, arr.items) catch |e| {
            print("{}> invalid request: {}\n", .{conn.address, e});
            try handleMalformedRequest(conn);
            break;
        };

        var is_prime: bool = false;
        if (request.number > 0) {
            is_prime = isNumPrime(request.number);
        }

        try handleConformingRequest(conn, is_prime);
        arr.clearRetainingCapacity();
    }
}

fn parseRequest(allocator: Allocator, message: []u8) !Request {
    var request: Request = undefined;

    const parsed = try json.parseFromSlice(
        json.Value,
        allocator,
        message,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();

    const method: ?json.Value = parsed.value.object.get("method");
    const number: ?json.Value = parsed.value.object.get("number");
    if (method == null or number == null) {
        return error.ParseError;
    }
    switch (method.?) {
        .string => {
            if (!eql(u8, method.?.string, "isPrime")) {
                return error.ParseError;
            }
            request.method = "isPrime";
        },
        else => return error.ParseError,
    }
    switch (number.?) {
        .integer => request.number = number.?.integer,
        .float => request.number = @intFromFloat(number.?.float),
        .number_string => {
            print("detected number_string\n", .{});
            var big = try std.math.big.int.Managed.init(allocator);
            defer big.deinit();

            try big.setString(10, number.?.number_string);
            request.number = try big.to(BigInt);
        },
        else => return error.ParseError,
    }

    return request;
}

fn handleMalformedRequest(conn: Connection) !void {
    _ = try conn.stream.write("\n");
}

fn handleConformingRequest(conn: Connection, isPrime: bool) !void {
    _ = try conn.stream.writer().print("{{\"method\":\"isPrime\",\"prime\":{}}}\n", .{isPrime});
}

fn isNumPrime(n: BigInt) bool {
    if (n <= 1) return false;

    var i: isize = 2;
    while (i * i <= n) : (i += 1) {
        if (@rem(n, i) == 0) return false;
    }

    return true;
}
