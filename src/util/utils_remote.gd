#! remote

const GitUtil = GitService.GitUtil
const GitDiff = GitService.GitDiff
const GlyphIcons = preload("uid://dvguymko6if63") #! resolve GitService.GlyphIcons


const ScriptListManager = ALibEditor.Singleton.ScriptListManager

const RightClickHandler = preload("uid://mmtkf4h8er3m") #! resolve ClickHandlers.RightClickHandler
const Options = preload("uid://c61qxuau2v0pb") #! resolve ALibRuntime.Popups.Options


const TabBarContainer = preload("uid://b7cxw711vl1jd") #! resolve ALibEditor.UIHelpers.Tab.TabBarContainer

const UControl = preload("uid://brio73mirr5e6") #! resolve ALibRuntime.Utils.UControl
