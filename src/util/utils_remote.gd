#! remote

const GitUtil = GitService.GitUtil
const GitDiff = GitService.GitDiff

const NUItemList = ALibRuntime.NodeUtils.NUItemList
const FSSmallPopup = preload("uid://1gdu201y6jro") #! resolve ALibEditor.FileSystem.Component.SmallPopup

const ScriptListManager = preload("uid://d3o6grkkmk4qk") #! resolve ALibEditor.Singleton.ScriptListManager

const SettingHelperEditor = preload("uid://c4l4v4eufkmtx") #! resolve ALibEditor.Settings.SettingHelperEditor

const RightClickHandler = preload("uid://mmtkf4h8er3m") #! resolve ClickHandlers.RightClickHandler
const Options = preload("uid://c61qxuau2v0pb") #! resolve ALibRuntime.Popups.Options


const TabBarContainer = preload("uid://b7cxw711vl1jd") #! resolve ALibEditor.UIHelpers.Tab.TabBarContainer

const UControl = preload("uid://brio73mirr5e6") #! resolve ALibRuntime.Utils.UControl
