extends ItemList

## The Git section's read-only `git log --oneline` list.
##
## Rows read: <dimmed mono hash>  <subject>
##
## ItemList only supports one font per item, so the mono hash is drawn into leading padding on the
## subject row. Tags are appended to the subject and tinted across the whole row.

const UtilsRemote = preload("res://addons/git_view/src/util/utils_remote.gd")
const GitUtil = UtilsRemote.GitUtil

## unscaled px between the hash and the subject
const GAP = 8
## Baseline ratio between top and bottom of the row, tuned by eye — ItemList text sits slightly
## below centre and there is no theme constant to query.
const BASELINE_CENTER = 0.57
## how much of GitUtil.Colors.YELLOW a tagged row's background takes
const TAG_BG_ALPHA = 0.1
const DIM_ALPHA = 0.5

# The mono face, for the hash and the hash alone
var _mono_font:Font


func _ready() -> void:
	_ensure_font()


# Idempotent: hot reload does not rerun _init/_ready on live instances, and a null font draws nothing.
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
	# Store the whole commit so _draw can read the hash back — no second array to keep in sync.
	set_item_metadata(idx, commit)

	# Tags tint the whole row because ItemList cannot colour just part of an item.
	if not tags.is_empty():
		set_item_custom_bg_color(idx, Color(GitUtil.Colors.YELLOW, TAG_BG_ALPHA))


func get_selected_hash() -> String:
	var selected = get_selected_items()
	if selected.is_empty():
		return ""
	return get_item_metadata(selected[0]).get(GitUtil.Keys.FULL_HASH, "")


# Leading padding wide enough for the hash. Measured per row because `%h` is uniform within a repo,
# so subjects still align and no cache needs invalidation.
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

	# get_item_rect() is in content space; the list draws shifted by scroll, so hashes would detach.
	var scroll_offset = Vector2(get_h_scroll_bar().value, get_v_scroll_bar().value)

	# ItemList adds an icon column to the item rect; with no icon it collapses to half h_separation.
	var x = get_theme_stylebox(&"panel").get_margin(SIDE_LEFT) \
		+ get_theme_constant(&"h_separation") * 0.5 - scroll_offset.x

	for i in item_count:
		var rect = get_item_rect(i, false)
		rect.position -= scroll_offset
		if rect.position.y + rect.size.y < 0 or rect.position.y > size.y:
			continue

		# draw_string wants a baseline; ItemList text sits slightly below row centre
		var ascent = font.get_ascent(font_size)
		var baseline = rect.position.y \
			+ (rect.size.y + ascent - font.get_descent(font_size)) * BASELINE_CENTER

		var short_hash = get_item_metadata(i).get(GitUtil.Keys.HASH, "")
		draw_string(_mono_font, Vector2(x, baseline), short_hash,
			HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, color)


func _string_width(font:Font, text:String) -> float:
	return font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1,
		get_theme_font_size(&"font_size")).x
