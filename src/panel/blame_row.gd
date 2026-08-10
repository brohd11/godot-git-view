extends HBoxContainer

## renders the commit behind the active caret line.


const UtilsRemote = preload("res://addons/git_view/src/util/utils_remote.gd")
const GitUtil = UtilsRemote.GitUtil

const BlameTracker = preload("res://addons/git_view/src/blame/blame_tracker.gd")

const DIM_ALPHA = 0.5
const GAP = 6

var hash_label:Label
var meta_label:Label
var subject_label:Label

var _mono_font:Font


func _ready() -> void:
	_mono_font = EditorInterface.get_editor_theme().get_font(&"source", &"EditorFonts")
	add_theme_constant_override(&"separation", int(GAP * EditorInterface.get_editor_scale()))

	hash_label = Label.new()
	hash_label.add_theme_font_override(&"font", _mono_font)
	hash_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(hash_label)

	meta_label = Label.new()
	meta_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(meta_label)

	subject_label = Label.new()
	subject_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	subject_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	subject_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(subject_label)
	
	set_blame({})


func set_blame(info:Dictionary) -> void:
	
	var dim = get_theme_color(&"font_color", &"Label")
	dim.a = DIM_ALPHA
	
	if info.is_empty():
		meta_label.text = "no blame data"
		meta_label.add_theme_color_override(&"font_color", dim)
		return
	
	if info.get(BlameTracker.Keys.UNCOMMITTED, false):
		_set_uncommitted(info.get(BlameTracker.Keys.LINE, 0))
		return
	
	hash_label.text = info.get(GitUtil.Keys.HASH, "")
	hash_label.add_theme_color_override(&"font_color", dim)
	
	meta_label.text = "%s · %s" % [
		info.get(GitUtil.Keys.AUTHOR, ""),
		info.get(GitUtil.Keys.DATE, ""),
	]
	meta_label.remove_theme_color_override(&"font_color")

	subject_label.text = info.get(GitUtil.Keys.SUBJECT, "")
	tooltip_text = _tooltip(info)


func _set_uncommitted(line:int) -> void:
	hash_label.text = ""
	meta_label.text = "uncommitted"
	meta_label.add_theme_color_override(&"font_color", GitUtil.Colors.L_GREEN)
	subject_label.text = ""
	tooltip_text = "Line %d has no committed version" % (line + 1)


func _tooltip(info:Dictionary) -> String:
	var stamp:int = info.get(GitUtil.Keys.AUTHOR_TIME, 0)
	var when = Time.get_datetime_string_from_unix_time(stamp, true) if stamp > 0 else ""

	return "%s\n\n%s\n%s <%s>\n%s %s" % [
		info.get(GitUtil.Keys.SUBJECT, ""),
		info.get(GitUtil.Keys.FULL_HASH, ""),
		info.get(GitUtil.Keys.AUTHOR, ""),
		info.get(GitUtil.Keys.AUTHOR_MAIL, ""),
		when,
		info.get(GitUtil.Keys.AUTHOR_TZ, ""),
	]
