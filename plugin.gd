@tool
extends EditorPlugin

## editor entry point for the git panel, gutter, minimap, and blame row.

const DiffGutter = preload("res://addons/git_view/src/diff_gutter/git_diff_gutter.gd")
const RegionMinimap = preload("res://addons/git_view/src/minimap/code_region_minimap.gd")
const GitPanel = preload("res://addons/git_view/src/panel/panel.gd")
const BlameTracker = preload("res://addons/git_view/src/blame/blame_tracker.gd")

const GIT_SECTION = &"GitView"

var diff_gutter:DiffGutter
var region_minimap:RegionMinimap
var git_panel:GitPanel
var blame_tracker:BlameTracker

var dock_manager:DockManager


func _get_plugin_name() -> String:
	return "Git View"
func _get_plugin_icon() -> Texture2D:
	return EditorInterface.get_base_control().get_theme_icon("Node", &"EditorIcons")

func _enable_plugin() -> void:
	pass

func _disable_plugin() -> void:
	pass

func _enter_tree() -> void:
	var gs = GitService.register_node(self)

	diff_gutter = DiffGutter.new()
	add_child(diff_gutter)
	gs.refresh_finished.connect(_on_git_refresh_finished)
	gs.status_updated.connect(_on_git_status_updated)
	diff_gutter.set_repos(gs.repos)

	region_minimap = RegionMinimap.new()
	add_child(region_minimap)
	
	await get_tree().process_frame
	
	git_panel = GitPanel.new()
	
	var script_dock = Singletons.CheckInstance.get_instance("ScriptDock")
	if not is_instance_valid(script_dock): # if ScriptDock is available: add. Not a hard dep
		return
	script_dock.call_on_ready(script_dock.add_section.bind(GIT_SECTION, git_panel))

	blame_tracker = BlameTracker.new()
	blame_tracker.gutter = diff_gutter
	blame_tracker.line_blame.connect(git_panel.set_blame)
	add_child(blame_tracker)
	blame_tracker.set_repos(gs.repos)


func _exit_tree() -> void:
	var script_dock = Singletons.CheckInstance.get_instance("ScriptDock")
	if is_instance_valid(script_dock):
		var gp_section = script_dock.get_instance().sidebar_container.get_section(GIT_SECTION)
		if is_instance_valid(gp_section):
			script_dock.remove_section(GIT_SECTION)
			git_panel.queue_free()
	
	if is_instance_valid(blame_tracker):
		blame_tracker.clean_up()
	if is_instance_valid(diff_gutter):
		diff_gutter.clean_up()
	if is_instance_valid(region_minimap):
		region_minimap.clean_up()
	
	GitService.unregister_node(self)


func _on_git_status_updated(repo_dir:String) -> void:
	var oid = GitService.get_instance().get_branch_oid_for(repo_dir)
	if is_instance_valid(diff_gutter):
		diff_gutter.head_moved(repo_dir, oid)
	if is_instance_valid(blame_tracker):
		blame_tracker.head_moved(repo_dir, oid)


func _on_git_refresh_finished() -> void:
	var repos = GitService.get_instance().repos
	if is_instance_valid(diff_gutter):
		diff_gutter.set_repos(repos)
	if is_instance_valid(blame_tracker):
		blame_tracker.set_repos(repos)
