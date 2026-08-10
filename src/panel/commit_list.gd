extends ItemList

## renders the selected repo's recent commits.


const UtilsRemote = preload("res://addons/git_view/src/util/utils_remote.gd")
const GitUtil = UtilsRemote.GitUtil

const GAP = 8
const BASELINE_CENTER = 0.57
const TAG_BG_ALPHA = 0.1
const DIM_ALPHA = 0.5

var _mono_font:Font


func _ready() -> void:
	_ensure_font()


func _ensure_font() -> void:
	if _mono_font != null:
		return
	_mono_font = EditorInterface.get_editor_theme().get_font(&"source", &"EditorFonts")


func clear_commits() -> void:
	clear()


func add_commit(commit:Dictionary) -> void:
	_ensure_font()

	var full_hash = commit.get(GitUtil.Keys.FULL_HASH, "")
	var subject = commit.get(GitUtil.Keys.SUBJECT, "")
	var tags:Array = commit.get(GitUtil.Keys.TAGS, [])

	var tooltip = "%s\n\n%s\n%s  %s" % [
		subject,
		full_hash,
		commit.get(GitUtil.Keys.AUTHOR, ""),
		commit.get(GitUtil.Keys.DATE, ""),
	]
	var tags_str = "tag(%s)" % ", ".join(tags)
	if not tags.is_empty():
		tooltip += "\n\n%s" % tags_str
		subject = "%s %s" % [tags_str, subject]

	var idx = item_count
	add_item(_hash_pad(commit.get(GitUtil.Keys.HASH, "")) + subject)
	set_item_tooltip(idx, tooltip)
	set_item_metadata(idx, commit)

	if not tags.is_empty():
		set_item_custom_bg_color(idx, Color(GitUtil.Colors.YELLOW, TAG_BG_ALPHA))


func get_selected_hash() -> String:
	var selected = get_selected_items()
	if selected.is_empty():
		return ""
	return get_item_metadata(selected[0]).get(GitUtil.Keys.FULL_HASH, "")


func _hash_pad(short_hash:String) -> String:
	if short_hash.is_empty() or _mono_font == null:
		return "" # no font to measure against; _draw also bails

	var space = _string_width(get_theme_font(&"font"), " ")
	if space <= 0.0:
		return ""

	var width = _string_width(_mono_font, short_hash) + GAP * EditorInterface.get_editor_scale()
	return " ".repeat(int(ceil(width / space)))


func _draw() -> void:
	if _mono_font == null:
		return

	var font = get_theme_font(&"font")
	var font_size = get_theme_font_size(&"font_size")
	var color = get_theme_color(&"font_color")
	color.a = DIM_ALPHA # dim the hash so the subject reads as primary

	var scroll_offset = Vector2(get_h_scroll_bar().value, get_v_scroll_bar().value)

	var x = get_theme_stylebox(&"panel").get_margin(SIDE_LEFT) \
		+ get_theme_constant(&"h_separation") * 0.5 - scroll_offset.x

	for i in item_count:
		var rect = get_item_rect(i, false)
		rect.position -= scroll_offset
		if rect.position.y + rect.size.y < 0 or rect.position.y > size.y:
			continue

		var ascent = font.get_ascent(font_size)
		var baseline = rect.position.y \
			+ (rect.size.y + ascent - font.get_descent(font_size)) * BASELINE_CENTER

		var short_hash = get_item_metadata(i).get(GitUtil.Keys.HASH, "")
		draw_string(_mono_font, Vector2(x, baseline), short_hash,
			HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, color)


func _string_width(font:Font, text:String) -> float:
	return font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1,
		get_theme_font_size(&"font_size")).x
