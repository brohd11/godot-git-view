extends "res://addons/git_view/src/util/overlay_item_list.gd"

## The Git section's Changes list.
##
## Rows read:  <file name>  <dimmed dir> ………………… <status>
##
## The dir yields, so a deep path shortens rather than crowding the file name. Below COMPACT_BELOW the
## status word drops to git's single letter, handing its width back to the name. That letter is a
## baked square rather than a string so the letters line up down the list (see glyph_icons.gd); until
## the cache is warm GlyphIcons returns null and the segment falls through to its `compact` string.

const RightClickHandler = UtilsRemote.RightClickHandler
const Options = UtilsRemote.Options


const GitUtil = UtilsRemote.GitUtil
const GlyphIcons = UtilsRemote.GlyphIcons

## unscaled px of list width below which the status word gives way to its letter
const COMPACT_BELOW = 200.0

var glyph_icons:GlyphIcons

# res:// path -> the status entry that built its row. The menu needs it: what a command can do to a
# file depends on its state, which the row alone does not say.
var _file_data:Dictionary = {}

signal changes_command(command:GitUtil.Command, paths:Array)

func _ready() -> void:
	super()
	compact_below = COMPACT_BELOW * EditorInterface.get_editor_scale()
	
	select_mode = ItemList.SELECT_MULTI
	allow_rmb_select = true
	item_clicked.connect(_on_item_clicked)
	glyph_icons = GitService.get_glyph_icons_node()


func clear_changes() -> void:
	clear_rows()
	_file_data.clear()


func add_change(res_path:String, repo_dir:String, file_data:Dictionary) -> void:
	var dir = res_path.get_base_dir().trim_prefix(repo_dir).trim_prefix("/")
	var letter = GitUtil.get_status_letter(file_data)
	_file_data[res_path] = file_data

	var compact_icon = glyph_icons.get_letter(letter) if is_instance_valid(glyph_icons) else null

	add_row(
		res_path.get_file(),
		[
			segment({
				&"text": dir,
				&"color": get_dim_color(),
				&"flex": true,
			}),
			segment({
				&"text": GitUtil.get_status_label(file_data),
				&"color": _get_status_color(file_data),
				&"align": Align.RIGHT,
				&"compact": letter,
				# null while the cache is cold; the letter above covers it
				&"compact_icon": compact_icon,
			}),
		],
		null, # the file name keeps ItemList's own colour: it is the primary here
		res_path, # metadata: what a click-to-open will read
		res_path,
	)


func get_selected_path() -> String:
	var path = get_selected_metadata()
	return path if path != null else ""

func get_selected_paths():
	var paths = []
	for i in get_selected_items():
		var meta = get_item_metadata(i)
		if meta:
			paths.append(meta)
	return paths


func _get_status_color(file_data:Dictionary) -> Color:
	# the line type settles conflicted and untracked outright, so neither can be shadowed by the
	# staged/unstaged pair below
	match file_data.get(GitUtil.Keys.KIND, GitUtil.Kind.ORDINARY):
		GitUtil.Kind.UNMERGED:
			return GitUtil.Colors.RED
		GitUtil.Kind.UNTRACKED:
			return GitUtil.Colors.L_GREEN

	# staged with nothing left dirty on disk: the change is already safely in the index
	var staged = file_data.get(GitUtil.Keys.STAGED, false)
	var unstaged = file_data.get(GitUtil.Keys.UNSTAGED, false)
	if staged and not unstaged:
		return GitUtil.Colors.GREEN

	if file_data.get(GitUtil.Keys.WORKTREE, GitUtil.Status.NONE) == GitUtil.Status.MODIFIED:
		return GitUtil.Colors.L_YELLOW

	return get_dim_color()

func _on_item_clicked(_index:int, _at_pos:Vector2, mouse_button:int):
	if mouse_button == MOUSE_BUTTON_RIGHT:
		_on_item_right_clicked()

func _on_item_right_clicked():

	var selected_paths = get_selected_paths()
	var options = Options.new()
	if selected_paths.size() == 1:
		var path = selected_paths[0]
		var valid = UtilsLocal.GenericFileContext.right_click(options, path)
		if valid != UtilsLocal.GenericFileContext.FileStatus.VALID:
			options = Options.new()

	_add_command_options(options, selected_paths)

	ScriptDock.get_right_click_handler().display_popup(options)


# One entry per command that has something to do to the selection. A command is handed only the
# subset it accepts — staging a mixed selection stages what it can rather than failing on the rest —
# and a command no selected file accepts is not offered at all.
func _add_command_options(options:Options, selected_paths:Array) -> void:
	var separated = false

	for command:GitUtil.Command in GitUtil.COMMANDS:
		var entry:Dictionary = GitUtil.COMMANDS[command]

		var paths = selected_paths.filter(
			func(path): return GitUtil.command_accepts(command, _file_data.get(path, {}))
		)
		if paths.is_empty():
			continue

		# the destructive pair is unrecoverable and one click away, so keep it apart from the rest
		if entry[GitUtil.Keys.CMD_DESTRUCTIVE] and not separated:
			options.add_separator()
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
