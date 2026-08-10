extends VBoxContainer

## renders git service data in the editor sidebar.


const UtilsRemote = preload("res://addons/git_view/src/util/utils_remote.gd")
const UControl = UtilsRemote.UControl
const TabBarContainer = UtilsRemote.TabBarContainer
const RightClickHandler = UtilsRemote.RightClickHandler
const Options = UtilsRemote.Options
const UOs = ALibRuntime.Utils.UOs

const UtilsLocal = preload("res://addons/git_view/src/util/utils_local.gd")

const GitUtil = UtilsRemote.GitUtil
const ChangeList = preload("res://addons/git_view/src/panel/change_list.gd")
const CommitList = preload("res://addons/git_view/src/panel/commit_list.gd")
const BlameRow = preload("res://addons/git_view/src/panel/blame_row.gd")

const MAIN_REPO = "res://"
const MAIN_REPO_TITLE = "Project"

var right_click_handler:RightClickHandler

var repo_popup_button:Button
var repo_label:Label
var top_row:HBoxContainer
var branch_hbox:HBoxContainer
var branch_texture:TextureRect
var branch_label:Label
var divergence_label:Label
var tab_container:TabBarContainer
var change_list:ChangeList
var commit_list:CommitList
var blame_row:BlameRow

var _git:GitService

var _dock_data:Dictionary
var _initialized:=false


func get_dock_data() -> Dictionary:
	return {
		Keys.CURRENT_REPO: _git.current_repo if is_instance_valid(_git) else MAIN_REPO,
		Keys.CURRENT_TAB: tab_container.get_tab_bar().current_tab,
	}


func set_dock_data(data:Dictionary) -> void:
	_dock_data = data
	_apply_dock_data()


func _ready() -> void:
	right_click_handler = RightClickHandler.new()
	add_child(right_click_handler)
	
	top_row = HBoxContainer.new()
	top_row.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(top_row)
	
	repo_popup_button = Button.new()
	repo_popup_button.theme_type_variation = &"FlatButton"
	repo_popup_button.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	repo_popup_button.icon = EditorInterface.get_editor_theme().get_icon(&"TexturePreviewChannels", &"EditorIcons")
	repo_popup_button.pressed.connect(_on_repo_popup_pressed)
	top_row.add_child(repo_popup_button)
	
	repo_label = Label.new()
	repo_label.text = MAIN_REPO_TITLE
	repo_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	top_row.add_child(repo_label)
	repo_label.add_theme_stylebox_override(&"normal", StyleBoxEmpty.new())
	
	
	top_row.add_child(VSeparator.new())
	
	branch_hbox = HBoxContainer.new()
	top_row.add_child(branch_hbox)
	
	branch_texture = TextureRect.new()
	branch_texture.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	branch_texture.texture = EditorInterface.get_editor_theme().get_icon(&"VcsBranches", &"EditorIcons")
	branch_texture.mouse_filter = Control.MOUSE_FILTER_IGNORE
	branch_hbox.add_child(branch_texture)

	branch_label = Label.new()
	branch_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	branch_hbox.add_child(branch_label)
	branch_label.add_theme_stylebox_override(&"normal", StyleBoxEmpty.new())

	divergence_label = Label.new()
	branch_hbox.add_child(divergence_label)

	blame_row = BlameRow.new()
	add_child(blame_row)

	tab_container = TabBarContainer.new()
	add_child(tab_container)
	UControl.expand(tab_container)
	
	change_list = ChangeList.new()
	change_list.name = "Changes"
	change_list.changes_command.connect(_on_changes_command)
	tab_container.add_tab(change_list)
	change_list.right_click_handler = right_click_handler
	UtilsLocal.set_item_list_sb(change_list)

	commit_list = CommitList.new()
	commit_list.name = "Commits"
	tab_container.add_tab(commit_list)
	UtilsLocal.set_item_list_sb(commit_list)

	var glyph_icons = GitService.get_glyph_icons_node()
	if is_instance_valid(glyph_icons):
		glyph_icons.generated.connect(change_list.queue_redraw)

	_bind_service()

	if not _initialized:
		_apply_dock_data()


func _bind_service() -> void:
	_git = GitService.get_instance()
	if not is_instance_valid(_git):
		return

	_git.status_updated.connect(_on_status_updated)
	_git.commits_updated.connect(_on_commits_updated)

	if not _git.status.is_empty():
		_on_status_updated(_git.current_repo)
	if not _git.commits.is_empty():
		_on_commits_updated(_git.current_repo)


func _apply_dock_data() -> void:
	tab_container.set_current_tab(int(_dock_data.get(Keys.CURRENT_TAB, 0)))
	var saved_repo:String = _dock_data.get(Keys.CURRENT_REPO, MAIN_REPO)
	_dock_data = {}

	if is_instance_valid(_git) and saved_repo != _git.current_repo and saved_repo in _git.repos:
		_clear_lists() # clear the default repo's rows while the restored repo's calls run
		_git.set_repo(saved_repo)

	_initialized = true


func clean_up() -> void:
	if not is_instance_valid(_git):
		return
	if _git.status_updated.is_connected(_on_status_updated):
		_git.status_updated.disconnect(_on_status_updated)
	if _git.commits_updated.is_connected(_on_commits_updated):
		_git.commits_updated.disconnect(_on_commits_updated)


func _on_repo_popup_pressed():
	var options = Options.new()
	options.add_option("Terminal", UOs.launch_term.bind("", _git.current_repo), ["Terminal"])
	var marker_icon = GitService.GitDataDraw.Util.get_marker_icon()
	for repo in _git.repos:
		var status = _git.get_repo_status(repo)
		var color = Color.WHITE if status.files.is_empty() else _git.colors.modified
		options.add_option("Repo/" + _get_repo_name(repo), _select_repo.bind(repo), ["TexturePreviewChannels", marker_icon])
		options.add_option_data("Repo/" + _get_repo_name(repo), [null, color])
	
	right_click_handler.display_on_control(options, repo_popup_button, Vector2(0, repo_popup_button.size.y))

func _select_repo(repo_dir:String):
	if _git.current_repo == repo_dir:
		return
	_clear_lists()
	_git.set_repo(repo_dir)

func _get_repo_name(repo_dir:String):
	return MAIN_REPO_TITLE if repo_dir == MAIN_REPO else repo_dir.trim_suffix("/").get_file()

func _clear_lists() -> void:
	change_list.set_files([])
	commit_list.clear_commits()

	branch_label.text = ""
	divergence_label.hide()
	top_row.tooltip_text = ""


func _on_status_updated(_repo_dir:String) -> void:
	_rebuild_change_list()
	_update_repo_info()


func _update_repo_info() -> void:
	var info = GitUtil.get_repo_info(_git.status, _git.commits)
	var branch:Dictionary = info[GitUtil.Keys.BRANCH]
	
	repo_label.text = _get_repo_name(_git.current_repo)

	branch_label.text = branch.get(GitUtil.Keys.BRANCH_NAME)
	branch_hbox.tooltip_text = GitUtil.format_repo_tooltip(info)

	var divergence = GitUtil.get_divergence_label(branch)
	divergence_label.text = divergence
	divergence_label.visible = not divergence.is_empty()

	if not divergence.is_empty():
		divergence_label.add_theme_color_override(&"font_color",
			GitUtil.Colors.L_YELLOW if branch[GitUtil.Keys.BRANCH_BEHIND] > 0
			else GitUtil.Colors.L_GREEN)

	


func _on_commits_updated(_repo_dir:String) -> void:
	_rebuild_commit_list()


func _rebuild_change_list() -> void:
	if not is_instance_valid(_git):
		return
	
	var files:Dictionary = _git.status.get(GitUtil.Keys.FILES, {})
	var paths = files.keys()
	paths.sort()
	change_list.set_files(paths, files, _git.current_repo)


func _rebuild_commit_list() -> void:
	commit_list.clear_commits()
	for commit in _git.commits:
		commit_list.add_commit(commit)


func _on_changes_command(command:GitUtil.Command, paths:Array):
	_git.run_command(command, paths)


func set_blame(info:Dictionary) -> void:
	if is_instance_valid(blame_row):
		blame_row.set_blame(info)


class Keys:
	const CURRENT_REPO = &"git_panel.current_repo"
	const CURRENT_TAB = &"git_panel.current_tab"
