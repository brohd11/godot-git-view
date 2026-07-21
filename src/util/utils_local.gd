
## A visible v-scrollbar already eats into the row width, so the panel's lists drop their right
## content margin while it is up and take it back when it goes.
static func set_item_list_sb(item_list:ItemList) -> void:
	var sb:StyleBoxFlat = item_list.get_theme_stylebox(&"panel").duplicate()
	sb.content_margin_right = 0
	var set_sb_call = func():
		if item_list.get_v_scroll_bar().visible:
			item_list.add_theme_stylebox_override(&"panel", sb)
		else:
			item_list.remove_theme_stylebox_override(&"panel")
	item_list.get_v_scroll_bar().visibility_changed.connect(set_sb_call)
	set_sb_call.call()


class EditorSet:
	const GUTTER_UNTRACKED = &"plugin/git_view/gutter/untracked_render"
	const GUTTER_IGNORE = &"plugin/git_view/gutter/ignored"
	const MINIMAP_REGIONS = &"plugin/git_view/minimap/code_regions"
