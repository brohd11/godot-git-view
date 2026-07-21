@tool
extends EditorPlugin

## Owns the script-editor diff gutter, driven by the shared GitService (registered as a consumer).
## The main-screen scaffolding below is a stub for the eventual full-screen git view.

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
	# repos_updated already fired during registration, above — sync the current list in
	diff_gutter.set_repos(gs.repos)

	# no GitService signals: the region labels are a navigation aid on any open script, git or not
	region_minimap = RegionMinimap.new()
	add_child(region_minimap)
	
	await get_tree().process_frame
	
	git_panel = GitPanel.new()
	
	if ScriptDock.instance_valid(): # this could be a nameless check
		ScriptDock.call_on_ready(ScriptDock.add_section.bind(GIT_SECTION, git_panel))


func _exit_tree() -> void:
	ScriptDock.remove_section(GIT_SECTION)
	git_panel.queue_free()
	# the gutter added gutters into CodeEdits that outlive us — tear those out before we free
	if is_instance_valid(diff_gutter):
		diff_gutter.clean_up()
	# same for the region labels' draw connections
	if is_instance_valid(region_minimap):
		region_minimap.clean_up()
	GitService.unregister_node(self)


# A commit is a new baseline for every script open under that repo; the gutter flushes and re-reads
# baselines when HEAD moves.
func _on_git_status_updated(repo_dir:String) -> void:
	if is_instance_valid(diff_gutter):
		# for repo_dir, not the panel's current repo — status_updated fires for every repo and
		# get_branch_oid() hands back current_repo's oid; a wrong oid stored here silently suppresses a real flush later
		diff_gutter.head_moved(repo_dir, GitService.get_instance().get_branch_oid_for(repo_dir))


func _on_git_repos_updated() -> void:
	if is_instance_valid(diff_gutter):
		diff_gutter.set_repos(GitService.get_instance().repos)
