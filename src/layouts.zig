//! Amethyst's layouts: where each tile of a workspace goes, from its place in the layout
//! order alone.
//!
//! The tiles fill panes in order: the main pane first, then the others. A pane splits
//! evenly into rows or columns, or stacks its tiles one over the other. Pure integer
//! arithmetic over a caller's buffer: nothing allocates, recurses or reads a clock, and
//! the cost is one pass over the tiles.
//!
//! Gaps lie between tiles and between panes, never at the edge (the outer gap is already
//! taken off the area). Tiles that are not stacked never overlap, however small the area:
//! a tile with no room left is given no size, and the engine makes it one pixel.
const std = @import("std");
const assert = std.debug.assert;
const geometry = @import("geometry.zig");
const command = @import("command.zig");
const tree = @import("tree.zig");

const Rect = geometry.Rect;
const Axis = geometry.Axis;
pub const Tiling = command.Tiling;

/// One step of 'main expand' and 'main shrink': 5% of the area, as in Amethyst.
pub const ratio_step: u32 = tree.ratio_unit / 20;
pub const main_count_max: u8 = 32;

/// How a pane holds its tiles.
const Fill = enum { rows, columns, stacked };

const Pane = struct {
    rect: Rect,
    fill: Fill,
    count: u32,
};

/// The part of a rect along an axis from one length to another, both counted from its start.
fn span(rect: Rect, axis: Axis, from: i32, to: i32) Rect {
    assert(from <= to);
    return switch (axis) {
        .x => .{ .x = rect.x + from, .y = rect.y, .w = to - from, .h = rect.h },
        .y => .{ .x = rect.x, .y = rect.y + from, .w = rect.w, .h = to - from },
    };
}

fn length(rect: Rect, axis: Axis) i32 {
    return if (axis == .x) rect.w else rect.h;
}

/// Part index of parts even parts of a rect, with a gap between each two.
fn part(rect: Rect, axis: Axis, parts: u32, index: u32, gap: i32) Rect {
    assert(parts > 0 and index < parts);
    const gaps: i64 = @as(i64, gap) * (parts - 1);
    const usable: i64 = @max(0, length(rect, axis) - gaps);
    const used_gap: i32 = if (parts > 1)
        @intCast(@divTrunc(length(rect, axis) - usable, parts - 1))
    else
        0;
    const from: i32 = @intCast(@divTrunc(usable * index, parts) + @as(i64, used_gap) * index);
    const to: i32 = @intCast(@divTrunc(usable * (index + 1), parts) + @as(i64, used_gap) * index);
    return span(rect, axis, from, to);
}

/// Cuts a rect in two along an axis: the first part gets ratio of what the gap leaves.
fn cut(rect: Rect, axis: Axis, ratio: u32, gap: i32) [2]Rect {
    assert(ratio <= tree.ratio_unit);
    const total = length(rect, axis);
    const usable: i64 = @max(0, total - gap);
    const used_gap: i32 = total - @as(i32, @intCast(usable));
    const first: i32 = @intCast((usable * ratio + tree.ratio_half) >> 16);
    return .{ span(rect, axis, 0, first), span(rect, axis, first + used_gap, total) };
}

/// Three columns: the main one gets ratio of the width, the two others share the rest.
/// Returns them left to right.
fn thirds(rect: Rect, ratio: u32, gap: i32, main_at: u2) [3]Rect {
    assert(main_at < 3);
    const usable: i64 = @max(0, rect.w - 2 * @as(i64, gap));
    const used_gap: i32 = @intCast(@divTrunc(rect.w - usable, 2));
    const main: i64 = (usable * ratio + tree.ratio_half) >> 16;
    const side: i64 = @divTrunc(usable - main, 2);
    var widths: [3]i64 = .{ side, side, side };
    widths[main_at] = main;
    // What rounding leaves goes to the last column, so the three fill the rect.
    widths[2] += usable - (widths[0] + widths[1] + widths[2]);
    var out: [3]Rect = undefined;
    var x: i64 = 0;
    for (&out, widths, 0..) |*column, width, index| {
        const from: i32 = @intCast(x + @as(i64, used_gap) * @as(i64, @intCast(index)));
        column.* = span(rect, .x, from, from + @as(i32, @intCast(width)));
        x += width;
    }
    return out;
}

/// The panes of a layout for count tiles, main pane first, at most three.
fn panes(tiling: Tiling, area: Rect, gap: i32, count: u32, main: u32, ratio: u32) [3]Pane {
    assert(count > 0 and main > 0);
    const m = @min(count, main);
    const s = count - m;
    const none: Pane = .{ .rect = Rect.zero, .fill = .stacked, .count = 0 };
    var out: [3]Pane = .{ none, none, none };
    const whole: Pane = .{ .rect = area, .fill = .stacked, .count = count };
    switch (tiling) {
        .bsp => unreachable,
        .fullscreen => out[0] = whole,
        .tall, .tall_right, .widescreen_tall => {
            const main_fill: Fill = if (tiling == .widescreen_tall) .columns else .rows;
            if (s == 0) {
                out[0] = .{ .rect = area, .fill = main_fill, .count = m };
                return out;
            }
            const right = tiling == .tall_right;
            const halves = cut(area, .x, if (right) tree.ratio_unit - ratio else ratio, gap);
            out[0] = .{ .rect = halves[@intFromBool(right)], .fill = main_fill, .count = m };
            out[1] = .{ .rect = halves[@intFromBool(!right)], .fill = .rows, .count = s };
        },
        .wide => {
            if (s == 0) {
                out[0] = .{ .rect = area, .fill = .columns, .count = m };
                return out;
            }
            const halves = cut(area, .y, ratio, gap);
            out[0] = .{ .rect = halves[0], .fill = .columns, .count = m };
            out[1] = .{ .rect = halves[1], .fill = .columns, .count = s };
        },
        .two_pane => {
            if (s == 0) {
                out[0] = .{ .rect = area, .fill = .stacked, .count = m };
                return out;
            }
            const axis: Axis = if (area.w >= area.h) .x else .y;
            const halves = cut(area, axis, ratio, gap);
            out[0] = .{ .rect = halves[0], .fill = .stacked, .count = m };
            out[1] = .{ .rect = halves[1], .fill = .stacked, .count = s };
        },
        .three_column_left, .three_column_middle, .three_column_right => {
            if (s == 0) {
                out[0] = .{ .rect = area, .fill = .rows, .count = m };
                return out;
            }
            // Amethyst's order: the main column, then the leftmost other one, then the last.
            const main_at: u2, const second_at: u2, const third_at: u2 = switch (tiling) {
                .three_column_left => .{ 0, 1, 2 },
                .three_column_middle => .{ 1, 0, 2 },
                else => .{ 2, 0, 1 },
            };
            const columns = thirds(area, ratio, gap, main_at);
            const third = s / 2;
            out[0] = .{ .rect = columns[main_at], .fill = .rows, .count = m };
            out[1] = .{ .rect = columns[second_at], .fill = .rows, .count = s - third };
            out[2] = .{ .rect = columns[third_at], .fill = .rows, .count = third };
        },
        .column, .row => {
            const fill: Fill = if (tiling == .column) .columns else .rows;
            if (s == 0) {
                out[0] = .{ .rect = area, .fill = fill, .count = m };
                return out;
            }
            const halves = cut(area, if (tiling == .column) .x else .y, ratio, gap);
            out[0] = .{ .rect = halves[0], .fill = fill, .count = m };
            out[1] = .{ .rect = halves[1], .fill = fill, .count = s };
        },
    }
    return out;
}

/// Where each of out.len tiles goes, in layout order. main is how many tiles the main pane
/// holds, ratio its share of the area out of tree.ratio_unit.
pub fn arrange(tiling: Tiling, area: Rect, gap: i32, main: u32, ratio: u32, out: []Rect) void {
    assert(tiling != .bsp);
    assert(area.w >= 0 and area.h >= 0 and gap >= 0);
    assert(ratio >= tree.ratio_min and ratio <= tree.ratio_max);
    if (out.len == 0) return;
    const count: u32 = @intCast(out.len);
    const list = panes(tiling, area, gap, count, @max(1, main), ratio);
    var next: u32 = 0;
    for (list) |pane| {
        var index: u32 = 0;
        while (index < pane.count) : (index += 1) {
            out[next] = switch (pane.fill) {
                .stacked => pane.rect,
                .rows => part(pane.rect, .y, pane.count, index, gap),
                .columns => part(pane.rect, .x, pane.count, index, gap),
            };
            next += 1;
        }
    }
    assert(next == count);
}

/// Whether tiles of this layout may lie over each other by design.
pub fn stacks(tiling: Tiling) bool {
    return tiling == .fullscreen or tiling == .two_pane;
}

/// The axis along which the main pane's share is measured.
pub fn main_axis(tiling: Tiling, area: Rect) Axis {
    return switch (tiling) {
        .wide, .row => .y,
        .two_pane => if (area.w >= area.h) .x else .y,
        else => .x,
    };
}

/// How many panes lie beside the main one along the main axis: two for three columns,
/// one for the others. They share what the main pane leaves, and a gap is before each.
pub fn side_panes(tiling: Tiling) u32 {
    return switch (tiling) {
        .three_column_left, .three_column_middle, .three_column_right => 2,
        else => 1,
    };
}

/// The ratio that gives the main pane this extent along the main axis: what a drag of its
/// edge with the mouse asks for.
pub fn main_ratio_from(
    tiling: Tiling,
    area: Rect,
    gap: i32,
    main_extent: i32,
) u32 {
    const axis = main_axis(tiling, area);
    const gaps: i32 = gap * @as(i32, @intCast(side_panes(tiling)));
    const usable: i64 = @max(1, length(area, axis) - gaps);
    const share: i64 = @divTrunc(@as(i64, @max(0, main_extent)) * tree.ratio_unit, usable);
    return @intCast(std.math.clamp(share, tree.ratio_min, tree.ratio_max));
}

const testing = std.testing;

fn layout_test(tiling: Tiling, count: usize, main: u32, out: []Rect) void {
    arrange(tiling, Rect.init(0, 0, 1000, 600), 10, main, tree.ratio_half, out[0..count]);
}

test "tall: one main window on the left, the others in rows on the right" {
    var out: [4]Rect = undefined;
    layout_test(.tall, 1, 1, &out);
    try testing.expect(out[0].eql(Rect.init(0, 0, 1000, 600)));
    layout_test(.tall, 3, 1, &out);
    try testing.expect(out[0].eql(Rect.init(0, 0, 495, 600)));
    try testing.expect(out[1].eql(Rect.init(505, 0, 495, 295)));
    try testing.expect(out[2].eql(Rect.init(505, 305, 495, 295)));
    layout_test(.tall_right, 2, 1, &out);
    try testing.expect(out[0].eql(Rect.init(505, 0, 495, 600)));
    try testing.expect(out[1].eql(Rect.init(0, 0, 495, 600)));
    layout_test(.tall, 3, 2, &out);
    try testing.expect(out[0].eql(Rect.init(0, 0, 495, 295)));
    try testing.expect(out[1].eql(Rect.init(0, 305, 495, 295)));
    try testing.expect(out[2].eql(Rect.init(505, 0, 495, 600)));
}

test "wide, column, row, widescreen-tall" {
    var out: [4]Rect = undefined;
    layout_test(.wide, 3, 1, &out);
    try testing.expect(out[0].eql(Rect.init(0, 0, 1000, 295)));
    try testing.expect(out[1].eql(Rect.init(0, 305, 495, 295)));
    try testing.expect(out[2].eql(Rect.init(505, 305, 495, 295)));
    layout_test(.column, 3, 1, &out);
    try testing.expect(out[0].eql(Rect.init(0, 0, 495, 600)));
    try testing.expect(out[2].eql(Rect.init(757, 0, 243, 600)));
    layout_test(.row, 2, 1, &out);
    try testing.expect(out[1].eql(Rect.init(0, 305, 1000, 295)));
    layout_test(.widescreen_tall, 3, 2, &out);
    try testing.expect(out[0].eql(Rect.init(0, 0, 242, 600)));
    try testing.expect(out[1].eql(Rect.init(252, 0, 243, 600)));
    try testing.expect(out[2].eql(Rect.init(505, 0, 495, 600)));
}

test "three columns put the main pane where they say and share the rest" {
    var out: [4]Rect = undefined;
    layout_test(.three_column_middle, 4, 1, &out);
    // 980 usable: 490 main, 245 each side.
    try testing.expect(out[0].eql(Rect.init(255, 0, 490, 600)));
    try testing.expect(out[1].eql(Rect.init(0, 0, 245, 295)));
    try testing.expect(out[2].eql(Rect.init(0, 305, 245, 295)));
    try testing.expect(out[3].eql(Rect.init(755, 0, 245, 600)));
    layout_test(.three_column_left, 2, 1, &out);
    try testing.expect(out[0].eql(Rect.init(0, 0, 490, 600)));
    try testing.expect(out[1].eql(Rect.init(500, 0, 245, 600)));
    layout_test(.three_column_right, 3, 1, &out);
    try testing.expect(out[0].eql(Rect.init(510, 0, 490, 600)));
    try testing.expect(out[1].eql(Rect.init(0, 0, 245, 600)));
    try testing.expect(out[2].eql(Rect.init(255, 0, 245, 600)));
}

test "two-pane and fullscreen stack their tiles" {
    var out: [4]Rect = undefined;
    layout_test(.two_pane, 4, 1, &out);
    try testing.expect(out[0].eql(Rect.init(0, 0, 495, 600)));
    try testing.expect(out[1].eql(Rect.init(505, 0, 495, 600)));
    try testing.expect(out[3].eql(out[1]));
    layout_test(.fullscreen, 3, 1, &out);
    for (out[0..3]) |rect| try testing.expect(rect.eql(Rect.init(0, 0, 1000, 600)));
}

test "no layout overlaps or leaves its area, however small the area or many the tiles" {
    var out: [40]Rect = undefined;
    var prng = std.Random.DefaultPrng.init(7);
    const random = prng.random();
    for (0..4000) |_| {
        const tiling = random.enumValue(Tiling);
        if (tiling == .bsp or stacks(tiling)) continue;
        const x = random.intRangeAtMost(i32, -3000, 3000);
        const area = Rect.init(x, 0, random.uintAtMost(u16, 3000), random.uintAtMost(u16, 2000));
        const count = random.intRangeAtMost(usize, 1, out.len);
        const gap = random.intRangeAtMost(i32, 0, 60);
        const main = random.intRangeAtMost(u32, 1, 6);
        const ratio = random.intRangeAtMost(u32, tree.ratio_min, tree.ratio_max);
        arrange(tiling, area, gap, main, ratio, out[0..count]);
        for (out[0..count], 0..) |rect, index| {
            try testing.expect(rect.w >= 0 and rect.h >= 0);
            try testing.expect(rect.x >= area.x and rect.right() <= area.right());
            try testing.expect(rect.y >= area.y and rect.bottom() <= area.bottom());
            for (out[0..index]) |other| try testing.expect(!rect.intersects(other));
        }
    }
}

test "a dragged main pane gives back the ratio it was laid out with" {
    var out: [3]Rect = undefined;
    const area = Rect.init(0, 0, 1000, 600);
    arrange(.tall, area, 10, 1, tree.ratio_unit * 3 / 10, &out);
    const ratio = main_ratio_from(.tall, area, 10, out[0].w);
    try testing.expect(@abs(@as(i64, ratio) - tree.ratio_unit * 3 / 10) < tree.ratio_unit / 100);
}
