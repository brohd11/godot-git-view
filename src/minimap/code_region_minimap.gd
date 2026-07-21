extends Node

## Writes each `#region`'s name across the script editor's minimap, the way VS Code does.
##
## A navigation aid and not a git signal: it attaches to whatever script is open, in a repo or not,
## so it shares nothing with the diff gutter but the minimap geometry both draw against. No baseline,
## no thread, no gutter column — just a line walk on a debounce and a draw.

const UtilsLocal = preload("res://addons/git_view/src/util/utils_local.gd")
const UtilsRemote = preload("res://addons/git_view/src/util/utils_remote.gd")
const MinimapGeometry = preload("res://addons/git_view/src/minimap/minimap_geometry.gd")
const GeoKeys = MinimapGeometry.Keys

const SettingHelperEditor = UtilsRemote.SettingHelperEditor
const ScriptListManager = UtilsRemote.ScriptListManager

## unscaled px. A name is sized up to fill the minimap's width, so these bound the result rather than
## setting it. The floor is legibility — a name that cannot fit at it is ellipsized, not shrunk on.
const LABEL_FONT_SIZE_MIN = 9
## The one number to turn if the labels read too small, or start swamping the code they sit on.
const LABEL_FONT_SIZE_MAX = 10

## unscaled px of air inside the backing rect
const LABEL_PAD_H = 3
const LABEL_PAD_V = 2

## The label is over the code the minimap is there to show, so it does not get to be opaque.
const LABEL_ALPHA = 0.9
## ...and neither does the rect behind it, which dims that code rather than replacing it
const LABEL_BACK_ALPHA = 0.7

## Time before rescanning on text changed
const RESCAN_DEBOUNCE = 0.5

var setting_helper:SettingHelperEditor

## Set from editor settings
var _enabled:bool = true

# CodeEdits we draw on, by instance id; see Keys for an entry's shape
var _editors:Dictionary = {}

# instance ids whose buffer has moved since the last scan
var _dirty:Dictionary = {}
var _debounce:Timer


func _ready() -> void:
	_debounce = Timer.new()
	_debounce.one_shot = true
	_debounce.wait_time = RESCAN_DEBOUNCE
	_debounce.timeout.connect(_on_debounce_timeout)
	add_child(_debounce)

	ScriptEditorRef.subscribe(ScriptEditorRef.Event.TAB_CHANGED, _on_script_editor_tab_changed, 1)

	setting_helper = SettingHelperEditor.new()
	setting_helper.subscribe_property(self, &"_enabled", UtilsLocal.EditorSet.MINIMAP_REGIONS, true)
	setting_helper.initialize()
	setting_helper.settings_changed.connect(apply_settings, 1)

	_attach_current_code_edit()


#region lifecycle

## Call after changing _enabled. What is drawn is as much a function of the setting as of the buffer,
## and a settings change touches no text — so nothing would otherwise bump VERSION, and the cache
## would keep serving the labels the setting just turned off.
func apply_settings() -> void:
	for id in _editors:
		_editors[id][Keys.CACHE_KEY] = null
		_editors[id][Keys.VERSION] += 1
		var code_edit:CodeEdit = _editors[id][Keys.CODE_EDIT]
		if is_instance_valid(code_edit):
			code_edit.queue_redraw()


func clean_up() -> void:
	_teardown()


# fine to run twice if needed (clean_up + predelete)
func _teardown() -> void:
	for id in _editors:
		_detach_signals(_editors[id][Keys.CODE_EDIT])
	_editors.clear()
	_dirty.clear()

#endregion


#region attaching

# using tab changed allows for any text doc type
func _on_script_editor_tab_changed():
	_attach_current_def.call_deferred()

func _attach_current_code_edit():
	_attach_current_def.call_deferred()

func _attach_current_def():
	var sl_man = ScriptListManager.get_instance()
	var current_editor = sl_man.get_current_script_editor()
	if not is_instance_valid(current_editor):
		return
	if not current_editor.has_method("get_base_editor"):
		return # excludes help docs
	_attach(current_editor.get_base_editor())


func _attach(code_edit:CodeEdit) -> void:
	if not is_instance_valid(code_edit):
		return

	_prune()

	var id = code_edit.get_instance_id()
	var state:Dictionary = _editors.get(id, {})
	state[Keys.CODE_EDIT] = code_edit
	if not state.has(Keys.REGIONS):
		state[Keys.REGIONS] = []
		state[Keys.VERSION] = 0
		state[Keys.CACHE] = []
		state[Keys.CACHE_KEY] = null
	_editors[id] = state

	# not ScriptEditorRef, background scripts (tabs) should update too
	if not code_edit.text_changed.is_connected(_on_text_changed):
		code_edit.text_changed.connect(_on_text_changed.bind(code_edit))

	# the minimap draws glyphs and nothing else, so the labels have to be painted over it. The draw
	# signal fires after TextEdit's own _draw, so this lands on top.
	if not code_edit.draw.is_connected(_draw_regions):
		code_edit.draw.connect(_draw_regions.bind(code_edit))

	_rescan(id)


func _detach_signals(code_edit:CodeEdit) -> void:
	if not is_instance_valid(code_edit):
		return # its tab was closed
	if code_edit.text_changed.is_connected(_on_text_changed):
		code_edit.text_changed.disconnect(_on_text_changed.bind(code_edit))
	if code_edit.draw.is_connected(_draw_regions):
		code_edit.draw.disconnect(_draw_regions.bind(code_edit))
	code_edit.queue_redraw()


# Editors whose tab has closed
func _prune() -> void:
	for id in _editors.keys():
		if not is_instance_valid(_editors[id][Keys.CODE_EDIT]):
			_editors.erase(id)
			_dirty.erase(id)

#endregion


#region scanning

func _on_text_changed(code_edit:CodeEdit) -> void:
	if not is_instance_valid(code_edit):
		return
	_dirty[code_edit.get_instance_id()] = true
	_debounce.start(RESCAN_DEBOUNCE)


func _on_debounce_timeout() -> void:
	for id in _dirty:
		_rescan(id)
	_dirty.clear()


func _rescan(id:int) -> void:
	var state:Dictionary = _editors.get(id, {})
	if state.is_empty():
		return

	var code_edit:CodeEdit = state[Keys.CODE_EDIT]
	if not is_instance_valid(code_edit):
		_editors.erase(id)
		_dirty.erase(id)
		return

	state[Keys.REGIONS] = _scan(code_edit)
	# what the draw cache watches — an int to compare, rather than the array itself
	state[Keys.VERSION] += 1
	code_edit.queue_redraw()


# The file's regions in start order, as {START, END, DEPTH, NAME}. CodeEdit answers only "does this
# line open/close one", so the nesting is ours to track. END is unread today — nothing draws a span —
# but resolving it here lets one be added later without walking the buffer again, and DEPTH is what
# an innermost-wins pass sorts on.
func _scan(code_edit:CodeEdit) -> Array:
	var regions:Array = []
	var open:Array = [] # indices into regions, innermost last
	var last_line = code_edit.get_line_count() - 1

	for i in code_edit.get_line_count():
		if code_edit.is_line_code_region_start(i):
			regions.append({
				Keys.START: i,
				Keys.END: last_line, # until a matching end says otherwise
				Keys.DEPTH: open.size(),
				Keys.NAME: _region_name(code_edit, i),
			})
			open.append(regions.size() - 1)
		elif code_edit.is_line_code_region_end(i) and not open.is_empty():
			regions[open.pop_back()][Keys.END] = i

	# anything still open is a region mid-typing; it keeps the last_line end it was created with
	return regions


# Everything after the start tag on the line. The tag is the bare word ("region"); find() past it
# works either way, so a tag arriving as "#region" needs no special case.
func _region_name(code_edit:CodeEdit, line:int) -> String:
	var text = code_edit.get_line(line)
	var tag = code_edit.get_code_region_start_tag()
	var idx = text.find(tag)
	if idx < 0:
		return ""
	return text.substr(idx + tag.length()).strip_edges()

#endregion


#region drawing

# Runs on the CodeEdit's draw signal, after TextEdit drew itself; the CodeEdit is not ours to free,
# hence the disconnect in _detach_signals(). A caret blink redraws twice a second, hence the cache.
func _draw_regions(code_edit:CodeEdit) -> void:
	if not _enabled:
		return
	var state:Dictionary = _editors.get(code_edit.get_instance_id(), {})
	# a file with no regions is the common case and this is the whole cost of it
	if state.is_empty() or state[Keys.REGIONS].is_empty():
		return
	if not code_edit.is_drawing_minimap():
		return

	var font = code_edit.get_theme_font(&"font")
	if font == null:
		return
	var color = Color(code_edit.get_theme_color(&"font_color"), LABEL_ALPHA)
	var back_color = Color(code_edit.get_theme_color(&"background_color"), LABEL_BACK_ALPHA)

	# every measurement was made in _build_labels and cached — this loop only paints
	for block in _labels(code_edit, state, font):
		code_edit.draw_rect(block[Keys.RECT], back_color)
		code_edit.draw_string(font, block[Keys.ORIGIN], block[Keys.TEXT],
			HORIZONTAL_ALIGNMENT_LEFT, -1, block[Keys.FONT_SIZE], color)


# The label blocks, from the cache when nothing that moves them has changed. The key is what the
# geometry is a function of — the anchor line rather than get_v_scroll(), since the minimap only
# moves in whole rows and the raw float would miss every frame.
func _labels(code_edit:CodeEdit, state:Dictionary, font:Font) -> Array:
	var geometry = MinimapGeometry.geometry(code_edit)
	if geometry.is_empty():
		return []

	var key = [
		state[Keys.VERSION],
		code_edit.size,
		geometry[GeoKeys.FIRST_LINE],
		code_edit.get_total_visible_line_count(),
	]
	if state.get(Keys.CACHE_KEY) == key:
		return state[Keys.CACHE]

	var labels = _build_labels(code_edit, state, geometry, font)
	state[Keys.CACHE_KEY] = key
	state[Keys.CACHE] = labels
	return labels


# One block per region, laid out and measured. See Keys for a block's shape.
func _build_labels(code_edit:CodeEdit, state:Dictionary, geometry:Dictionary, font:Font) -> Array:
	var labels:Array = []
	var scale = EditorInterface.get_editor_scale()
	
	var pad_h_scaled = LABEL_PAD_H * scale
	var bar_lane_scaled = MinimapGeometry.BAR_LANE * scale

	# past the lane the diff bars own, so a label never hides one
	var rect_x = MinimapGeometry.left_x(code_edit) + bar_lane_scaled
	var rect_w = code_edit.get_minimap_width() - bar_lane_scaled
	
	var avail = rect_w - 2 * pad_h_scaled
	if avail <= 0.0:
		return labels

	var bottom = MinimapGeometry.bottom(code_edit, geometry)
	var pad_v_scaled = LABEL_PAD_V * scale

	# regions come out of _scan in start order, so one pass places them top-down
	var last_bottom := -INF
	for region in state[Keys.REGIONS]:
		var name_text:String = region[Keys.NAME]
		if name_text.is_empty():
			continue # nothing to label

		var layout = _layout(name_text, font, avail)
		var text:String = layout[Keys.TEXT]
		var font_size:int = layout[Keys.FONT_SIZE]

		# measure THIS string — the one that gets drawn, already ellipsized; the raw name would size the
		# rect for text that is not there
		var ascent = font.get_ascent(font_size)
		var text_w = font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
		var block_h = font.get_height(font_size) + 2 * pad_v_scaled

		# the block straddles its line rather than hanging under it: anchoring the top puts the label's
		# centre half a block below the tag it marks
		var top = MinimapGeometry.line_y(code_edit, geometry, region[Keys.START]) - block_h * 0.5
		# the block is off the top of the minimap, or would hang past the drawn content
		if top < 0.0 or top + block_h > bottom:
			continue
		# two regions a few lines apart sit a couple of px apart on the minimap — the second would
		# print straight through the first, so it is dropped rather than smeared
		if top < last_bottom:
			continue
		last_bottom = top + block_h

		# the baseline sits a pad below the block's top, the ascent down from the text's top; the block's
		# height is ascent + descent + matching pad, so the text is padded equally and the rect cannot drift
		var text_origin = Vector2(rect_x + pad_h_scaled, top + pad_v_scaled + ascent)
		# hugs the text rather than running the full width — a short name should not black out the map
		var block_rect = Rect2(rect_x, top, minf(text_w + 2 * pad_h_scaled, rect_w), block_h)

		labels.append({
			Keys.RECT: block_rect,
			Keys.ORIGIN: text_origin,
			Keys.TEXT: text,
			Keys.FONT_SIZE: font_size,
		})

	return labels


# How to set a name on the minimap: one line, sized up to fill the width, ellipsized if it cannot fit
# even at the floor.
#! keys text:String font_size:int
func _layout(text:String, font:Font, avail:float) -> Dictionary:
	var size = _size_to_fit(text, font, avail)
	if size >= _scaled(LABEL_FONT_SIZE_MIN):
		return {Keys.TEXT: text, Keys.FONT_SIZE: size}

	# too long for the width at a legible size — shrinking further would only make it unreadable AND
	# still not fit, so hold the floor and cut the text instead
	size = _scaled(LABEL_FONT_SIZE_MIN)
	return {Keys.TEXT: _fit(text, font, size, avail), Keys.FONT_SIZE: size}


# The largest font size the text still fits at, capped at LABEL_FONT_SIZE_MAX. get_string_size is
# near-linear in size, so one estimate lands beside the answer and the loop only walks off the rounding.
func _size_to_fit(text:String, font:Font, avail:float) -> int:
	var max_size = _scaled(LABEL_FONT_SIZE_MAX)
	var width = font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, max_size).x
	if width <= 0.0:
		return max_size

	var size = clampi(int(max_size * avail / width), 1, max_size)
	while size < max_size and _width_at(text, font, size + 1) <= avail:
		size += 1
	while size > 1 and _width_at(text, font, size) > avail:
		size -= 1
	return size


func _width_at(text:String, font:Font, font_size:int) -> float:
	return font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x


func _scaled(unscaled:int) -> int:
	return maxi(1, int(unscaled * EditorInterface.get_editor_scale()))


# draw_string's width param clips but does not ellipsize, so the cut is ours to make
func _fit(text:String, font:Font, font_size:int, avail:float) -> String:
	if font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x <= avail:
		return text

	var ellipsis = "…"
	var width = avail - font.get_string_size(ellipsis, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	if width <= 0.0:
		return ""

	var cut = text
	while not cut.is_empty():
		cut = cut.substr(0, cut.length() - 1)
		if font.get_string_size(cut, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x <= width:
			break
	return cut.strip_edges(false, true) + ellipsis

#endregion


class Keys:
	## one entry of _editors
	const CODE_EDIT = &"code_edit"
	## the file's regions, as returned by _scan()
	const REGIONS = &"regions"
	## bumped whenever REGIONS is rebuilt, so the draw cache has an int to compare
	const VERSION = &"version"
	## the resolved label blocks, and what they were computed for
	const CACHE = &"label_cache"
	const CACHE_KEY = &"label_cache_key"

	## one label block, as built by _build_labels()
	## the backing rect, spanning the minimap bar the diff bars' lane
	const RECT = &"rect"
	## the text's baseline, a pad below the rect's top
	const ORIGIN = &"origin"
	## also one entry of _layout(): the name as it will actually be drawn, ellipsized if it had to be
	const TEXT = &"text"
	const FONT_SIZE = &"font_size"

	## one entry of REGIONS
	const START = &"start"
	## the matching endregion's line, or the file's last line while the region is still open. Unread
	## until something draws a span rather than a label.
	const END = &"end"
	## how many regions enclose this one, 0 at the top level
	const DEPTH = &"depth"
	const NAME = &"name"
