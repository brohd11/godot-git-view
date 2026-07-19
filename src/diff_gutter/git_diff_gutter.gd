extends Node

## Marks the script editor's gutter with what has changed since the last commit.
##
## Diffs HEAD against the editor's buffer, not the file on disk: the baseline comes from
## `git show HEAD:<path>`, the diff from GitDiff. Hunks are kept per editor even though only the
## markers are drawn — the diff preview reads them rather than diffing the same buffer twice.

const UtilsLocal = preload("res://addons/git_view/src/util/utils_local.gd")
const UtilsRemote = preload("res://addons/git_view/src/util/utils_remote.gd")

const SettingHelperEditor = UtilsRemote.SettingHelperEditor
const ScriptListManager = UtilsRemote.ScriptListManager

const GitUtil = UtilsRemote.GitUtil
const GitDiff = UtilsRemote.GitDiff

const GUTTER_NAME = &"git_view_git_diff"

## ScriptTextEditor's connection_gutter is a plain int cached at construction and never revisited —
## insert at or before it and the editor quietly draws its signal icons into this gutter. Going in
## ahead of the fold arrows clears it. (CodeEdit re-finds its own gutters by name, so it does not care.)
const GUTTER_BEFORE = &"fold_gutter"

## unscaled px: the column, of which the bar is the leftmost part and the rest is air before the text
const GUTTER_WIDTH = 7
const BAR_WIDTH = 3

## unscaled px of the stub marking a deletion, which owns no line and so sits on the boundary between
## the two that closed over it. A rect, not a triangle: a rect clips by intersecting in one call and
## still shows the part that fits, where a triangle half off the top would have to vanish instead.
const TICK_WIDTH = 4
const TICK_HEIGHT = 2

## unscaled px of the mark down the minimap's left edge. A bar and not a band across the whole
## minimap, which would cover the code the minimap is there to show.
const MINIMAP_BAR_WIDTH = 3

## The Changes list's palette, not the editor theme's success/warning/error. UtilsRemote.EditorColors if want to change
const COLOR_ADDED = GitUtil.Colors.L_GREEN
const COLOR_MODIFIED = GitUtil.Colors.L_YELLOW
const COLOR_DELETED = GitUtil.Colors.RED

## What to draw for a file with no baseline to diff against. FULL is the ordinary treatment — the
## baseline is empty, so every line reads as added; DIM is one muted bar down the whole file; OFF
## takes the gutter away entirely.
enum Mode {
	OFF,
	DIM,
	FULL,
}

var setting_helper:SettingHelperEditor

## Set from editor settings. Ignored is a bool and not a Mode: FULL for a file git will never see is
## the noise this went in to fix, so the only real choice is a muted bar or nothing.
var _show_ignored:bool = true
## Untracked but not ignored defaults to FULL — every line of it really is uncommitted.
var _untracked_mode:int = Mode.DIM

const WASH_ALPHA = 0.5
## Gray for what git will never track, green for what it has simply not seen yet — derived from
## COLOR_ADDED so it stays the muted version of the bar the same file gets at FULL.
const COLOR_WASH_IGNORED = GitUtil.Colors.DIM
const COLOR_WASH_UNTRACKED = Color(COLOR_ADDED, WASH_ALPHA)

## Time before checking current line on text changed
const RECOMPUTE_DEBOUNCE = 0.2

# CodeEdits with a gutter in, by instance id; see Keys for an entry's shape
var _editors:Dictionary = {}
# res:// path -> {repo, lines, head}, the committed side, cached across tab switches
var _baselines:Dictionary = {}
# repo -> the BRANCH_OID last seen, the only thing that can make a baseline stale
var _repo_oids:Dictionary = {}
var _repos:Array[String] = []

# instance ids whose buffer has moved since the last recompute
var _dirty:Dictionary = {}
var _debounce:Timer

var _thread:Thread
# the one queued baseline request, as [res_path, repo] — see _start_work()
var _pending:Array = []


func _ready() -> void:
	_debounce = Timer.new()
	_debounce.one_shot = true
	_debounce.wait_time = RECOMPUTE_DEBOUNCE
	_debounce.timeout.connect(_on_debounce_timeout)
	add_child(_debounce)
	
	ScriptEditorRef.subscribe(ScriptEditorRef.Event.TAB_CHANGED, _on_script_editor_tab_changed, 1)
	
	setting_helper = SettingHelperEditor.new()
	setting_helper.subscribe_property(self, &"_show_ignored", UtilsLocal.EditorSet.GUTTER_IGNORE, true)
	setting_helper.subscribe_property(self, &"_untracked_mode", UtilsLocal.EditorSet.GUTTER_UNTRACKED, Mode.DIM)
	setting_helper.initialize()
	
	setting_helper.settings_changed.connect(apply_settings, 1)
	# initialize
	_attach_current_code_edit()


#region lifecycle

## Project repos, set by git panel on refresh
func set_repos(repos:Array[String]) -> void:
	_repos = repos.duplicate()
	# which repo owns a path may have just changed, and with it every baseline read from one
	_baselines.clear()
	_attach_current_code_edit()


## A commit is a new baseline, and nothing else about a repo can make one stale — so compare the oid
## and flush only when it actually moved.
func head_moved(repo_dir:String, oid:String) -> void:
	if _repo_oids.get(repo_dir, "") == oid:
		return
	_repo_oids[repo_dir] = oid

	for path in _baselines.keys():
		if _baselines[path][Keys.REPO] == repo_dir:
			_baselines.erase(path)

	_refresh_all()


## Call after changing _show_ignored or _untracked_mode. What is drawn is as much a function of the
## settings as of the buffer, and a settings change touches neither the text nor a baseline — so
## nothing would otherwise bump VERSION, and the minimap cache would keep serving the old rects.
##
## The baselines deliberately survive: no setting can make a `git show` result stale, and re-reading
## every open file off-thread to change a color would be waste.
func apply_settings() -> void:
	for id in _editors:
		_editors[id][Keys.CACHE_KEY] = null
	_refresh_all()
	# OFF is the one mode with no gutter column at all, so crossing it either way re-attaches
	_attach_current_code_edit()


func clean_up() -> void:
	_teardown()


# fine to run twice if needed (clean_up + predelete)
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

# using tab changed allows for any text doc type
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
		# it can have moved out of the tracked set since it was attached — set_repos may have just
		# taken its repo away
		_detach(code_edit)
		return

	# a file already known to be drawn as nothing gets no gutter added and removed again on every
	# visit to its tab, which would shift the text sideways each time. A first open still flickers:
	# the answer is not known until the baseline thread returns.
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
		state[Keys.WASH_COLOR] = COLOR_WASH_IGNORED
		state[Keys.VERSION] = 0
		state[Keys.CACHE] = []
		state[Keys.CACHE_KEY] = null
	_editors[id] = state

	# not ScriptEditorRef, background scripts (tabs) should update too
	if not code_edit.text_changed.is_connected(_on_text_changed):
		code_edit.text_changed.connect(_on_text_changed.bind(code_edit))

	# the minimap draws glyphs and nothing else — it has no notion of a gutter, so the marks have to
	# be painted over it. The draw signal fires after TextEdit's own _draw, so this lands on top.
	if not code_edit.draw.is_connected(_draw_minimap):
		code_edit.draw.connect(_draw_minimap.bind(code_edit))

	# draw from the cache now so a tab switch does not flicker
	# refresh regardless: commit in terminal never reaches filesystem_changed
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
	_remove_gutter(code_edit)
	_editors.erase(code_edit.get_instance_id())
	_dirty.erase(code_edit.get_instance_id())


# Editors whose tab has closed. Their CodeEdit is gone and took the gutter with it
func _prune() -> void:
	for id in _editors.keys():
		if not is_instance_valid(_editors[id][Keys.CODE_EDIT]):
			_editors.erase(id)
			_dirty.erase(id)


# The repo a script belongs to, in case of submodules/repos
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

	# re-pointed, not added twice, so this survives a hot-reload: the CodeEdits live on with our gutter
	# still in them, holding a Callable into an object that no longer exists
	code_edit.set_gutter_type(idx, TextEdit.GUTTER_TYPE_CUSTOM)
	code_edit.set_gutter_custom_draw(idx, _draw_gutter.bind(code_edit))
	code_edit.set_gutter_width(idx, int(GUTTER_WIDTH * EditorInterface.get_editor_scale()))
	code_edit.set_gutter_draw(idx, true)
	code_edit.set_gutter_overwritable(idx, false)


# By name: add_gutter shifts every later index, and other plugins add gutters too
func _find_gutter(code_edit:CodeEdit) -> int:
	for i in code_edit.get_gutter_count():
		if code_edit.get_gutter_name(i) == GUTTER_NAME:
			return i
	return -1


# -1 to append, add_gutter's default.
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


# Called from inside TextEdit's _draw, once per visible row: _recompute resolved the hunks into one
# byte per line and this reads it.
func _draw_gutter(line:int, _gutter:int, rect:Rect2, code_edit:CodeEdit) -> void:
	var state:Dictionary = _editors.get(code_edit.get_instance_id(), {})
	if state.is_empty():
		return

	var markers:PackedByteArray = state[Keys.MARKERS]
	# the buffer is edited on every keystroke and re-diffed on a debounce, so the markers are
	# routinely a line or two short of the text they describe. Draw what is known and nothing else.
	if line < 0 or line >= markers.size():
		return

	var mask = markers[line]
	if mask == 0:
		return

	var scale = EditorInterface.get_editor_scale()
	# the first and last rows on screen are half rows but the rect handed over is whole, so it hangs
	# over the edge — and clip_contents is false here, so anything past it lands on the scrollbar
	var bounds = Rect2(Vector2.ZERO, code_edit.size)

	# the whole file wears this one and nothing else, so it answers for the row on its own.
	# Defaulted, not indexed: a hot-reload rebinds live instances to the new script while keeping the
	# state they already had, so an entry built before WASH_COLOR existed would otherwise hard-error
	# here once per row per frame.
	if mask & GitDiff.Marker.NO_BASELINE:
		_draw_clamped(code_edit, Rect2(rect.position, Vector2(BAR_WIDTH * scale, rect.size.y)),
			state.get(Keys.WASH_COLOR, COLOR_WASH_IGNORED), bounds)
		return

	if mask & (GitDiff.Marker.ADDED | GitDiff.Marker.MODIFIED):
		var color = COLOR_MODIFIED if mask & GitDiff.Marker.MODIFIED else COLOR_ADDED
		_draw_clamped(code_edit, Rect2(rect.position, Vector2(BAR_WIDTH * scale, rect.size.y)),
			color, bounds)

	# a deletion has no line of its own to occupy, so it sits on the boundary of the line that closed
	# over it rather than running down the middle of a line that is still there
	var tick = Vector2(TICK_WIDTH * scale, TICK_HEIGHT * scale)
	if mask & GitDiff.Marker.DELETED_ABOVE:
		_draw_clamped(code_edit, Rect2(rect.position, tick), COLOR_DELETED, bounds)
	if mask & GitDiff.Marker.DELETED_BELOW:
		var bottom = rect.position + Vector2(0, rect.size.y - tick.y)
		_draw_clamped(code_edit, Rect2(bottom, tick), COLOR_DELETED, bounds)


# Nothing reaches the CodeEdit's canvas except through here — a wrapped line half off the top gives a
# rect starting above zero, with no clipping downstream to catch it.
func _draw_clamped(code_edit:CodeEdit, rect:Rect2, color:Color, bounds:Rect2) -> void:
	var clipped = rect.intersection(bounds)
	if clipped.has_area():
		code_edit.draw_rect(clipped, color)


# The same markers down the minimap, where the gutter cannot reach. Runs on the CodeEdit's draw
# signal, which fires after TextEdit drew itself, so this paints over the minimap — and the CodeEdit
# is not ours to free, hence the disconnect in _detach(). A caret blink redraws twice a second on an
# untouched editor, hence the cache.
func _draw_minimap(code_edit:CodeEdit) -> void:
	var state:Dictionary = _editors.get(code_edit.get_instance_id(), {})
	# hunks and not markers: an unmodified file is the common case and this is the whole cost of it.
	# A wash is the one thing with markers and no hunks, so it has to be asked about separately.
	if state.is_empty():
		return
	if state[Keys.HUNKS].is_empty() and not state.get(Keys.NO_BASELINE, false):
		return
	if not code_edit.is_drawing_minimap():
		return

	for entry in _minimap_rects(code_edit, state):
		code_edit.draw_rect(entry[0], entry[1])


# The marks as [Rect2, Color], from the cache when nothing that moves them has changed. The key is
# what the geometry is a function of and nothing else — notably the anchor line rather than
# get_v_scroll(), since the minimap only moves in whole rows and the raw float would miss every frame.
func _minimap_rects(code_edit:CodeEdit, state:Dictionary) -> Array:
	var geometry = _minimap_geometry(code_edit)
	if geometry.is_empty():
		return []

	var key = [
		state[Keys.VERSION],
		code_edit.size,
		geometry[Keys.FIRST_LINE],
		code_edit.get_total_visible_line_count(),
	]
	if state.get(Keys.CACHE_KEY) == key:
		return state[Keys.CACHE]

	var rects = _build_minimap_rects(code_edit, state, geometry)
	state[Keys.CACHE_KEY] = key
	state[Keys.CACHE] = rects
	return rects


# What the minimap is currently showing, as a row height and the first line it draws.
#
# Positions are measured from that first line, never from a probe that moves with the scroll:
# get_minimap_line_at_pos() folds the fractional part of the scroll into its answer, so a fixed probe
# pixel flips by a line as you scroll even while a fitting minimap sits still — which is what jittered.
#! keys h:int content_bottom:float first_line:int
func _minimap_geometry(code_edit:CodeEdit) -> Dictionary:
	# capacity, not the count actually drawn: it is floor(minimap_height / row_height), so it stays put
	# whatever the file's length, and dividing the height back by it recovers the row height
	var capacity = code_edit.get_minimap_visible_lines()
	if capacity <= 0 or code_edit.size.y <= 0.0:
		return {}

	# x is ignored by the mapping — pos(0, y) and pos(2000, y) answer the same — so it stays 0
	var margin = code_edit.get_theme_stylebox(&"normal").get_margin(SIDE_TOP)
	var margin_bottom = code_edit.get_theme_stylebox(&"normal").get_margin(SIDE_BOTTOM)
	#print(code_edit.get_theme_stylebox(&"normal"))
	
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


# Takes the whole state and not just its markers: a wash's color is a per-file fact that no marker
# byte carries, so the run below has to be able to ask for it.
func _build_minimap_rects(code_edit:CodeEdit, state:Dictionary, geometry:Dictionary) -> Array:
	var markers:PackedByteArray = state[Keys.MARKERS]
	var rects:Array = []
	var h:int = geometry[Keys.H]
	var height = code_edit.size.y
	var scale = EditorInterface.get_editor_scale()

	var v_scroll = code_edit.get_v_scroll_bar()
	var x = code_edit.size.x - code_edit.get_minimap_width()
	if is_instance_valid(v_scroll):
		# minimap hard coded to clear the scroll, always subtract it
		x -= v_scroll.size.x

	var bar_width = MINIMAP_BAR_WIDTH * scale
	var tick_height = TICK_HEIGHT * scale

	# stop at the drawn content, not code_edit.size: a short file's minimap ends well above the bottom,
	# and a long one is inset by the bottom margin — either way a run past it should clip, not fill down
	var margin_bottom = code_edit.get_theme_stylebox(&"normal").get_margin(SIDE_BOTTOM)
	var mini_bottom = minf(height - margin_bottom, geometry[Keys.CONTENT_BOTTOM])
	var bounds = Rect2(0, 0, code_edit.size.x, mini_bottom)

	# by run and not by row: at ~3px a line a per line rect is a stack of slivers, and a hunk is one
	# thing to look at anyway
	var i = 0
	while i < markers.size():
		var mask = markers[i]
		if mask == 0:
			i += 1
			continue

		var start = i
		while i < markers.size() and markers[i] == mask:
			i += 1

		var top = _minimap_y(code_edit, geometry, start)
		var bottom = _minimap_y(code_edit, geometry, i - 1) + h
		# a run reaching the file's last line should fill to the true content bottom: integer stepping
		# leaves it a few px short on a short file (and over on a long one), and mini_bottom is exact
		if i >= markers.size():
			bottom = mini_bottom
		if bottom <= 0.0 or top >= height:
			continue # scrolled off the minimap

		var color = COLOR_DELETED
		var rect := Rect2(x, top, bar_width, tick_height)
		if mask & GitDiff.Marker.NO_BASELINE:
			# one run for the whole file, the coalescing above having already collapsed it
			color = state.get(Keys.WASH_COLOR, COLOR_WASH_IGNORED)
			rect = Rect2(x, top, bar_width, bottom - top)
		elif mask & (GitDiff.Marker.ADDED | GitDiff.Marker.MODIFIED):
			color = COLOR_MODIFIED if mask & GitDiff.Marker.MODIFIED else COLOR_ADDED
			rect = Rect2(x, top, bar_width, bottom - top)

		rect = rect.intersection(bounds)
		if rect.has_area():
			rects.append([rect, color])

	return rects


# Where the minimap draws a line, counted in rows from the first drawn line (which sits at pixel 0).
# get_visible_line_count_in_range() makes this arithmetic rather than a search, folds and wraps included.
func _minimap_y(code_edit:CodeEdit, geometry:Dictionary, line:int) -> float:
	# markers are rebuilt on a debounce, so on a fresh deletion they can still index a line
	# the buffer no longer has — get_visible_line_count_in_range errors on that, so clamp
	var last = code_edit.get_line_count() - 1
	var first:int = clampi(geometry[Keys.FIRST_LINE], 0, last)
	line = clampi(line, 0, last)
	var rows:int
	if line >= first:
		rows = code_edit.get_visible_line_count_in_range(first, line) - 1
	else:
		rows = -(code_edit.get_visible_line_count_in_range(line, first) - 1)
	return float(rows * int(geometry[Keys.H]))

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


# Nothing to say about this file: no marks, and no gutter column to hold them either.
func _blank(state:Dictionary, code_edit:CodeEdit) -> void:
	state[Keys.HUNKS] = []
	state[Keys.MARKERS] = PackedByteArray()
	state[Keys.NO_BASELINE] = false
	state[Keys.VERSION] += 1
	_remove_gutter(code_edit)


# The mode a head state is drawn under. The settings are read here and nowhere else, so everything
# downstream of this speaks one vocabulary — a file git could answer for is never anything but FULL.
func _mode_for(head:int) -> int:
	match head:
		GitUtil.Head.IGNORED: return Mode.DIM if _show_ignored else Mode.OFF
		GitUtil.Head.ABSENT:  return _untracked_mode
		_:                    return Mode.FULL


# Which muted color a wash uses — the whole point of separating IGNORED from ABSENT, since the two
# would otherwise be the same fact by the time anything draws.
func _wash_color(head:int) -> Color:
	return COLOR_WASH_IGNORED if head == GitUtil.Head.IGNORED else COLOR_WASH_UNTRACKED


# Resolves the editor's buffer against its baseline. Cheap enough for a keystroke's debounce: the
# trim in GitDiff means a one line edit costs a one line diff, whatever the file's size.
func _recompute(id:int) -> void:
	var state:Dictionary = _editors.get(id, {})
	if state.is_empty():
		return

	var code_edit:CodeEdit = state[Keys.CODE_EDIT]
	if not is_instance_valid(code_edit):
		_editors.erase(id)
		return

	var baseline:Dictionary = _baselines.get(state[Keys.PATH], {})
	if baseline.is_empty():
		return # still in flight — leave whatever is drawn rather than blank it and blink

	var head:int = baseline[Keys.HEAD]

	# the repo would not answer, so anything drawn now would be a guess — a machine with no git on
	# PATH would otherwise light up every open script
	if head == GitUtil.Head.ERROR or _mode_for(head) == Mode.OFF:
		_blank(state, code_edit)
		return

	if _mode_for(head) == Mode.DIM:
		state[Keys.HUNKS] = []
		state[Keys.NO_BASELINE] = true
		state[Keys.WASH_COLOR] = _wash_color(head)
		# a uniform fill needs the count and not the lines themselves
		state[Keys.MARKERS] = GitDiff.fill_markers(code_edit.get_line_count(), GitDiff.Marker.NO_BASELINE)
		state[Keys.VERSION] += 1
		code_edit.queue_redraw()
		return

	# Mode.FULL falls through: ABSENT and IGNORED both arrive as an empty baseline, so a file git has
	# never seen diffs as entirely added, which is what it is
	var new_lines = GitDiff.to_lines(code_edit.text)
	var hunks = GitDiff.diff_lines(baseline[Keys.LINES], new_lines)

	state[Keys.NO_BASELINE] = false
	state[Keys.HUNKS] = hunks
	state[Keys.MARKERS] = GitDiff.hunks_to_markers(hunks, new_lines.size())
	# what the minimap cache watches — an int to compare, rather than the marker array itself
	state[Keys.VERSION] += 1
	code_edit.queue_redraw()

#endregion


#region the baseline read

# `git show` off the main thread, on this object's own Thread and not the panel's — the file is often
# not in the panel's selected repo. Running concurrently with it is safe: both commands only read.
func _request_baseline(res_path:String, repo_dir:String) -> void:
	if is_instance_valid(_thread) and _thread.is_alive():
		# only the newest request can matter, so replace rather than queue
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

	# a commit landing while the read was in flight makes this the previous baseline. Guarded by oid
	# and not by "is this still the current tab": a result for a tab the user has left is not stale,
	# it is a cache entry they are about to want back.
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


# Mandatory before this object is freed: Godot errors on a Thread that is still running.
func _join_thread() -> void:
	if not is_instance_valid(_thread):
		return
	_thread.wait_to_finish()
	_thread = null

#endregion


class Keys:
	## one entry of _editors
	const CODE_EDIT = &"code_edit"
	const PATH = &"path"
	const MARKERS = &"markers"
	## unread here — what the diff preview window will want, so it need not diff the buffer again
	const HUNKS = &"hunks"
	## bumped whenever MARKERS is rebuilt, so the minimap cache has an int to compare
	const VERSION = &"version"
	## whether MARKERS is a whole file wash rather than a diff — the one case with markers but no
	## hunks, which the minimap's early out would otherwise read as "nothing to draw"
	const NO_BASELINE = &"no_baseline"
	## the wash's Color, resolved once where the settings are read so the per-frame draws need no
	## notion of why a file has no baseline. Only meaningful while NO_BASELINE is true.
	const WASH_COLOR = &"wash_color"
	## the minimap marks as [Rect2, Color], and what they were computed for
	const CACHE = &"minimap_cache"
	const CACHE_KEY = &"minimap_cache_key"

	## one entry of _minimap_geometry()
	const H = &"row_height"
	## the drawn content's pixel extent from the minimap top, for the bottom clamp
	const CONTENT_BOTTOM = &"content_bottom"
	## the first line the minimap paints (0 unless it is scrolled), the reference every mark is placed from
	const FIRST_LINE = &"first_line"

	## one entry of _baselines, and REPO is on an _editors entry too
	const REPO = &"repo"
	const LINES = &"lines"
	const HEAD = &"head"
