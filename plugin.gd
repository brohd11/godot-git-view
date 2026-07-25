@tool
extends EditorPlugin

const DiffGutter = preload("res://addons/git_view/src/diff_gutter/git_diff_gutter.gd")
const RegionMinimap = preload("res://addons/git_view/src/minimap/code_region_minimap.gd")
const GitPanel = preload("res://addons/git_view/src/panel/panel.gd")

const GIT_SECTION = &"GitView"

var diff_gutter:DiffGutter
var region_minimap:RegionMinimap
var git_panel:GitPanel

var dock_manager:DockManager


func _get_plugin_name() -> String:
	return "Git View"
func _get_plugin_icon() -> Texture2D:
	return EditorInterface.get_base_control().get_theme_icon("Node", &"EditorIcons")
func _has_main_screen() -> bool:
	return true

func _make_visible(visible:bool) -> void:
	pass

func _enable_plugin() -> void:
	pass

func _disable_plugin() -> void:
	pass

func _enter_tree() -> void:
	var gs = GitService.register_node(self)

	diff_gutter = DiffGutter.new()
	add_child(diff_gutter)
	gs.repos_updated.connect(_on_git_repos_updated)
	gs.status_updated.connect(_on_git_status_updated)
	# repos_updated already fired in GitService ready, sync in set_repos
	diff_gutter.set_repos(gs.repos)

	# doesn't use git, but does use the minimap
	region_minimap = RegionMinimap.new()
	add_child(region_minimap)
	
	await get_tree().process_frame
	
	git_panel = GitPanel.new()
	
	var script_dock = Singletons.CheckInstance.get_instance("ScriptDock")
	if is_instance_valid(script_dock): # if ScriptDock is available: add. Not a hard dep
		script_dock.call_on_ready(script_dock.add_section.bind(GIT_SECTION, git_panel))


func _exit_tree() -> void:
	var script_dock = Singletons.CheckInstance.get_instance("ScriptDock")
	if is_instance_valid(script_dock):
		var gp_section = script_dock.get_instance().sidebar_container.get_section(GIT_SECTION)
		if is_instance_valid(gp_section):
			script_dock.remove_section(GIT_SECTION)
			git_panel.queue_free()
	
	if is_instance_valid(diff_gutter):
		diff_gutter.clean_up()
	if is_instance_valid(region_minimap):
		region_minimap.clean_up()
	
	GitService.unregister_node(self)


# commits move HEAD, so flush and re-read every open script's baseline in that repo.
func _on_git_status_updated(repo_dir:String) -> void:
	if is_instance_valid(diff_gutter):
		# for repo_dir, not the panel's current repo — status_updated fires for every repo and
		# get_branch_oid() hands back current_repo's oid; a wrong oid stored here silently suppresses a real flush later
		diff_gutter.head_moved(repo_dir, GitService.get_instance().get_branch_oid_for(repo_dir))


func _on_git_repos_updated() -> void:
	if is_instance_valid(diff_gutter):
		diff_gutter.set_repos(GitService.get_instance().repos)
