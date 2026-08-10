extends Node

## draws `#region` labels over the active CodeEdit minimap.


const UtilsLocal = preload("res://addons/git_view/src/util/utils_local.gd")
const UtilsRemote = preload("res://addons/git_view/src/util/utils_remote.gd")
const MinimapGeometry = preload("res://addons/git_view/src/minimap/minimap_geometry.gd")
const GeoKeys = MinimapGeometry.Keys

const SettingHelperEditor = UtilsRemote.SettingHelperEditor
const ScriptListManager = UtilsRemote.ScriptListManager

const LABEL_FONT_SIZE_MIN = 9
const LABEL_FONT_SIZE_MAX = 10

const LABEL_PAD_H = 3
const LABEL_PAD_V = 2

const LABEL_ALPHA = 0.9
const LABEL_BACK_ALPHA = 0.7

const RESCAN_DEBOUNCE = 0.5

var setting_helper:SettingHelperEditor

var _enabled:bool = true

var _editors:Dictionary = {}

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

func apply_settings() -> void:
	for id in _editors:
		_editors[id][Keys.CACHE_KEY] = null
		_editors[id][Keys.VERSION] += 1
		var code_edit:CodeEdit = _editors[id][Keys.CODE_EDIT]
		if is_instance_valid(code_edit):
			code_edit.queue_redraw()


func clean_up() -> void:
	_teardown()


func _teardown() -> void:
	for id in _editors:
		_detach_signals(_editors[id][Keys.CODE_EDIT])
	_editors.clear()
	_dirty.clear()

#endregion


#region attaching

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

	if not code_edit.text_changed.is_connected(_on_text_changed):
		code_edit.text_changed.connect(_on_text_changed.bind(code_edit))

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
	state[Keys.VERSION] += 1
	code_edit.queue_redraw()


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

	return regions


func _region_name(code_edit:CodeEdit, line:int) -> String:
	var text = code_edit.get_line(line)
	var tag = code_edit.get_code_region_start_tag()
	var idx = text.find(tag)
	if idx < 0:
		return ""
	return text.substr(idx + tag.length()).strip_edges()

#endregion


#region drawing

func _draw_regions(code_edit:CodeEdit) -> void:
	if not _enabled:
		return
	var state:Dictionary = _editors.get(code_edit.get_instance_id(), {})
	if state.is_empty() or state[Keys.REGIONS].is_empty():
		return
	if not code_edit.is_drawing_minimap():
		return

	var font = code_edit.get_theme_font(&"font")
	if font == null:
		return
	var color = Color(code_edit.get_theme_color(&"font_color"), LABEL_ALPHA)
	var back_color = Color(code_edit.get_theme_color(&"background_color"), LABEL_BACK_ALPHA)

	for block in _labels(code_edit, state, font):
		code_edit.draw_rect(block[Keys.RECT], back_color)
		code_edit.draw_string(font, block[Keys.ORIGIN], block[Keys.TEXT],
			HORIZONTAL_ALIGNMENT_LEFT, -1, block[Keys.FONT_SIZE], color)


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


func _build_labels(code_edit:CodeEdit, state:Dictionary, geometry:Dictionary, font:Font) -> Array:
	var labels:Array = []
	var scale = EditorInterface.get_editor_scale()
	
	var pad_h_scaled = LABEL_PAD_H * scale
	var bar_lane_scaled = MinimapGeometry.BAR_LANE * scale

	var rect_x = MinimapGeometry.left_x(code_edit) + bar_lane_scaled
	var rect_w = code_edit.get_minimap_width() - bar_lane_scaled
	
	var avail = rect_w - 2 * pad_h_scaled
	if avail <= 0.0:
		return labels

	var bottom = MinimapGeometry.bottom(code_edit, geometry)
	var pad_v_scaled = LABEL_PAD_V * scale

	var last_bottom := -INF
	for region in state[Keys.REGIONS]:
		var name_text:String = region[Keys.NAME]
		if name_text.is_empty():
			continue # nothing to label

		var layout = _layout(name_text, font, avail)
		var text:String = layout[Keys.TEXT]
		var font_size:int = layout[Keys.FONT_SIZE]

		var ascent = font.get_ascent(font_size)
		var text_w = font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
		var block_h = font.get_height(font_size) + 2 * pad_v_scaled

		var top = MinimapGeometry.line_y(code_edit, geometry, region[Keys.START]) - block_h * 0.5
		if top < 0.0 or top + block_h > bottom:
			continue
		if top < last_bottom:
			continue
		last_bottom = top + block_h

		var text_origin = Vector2(rect_x + pad_h_scaled, top + pad_v_scaled + ascent)
		var block_rect = Rect2(rect_x, top, minf(text_w + 2 * pad_h_scaled, rect_w), block_h)

		labels.append({
			Keys.RECT: block_rect,
			Keys.ORIGIN: text_origin,
			Keys.TEXT: text,
			Keys.FONT_SIZE: font_size,
		})

	return labels


#! keys text:String font_size:int
func _layout(text:String, font:Font, avail:float) -> Dictionary:
	var size = _size_to_fit(text, font, avail)
	if size >= _scaled(LABEL_FONT_SIZE_MIN):
		return {Keys.TEXT: text, Keys.FONT_SIZE: size}

	size = _scaled(LABEL_FONT_SIZE_MIN)
	return {Keys.TEXT: _fit(text, font, size, avail), Keys.FONT_SIZE: size}


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
	const CODE_EDIT = &"code_edit"
	const REGIONS = &"regions"
	const VERSION = &"version"
	const CACHE = &"label_cache"
	const CACHE_KEY = &"label_cache_key"

	const RECT = &"rect"
	const ORIGIN = &"origin"
	const TEXT = &"text"
	const FONT_SIZE = &"font_size"

	const START = &"start"
	const END = &"end"
	const DEPTH = &"depth"
	const NAME = &"name"
