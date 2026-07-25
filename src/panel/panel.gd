extends VBoxContainer

## The sidebar's Git section — a view over GitService.
##
## Owns no git state; renders what GitService publishes and pushes user actions back to it.
## GitService runs git off the main thread and emits `status_updated` / `commits_updated` / `repos_updated`.

const UtilsRemote = preload("res://addons/git_view/src/util/utils_remote.gd")
const UControl = UtilsRemote.UControl
const TabBarContainer = UtilsRemote.TabBarContainer
const RightClickHandler = UtilsRemote.RightClickHandler
const Options = UtilsRemote.Options

const UtilsLocal = preload("res://addons/git_view/src/util/utils_local.gd")

const GitUtil = UtilsRemote.GitUtil
const ChangeList = preload("res://addons/git_view/src/panel/change_list.gd")
const CommitList = preload("res://addons/git_view/src/panel/commit_list.gd")

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

# bound in _ready; every rendered value comes from here
var _git:GitService

var _dock_data:Dictionary
var _initialized:=false


func get_dock_data() -> Dictionary:
	return {
		Keys.CURRENT_REPO: _git.current_repo if is_instance_valid(_git) else MAIN_REPO,
		Keys.CURRENT_TAB: tab_container.get_tab_bar().current_tab,
	}


## Arrives after _ready — the nodes already exist, so apply straight away.
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
	
	
	#branch_row.add_spacer(false)
	top_row.add_child(VSeparator.new())
	
	branch_hbox = HBoxContainer.new()
	top_row.add_child(branch_hbox)
	
	branch_texture = TextureRect.new()
	branch_texture.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	branch_texture.texture = EditorInterface.get_editor_theme().get_icon(&"VcsBranches", &"EditorIcons")
	branch_texture.mouse_filter = Control.MOUSE_FILTER_IGNORE
	branch_hbox.add_child(branch_texture)

	# keep labels separate: ellipsis trims the branch name, so a combined label would hide the divergence
	branch_label = Label.new()
	#branch_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	#branch_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	branch_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	branch_hbox.add_child(branch_label)
	branch_label.add_theme_stylebox_override(&"normal", StyleBoxEmpty.new())

	divergence_label = Label.new()
	branch_hbox.add_child(divergence_label)

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

	# rows fetch status textures at draw time, so a late icon bake only needs a redraw
	var glyph_icons = GitService.get_glyph_icons_node()
	if is_instance_valid(glyph_icons):
		glyph_icons.generated.connect(change_list.queue_redraw)

	# GitService is already registered by ScriptDock when this panel is built
	_bind_service()

	if not _initialized:
		_apply_dock_data()


func _bind_service() -> void:
	_git = GitService.get_instance()
	if not is_instance_valid(_git):
		# no service to render against; later signals would hit a dead panel
		return

	_git.status_updated.connect(_on_status_updated)
	_git.commits_updated.connect(_on_commits_updated)
	_git.repos_updated.connect(_on_repos_updated)

	# render any status/commits/repos the service already scanned
	_on_repos_updated()
	if not _git.status.is_empty():
		_on_status_updated(_git.current_repo)
	if not _git.commits.is_empty():
		_on_commits_updated(_git.current_repo)


func _apply_dock_data() -> void:
	tab_container.set_current_tab(int(_dock_data.get(Keys.CURRENT_TAB, 0)))
	var saved_repo:String = _dock_data.get(Keys.CURRENT_REPO, MAIN_REPO)
	_dock_data = {}

	# restore the saved repo through the service; set_repo no-ops if unchanged
	if is_instance_valid(_git) and saved_repo != _git.current_repo and saved_repo in _git.repos:
		_clear_lists() # clear the default repo's rows while the restored repo's calls run
		_git.set_repo(saved_repo)

	_initialized = true


func clean_up() -> void:
	if not is_instance_valid(_git):
		return
	# the service outlives this panel; disconnect so it can't emit into a freed node
	if _git.status_updated.is_connected(_on_status_updated):
		_git.status_updated.disconnect(_on_status_updated)
	if _git.commits_updated.is_connected(_on_commits_updated):
		_git.commits_updated.disconnect(_on_commits_updated)
	
	#if _git.repos_updated.is_connected(_on_repos_updated):
		#_git.repos_updated.disconnect(_on_repos_updated)


func _on_repos_updated() -> void:
	return


func _on_repo_popup_pressed():
	var options = Options.new()
	for repo in _git.repos:
		options.add_option("Repo/" + _get_repo_name(repo), _select_repo.bind(repo))
	
	right_click_handler.display_on_control(options, repo_popup_button, Vector2(0, repo_popup_button.size.y))

func _select_repo(repo_dir:String):
	if _git.current_repo == repo_dir:
		return
	# clear old rows while the new repo's git calls run; the branch label is the worst to keep
	_clear_lists()
	_git.set_repo(repo_dir)

func _get_repo_name(repo_dir:String):
	return MAIN_REPO_TITLE if repo_dir == MAIN_REPO else repo_dir.trim_suffix("/").get_file()

# Clear old rows while another repo's data is in flight — showing the old branch under the new repo's name is worse than empty.
func _clear_lists() -> void:
	# use set_files so the rows and their status dict stay matched; a menu built from a stale dict is dangerous
	change_list.set_files([])
	commit_list.clear_commits()

	branch_label.text = ""
	divergence_label.hide()
	top_row.tooltip_text = ""


func _on_status_updated(_repo_dir:String) -> void:
	_rebuild_change_list()
	_update_repo_info()


# reads status/log GitService already fetched; both members are assigned before either signal emits
func _update_repo_info() -> void:
	var info = GitUtil.get_repo_info(_git.status, _git.commits)
	var branch:Dictionary = info[GitUtil.Keys.BRANCH]
	
	repo_label.text = _get_repo_name(_git.current_repo)

	#branch_label.text = GitUtil.get_branch_label(branch)
	branch_label.text = branch.get(GitUtil.Keys.BRANCH_NAME)
	branch_hbox.tooltip_text = GitUtil.format_repo_tooltip(info)

	var divergence = GitUtil.get_divergence_label(branch)
	divergence_label.text = divergence
	divergence_label.visible = not divergence.is_empty()

	# "behind" means there is something to pull, so it gets the attention color
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
	# the status dict must match the rows: command offerings and pathspecs are built from this snapshot
	change_list.set_files(paths, files, _git.current_repo)


func _rebuild_commit_list() -> void:
	commit_list.clear_commits()
	# git returned these newest first; don't re-sort
	for commit in _git.commits:
		commit_list.add_commit(commit)


func _on_changes_command(command:GitUtil.Command, paths:Array):
	_git.run_command(command, paths)


class Keys:
	const CURRENT_REPO = &"git_panel.current_repo"
	const CURRENT_TAB = &"git_panel.current_tab"
