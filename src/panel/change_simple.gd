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

func set_files(file_paths:Array):
	
	clear()
	
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


# One entry per command that has something to do to the selection. A command is handed only the
# subset it accepts — staging a mixed selection stages what it can rather than failing on the rest —
# and a command no selected file accepts is not offered at all.
func _add_command_options(options:Options, selected_paths:Array) -> void:
	var separated = false
	if not options.is_empty():
		options.add_separator("Git")

	for command:GitUtil.Command in GitUtil.COMMANDS:
		var entry:Dictionary = GitUtil.COMMANDS[command]

		var paths = selected_paths.filter(
			func(path): return GitUtil.command_accepts(command, git_service.get_file_status(path))
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
	changes_command.emit(command, paths)
