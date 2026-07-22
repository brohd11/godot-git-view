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

# the FILES dict the rows were built from, and the one a command's pathspecs resolve against. Not
# GitService.get_file_status(): that answers from the repo owning the path, which a nested clone
# makes a different repo from the one `git -C` will run in.
var _files:Dictionary = {}
# the repo those keys are relative to — what turns a row back into something to show the user
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

	ScriptDock.get_right_click_handler().display_popup(options)


# One entry per command with something to do to the selection: each is handed only the subset it
# accepts (staging a mixed selection stages what it can), and one no file accepts is not offered.
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

		# the destructive pair is unrecoverable and one click away, so keep it apart from the rest
		if entry[GitUtil.Keys.CMD_DESTRUCTIVE] and not separated:
			options.add_separator("Destructive")
			separated = true

		options.add_option(_command_label(entry, paths, selected_paths),
			_changes_command.bind(command, paths))


# Says so when a command will act on fewer files than are selected — otherwise "Unstage" over five
# rows of which two are staged gives no hint the other three are left alone.
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


# Discarding a file git reports as deleted *restores* it, so the destructive framing is wrong there —
# and a bare file name is not enough to recognise the file by, since two dirs can hold the same one.
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
