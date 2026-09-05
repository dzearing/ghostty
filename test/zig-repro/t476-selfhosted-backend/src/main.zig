const std = @import("std");
const uucode = @import("uucode");

/// Reduced from ghostty's `input.Binding.Trigger.foldedCodepoint`.
fn foldedCodepoint(cp: u21) [3]u21 {
    var buffer: [1]u21 = undefined;
    const slice = uucode.get(.case_folding_full, cp).with(&buffer, cp);
    var array: [3]u21 = [_]u21{0} ** 3;
    @memcpy(array[0..slice.len], slice);
    return array;
}

test "case folding" {
    try std.testing.expectEqual([3]u21{ 'a', 0, 0 }, foldedCodepoint('A'));
}
