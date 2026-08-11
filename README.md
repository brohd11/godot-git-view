# Git View Godot Plugin

This plugin adds some git features to Godot's built in script editor.

The Git View plugin by itself will draw gutter diffs, minimap diffs, diff previews,
and draws code regions on the minimap.

It integrates with [ScriptDock](https://github.com/brohd11/Godot-Script-Dock), where it places a panel that shows line blame,
 modified files, and a commit list.
It also integrates with ScriptDock's file system to display git file status in the tree.


## Install
This plugin uses external dependencies packaged with [Plugin Exporter]
(https://github.com/brohd11/Godot-Plugin-Exporter), download the latest package
 from releases, it includes the required dependencies.

You can also use [gdaddon](https://github.com/brohd11/gdaddon) to manage the
 addon. It is a TUI package/repo manager that can install and update addons for
  you.
`curl -fsSL https://raw.githubusercontent.com/brohd11/gdaddon/main/install.sh | sh`