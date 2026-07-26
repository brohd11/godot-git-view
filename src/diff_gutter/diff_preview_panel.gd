extends PanelContainer

const UtilsLocal = preload("res://addons/git_view/src/util/utils_local.gd")
const UtilsRemote = preload("res://addons/git_view/src/util/utils_remote.gd")
const MinimapGeometry = preload("res://addons/git_view/src/minimap/minimap_geometry.gd")
const GeoKeys = MinimapGeometry.Keys

const SettingHelperEditor = UtilsRemote.SettingHelperEditor
const ScriptListManager = UtilsRemote.ScriptListManager

const GitUtil = UtilsRemote.GitUtil
const GitDiff = UtilsRemote.GitDiff

const COLOR_GREEN = Color(GitUtil.Colors.GREEN, 0.25)
const COLOR_RED = Color(GitUtil.Colors.RED, 0.25)

const PANEL_MARGIN = 4
## Cap on the panel's visible rows — a big hunk scrolls inside rather than swallowing the editor
const MAX_PREVIEW_LINES = 12
## unscaled px of the line-number gutter: side padding and the gap between the old/new columns
const NUM_PAD = 4
const NUM_GAP = 6

## _row_meta entry: origin plus the two 1-based file line numbers, -1 where a side has no line
const META_ORIGIN = &"origin"
const META_OLD = &"old"
const META_NEW = &"new"

var close_marg:MarginContainer
var close_button:Button
var code_edit:CodeEdit

var _target_code_edit:CodeEdit
var current_line:int

# side + height are decided once when shown (see _choose_anchor); _layout only repositions after,
# so the panel does not flip above/below as the user scrolls
var _anchor_below:bool = true
var _panel_height:float = 0.0

# one entry per preview row, parallel to code_edit's lines — feeds the number gutter and centering
var _row_meta:Array = []
var _num_gutter_idx:int = -1
# resolved once per hunk so the per-row draw does no theme lookups
var _num_font:Font
var _num_font_size:int
var _num_color:Color
var _num_col_w:float

func _ready() -> void:
	name = "DiffPreview"

	var sb = StyleBoxFlat.new()
	sb.content_margin_top = _scaled(PANEL_MARGIN)
	sb.content_margin_bottom = _scaled(PANEL_MARGIN)
	sb.set_content_margin_all(_scaled(PANEL_MARGIN))
	sb.bg_color = UtilsRemote.EditorColors.get_theme_color(UtilsRemote.EditorColors.ThemeColor.ACCENT)
	add_theme_stylebox_override("panel", sb)

	code_edit = CodeEdit.new()
	code_edit.syntax_highlighter = GDScriptSyntaxHighlighter.new()
	add_child(code_edit)
	code_edit.add_theme_color_override(&"font_readonly_color", Color.WHITE)
	code_edit.draw_tabs = true
	code_edit.editable = false

	# a custom gutter, not the built-in line-number one: that always counts from 1, and a hunk can
	# start anywhere in the file. This draws the real old/new numbers straight from _row_meta.
	_num_gutter_idx = code_edit.get_gutter_count()
	code_edit.add_gutter(_num_gutter_idx)
	code_edit.set_gutter_type(_num_gutter_idx, TextEdit.GUTTER_TYPE_CUSTOM)
	code_edit.set_gutter_custom_draw(_num_gutter_idx, _draw_line_nums)
	code_edit.set_gutter_draw(_num_gutter_idx, true)

	close_marg = MarginContainer.new()
	code_edit.add_child(close_marg)
	close_marg.add_theme_constant_override("margin_right", 8 * EditorInterface.get_editor_scale())
	close_marg.set_anchors_and_offsets_preset.call_deferred(Control.PRESET_TOP_RIGHT)

	close_button = Button.new()
	close_marg.add_child(close_button)
	close_button.icon = EditorInterface.get_editor_theme().get_icon(&"Close", &"EditorIcons")
	close_button.theme_type_variation = &"FlatButton"
	close_button.pressed.connect(_close)
	close_button.flat = true

	var script_tab = EditorNodeRef.get_node_ref(EditorNodeRef.Nodes.SCRIPT_EDITOR_TAB_CONTAINER)
	script_tab.tab_changed.connect(_on_editor_tab_changed)

func display_hunk(hunk:Dictionary, line:int, target_code_edit:CodeEdit):
	_target_code_edit = target_code_edit
	current_line = line

	var lines = hunk.get(GitUtil.Keys.LINES, [])
	_build_rows(hunk, lines)
	_setup_number_gutter()

	show()
	_choose_anchor()
	_layout()
	_manage_target_signals(true)

	# the preview row for the clicked new-text line (file line == line + 1), so it stays in view
	var center_row = 0
	for i in _row_meta.size():
		if _row_meta[i][META_NEW] == line + 1:
			center_row = i
			break
	code_edit.set_line_as_center_visible.call_deferred(center_row)

# Fills code_edit with the hunk text, colors +/- rows, and records each row's old/new file line
# number. Numbers are 1-based; a side with no line on a row gets -1.
func _build_rows(hunk:Dictionary, lines:Array) -> void:
	_row_meta.clear()

	var text_lines = PackedStringArray()
	for l_data in lines:
		text_lines.append(l_data.get(GitUtil.Keys.TEXT))
	code_edit.text = "\n".join(text_lines)

	# a zero count means START names the 0-based line before the change; +1 lifts it to the 1-based
	# number of the first real line. Non-zero START is already that number.
	var new_n:int = hunk.get(GitUtil.Keys.NEW_START)
	if hunk.get(GitUtil.Keys.NEW_COUNT) == 0:
		new_n += 1
	var old_n:int = hunk.get(GitUtil.Keys.OLD_START)
	if hunk.get(GitUtil.Keys.OLD_COUNT) == 0:
		old_n += 1

	for i in lines.size():
		var origin = lines[i].get(GitUtil.Keys.ORIGIN)
		var meta = {META_ORIGIN: origin, META_OLD: -1, META_NEW: -1}
		match origin:
			"+":
				meta[META_NEW] = new_n
				new_n += 1
				code_edit.set_line_background_color(i, COLOR_GREEN)
			"-":
				meta[META_OLD] = old_n
				old_n += 1
				code_edit.set_line_background_color(i, COLOR_RED)
			_:
				meta[META_OLD] = old_n
				meta[META_NEW] = new_n
				old_n += 1
				new_n += 1
		_row_meta.append(meta)

# Resolves the number font/color once and sizes the gutter to two columns wide enough for the
# largest number in the hunk, so a hunk at line 1000+ still fits.
func _setup_number_gutter() -> void:
	_num_font = code_edit.get_theme_font(&"font")
	_num_font_size = code_edit.get_theme_font_size(&"font_size")
	_num_color = code_edit.get_theme_color(&"line_number_color", &"CodeEdit")

	var max_num = 1
	for meta in _row_meta:
		max_num = maxi(max_num, maxi(meta[META_OLD], meta[META_NEW]))
	var digits = str(max_num).length()
	_num_col_w = _num_font.get_string_size("0".repeat(digits),
		HORIZONTAL_ALIGNMENT_LEFT, -1, _num_font_size).x

	var width = int(_scaled(NUM_PAD) * 2 + _num_col_w * 2 + _scaled(NUM_GAP))
	code_edit.set_gutter_width(_num_gutter_idx, width)

# Two right-aligned columns — old then new. A "-" row draws only old, "+" only new, context both.
func _draw_line_nums(line:int, _gutter:int, rect:Rect2) -> void:
	if line < 0 or line >= _row_meta.size() or _num_font == null:
		return
	var meta = _row_meta[line]
	var baseline_y = rect.position.y \
		+ (rect.size.y - _num_font.get_height(_num_font_size)) * 0.5 \
		+ _num_font.get_ascent(_num_font_size)
	var left_x = rect.position.x + _scaled(NUM_PAD)
	var right_x = left_x + _num_col_w + _scaled(NUM_GAP)
	if meta[META_OLD] >= 0:
		code_edit.draw_string(_num_font, Vector2(left_x, baseline_y), str(meta[META_OLD]),
			HORIZONTAL_ALIGNMENT_RIGHT, _num_col_w, _num_font_size, _num_color)
	if meta[META_NEW] >= 0:
		code_edit.draw_string(_num_font, Vector2(right_x, baseline_y), str(meta[META_NEW]),
			HORIZONTAL_ALIGNMENT_RIGHT, _num_col_w, _num_font_size, _num_color)

# Decides the anchor side and height once, when the panel is shown. Prefers below; flips above only
# when the capped panel will not fit below, and falls back to the roomier side (clamped) when it
# fits on neither. Frozen after this so scrolling does not flip the panel from side to side.
func _choose_anchor() -> void:
	if not is_instance_valid(_target_code_edit):
		return
	var line_h = _target_code_edit.get_line_height()
	var y0 = _target_code_edit.get_pos_at_line_column(current_line, 0).y
	var view_h = _target_code_edit.size.y

	# capped so a big hunk scrolls inside the panel rather than filling the whole side
	var want = line_h * mini(_row_meta.size(), MAX_PREVIEW_LINES) + 2 * _scaled(PANEL_MARGIN)
	var space_below = view_h - (y0 + line_h)
	var space_above = y0

	if space_below >= want:
		_anchor_below = true
		_panel_height = want
	elif space_above >= want:
		_anchor_below = false
		_panel_height = want
	elif space_below >= space_above:
		_anchor_below = true
		_panel_height = space_below
	else:
		_anchor_below = false
		_panel_height = space_above

# Repositions the panel against the clicked line's current on-screen spot, keeping the side and
# height chosen in _choose_anchor. Re-run on scroll and resize, so it follows the editor without
# re-deciding the side. Width still tracks the editor so a resize is picked up.
func _layout() -> void:
	if not is_instance_valid(_target_code_edit):
		return
	
	# the clicked line scrolled out of view — nothing to anchor to, so drop out of sight but keep
	# state and signals so scrolling it back re-shows the panel. Checked against the visible-line range
	# (any part visible): _last_full_ would exclude the file's last line, which can never be scrolled to
	# be fully visible, so a diff on it would hide once and never come back.
	var is_floored = false
	var lc_floor = _target_code_edit.get_line_count() - 3
	#^ Issue when clicked on last line, get_last_fill_visible_line does not report correctly
	#^ this will ensure the last line both shows upp again, and draws at the bottom
	if current_line > lc_floor and _target_code_edit.get_last_full_visible_line() > lc_floor:
		is_floored = true
	elif current_line < _target_code_edit.get_first_visible_line() \
			or current_line > _target_code_edit.get_last_full_visible_line():
		visible = false
		return
	visible = true

	var line_h = _target_code_edit.get_line_height()
	var y0 = _target_code_edit.get_pos_at_line_column(current_line, 0).y
	# top used to be y0 + line_h, seems to be an extra space though
	var top = y0 if _anchor_below else (y0 - line_h - _panel_height)
	
	if is_floored:
		top = _target_code_edit.size.y - _panel_height
	
	# from just right of the editor's gutters to its right edge, matching the old placement
	var gutter_x = _target_code_edit.get_total_gutter_width()
	var width = _target_code_edit.size.x - gutter_x
	
	var global_pos = _target_code_edit.global_position
	global_pos.x += gutter_x - _scaled(PANEL_MARGIN) - code_edit.get_total_gutter_width()
	global_pos.y += top

	custom_minimum_size = Vector2.ZERO
	position = global_pos
	size = Vector2(width, _panel_height)

func _on_target_changed(_arg=null):
	if not is_instance_valid(_target_code_edit):
		return
	_layout()

func _scaled(val:float):
	return EditorInterface.get_editor_scale() * val

# Follow the target on both scroll and resize through the one layout path.
func _manage_target_signals(connect_state:bool):
	if not is_instance_valid(_target_code_edit):
		return
	var scroll = _target_code_edit.get_v_scroll_bar()
	if connect_state:
		if not scroll.value_changed.is_connected(_on_target_changed):
			scroll.value_changed.connect(_on_target_changed)
		if not _target_code_edit.resized.is_connected(_on_target_changed):
			_target_code_edit.resized.connect(_on_target_changed)
	else:
		if scroll.value_changed.is_connected(_on_target_changed):
			scroll.value_changed.disconnect(_on_target_changed)
		if _target_code_edit.resized.is_connected(_on_target_changed):
			_target_code_edit.resized.disconnect(_on_target_changed)

func _on_editor_tab_changed(tab:int):
	if visible:
		_close()

func _close():
	hide()
	_manage_target_signals(false)
	code_edit.text = ""
	_row_meta.clear()
	_target_code_edit = null
	current_line = -1
