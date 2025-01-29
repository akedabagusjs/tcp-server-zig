const std = @import("std");
const posix = std.posix;
const fd_t = posix.fd_t;
const socket = posix.socket;
const sendto = posix.sendto;
const print = std.debug.print;
const Map = std.StringHashMap;
const Allocator = std.mem.Allocator;
const eql = std.mem.eql;
const allocPrint = std.fmt.allocPrint;

var db: DB = undefined;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const addr = try std.net.Address.parseIp("127.0.0.1", 9999);
    const sock = try socket(posix.AF.INET, posix.SOCK.DGRAM, posix.IPPROTO.UDP);
    defer posix.close(sock);
    try posix.bind(sock, &addr.any, addr.getOsSockLen());

    db = DB.init(allocator, sock);
    defer db.deinit();

    while (true) {
        try db.listen();
    }
}

const DB = struct {
    allocator: Allocator,
    sock: fd_t,
    entries: Map([]u8),

    pub fn init(allocator: Allocator, sock: fd_t) DB {
        return .{
            .allocator = allocator,
            .sock = sock,
            .entries = Map([]u8).init(allocator),
        };
    }

    pub fn deinit(self: *DB) void {
        self.entries.deinit();
    }

    pub fn listen(self: *DB) !void {
        var buf: [1024]u8 = undefined;
        var dst: posix.sockaddr = undefined;
        var dst_len: posix.socklen_t = @sizeOf(posix.sockaddr);
        const len = try posix.recvfrom(self.sock, &buf, 0, &dst, &dst_len);

        try self.handle(buf[0..len], dst, dst_len);
    }

    pub fn handle(self: *DB, msg: []const u8, dst: posix.sockaddr, dst_len: posix.socklen_t) !void {
        if (std.mem.indexOf(u8, msg, "=")) |eq_index| {
            const key = msg[0..eq_index];
            const val = msg[eq_index+1..];
            try self.insert(key, val);
            print("<- '{s}'='{s}'\n", .{key, val});
        } else {
            const val = self.query(msg);
            const resp = try allocPrint(self.allocator, "{s}={s}", .{msg, val});
            print("<- '{s}'\n", .{msg});
            print("-> '{s}'='{s}'\n", .{msg, val});
            _ = try sendto(self.sock, resp, 0, &dst, dst_len);
        }
    }

    pub fn insert(self: *DB, key: []const u8, val: []const u8) !void {
        if (eql(u8, key, "version")) return;

        const dupe_key = try std.mem.Allocator.dupe(self.allocator, u8, key);
        const dupe_val = try std.mem.Allocator.dupe(self.allocator, u8, val);
        try self.entries.put(dupe_key, dupe_val);
    }

    pub fn query(self: *DB, key: []const u8) []const u8 {
        if (eql(u8, key, "version")) {
            return "Ken's Key-Value Store 1.0";
        }
        return self.entries.get(key) orelse "";
    }
};
