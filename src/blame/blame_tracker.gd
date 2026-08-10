extends Node

## The commit behind the caret's line, for the Git section's blame row.
##
## Blames HEAD and not the worktree, so the line numbers are the commit's — the buffer's are walked
## back to them through the diff gutter's hunks. That is what keeps this to one spawn per file per
## commit: an edit shifts line numbers, which the mapping already covers, so only HEAD moving can
## make a blame stale.

const UtilsLocal = preload("res://addons/git_view/src/util/utils_local.gd")
const UtilsRemote = preload("res://addons/git_view/src/util/utils_remote.gd")

const SettingHelperEditor = UtilsRemote.SettingHelperEditor
const ScriptListManager = UtilsRemote.ScriptListManager

const GitUtil = UtilsRemote.GitUtil
const GitDiff = UtilsRemote.GitDiff

const DiffGutter = preload("res://addons/git_view/src/diff_gutter/git_diff_gutter.gd")

## The caret line's commit, or {} when there is nothing to attribute it to. Carries a parse_log
## shaped commit plus LINE and UNCOMMITTED, so a row that already renders a log entry needs no
## notion of blame.
signal line_blame(info:Dictionary)

## Where the buffer-to-HEAD hunks come from. Set by plugin.gd before this enters the tree; without
## it nothing is emitted, since a buffer line cannot be assumed to be the line HEAD has.
var gutter:DiffGutter

var setting_helper:SettingHelperEditor
var _enabled:bool = true

# res:// path -> {repo, commits, blame_lines}, kept across tab switches
var _blames:Dictionary = {}
# repo -> the BRANCH_OID last seen, the only thing that can make a blame stale
var _repo_oids:Dictionary = {}
var _repos:Array[String] = []

# the editor being reported on. Only the visible one, unlike the gutter: a background tab has no
# caret to report
var _code_edit:CodeEdit
var _path:String = ""
# the line last reported, so a caret moving along a line rather than off it costs nothing
var _last_line:int = -1

var _thread:Thread
# the one queued blame request, as [res_path, repo] — see _request_blame()
var _pending:Array = []


func _ready() -> void:
	ScriptEditorRef.subscribe(ScriptEditorRef.Event.TAB_CHANGED, _on_tab_changed, 1)
	ScriptEditorRef.subscribe(ScriptEditorRef.Event.CARET_CHANGED, _on_caret_changed)

	# assigned by plugin.gd before this entered the tree, so it is here to connect to
	if is_instance_valid(gutter):
		gutter.hunks_changed.connect(_on_hunks_changed)

	setting_helper = SettingHelperEditor.new()
	setting_helper.subscribe_property(self, &"_enabled", UtilsLocal.EditorSet.BLAME_CARET_LINE, true)
	setting_helper.initialize()
	setting_helper.settings_changed.connect(apply_settings, 1)

	await get_tree().process_frame
	Singletons.CheckInstance.call_on_ready("ScriptTabSingleton", _attach_current)


#region lifecycle

## Project repos, set by plugin.gd on refresh
func set_repos(repos:Array[String]) -> void:
	if _repos == repos:
		return
	_repos = repos.duplicate()
	# which repo owns a path may have just changed, and with it every blame read from one
	_blames.clear()
	_attach_current()


## A commit rewrites who last touched each line, and nothing else about a repo can — so compare the
## oid and flush only when it actually moved.
func head_moved(repo_dir:String, oid:String) -> void:
	if _repo_oids.get(repo_dir, "") == oid:
		return
	_repo_oids[repo_dir] = oid

	for path in _blames.keys():
		if _blames[path][Keys.REPO] == repo_dir:
			_blames.erase(path)

	_attach_current()


## Call after changing _enabled. Turning it off drops the cache as well as the row: the spawns are
## the cost being asked about, and holding results for a feature nobody is watching is the rest of it.
func apply_settings() -> void:
	if not _enabled:
		_blames.clear()
		line_blame.emit({})
		return
	_attach_current()


func clean_up() -> void:
	_teardown()


# fine to run twice if needed (clean_up + predelete)
func _teardown() -> void:
	_join_thread()
	_blames.clear()
	_code_edit = null
	# a hot reload leaves the gutter alive holding a Callable into an object that no longer exists
	if is_instance_valid(gutter) and gutter.hunks_changed.is_connected(_on_hunks_changed):
		gutter.hunks_changed.disconnect(_on_hunks_changed)

#endregion


#region attaching

# using tab changed allows for any text doc type
func _on_tab_changed() -> void:
	_attach_current.call_deferred()


func _attach_current() -> void:
	if not _enabled:
		return

	var sl_man = ScriptListManager.get_instance()
	var current_editor = sl_man.get_current_script_editor()

	# a help doc has no buffer to attribute. Cleared rather than left alone, unlike the gutter's
	# early-out: the gutter draws into a CodeEdit that is no longer on screen, where this row is
	# always on screen and would go on describing the file behind the docs
	if not is_instance_valid(current_editor) or not current_editor.has_method("get_base_editor"):
		_path = ""
		_code_edit = null
		_last_line = -1
		line_blame.emit({})
		return

	_attach(current_editor.get_base_editor(),
		sl_man.get_current_item_data().get(ScriptListManager.Keys.TOOLTIP, ""))


func _attach(code_edit:CodeEdit, path:String) -> void:
	if not is_instance_valid(code_edit):
		return

	# whatever the row still shows belongs to the file being left, so clear it before anything can
	# make the new one's answer take a spawn to arrive
	if path != _path:
		_last_line = -1
		line_blame.emit({})

	_path = path
	# only one editor is ever held, unlike the gutter's set: it draws into every open tab, where this
	# reports on the caret, of which there is one
	_code_edit = code_edit

	if path.is_empty() or path.contains("::"): # "::" -> tscn script, nah
		return

	# it can have moved out of the tracked set since it was attached — set_repos may have just taken
	# its repo away
	var repo = GitUtil.find_repo_for(path, _repos)
	if repo.is_empty():
		return

	# draw from the cache now so a tab switch does not wait on a spawn that will answer the same
	if _blames.has(path):
		_emit_current()
	_request_blame(path, repo)


# The buffer moved against HEAD, so the caret's line may now map somewhere else — or map at all,
# where before the baseline had not landed and the hunks were empty for want of one.
func _on_hunks_changed(code_edit:CodeEdit) -> void:
	if code_edit == _code_edit:
		_emit_current()


func _on_caret_changed() -> void:
	if not _enabled or not is_instance_valid(_code_edit):
		return
	var line = _code_edit.get_caret_line()
	if line == _last_line:
		return # moved along the line, not off it
	_last_line = line
	_emit_current()

#endregion


#region resolving

func _emit_current() -> void:
	line_blame.emit(_resolve())


# The commit behind the caret line. {} whenever the answer would be a guess: a file with no history,
# a blame still in flight, or hunks that have not caught up with the buffer.
func _resolve() -> Dictionary:
	if not _enabled or not is_instance_valid(_code_edit):
		return {}

	var blame:Dictionary = _blames.get(_path, {})
	if blame.is_empty():
		return {} # still in flight

	var line = _code_edit.get_caret_line()
	var hunks:Array = gutter.get_hunks(_code_edit) if is_instance_valid(gutter) else []
	var head_line = GitDiff.map_new_to_old(hunks, line)

	# typed since the commit, so there is nothing committed that owns it
	if head_line < 0:
		return {Keys.LINE: line, Keys.UNCOMMITTED: true}

	var blame_lines:PackedStringArray = blame[GitUtil.Keys.BLAME_LINES]
	# a file git has no history for, or hunks a keystroke behind the buffer they are mapping
	if head_line >= blame_lines.size():
		return {}

	var commit:Dictionary = blame[GitUtil.Keys.COMMITS].get(blame_lines[head_line], {})
	if commit.is_empty():
		return {}

	var info = commit.duplicate()
	info[Keys.LINE] = line
	info[Keys.UNCOMMITTED] = false
	return info

#endregion


#region the blame read

# `git blame` off the main thread, on this object's own Thread and not the gutter's — the file is
# often not in the panel's selected repo, and both commands only read, so they may overlap.
#
# Cached rather than re-read on every attach, unlike the gutter's baseline: blame walks history where
# `git show` reads one blob, and head_moved already flushes it when the answer could have changed.
func _request_blame(res_path:String, repo_dir:String) -> void:
	if _blames.has(res_path):
		return

	if is_instance_valid(_thread) and _thread.is_alive():
		# only the newest request can matter, so replace rather than queue
		_pending = [res_path, repo_dir]
		return

	_join_thread()
	_pending = []
	_thread = Thread.new()
	_thread.start(_blame_task.bind(res_path, repo_dir, _repo_oids.get(repo_dir, "")))


func _blame_task(res_path:String, repo_dir:String, oid:String) -> void:
	_on_blame_ready.call_deferred(res_path, repo_dir, oid, GitUtil.get_blame(repo_dir, res_path))


func _on_blame_ready(res_path:String, repo_dir:String, oid:String, result:Dictionary) -> void:
	_join_thread()

	# a commit landing mid-read makes this the previous HEAD's answer. Guarded by oid, not "is this
	# still the open tab": a result for a tab the user left is a cache entry they are about to want back
	if _repo_oids.get(repo_dir, "") == oid:
		# stored even when git had nothing to say, so a file with no history is asked about once
		# rather than on every visit to its tab
		_blames[res_path] = {
			Keys.REPO: repo_dir,
			GitUtil.Keys.COMMITS: result[GitUtil.Keys.COMMITS],
			GitUtil.Keys.BLAME_LINES: result[GitUtil.Keys.BLAME_LINES],
		}

	if not _pending.is_empty():
		var next = _pending
		_pending = []
		_request_blame(next[0], next[1])

	_emit_current()


# Mandatory before this object is freed: Godot errors on a Thread that is still running.
func _join_thread() -> void:
	if not is_instance_valid(_thread):
		return
	_thread.wait_to_finish()
	_thread = null

#endregion


class Keys:
	## one entry of _blames, alongside GitUtil's COMMITS and BLAME_LINES
	const REPO = &"repo"

	## the line_blame payload, on top of the commit's own fields
	const LINE = &"line"
	## the line was typed since the commit, so the rest of the payload is absent rather than stale
	const UNCOMMITTED = &"uncommitted"
