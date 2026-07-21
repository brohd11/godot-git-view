extends RefCounted

## Where the script editor's minimap is currently drawing, so more than one overlay can paint onto it
## and agree on where a line sits.
##
## The minimap draws glyphs and nothing else — it has no notion of a gutter, so anything extra has to
## be painted over it from the CodeEdit's `draw` signal, which fires after TextEdit's own _draw.
## Everything here is static: it holds no state, it only measures the CodeEdit it is handed.

## unscaled px of the lane down the minimap's left edge that the diff bars own. Anything else drawing
## on the minimap starts after it, or it paints over them.
const BAR_LANE = 3


## What the minimap is currently showing, as a row height and the first line it draws.
##
## Positions are measured from that first line, never from a probe that moves with the scroll:
## get_minimap_line_at_pos() folds the fractional part of the scroll into its answer, so a fixed probe
## pixel flips by a line as you scroll even while a fitting minimap sits still — which is what jittered.
##
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

	# the lines the minimap actually paints, and the pixel span they cover. A rough row height from the
	# capacity is enough to place the probes — the accurate one comes from measuring below.
	var drawn = mini(code_edit.get_total_visible_line_count(), capacity)
	var h_approx = (code_edit.size.y - margin - margin_bottom) / float(capacity)
	var span = drawn * h_approx

	# measured, not modelled: the margin and the scroll fraction are constant additions, so they cancel
	# in a difference. Probed at fractions of the drawn span, not fixed offsets, so both points land on a
	# real line even on a short file — a probe past the last line clamps to it and inflates the height.
	var ya = int(margin + span * 0.2)
	var yb = int(margin + span * 0.8)
	var la = code_edit.get_minimap_line_at_pos(Vector2i(0, ya))
	var lb = code_edit.get_minimap_line_at_pos(Vector2i(0, yb))
	var between = code_edit.get_visible_line_count_in_range(la, lb) - 1
	var h_float = h_approx if between <= 0 else (yb - ya) / float(between)
	# an integer row height for positioning: it puts the row boundaries on whole pixels, so the anchor
	# probe lands cleanly on one and get_minimap_line_at_pos does not flip it back and forth on a scroll.
	# the float is kept only for the content extent below, which never feeds the probe.
	var h = maxi(1, int(round(h_float)))
	var content_bottom = drawn * h_float

	# the first line the minimap paints. A fitting file (the common case) never scrolls its minimap, so
	# it is a hard 0 — no scroll-sensitive probe, nothing for a mark to jitter with.
	var first_line = 0
	if code_edit.get_total_visible_line_count() > capacity:
		# get_minimap_line_at_pos answers floor((y - margin)/h + scroll_fraction), so it is steady only
		# where (y - margin) is a whole multiple of the row height — off a multiple the fraction tips the
		# floor across a line as you scroll, which is the jitter. Probe the FIRST full row below the margin
		# (y - margin == h, a multiple, and clear of the top edge where y == margin dips on a low fraction),
		# median a ±1px window to absorb any rounding when h is not exactly integral, then drop that one row.
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
	# an overlay's lines are rebuilt on a debounce, so on a fresh deletion they can still index a line
	# the buffer no longer has — get_visible_line_count_in_range errors on that, so clamp
	var last = code_edit.get_line_count() - 1
	var first:int = clampi(geo[Keys.FIRST_LINE], 0, last)
	line = clampi(line, 0, last)
	var rows:int
	if line >= first:
		rows = code_edit.get_visible_line_count_in_range(first, line) - 1
	else:
		rows = -(code_edit.get_visible_line_count_in_range(line, first) - 1)
	return float(rows * int(geo[Keys.H]))


## The minimap's left edge. The minimap is hard coded to clear the vertical scrollbar, so that always
## comes off too.
static func left_x(code_edit:CodeEdit) -> float:
	var x = code_edit.size.x - code_edit.get_minimap_width()
	var v_scroll = code_edit.get_v_scroll_bar()
	if is_instance_valid(v_scroll):
		x -= v_scroll.size.x
	return x


## Where the drawn content ends, for the bottom clamp. Not code_edit.size.y: a short file's minimap ends
## well above the bottom, and a long one is inset by the bottom margin — either way a mark past it should
## clip, not fill down.
static func bottom(code_edit:CodeEdit, geo:Dictionary) -> float:
	var margin_bottom = code_edit.get_theme_stylebox(&"normal").get_margin(SIDE_BOTTOM)
	return minf(code_edit.size.y - margin_bottom, geo[Keys.CONTENT_BOTTOM])


class Keys:
	## one entry of geometry()
	const H = &"row_height"
	## the drawn content's pixel extent from the minimap top, for the bottom clamp
	const CONTENT_BOTTOM = &"content_bottom"
	## the first line the minimap paints (0 unless it is scrolled), the reference every mark is placed from
	const FIRST_LINE = &"first_line"
