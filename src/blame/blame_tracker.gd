extends Node

## maps the active caret line back to its HEAD commit.


const UtilsLocal = preload("res://addons/git_view/src/util/utils_local.gd")
const UtilsRemote = preload("res://addons/git_view/src/util/utils_remote.gd")

const SettingHelperEditor = UtilsRemote.SettingHelperEditor
const ScriptListManager = UtilsRemote.ScriptListManager

const GitUtil = UtilsRemote.GitUtil
const GitDiff = UtilsRemote.GitDiff

const DiffGutter = preload("res://addons/git_view/src/diff_gutter/git_diff_gutter.gd")

signal line_blame(info:Dictionary)

var gutter:DiffGutter

var setting_helper:SettingHelperEditor
var _enabled:bool = true

var _blames:Dictionary = {}
var _repo_oids:Dictionary = {}
var _repos:Array[String] = []

var _code_edit:CodeEdit
var _path:String = ""
var _last_line:int = -1

var _thread:Thread
var _pending:Array = []


func _ready() -> void:
	ScriptEditorRef.subscribe(ScriptEditorRef.Event.TAB_CHANGED, _on_tab_changed, 1)
	ScriptEditorRef.subscribe(ScriptEditorRef.Event.CARET_CHANGED, _on_caret_changed)

	if is_instance_valid(gutter):
		gutter.hunks_changed.connect(_on_hunks_changed)

	setting_helper = SettingHelperEditor.new()
	setting_helper.subscribe_property(self, &"_enabled", UtilsLocal.EditorSet.BLAME_CARET_LINE, true)
	setting_helper.initialize()
	setting_helper.settings_changed.connect(apply_settings, 1)

	await get_tree().process_frame
	Singletons.CheckInstance.call_on_ready("ScriptTabSingleton", _attach_current)


#region lifecycle

func set_repos(repos:Array[String]) -> void:
	if _repos == repos:
		return
	_repos = repos.duplicate()
	_blames.clear()
	_attach_current()


func head_moved(repo_dir:String, oid:String) -> void:
	if _repo_oids.get(repo_dir, "") == oid:
		return
	_repo_oids[repo_dir] = oid

	for path in _blames.keys():
		if _blames[path][Keys.REPO] == repo_dir:
			_blames.erase(path)

	_attach_current()


func apply_settings() -> void:
	if not _enabled:
		_blames.clear()
		line_blame.emit({})
		return
	_attach_current()


func clean_up() -> void:
	_teardown()


func _teardown() -> void:
	_join_thread()
	_blames.clear()
	_code_edit = null
	if is_instance_valid(gutter) and gutter.hunks_changed.is_connected(_on_hunks_changed):
		gutter.hunks_changed.disconnect(_on_hunks_changed)

#endregion


#region attaching

func _on_tab_changed() -> void:
	_attach_current.call_deferred()


func _attach_current() -> void:
	if not _enabled:
		return

	var sl_man = ScriptListManager.get_instance()
	var current_editor = sl_man.get_current_script_editor()

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

	if path != _path:
		_last_line = -1
		line_blame.emit({})

	_path = path
	_code_edit = code_edit

	if path.is_empty() or path.contains("::"): # "::" -> tscn script, nah
		return

	var repo = GitUtil.find_repo_for(path, _repos)
	if repo.is_empty():
		return

	if _blames.has(path):
		_emit_current()
	_request_blame(path, repo)


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


func _resolve() -> Dictionary:
	if not _enabled or not is_instance_valid(_code_edit):
		return {}

	var blame:Dictionary = _blames.get(_path, {})
	if blame.is_empty():
		return {} # still in flight

	var line = _code_edit.get_caret_line()
	var hunks:Array = gutter.get_hunks(_code_edit) if is_instance_valid(gutter) else []
	var head_line = GitDiff.map_new_to_old(hunks, line)

	if head_line < 0:
		return {Keys.LINE: line, Keys.UNCOMMITTED: true}

	var blame_lines:PackedStringArray = blame[GitUtil.Keys.BLAME_LINES]
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

func _request_blame(res_path:String, repo_dir:String) -> void:
	if _blames.has(res_path):
		return

	if is_instance_valid(_thread) and _thread.is_alive():
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

	if _repo_oids.get(repo_dir, "") == oid:
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


func _join_thread() -> void:
	if not is_instance_valid(_thread):
		return
	_thread.wait_to_finish()
	_thread = null

#endregion


class Keys:
	const REPO = &"repo"

	const LINE = &"line"
	const UNCOMMITTED = &"uncommitted"
