extends RefCounted

## measures the live CodeEdit minimap for overlay drawing.


const BAR_LANE = 3


#! keys h:int content_bottom:float first_line:int
static func geometry(code_edit:CodeEdit) -> Dictionary:
	var capacity = code_edit.get_minimap_visible_lines()
	if capacity <= 0 or code_edit.size.y <= 0.0:
		return {}

	var margin = code_edit.get_theme_stylebox(&"normal").get_margin(SIDE_TOP)
	var margin_bottom = code_edit.get_theme_stylebox(&"normal").get_margin(SIDE_BOTTOM)

	var drawn = mini(code_edit.get_total_visible_line_count(), capacity)
	var h_approx = (code_edit.size.y - margin - margin_bottom) / float(capacity)
	var span = drawn * h_approx

	var ya = int(margin + span * 0.2)
	var yb = int(margin + span * 0.8)
	var la = code_edit.get_minimap_line_at_pos(Vector2i(0, ya))
	var lb = code_edit.get_minimap_line_at_pos(Vector2i(0, yb))
	var between = code_edit.get_visible_line_count_in_range(la, lb) - 1
	var h_float = h_approx if between <= 0 else (yb - ya) / float(between)
	var h = maxi(1, int(round(h_float)))
	var content_bottom = drawn * h_float

	var first_line = 0
	if code_edit.get_total_visible_line_count() > capacity:
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


static func line_y(code_edit:CodeEdit, geo:Dictionary, line:int) -> float:
	var last = code_edit.get_line_count() - 1
	var first:int = clampi(geo[Keys.FIRST_LINE], 0, last)
	line = clampi(line, 0, last)
	var rows:int
	if line >= first:
		rows = code_edit.get_visible_line_count_in_range(first, line) - 1
	else:
		rows = -(code_edit.get_visible_line_count_in_range(line, first) - 1)
	return float(rows * int(geo[Keys.H]))


#static func left_x(code_edit:CodeEdit) -> float:
	#var x = code_edit.size.x - code_edit.get_minimap_width()
	#var v_scroll = code_edit.get_v_scroll_bar()
	#if is_instance_valid(v_scroll):
		#x -= v_scroll.size.x
		#pass
	#return x

# calc based off modern theme's calc...
static func left_x(code_edit:CodeEdit) -> float:
	var style_name = &"normal" if code_edit.editable else &"read_only"
	var style = code_edit.get_theme_stylebox(style_name)
	var right_margin = floorf(style.get_margin(SIDE_RIGHT))
	var result = code_edit.size.x - right_margin - code_edit.get_minimap_width() + 2.0
	# an arbitrary number to match the other arbitratry number, this seems ok
	result -= 4 * EditorInterface.get_editor_scale()
	return result

static func bottom(code_edit:CodeEdit, geo:Dictionary) -> float:
	var margin_bottom = code_edit.get_theme_stylebox(&"normal").get_margin(SIDE_BOTTOM)
	return minf(code_edit.size.y - margin_bottom, geo[Keys.CONTENT_BOTTOM])


class Keys:
	const H = &"row_height"
	const CONTENT_BOTTOM = &"content_bottom"
	const FIRST_LINE = &"first_line"
