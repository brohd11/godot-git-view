extends ItemList

## An ItemList whose rows are an item text plus any number of overlay segments drawn on top of it.
##
## ItemList gives one string and one colour per row, so the item text is left to it — which keeps
## selection and highlighting working — and the segments are drawn over the top. The item text leads,
## and _fit_texts() ellipsizes it so the segments have room; _rows keeps the full string.
##
## A row may carry no item text, making every segment an overlay. That is the only way to give the
## leading string a face of its own, since ItemList has one font for all of its text. See ROW_SPACER.

const UtilsLocal = preload("res://addons/script_dock/src/utils/utils_local.gd")
const UtilsRemote = preload("res://addons/git_view/src/util/utils_remote.gd")

const DIM_ALPHA = 0.5

## A row's height is MAX(icon, text) and an empty string shapes to nothing, so a text-less row would
## collapse. A space is text. Segment 0 is measured from the real, empty string, so it costs only the
## row height it is here for.
const ROW_SPACER = " "
## unscaled px between one segment and the next
const GAP = 8
## unscaled px kept clear at the right, so a right aligned segment does not sit flush against the end
const RIGHT_PAD = 4
## unscaled px below which a flex segment is dropped rather than trimmed — a two letter stub of a
## path is noise, not information
const MIN_FLEX_WIDTH = 36
const ELLIPSIS = "…"

## Where the overlay's baseline sits between the top and the bottom of the row. Tuned by eye, not
## derived: ItemList draws its item text a shade below true centre, off theme constants there is no
## way to query, and the overlay has to match or the two read as misaligned.
const BASELINE_CENTER = 0.57

enum Align {
	LEFT,  ## flows immediately after whatever precedes it
	RIGHT, ## packed against the right edge
}

## unscaled px below which segments swap to their `compact` string. 0 disables.
var compact_below:float = 0.0

# overlay data, index aligned with the ItemList items. Each row is an Array of segment dicts, each
# segment's `text` the full, unellipsized string.
var _rows:Array[Array] = []

# resolved geometry per row, rebuilt by _fit_texts and only read by _draw
var _layouts:Array[Array] = []

var _fit_queued:bool = false


## One overlay segment. Every key is optional and resolves to its default where it is read, not here.
##
##   text          ""            the string to draw
##   color         white         drawn colour, and an icon segment's modulate
##   align         Align.LEFT    LEFT flows on from the segment before it; RIGHT packs to the edge
##   flex          false         ellipsizes to absorb the leftover room. At most one per row.
##   compact       ""            shorter stand-in, swapped in when narrower than `compact_below`
##   compact_icon  null          as `compact` and wins over it. Fixed width: never flexes.
##   font          the list's    only needed where the segment must differ from the item text
##   font_size     the list's

#! keys text:String color:Color align:Align flex:bool compact:String compact_icon:Texture2D
#! keys font:Font font_size:int
static func segment(params:={}) -> Dictionary:
	return params


func _ready() -> void:
	resized.connect(_queue_fit)

# A segment's own face, or the list's. Every measure and draw goes through here, so a segment can
# never be measured with one font and drawn with another.
func _seg_font(seg:Dictionary) -> Font:
	var font = seg.get(&"font")
	return font if font != null else get_theme_font(&"font")


func _seg_font_size(seg:Dictionary) -> int:
	var font_size:int = seg.get(&"font_size", 0)
	return font_size if font_size > 0 else get_theme_font_size(&"font_size")


func clear_rows() -> void:
	clear()
	_rows.clear()
	_layouts.clear()
	queue_redraw()


# What ItemList is given to shape, which is not always what the overlay lays out — see ROW_SPACER.
func _shaped_text(text:String) -> String:
	return text if not text.is_empty() else ROW_SPACER


func add_row(text:String, segments:Array, text_color = null, metadata = null, tooltip:="") -> void:
	add_item(_shaped_text(text))

	var idx = item_count - 1
	if tooltip != "":
		set_item_tooltip(idx, tooltip)
	if metadata != null:
		set_item_metadata(idx, metadata)
	if text_color != null:
		set_item_custom_fg_color(idx, text_color)

	# the item text is segment zero: it leads, and it is the last thing to yield
	_rows.append([segment({&"text": text})] + segments)
	_queue_fit()


func get_selected_metadata():
	var selected = get_selected_items()
	if selected.is_empty():
		return null
	return get_item_metadata(selected[0])


func get_dim_color() -> Color:
	var color = get_theme_color(&"font_color")
	color.a = DIM_ALPHA
	return color


# Rows change in batches, so coalesce into one pass per frame rather than refitting every add.
func _queue_fit() -> void:
	if _fit_queued:
		return
	_fit_queued = true
	_fit_texts.call_deferred()


# Resolve every row's geometry, ellipsizing each item text so the segments right of it have room.
# _draw only reads what this leaves in _layouts.
func _fit_texts() -> void:
	_fit_queued = false
	_layouts.clear()
	queue_redraw()

	if _rows.is_empty() or size.x <= 0:
		return # no layout yet — the resized signal will bring us back

	# ItemList lays out in its draw notification and a hidden control never draws, so on a background
	# tab the scrollbar visibility _get_right_edge() reads is stale. A redraw re-reads _layouts rather
	# than rebuilding them, so measuring against it now strands the right-most segment under the
	# scrollbar for good.
	force_update_list_size()

	var font = get_theme_font(&"font")
	var font_size = get_theme_font_size(&"font_size")

	for i in range(min(item_count, _rows.size())):
		var layout = _layout_row(_rows[i], font, font_size)
		_layouts.append(layout)
		set_item_text(i, _shaped_text(layout[0][&"draw_text"]))


# Resolve a row to a list of `{draw_text, x, width, color}`, index aligned with its segments. Segment
# 0 is the item text, whose x/width ItemList owns — only its `draw_text` is used. The item text keeps
# its natural width where it can: the flex segment absorbs the shortfall and vanishes before it.
func _layout_row(row:Array, font:Font, font_size:int) -> Array:
	var gap = GAP * EditorInterface.get_editor_scale()
	var text_x = _get_text_start_x()
	var right_edge = _get_right_edge()
	var compact = compact_below > 0.0 and size.x < compact_below * EditorInterface.get_editor_scale()

	var out:Array = []
	var flex_idx = -1

	# 1. resolve every segment's text and natural width, and find the one that yields. Segment 0 is
	# drawn by ItemList from the list's own font; the rest are measured with the face they carry
	# through to _draw.
	for i in row.size():
		var seg:Dictionary = row[i]
		var text:String = seg.get(&"text", "")
		var icon:Texture2D = null

		# the item text cannot become an icon: ItemList, not this file, draws it
		if compact and i > 0:
			icon = seg.get(&"compact_icon")
			if icon != null:
				text = "" # the icon *is* the segment now; nothing is drawn as a string
			elif not seg.get(&"compact", "").is_empty():
				text = seg[&"compact"]
		
		var seg_font = font if i == 0 else _seg_font(seg)
		var seg_font_size = font_size if i == 0 else _seg_font_size(seg)
		
		out.append({
			&"draw_text": text,
			&"icon": icon,
			&"x": 0.0,
			&"width": float(icon.get_width()) if icon != null else _string_width(seg_font, seg_font_size, text),
			&"color": seg.get(&"color", Color.WHITE),
			&"align": seg.get(&"align", Align.LEFT),
			&"font": seg_font,
			&"font_size": seg_font_size,
		})
		# an icon is a fixed size square with nothing to give up, so it cannot yield even if marked flex
		if i > 0 and seg.get(&"flex", false) and icon == null and flex_idx < 0:
			flex_idx = i

	# 2. every non-flex segment keeps its natural width; what is left over is the flex segment's.
	# A gap is only charged for a segment with something before it, which cannot key off the index:
	# on a text-less row the first *segment* leads, and would otherwise be billed a gap step 4 never
	# places, with the flex segment paying for it.
	var fixed = 0.0
	var leading = true
	for i in out.size():
		if i == flex_idx or _is_blank(out[i]):
			continue
		fixed += out[i][&"width"] + (0.0 if leading else gap)
		leading = false

	var total = right_edge - text_x
	var slack = total - fixed - (gap if flex_idx > 0 else 0.0)

	if flex_idx > 0:
		var natural = out[flex_idx][&"width"]
		if slack < MIN_FLEX_WIDTH * EditorInterface.get_editor_scale():
			out[flex_idx][&"draw_text"] = "" # dropped: a two letter stub of a path is not information
			out[flex_idx][&"width"] = 0.0
		elif natural > slack:
			out[flex_idx][&"width"] = slack

	# 3. only now, if the fixed content alone still does not fit, does the item text give way
	var overflow = fixed - total
	if overflow > 0:
		var room = maxf(out[0][&"width"] - overflow, 0.0)
		out[0][&"draw_text"] = _ellipsize(out[0][&"draw_text"], room, font, font_size)
		out[0][&"width"] = _string_width(font, font_size, out[0][&"draw_text"])

	# 4. place them: LEFT flows rightwards from the item text, RIGHT packs leftwards from the edge. A
	# text-less row has nothing to flow from, so its first segment starts flush at text_x — otherwise
	# it would sit a gap right of where every other row's item text begins.
	var left_x = text_x
	if not _is_blank(out[0]):
		left_x += out[0][&"width"] + gap

	var right_x = right_edge

	for i in range(1, out.size()):
		var placed:Dictionary = out[i]
		if _is_blank(placed):
			continue

		if placed[&"align"] == Align.RIGHT:
			right_x -= placed[&"width"]
			placed[&"x"] = right_x
			right_x -= gap
		else:
			placed[&"x"] = left_x
			left_x += placed[&"width"] + gap

	return out


func _draw() -> void:
	if _layouts.is_empty():
		return # _fit_texts is deferred and has not run yet; it will queue_redraw when it does

	# the list's own font, which ItemList draws the item text with. Segments may each carry a different
	# face, but all sit on the baseline this one defines — centring each in the row separately instead
	# is what would make them jitter against one another.
	var font = get_theme_font(&"font")
	var font_size = get_theme_font_size(&"font_size")

	# get_item_rect() and the segments' x are in unscrolled content space while the list draws itself
	# shifted by the scroll value — without this the overlay detaches from its rows on scroll
	var scroll_offset = Vector2(get_h_scroll_bar().value, get_v_scroll_bar().value)

	for i in range(min(item_count, _layouts.size())):
		var layout:Array = _layouts[i]
		var rect = get_item_rect(i, false)
		rect.position -= scroll_offset

		# draw_string takes a baseline, and ItemList sits its text a shade below the row's centre
		var ascent = font.get_ascent(font_size)
		var baseline = rect.position.y \
			+ (rect.size.y + ascent - font.get_descent(font_size)) * BASELINE_CENTER

		for j in range(1, layout.size()):
			var seg:Dictionary = layout[j]
			if _is_blank(seg):
				continue

			var x = seg[&"x"] - scroll_offset.x
			var icon:Texture2D = seg[&"icon"]

			# centred in the row, not on the baseline: an icon is a square of one size, so every row's
			# lands on the same x, which is why a letter that must line up down the list is a texture
			if icon != null:
				var side:float = seg[&"width"]
				var pos = Vector2(x, rect.position.y + (rect.size.y - side) * 0.5).round()
				draw_texture_rect(icon, Rect2(pos, Vector2(side, side)), false, seg[&"color"])
				continue

			var text:String = seg[&"draw_text"]
			var seg_font:Font = seg[&"font"]
			var seg_font_size:int = seg[&"font_size"]

			# TextLine is only needed by the segment that gave up width; draw_string is much cheaper
			if _string_width(seg_font, seg_font_size, text) <= seg[&"width"]:
				draw_string(seg_font, Vector2(x, baseline), text,
					HORIZONTAL_ALIGNMENT_LEFT, -1, seg_font_size, seg[&"color"])
				continue

			# draw_string can only hard clip, which chops text mid word and reads as a glitch.
			# TextLine is the only thing that will ellipsize.
			var line = TextLine.new()
			line.add_string(text, seg_font, seg_font_size)
			line.width = seg[&"width"]
			line.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS

			# TextLine.draw takes the top of the line box where draw_string takes a baseline; matching
			# them stops a segment jumping vertically as it swaps between the two calls
			line.draw(get_canvas_item(), Vector2(x, baseline - line.get_line_ascent()), seg[&"color"])


# A resolved segment with nothing to draw, so it takes no width and no gap. Usually a dropped flex.
func _is_blank(seg:Dictionary) -> bool:
	return seg[&"icon"] == null and seg[&"draw_text"].is_empty()


# ItemList lays text out at the item rect plus the icon column. These rows carry no icon of its own,
# so that column collapses to one h_separation — call set_item_icon and this must grow by its width.
func _get_text_indent() -> float:
	return get_theme_constant(&"h_separation")


func _get_text_start_x() -> float:
	var indent = _get_text_indent() * 0.5 # half lands exactly right; ItemList appears to split the separation across both ends
	return get_theme_stylebox(&"panel").get_margin(SIDE_LEFT) + indent


# RIGHT_PAD is applied here, not where a right aligned segment is packed, so the one value feeds both
# that position and the width the flex segment is sized against — otherwise flex grows into it.
func _get_right_edge() -> float:
	var right_edge = size.x - get_theme_stylebox(&"panel").get_margin(SIDE_RIGHT)
	if get_v_scroll_bar().visible:
		right_edge -= get_v_scroll_bar().size.x
	return right_edge - RIGHT_PAD * EditorInterface.get_editor_scale()


func _string_width(font:Font, font_size:int, text:String) -> float:
	if text.is_empty():
		return 0.0
	return font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x


func _ellipsize(text:String, max_width:float, font:Font, font_size:int) -> String:
	if max_width <= 0:
		return ""
	if _string_width(font, font_size, text) <= max_width:
		return text

	var budget = max_width - _string_width(font, font_size, ELLIPSIS)
	if budget <= 0:
		return ELLIPSIS

	# longest prefix that still fits
	var low = 0
	var high = text.length()
	while low < high:
		@warning_ignore("integer_division")
		var mid = (low + high + 1) / 2
		if _string_width(font, font_size, text.substr(0, mid)) <= budget:
			low = mid
		else:
			high = mid - 1

	return text.substr(0, low).strip_edges(false, true) + ELLIPSIS
