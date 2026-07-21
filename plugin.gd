@tool
extends EditorPlugin

## Owns the script-editor diff gutter, driven by the shared GitService (registered as a consumer).
## The main-screen scaffolding below is a stub for the eventual full-screen git view.

const DiffGutter = preload("res://addons/git_view/src/diff_gutter/git_diff_gutter.gd")
const GitPanel = preload("res://addons/git_view/src/panel/panel.gd")


var diff_gutter:DiffGutter
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
	
	await get_tree().process_frame
	if ScriptDock.instance_valid(): # this could be a nameless check
		ScriptDock.call_on_ready(ScriptDock.add_section.bind(&"git_view", GitPanel.new()))


func _exit_tree() -> void:
	# the gutter added gutters into CodeEdits that outlive us — tear those out before we free
	if is_instance_valid(diff_gutter):
		diff_gutter.clean_up()
	GitService.unregister_node(self)


# A commit is a new baseline for every script open under that repo; the gutter flushes and re-reads
# baselines when HEAD moves.
func _on_git_status_updated(repo_dir:String) -> void:
	if is_instance_valid(diff_gutter):
		# for repo_dir, not for whichever repo the panel is pointed at — status_updated fires for every
		# repo now, and get_branch_oid() would hand each of them current_repo's oid. The gutter stores
		# that per repo and compares it next time, so a wrong oid here silently suppresses a real
		# baseline flush later.
		diff_gutter.head_moved(repo_dir, GitService.get_instance().get_branch_oid_for(repo_dir))


func _on_git_repos_updated() -> void:
	if is_instance_valid(diff_gutter):
		diff_gutter.set_repos(GitService.get_instance().repos)
