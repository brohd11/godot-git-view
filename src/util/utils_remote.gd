#! remote

## exported references needed by git view.

const GitUtil = GitService.GitUtil
const GitDiff = GitService.GitDiff

const Confirm = preload("uid://dwhlbgevd62gg") #! resolve Dialogs.Handlers.Confirmation

const UItemList = preload("uid://bmkydws861tcb") #! resolve UtilR.Nodes.ItemLists.UItemList
const FSSmallPopup = preload("uid://1gdu201y6jro") #! resolve EditorFS.Components.SmallPopup

const EditorColors = preload("uid://cpw0fsrs38esk") #! resolve UtilE.Colors
const ScriptListManager = preload("uid://esgr5a6b8qbw") #! resolve EditorNodes.ScriptListManager

const SettingHelperEditor = preload("uid://dnov6vp7pjnbb") #! resolve SettingHelper.Editor

const RightClickHandler = preload("uid://cs6pl78crcr0g") #! resolve UtilR.Nodes.PopupMenus.Placer
const Options = preload("uid://dxdxq2n3imf4q") #! resolve UtilR.Nodes.PopupMenus.Options


const TabBarContainer = preload("uid://dhohyyr2xlven") #! resolve UIRuntime.Tabs.TabBarContainer

const UControl = preload("uid://cdo8rcof3ilt1") #! resolve UtilR.Nodes.UControl
const UOs = preload("uid://dppsxjnth11uc") #! resolve UtilR.UOs
