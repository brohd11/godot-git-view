extends RefCounted

## Where the script editor's minimap is currently drawing, so more than one overlay can paint onto it
## and agree on where a line sits.
##
## The minimap draws glyphs only — no gutter — so anything extra is painted over it from the CodeEdit's
## `draw` signal, which fires after TextEdit's own _draw. All static: no state, it only measures the
## CodeEdit it is handed.

## unscaled px of the lane down the minimap's left edge that the diff bars own. Anything else drawing
## on the minimap starts after it, or it paints over them.
const BAR_LANE = 3


## What the minimap is currently showing, as a row height and the first line it draws.
##
## Positions are measured from that first line, never from a probe that moves with the scroll —
## get_minimap_line_at_pos() folds the fractional scroll into its answer, so a fixed probe pixel flips
## by a line as you scroll even while a fitting minimap sits still, which is what jittered.
## Empty when the minimap has no room to draw.
#! keys h:int content_bottom:float first_line:int
static func geometry(code_edit:CodeEdit) -> Dictionary:
	# capacity, not the count actually drawn: it is floor(minimap_height / row_height), so it stays put
	# whatever the file's length, and dividing the height back by it recovers the row height
	var capacity = code_edit.get_minimap_visible_lines()
	if capacity <= 0 or code_edit.size.y <= 0.0:
		return {}

	# x is ignored by the mapping — pos(0, y) and pos(2000, y) answer the same — so it stays 0
	var margin = code_edit.get_theme_stylebox(&"normal").get_margin(SIDE_TOP)
	var margin_bottom = code_edit.get_theme_stylebox(&"normal").get_margin(SIDE_BOTTOM)

	# lines actually painted and their pixel span; the rough height places probes — the accurate one is measured below.
	var drawn = mini(code_edit.get_total_visible_line_count(), capacity)
	var h_approx = (code_edit.size.y - margin - margin_bottom) / float(capacity)
	var span = drawn * h_approx

	# measured, not modelled: margin and scroll fraction are constant additions, so they cancel in a difference.
	# Probed at fractions of the drawn span — a probe past the last line clamps to it and inflates the height.
	var ya = int(margin + span * 0.2)
	var yb = int(margin + span * 0.8)
	var la = code_edit.get_minimap_line_at_pos(Vector2i(0, ya))
	var lb = code_edit.get_minimap_line_at_pos(Vector2i(0, yb))
	var between = code_edit.get_visible_line_count_in_range(la, lb) - 1
	var h_float = h_approx if between <= 0 else (yb - ya) / float(between)
	# integer height so row boundaries sit on whole pixels and the anchor does not flip on scroll; float is kept only for content extent.
	var h = maxi(1, int(round(h_float)))
	var content_bottom = drawn * h_float

	# first line the minimap paints; a fitting file never scrolls, so it stays 0 with no jitter-sensitive probe.
	var first_line = 0
	if code_edit.get_total_visible_line_count() > capacity:
		# steady only where (y - margin) is a multiple of h; probe the first full row below the margin and median ±1px.
		# QUIRK: the answered line is treated as pixel 0, not shifted by the margin — the margin is real to the query, not the paint.
		var c: int = int(margin) + h
		var samples: PackedInt32Array = [
			code_edit.get_minimap_line_at_pos(Vector2i(0, c - 1)),
			code_edit.get_minimap_line_at_pos(Vector2i(0, c)),
			code_edit.get_minimap_line_at_pos(Vector2i(0, c + 1)),
		]
		samples.sort()
		first_line = samples[1]

	return {
		Keys.H: h,
		Keys.CONTENT_BOTTOM: content_bottom,
		Keys.FIRST_LINE: first_line,
	}


## Where the minimap draws a line, counted in rows from the first drawn line (which sits at pixel 0).
## get_visible_line_count_in_range() makes this arithmetic rather than a search, folds and wraps included.
static func line_y(code_edit:CodeEdit, geo:Dictionary, line:int) -> float:
	# overlays rebuild on debounce, so a fresh deletion can still reference a gone line — clamp to avoid the error.
	var last = code_edit.get_line_count() - 1
	var first:int = clampi(geo[Keys.FIRST_LINE], 0, last)
	line = clampi(line, 0, last)
	var rows:int
	if line >= first:
		rows = code_edit.get_visible_line_count_in_range(first, line) - 1
	else:
		rows = -(code_edit.get_visible_line_count_in_range(line, first) - 1)
	return float(rows * int(geo[Keys.H]))


## The minimap's left edge, clearing the vertical scrollbar too.
static func left_x(code_edit:CodeEdit) -> float:
	var x = code_edit.size.x - code_edit.get_minimap_width()
	var v_scroll = code_edit.get_v_scroll_bar()
	if is_instance_valid(v_scroll):
		x -= v_scroll.size.x
	return x


## Where drawn content ends, for the bottom clamp. Short files end above the bottom; long files are inset by the margin.
static func bottom(code_edit:CodeEdit, geo:Dictionary) -> float:
	var margin_bottom = code_edit.get_theme_stylebox(&"normal").get_margin(SIDE_BOTTOM)
	return minf(code_edit.size.y - margin_bottom, geo[Keys.CONTENT_BOTTOM])


class Keys:
	## one entry of geometry()
	const H = &"row_height"
	## the drawn content's pixel extent from the minimap top, for the bottom clamp
	const CONTENT_BOTTOM = &"content_bottom"
	## the first line the minimap paints (0 unless scrolled); the reference for every mark
	const FIRST_LINE = &"first_line"
