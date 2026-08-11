extends Node

## draws buffer changes in CodeEdit gutters and minimaps.


const UtilsLocal = preload("res://addons/git_view/src/util/utils_local.gd")
const UtilsRemote = preload("res://addons/git_view/src/util/utils_remote.gd")
const MinimapGeometry = preload("res://addons/git_view/src/minimap/minimap_geometry.gd")
const GeoKeys = MinimapGeometry.Keys

const SettingHelperEditor = UtilsRemote.SettingHelperEditor
const ScriptListManager = UtilsRemote.ScriptListManager

const GitUtil = UtilsRemote.GitUtil
const GitDiff = UtilsRemote.GitDiff

const DiffPreviewPanel = preload("res://addons/git_view/src/diff_gutter/diff_preview_panel.gd")

signal hunks_changed(code_edit:CodeEdit)

const GUTTER_NAME = &"git_view_git_diff"

const GUTTER_BEFORE = &"fold_gutter"

const GUTTER_WIDTH = 7
const BAR_WIDTH = 3

const TICK_WIDTH = 4
const TICK_HEIGHT = 6
const TICK_HEIGHT_MINIMAP = 2

const MINIMAP_BAR_WIDTH = MinimapGeometry.BAR_LANE

const COLOR_ADDED = GitUtil.Colors.L_GREEN
const COLOR_MODIFIED = GitUtil.Colors.L_YELLOW
const COLOR_DELETED = GitUtil.Colors.RED

enum Mode {
	OFF,
	DIM,
	FULL,
}

var setting_helper:SettingHelperEditor

var _show_ignored:bool = true
var _untracked_mode:int = Mode.DIM
var _untracked_dim_color:Color

const WASH_ALPHA = 0.5
const COLOR_WASH_IGNORED = GitUtil.Colors.DIM
const COLOR_WASH_UNTRACKED = Color(COLOR_ADDED, WASH_ALPHA)

const RECOMPUTE_DEBOUNCE = 0.2

var _editors:Dictionary = {}
var _baselines:Dictionary = {}
var _repo_oids:Dictionary = {}
var _repos:Array[String] = []

var _dirty:Dictionary = {}
var _debounce:Timer

var _thread:Thread
var _pending:Array = []

var git_service:GitService

var _diff_preview_panel:DiffPreviewPanel
var _diff_code_edit:CodeEdit

func _ready() -> void:
	_debounce = Timer.new()
	_debounce.one_shot = true
	_debounce.wait_time = RECOMPUTE_DEBOUNCE
	_debounce.timeout.connect(_on_debounce_timeout)
	add_child(_debounce)
	
	git_service = GitService.get_instance()
	
	ScriptEditorRef.subscribe(ScriptEditorRef.Event.TAB_CHANGED, _on_script_editor_tab_changed, 1)
	
	setting_helper = SettingHelperEditor.new()
	setting_helper.subscribe_property(self, &"_show_ignored", UtilsLocal.EditorSet.GUTTER_IGNORE, true)
	setting_helper.subscribe_property(self, &"_untracked_mode", UtilsLocal.EditorSet.GUTTER_UNTRACKED, Mode.DIM)
	setting_helper.initialize()
	
	setting_helper.settings_changed.connect(apply_settings, 1)
	_set_untracked_color()
	await get_tree().process_frame
	if Singletons.CheckInstance.check_valid("ScriptTabSingleton"):
		Singletons.CheckInstance.call_on_ready("ScriptTabSingleton", _attach_current_code_edit)
	else:
		ScriptListManager.call_on_ready(_attach_current_code_edit)


#region lifecycle

func set_repos(repos:Array[String]) -> void:
	if _repos == repos:
		return
	_repos = repos.duplicate()
	_baselines.clear()
	_attach_current_code_edit()


func head_moved(repo_dir:String, oid:String) -> void:
	if _repo_oids.get(repo_dir, "") == oid:
		return
	_repo_oids[repo_dir] = oid

	for path in _baselines.keys():
		if _baselines[path][Keys.REPO] == repo_dir:
			_baselines.erase(path)

	_attach_current_code_edit()


func apply_settings() -> void:
	_set_untracked_color()
	for id in _editors:
		_editors[id][Keys.CACHE_KEY] = null
	_refresh_all()
	_attach_current_code_edit()

func _set_untracked_color():
	_untracked_dim_color = Color(git_service.colors.untracked, WASH_ALPHA)

func clean_up() -> void:
	_teardown()


func _teardown() -> void:
	_join_thread()
	for id in _editors:
		var code_edit:CodeEdit = _editors[id][Keys.CODE_EDIT]
		if not is_instance_valid(code_edit):
			continue # its tab was closed and the gutter went with it
		_remove_gutter(code_edit)
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
	sl_man.get_current_script_editor()
	var current_editor = sl_man.get_current_script_editor()
	if not is_instance_valid(current_editor):
		return
	if not current_editor.has_method("get_base_editor"):
		return # excludes help docs
	var code_edit = current_editor.get_base_editor()
	var item_path = sl_man.get_current_item_data().get(ScriptListManager.Keys.TOOLTIP, "")
	
	_attach(code_edit, item_path)


func _attach(code_edit:CodeEdit, path:String) -> void:
	if not is_instance_valid(code_edit):
		return
	
	_prune()
	
	if path.is_empty() or path.contains("::"): # "::" -> tscn script, nah
		return
	
	var repo = _repo_for(path)
	if repo.is_empty():
		_detach(code_edit)
		return

	var known:Dictionary = _baselines.get(path, {})
	if not known.is_empty() and _mode_for(known[Keys.HEAD]) == Mode.OFF:
		_detach(code_edit)
		return

	_ensure_gutter(code_edit)

	var id = code_edit.get_instance_id()
	var state:Dictionary = _editors.get(id, {})
	state[Keys.CODE_EDIT] = code_edit
	state[Keys.PATH] = path
	state[Keys.REPO] = repo
	if not state.has(Keys.MARKERS):
		state[Keys.MARKERS] = PackedByteArray()
		state[Keys.HUNKS] = []
		state[Keys.NO_BASELINE] = false
		state[Keys.WASH_COLOR] = git_service.colors.ignored
		state[Keys.VERSION] = 0
		state[Keys.CACHE] = []
		state[Keys.CACHE_KEY] = null
	_editors[id] = state

	if not code_edit.text_changed.is_connected(_on_text_changed):
		code_edit.text_changed.connect(_on_text_changed.bind(code_edit))

	if not code_edit.draw.is_connected(_draw_minimap):
		code_edit.draw.connect(_draw_minimap.bind(code_edit))

	if not code_edit.gutter_clicked.is_connected(_on_gutter_clicked):
		code_edit.gutter_clicked.connect(_on_gutter_clicked.bind(code_edit))

	if _baselines.has(path):
		_recompute(id)
	_request_baseline(path, repo)


func _detach(code_edit:CodeEdit) -> void:
	if not is_instance_valid(code_edit):
		return
	if code_edit.text_changed.is_connected(_on_text_changed):
		code_edit.text_changed.disconnect(_on_text_changed.bind(code_edit))
	if code_edit.draw.is_connected(_draw_minimap):
		code_edit.draw.disconnect(_draw_minimap.bind(code_edit))
	if code_edit.gutter_clicked.is_connected(_on_gutter_clicked):
		code_edit.gutter_clicked.disconnect(_on_gutter_clicked)
	_remove_gutter(code_edit)
	_editors.erase(code_edit.get_instance_id())
	_dirty.erase(code_edit.get_instance_id())


func _prune() -> void:
	for id in _editors.keys():
		if not is_instance_valid(_editors[id][Keys.CODE_EDIT]):
			_editors.erase(id)
			_dirty.erase(id)


func _repo_for(path:String) -> String:
	return GitUtil.find_repo_for(path, _repos)

#endregion


#region the gutter

func _ensure_gutter(code_edit:CodeEdit) -> void:
	var idx = _find_gutter(code_edit)
	if idx < 0:
		idx = _insert_index(code_edit)
		code_edit.add_gutter(idx)
		if idx < 0:
			idx = code_edit.get_gutter_count() - 1
		code_edit.set_gutter_name(idx, GUTTER_NAME)

	code_edit.set_gutter_type(idx, TextEdit.GUTTER_TYPE_CUSTOM)
	code_edit.set_gutter_custom_draw(idx, _draw_gutter.bind(code_edit))
	code_edit.set_gutter_width(idx, int(GUTTER_WIDTH * EditorInterface.get_editor_scale()))
	code_edit.set_gutter_draw(idx, true)
	code_edit.set_gutter_overwritable(idx, false)
	code_edit.set_gutter_clickable(idx, true)


func _find_gutter(code_edit:CodeEdit) -> int:
	for i in code_edit.get_gutter_count():
		if code_edit.get_gutter_name(i) == GUTTER_NAME:
			return i
	return -1


func _insert_index(code_edit:CodeEdit) -> int:
	for i in code_edit.get_gutter_count():
		if code_edit.get_gutter_name(i) == GUTTER_BEFORE:
			return i
	return -1


func _remove_gutter(code_edit:CodeEdit) -> void:
	var idx = _find_gutter(code_edit)
	if idx > -1:
		code_edit.remove_gutter(idx)
		code_edit.queue_redraw()

func _on_gutter_clicked(line:int, gutter_idx:int, code_edit:CodeEdit):
	if _find_gutter(code_edit) != gutter_idx:
		return
	var state:Dictionary = _editors.get(code_edit.get_instance_id(), {})
	if state.is_empty():
		return
	
	var markers:PackedByteArray = state[Keys.MARKERS]
	if line < 0 or line >= markers.size():
		return
	var mask = markers[line]
	if mask == 0:
		return
	
	var hunk = _hunk_for_line(state, line, code_edit.get_line_count())
	if hunk.is_empty():
		return # a wash / clean / context-only line — nothing to preview
	
	if is_instance_valid(_diff_preview_panel):
		_diff_preview_panel.queue_free()
		_diff_preview_panel = null
	
	if not is_instance_valid(_diff_preview_panel):
		_diff_preview_panel = DiffPreviewPanel.new()
		EditorInterface.get_base_control().add_child(_diff_preview_panel)
	
	_diff_preview_panel.display_hunk(hunk, line, code_edit)

func _draw_gutter(line:int, _gutter:int, rect:Rect2, code_edit:CodeEdit) -> void:
	var state:Dictionary = _editors.get(code_edit.get_instance_id(), {})
	if state.is_empty():
		return

	var markers:PackedByteArray = state[Keys.MARKERS]
	if line < 0 or line >= markers.size():
		return

	var mask = markers[line]
	if mask == 0:
		return

	var scale = EditorInterface.get_editor_scale()
	var bounds = Rect2(Vector2.ZERO, code_edit.size)

	if mask & GitDiff.Marker.NO_BASELINE:
		_draw_clamped(code_edit, Rect2(rect.position, Vector2(BAR_WIDTH * scale, rect.size.y)),
			state.get(Keys.WASH_COLOR, git_service.colors.ignored), bounds)
		return

	if mask & (GitDiff.Marker.ADDED | GitDiff.Marker.MODIFIED):
		var color = git_service.colors.modified if mask & GitDiff.Marker.MODIFIED else COLOR_ADDED
		_draw_clamped(code_edit, Rect2(rect.position, Vector2(BAR_WIDTH * scale, rect.size.y)),
			color, bounds)

	var tick = Vector2(TICK_WIDTH * scale, TICK_HEIGHT * scale)
	if mask & GitDiff.Marker.DELETED_ABOVE:
		_draw_clamped(code_edit, Rect2(rect.position, tick), COLOR_DELETED, bounds)
	if mask & GitDiff.Marker.DELETED_BELOW:
		var bottom = rect.position + Vector2(0, rect.size.y - tick.y)
		_draw_clamped(code_edit, Rect2(bottom, tick), COLOR_DELETED, bounds)


func _draw_clamped(code_edit:CodeEdit, rect:Rect2, color:Color, bounds:Rect2) -> void:
	var clipped = rect.intersection(bounds)
	if clipped.has_area():
		code_edit.draw_rect(clipped, color)


func _draw_minimap(code_edit:CodeEdit) -> void:
	var state:Dictionary = _editors.get(code_edit.get_instance_id(), {})
	if state.is_empty():
		return
	if state[Keys.HUNKS].is_empty() and not state.get(Keys.NO_BASELINE, false):
		return
	if not code_edit.is_drawing_minimap():
		return

	for entry in _minimap_rects(code_edit, state):
		code_edit.draw_rect(entry[0], entry[1])


func _minimap_rects(code_edit:CodeEdit, state:Dictionary) -> Array:
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

	var rects = _build_minimap_rects(code_edit, state, geometry)
	state[Keys.CACHE_KEY] = key
	state[Keys.CACHE] = rects
	return rects


func _build_minimap_rects(code_edit:CodeEdit, state:Dictionary, geometry:Dictionary) -> Array:
	var markers:PackedByteArray = state[Keys.MARKERS]
	var rects:Array = []
	var h:int = geometry[GeoKeys.H]
	var height = code_edit.size.y
	var scale = EditorInterface.get_editor_scale()
	
	var x = MinimapGeometry.left_x(code_edit)

	var bar_width = MINIMAP_BAR_WIDTH * scale
	var tick_height = TICK_HEIGHT_MINIMAP * scale

	var mini_bottom = MinimapGeometry.bottom(code_edit, geometry)
	var bounds = Rect2(0, 0, code_edit.size.x, mini_bottom)

	var i = 0
	while i < markers.size():
		var mask = markers[i]
		if mask == 0:
			i += 1
			continue

		var start = i
		while i < markers.size() and markers[i] == mask:
			i += 1

		var top = MinimapGeometry.line_y(code_edit, geometry, start)
		var bottom = MinimapGeometry.line_y(code_edit, geometry, i - 1) + h
		if i >= markers.size():
			bottom = mini_bottom
		if bottom <= 0.0 or top >= height:
			continue # scrolled off the minimap

		var color = COLOR_DELETED
		var rect := Rect2(x, top, bar_width, tick_height)
		if mask & GitDiff.Marker.NO_BASELINE:
			color = state.get(Keys.WASH_COLOR, git_service.colors.ignored)
			rect = Rect2(x, top, bar_width, bottom - top)
		elif mask & (GitDiff.Marker.ADDED | GitDiff.Marker.MODIFIED):
			color = COLOR_MODIFIED if mask & GitDiff.Marker.MODIFIED else COLOR_ADDED
			rect = Rect2(x, top, bar_width, bottom - top)

		rect = rect.intersection(bounds)
		if rect.has_area():
			rects.append([rect, color])

	return rects

#endregion


#region recomputing

func _on_text_changed(code_edit:CodeEdit) -> void:
	if not is_instance_valid(code_edit):
		return
	_dirty[code_edit.get_instance_id()] = true
	_debounce.start()


func _on_debounce_timeout() -> void:
	for id in _dirty:
		_recompute(id)
	_dirty.clear()


func _refresh_all() -> void:
	_prune()
	for id in _editors:
		_recompute(id)


func _hunk_for_line(state:Dictionary, line:int, line_count:int) -> Dictionary:
	for hunk:Dictionary in state[Keys.HUNKS]:
		var new_count:int = hunk[GitUtil.Keys.NEW_COUNT]
		var start:int
		var span:int
		if new_count == 0:
			start = mini(hunk[GitUtil.Keys.NEW_START], maxi(0, line_count - 1))
			span = 1
		else:
			start = hunk[GitUtil.Keys.NEW_START] - 1
			span = new_count
		if line >= start and line < start + span:
			return hunk
	return {}


func _blank(state:Dictionary, code_edit:CodeEdit) -> void:
	state[Keys.HUNKS] = []
	state[Keys.MARKERS] = PackedByteArray()
	state[Keys.NO_BASELINE] = false
	state[Keys.VERSION] += 1
	_remove_gutter(code_edit)


func _mode_for(head:int) -> int:
	match head:
		GitUtil.Head.IGNORED: return Mode.DIM if _show_ignored else Mode.OFF
		GitUtil.Head.ABSENT:  return _untracked_mode
		_:                    return Mode.FULL


func _wash_color(head:int) -> Color:
	return git_service.colors.ignored if head == GitUtil.Head.IGNORED else _untracked_dim_color


func _recompute(id:int) -> void:
	var state:Dictionary = _editors.get(id, {})
	if state.is_empty():
		return

	var code_edit:CodeEdit = state[Keys.CODE_EDIT]
	if not is_instance_valid(code_edit):
		_editors.erase(id)
		return

	if _rebuild(state, code_edit):
		hunks_changed.emit(code_edit)


func _rebuild(state:Dictionary, code_edit:CodeEdit) -> bool:
	var baseline:Dictionary = _baselines.get(state[Keys.PATH], {})
	if baseline.is_empty():
		return false # still in flight — leave whatever is drawn rather than blank it and blink

	var head:int = baseline[Keys.HEAD]

	if head == GitUtil.Head.ERROR or _mode_for(head) == Mode.OFF:
		_blank(state, code_edit)
		return true

	if _mode_for(head) == Mode.DIM:
		state[Keys.HUNKS] = []
		state[Keys.NO_BASELINE] = true
		state[Keys.WASH_COLOR] = _wash_color(head)
		state[Keys.MARKERS] = GitDiff.fill_markers(code_edit.get_line_count(), GitDiff.Marker.NO_BASELINE)
		state[Keys.VERSION] += 1
		code_edit.queue_redraw()
		return true

	var new_lines = GitDiff.to_lines(code_edit.text)
	var hunks = GitDiff.diff_lines(baseline[Keys.LINES], new_lines)

	state[Keys.NO_BASELINE] = false
	state[Keys.HUNKS] = hunks
	state[Keys.MARKERS] = GitDiff.hunks_to_markers(hunks, new_lines.size())
	state[Keys.VERSION] += 1
	code_edit.queue_redraw()
	return true


func get_hunks(code_edit:CodeEdit) -> Array:
	if not is_instance_valid(code_edit):
		return []
	return _editors.get(code_edit.get_instance_id(), {}).get(Keys.HUNKS, [])

#endregion


#region the baseline read

func _request_baseline(res_path:String, repo_dir:String) -> void:
	if is_instance_valid(_thread) and _thread.is_alive():
		_pending = [res_path, repo_dir]
		return

	_join_thread()
	_pending = []
	_thread = Thread.new()
	_thread.start(_baseline_task.bind(res_path, repo_dir, _repo_oids.get(repo_dir, "")))


func _baseline_task(res_path:String, repo_dir:String, oid:String) -> void:
	_on_baseline_ready.call_deferred(res_path, repo_dir, oid, GitUtil.get_file_at_head(repo_dir, res_path))


func _on_baseline_ready(res_path:String, repo_dir:String, oid:String, result:Dictionary) -> void:
	_join_thread()

	if _repo_oids.get(repo_dir, "") == oid:
		_baselines[res_path] = {
			Keys.REPO: repo_dir,
			Keys.LINES: GitDiff.to_lines(result[GitUtil.Keys.TEXT]),
			Keys.HEAD: result[GitUtil.Keys.HEAD],
		}

	if not _pending.is_empty():
		var next = _pending
		_pending = []
		_request_baseline(next[0], next[1])

	_refresh_all()


func _join_thread() -> void:
	if not is_instance_valid(_thread):
		return
	_thread.wait_to_finish()
	_thread = null

#endregion


class Keys:
	const CODE_EDIT = &"code_edit"
	const PATH = &"path"
	const MARKERS = &"markers"
	const HUNKS = &"hunks"
	const VERSION = &"version"
	const NO_BASELINE = &"no_baseline"
	const WASH_COLOR = &"wash_color"
	const CACHE = &"minimap_cache"
	const CACHE_KEY = &"minimap_cache_key"

	const REPO = &"repo"
	const LINES = &"lines"
	const HEAD = &"head"
