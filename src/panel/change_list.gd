extends ItemList

const GitUtil = GitService.GitUtil
const GitDataDraw = GitService.GitDataDraw


const UtilsRemote = preload("res://addons/git_view/src/util/utils_remote.gd")
const RightClickHandler = UtilsRemote.RightClickHandler
const Options = UtilsRemote.Options

const NUItemList = UtilsRemote.NUItemList
const FSSmallPopup = UtilsRemote.FSSmallPopup

var git_service:GitService
var icon_overlay:GitDataDraw.GitItemHelper

var right_click_handler:RightClickHandler

# Source-of-truth status dict for the rows, not GitService.get_file_status(): nested clones make
# the repo owning the path differ from the one `git -C` runs in.
var _files:Dictionary = {}
# repo the displayed paths are relative to
var _repo_dir:String = ""

signal changes_command(command:GitUtil.Command, paths:Array)


func _init() -> void:
	git_service = GitService.get_instance()
	icon_overlay = GitDataDraw.GitItemHelper.new(self)
	right_click_handler = RightClickHandler.new()
	add_child(right_click_handler)
	
	select_mode = ItemList.SELECT_MULTI
	allow_rmb_select = true
	item_clicked.connect(_on_item_clicked)
	item_activated.connect(_on_item_activated)

func set_files(file_paths:Array, files:Dictionary={}, repo_dir:String=""):

	clear()
	_files = files
	_repo_dir = repo_dir

	for p in file_paths:
		var idx = item_count
		add_item(p.get_file())
		set_item_metadata(idx, p)
		set_item_tooltip(idx, p)
		
		#icon_overlay.set_item_fg_color(idx, p)
		

func _on_item_activated(idx:int):
	var path = get_item_metadata(idx)
	FileSystemSingleton.activate_path(path)

func _on_item_clicked(_index:int, _at_pos:Vector2, mouse_button:int):
	if mouse_button == MOUSE_BUTTON_RIGHT:
		_on_item_right_clicked()

func _on_item_right_clicked():

	var selected_paths = NUItemList.get_selected_meta(self)
	var options = Options.new()
	if selected_paths.size() == 1:
		var path = selected_paths[0]
		
		var valid = FSSmallPopup.right_click(options, path)
		if valid != FSSmallPopup.FileStatus.VALID:
			options = Options.new()
	
	_add_command_options(options, selected_paths)

	right_click_handler.display_popup(options)


# Add one option per command that applies to at least one selected file; a mixed selection only
# stages what the command accepts.
func _add_command_options(options:Options, selected_paths:Array) -> void:
	var separated = false
	if not options.is_empty():
		options.add_separator("Git")

	for command:GitUtil.Command in GitUtil.COMMANDS:
		var entry:Dictionary = GitUtil.COMMANDS[command]

		var paths = selected_paths.filter(
			func(path): return GitUtil.command_accepts(command, _files.get(path, {}))
		)
		if paths.is_empty():
			continue

		# keep destructive commands separated — they are one click and unrecoverable
		if entry[GitUtil.Keys.CMD_DESTRUCTIVE] and not separated:
			options.add_separator("Destructive")
			separated = true

		options.add_option(_command_label(entry, paths, selected_paths),
			_changes_command.bind(command, paths))


# Hint when a command skips some selected files, so "Unstage" on a mixed selection does not lie.
func _command_label(entry:Dictionary, paths:Array, selected_paths:Array) -> String:
	var label:String = entry[GitUtil.Keys.CMD_LABEL]
	if paths.size() == selected_paths.size():
		return label
	return "%s (%d of %d)" % [label, paths.size(), selected_paths.size()]


func _changes_command(command:GitUtil.Command, paths:Array):
	if command in GitUtil.COMMAND_DESTRUCTIVE:
		if not await ALibRuntime.Dialog.confirm(_confirm_text(command, paths), self):
			return
	changes_command.emit(command, paths)


# Discard on a deleted file actually restores it, and bare file names are ambiguous across dirs.
func _confirm_text(command:GitUtil.Command, paths:Array) -> String:
	var label:String = GitUtil.COMMANDS[command][GitUtil.Keys.CMD_LABEL]

	var restores_all = command == GitUtil.Command.DISCARD
	var lines:Array = []
	for p:String in paths:
		var file_data:Dictionary = _files.get(p, {})
		if file_data.get(GitUtil.Keys.WORKTREE, GitUtil.Status.NONE) != GitUtil.Status.DELETED:
			restores_all = false
		lines.append("  %s  (%s)" % [
			GitUtil.to_repo_path(_repo_dir, p) if not _repo_dir.is_empty() else p,
			GitUtil.get_status_label(file_data),
		])

	var heading = ("%s — every file below is deleted on disk, so this restores them from the index:"
		if restores_all else "Destructive git command: %s\nFiles:") % label
	return "%s\n%s\n\nProceed?" % [heading, "\n".join(lines)]
