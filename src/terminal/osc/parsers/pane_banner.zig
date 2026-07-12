const std = @import("std");

const Parser = @import("../../osc.zig").Parser;
const Command = @import("../../osc.zig").Command;

/// Parse OSC 7778: sticky pane banner (Ghoztty extension). The payload is
/// the banner text in the Ghoztty banner markdown subset. An empty payload
/// clears the banner.
pub fn parse(parser: *Parser, _: ?u8) ?*Command {
    const cap = if (parser.capture) |*c| c else {
        parser.state = .invalid;
        return null;
    };
    cap.writer.writeByte(0) catch {
        parser.state = .invalid;
        return null;
    };
    const data = cap.trailing();
    parser.command = .{
        .pane_banner = data[0 .. data.len - 1 :0],
    };
    return &parser.command;
}

test "OSC 7778: pane banner" {
    const testing = std.testing;
    var p: Parser = .init(null);
    const input = "7778;**PR #123** [view](https://example.com)";
    for (input) |ch| p.next(ch);
    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .pane_banner);
    try testing.expectEqualStrings(
        "**PR #123** [view](https://example.com)",
        cmd.pane_banner,
    );
}

test "OSC 7778: empty payload clears" {
    const testing = std.testing;
    var p: Parser = .init(null);
    const input = "7778;";
    for (input) |ch| p.next(ch);
    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .pane_banner);
    try testing.expectEqualStrings("", cmd.pane_banner);
}

test "OSC 7778: no separator is invalid" {
    const testing = std.testing;
    var p: Parser = .init(null);
    const input = "7778";
    for (input) |ch| p.next(ch);
    try testing.expect(p.end(null) == null);
}
