#! remote

## exported references needed by git view.

const GitUtil = GitService.GitUtil
const GitDiff = GitService.GitDiff

const Confirm = preload("uid://b4rwv7tgks0b5") #! resolve ALibRuntime.Dialog.Handlers.Confirmation

const NUItemList = preload("uid://cjls86v1v4242") #! resolve ALibRuntime.NodeUtils.NUItemList
const FSSmallPopup = preload("uid://1gdu201y6jro") #! resolve EditorFS.Components.SmallPopup

const EditorColors = preload("uid://cpw0fsrs38esk") #! resolve UtilE.Colors
const ScriptListManager = preload("uid://d3o6grkkmk4qk") #! resolve ALibEditor.Singleton.ScriptListManager

const SettingHelperEditor = preload("uid://dnov6vp7pjnbb") #! resolve SettingHelper.Editor

const RightClickHandler = preload("uid://mmtkf4h8er3m") #! resolve ClickHandlers.RightClickHandler
const Options = preload("uid://c61qxuau2v0pb") #! resolve ALibRuntime.Popups.Options


const TabBarContainer = preload("uid://b7cxw711vl1jd") #! resolve ALibEditor.UIHelpers.Tab.TabBarContainer

const UControl = preload("uid://cdo8rcof3ilt1") #! resolve UtilR.Nodes.UControl
const UOs = preload("uid://dppsxjnth11uc") #! resolve UtilR.UOs
