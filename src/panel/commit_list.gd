extends ItemList

## The Git section's Commits list — a read only `git log --oneline` view.
##
## Rows read:  <dimmed mono hash>  <subject>
##
## An ItemList has one font for all its text, so the hash cannot be part of the item string and stay
## mono. Instead the subject is padded with enough leading spaces to clear a hash, and the hash is
## drawn into that gap in the source face. A tag joins the subject inline, over a tinted row.

const UtilsRemote = preload("res://addons/git_view/src/util/utils_remote.gd")
const GitUtil = UtilsRemote.GitUtil

## unscaled px between the hash and the subject
const GAP = 8
## Where the hash's baseline sits between the top and the bottom of the row. Tuned by eye, not
## derived: ItemList draws its item text a shade below true centre, off theme constants there is no
## way to query, and the hash has to match or the two read as misaligned.
const BASELINE_CENTER = 0.57
## how much of GitUtil.Colors.YELLOW a tagged row's background takes
const TAG_BG_ALPHA = 0.1
const DIM_ALPHA = 0.5

# The mono face, for the hash and the hash alone
var _mono_font:Font


func _ready() -> void:
	_ensure_font()


# Idempotent and called from add_commit as well as _ready: a hot reload re-runs neither _init nor
# _ready on a live instance, and a null font would draw nothing.
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
	# the whole commit, not just the hash: _draw reads its row's hash back off this, so there is no
	# second array to fall out of step with the items
	set_item_metadata(idx, commit)

	# a tag has no colour of its own here — ItemList colours a whole row — so the row carries it
	if not tags.is_empty():
		set_item_custom_bg_color(idx, Color(GitUtil.Colors.YELLOW, TAG_BG_ALPHA))


func get_selected_hash() -> String:
	var selected = get_selected_items()
	if selected.is_empty():
		return ""
	return get_item_metadata(selected[0]).get(GitUtil.Keys.FULL_HASH, "")


# Leading spaces wide enough for the hash to be drawn over. Measured per row rather than shared:
# `%h` is uniform within a repo, so every subject still lands on the same x, and there is nothing
# cached to invalidate when the font or the repo changes.
func _hash_pad(short_hash:String) -> String:
	if short_hash.is_empty() or _mono_font == null:
		return "" # no face to measure against, and _draw draws nothing either

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
	color.a = DIM_ALPHA # dim, so the subject beside it reads as the primary

	# get_item_rect() is in unscrolled content space while the list draws itself shifted by the
	# scroll value — without this the hashes detach from their rows on scroll
	var scroll_offset = Vector2(get_h_scroll_bar().value, get_v_scroll_bar().value)

	# ItemList lays text out at the item rect plus the icon column; with no icon that column
	# collapses to one h_separation, halved — ItemList appears to split it across both ends
	var x = get_theme_stylebox(&"panel").get_margin(SIDE_LEFT) \
		+ get_theme_constant(&"h_separation") * 0.5 - scroll_offset.x

	for i in item_count:
		var rect = get_item_rect(i, false)
		rect.position -= scroll_offset
		if rect.position.y + rect.size.y < 0 or rect.position.y > size.y:
			continue

		# draw_string takes a baseline, and ItemList sits its text a shade below the row's centre
		var ascent = font.get_ascent(font_size)
		var baseline = rect.position.y \
			+ (rect.size.y + ascent - font.get_descent(font_size)) * BASELINE_CENTER

		var short_hash = get_item_metadata(i).get(GitUtil.Keys.HASH, "")
		draw_string(_mono_font, Vector2(x, baseline), short_hash,
			HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, color)


func _string_width(font:Font, text:String) -> float:
	return font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1,
		get_theme_font_size(&"font_size")).x
