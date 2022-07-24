import std/[strformat, strutils, os]

import imstyle
import niprefs
import nimgl/[opengl, glfw]
import nimgl/imgui, nimgl/imgui/[impl_opengl, impl_glfw]

import src/[prefsmodal, utils, icons]
when defined(release):
  from resourcesdata import resources

const configPath = "config.toml"

proc getData(path: string): string = 
  when defined(release):
    resources[path]
  else:
    readFile(path)

proc getData(node: TomlValueRef): string = 
  node.getString().getData()

proc getCacheDir(app: App): string = 
  getCacheDir(app.config["name"].getString())

proc drawAboutModal(app: App) = 
  var center: ImVec2
  getCenterNonUDT(center.addr, igGetMainViewport())
  igSetNextWindowPos(center, Always, igVec2(0.5f, 0.5f))

  let unusedOpen = true # Passing this parameter creates a close button
  if igBeginPopupModal(cstring "About " & app.config["name"].getString(), unusedOpen.unsafeAddr, flags = makeFlags(ImGuiWindowFlags.NoResize)):
    # Display icon image
    var texture: GLuint
    var image = app.config["iconPath"].getData().readImageFromMemory()

    image.loadTextureFromData(texture)

    igImage(cast[ptr ImTextureID](texture), igVec2(64, 64)) # Or igVec2(image.width.float32, image.height.float32)
    if igIsItemHovered():
      igSetTooltip(cstring app.config["website"].getString() & " " & FA_ExternalLink)
      
      if igIsMouseClicked(ImGuiMouseButton.Left):
        app.config["website"].getString().openURL()

    igSameLine()
    
    igPushTextWrapPos(250)
    igTextWrapped(app.config["comment"].getString().cstring)
    igPopTextWrapPos()

    igSpacing()

    # To make it not clickable
    igPushItemFlag(ImGuiItemFlags.Disabled, true)
    igSelectable("Credits", true, makeFlags(ImGuiSelectableFlags.DontClosePopups))
    igPopItemFlag()

    if igBeginChild("##credits", igVec2(0, 75)):
      for author in app.config["authors"]:
        let (name, url) = block: 
          let (name,  url) = author.getString().removeInside('<', '>')
          (name.strip(),  url.strip())

        if igSelectable(cstring name) and url.len > 0:
            url.openURL()
        if igIsItemHovered() and url.len > 0:
          igSetTooltip(cstring url & " " & FA_ExternalLink)
      
      igEndChild()

    igSpacing()

    igText(app.config["version"].getString().cstring)

    igEndPopup()

proc drawMainMenuBar(app: var App) =
  var openAbout, openPrefs = false

  if igBeginMainMenuBar():
    if igBeginMenu("File"):
      igMenuItem("Preferences " & FA_Cog, "Ctrl+P", openPrefs.addr)
      if igMenuItem("Quit " & FA_Times, "Ctrl+Q"):
        app.win.setWindowShouldClose(true)
      igEndMenu()

    if igBeginMenu("Edit"):
      if igMenuItem("Hello"):
        echo "Hello"

      igEndMenu()

    if igBeginMenu("About"):
      if igMenuItem("Website " & FA_ExternalLink):
        app.config["website"].getString().openURL()

      igMenuItem(cstring "About " & app.config["name"].getString(), shortcut = nil, p_selected = openAbout.addr)

      igEndMenu() 

    igEndMainMenuBar()

  # See https://github.com/ocornut/imgui/issues/331#issuecomment-751372071
  if openPrefs:
    igOpenPopup("Preferences")
  if openAbout:
    igOpenPopup(cstring "About " & app.config["name"].getString())

  # These modals will only get drawn when igOpenPopup(name) are called, respectly
  app.drawAboutModal()
  app.drawPrefsModal()

proc setClipTitle(app: App, clip: string) = 
  var clip = clip.line(0).ellipse(50)
  
  if '\n' in clip and clip[^3..^1] != "...":
    clip.add("...")

  app.win.setWindowTitle(cstring &"{clip} — {app.config[\"name\"].getString()}")

proc drawClipList(app: var App) = 
  if igBeginChild("##clipList"):
    let drawList = igGetWindowDrawList()
    for e, clip in app.clipList.deepCopy():
      drawList.channelsSplit(2)
      drawList.channelsSetCurrent(1)
      if igSelectable(cstring clip.ellipse(app.prefs["maxBuffer"].getInt()).igTextEllipsis(), app.selectedClip == e):
        app.selectedClip = e

        app.lastClipboard = clip
        igSetClipboardText(cstring clip)
        app.setClipTitle(clip)

      drawList.channelsSetCurrent(0)
      igItemBg(if e mod 2 == 0: igGetColorU32(ChildBg) else: igGetColorU32(FrameBg))

      drawList.channelsMerge()

      if igIsItemActive() and not igIsItemHovered(): # Reorder
        let nextIdx = e + (if igGetMouseDragDelta().y < 0: -1 else: 1)
        if nextIdx >= 0 and nextIdx < app.clipList.len:
          (app.clipList[e], app.clipList[nextIdx]) = (app.clipList[nextIdx], clip)
          
          igResetMouseDragDelta()

      if igBeginPopupContextItem():
        if igMenuItem(FA_TrashO & " Remove"):
          app.clipList.delete(e)
        igEndPopup()

  igEndChild()

proc drawMain(app: var App) = # Draw the main window
  let viewport = igGetMainViewport()  
  
  app.drawMainMenuBar()
  # Work area is the entire viewport minus main menu bar, task bars, etc.
  igSetNextWindowPos(viewport.workPos)
  igSetNextWindowSize(viewport.workSize)

  if igBegin(cstring app.config["name"].getString(), flags = makeFlags(ImGuiWindowFlags.NoResize, NoDecoration, NoMove)):
    igText(FA_Info & " Application average %.3f ms/frame (%.1f FPS)", 1000f / igGetIO().framerate, igGetIO().framerate)
    app.drawClipList()
  igEnd()

  # GLFW clipboard -> ImGui clipboard
  if not app.win.getClipboardString().isNil and $app.win.getClipboardString() != app.curClipboard:
    igSetClipboardText(app.win.getClipboardString())
    app.curClipboard = $app.win.getClipboardString()

  # ImGui clipboard -> GLFW clipboard
  if not igGetClipboardText().isNil and $igGetClipboardText() != app.curClipboard:
    app.win.setClipboardString(igGetClipboardText())
    app.curClipboard = $igGetClipboardText()

  if app.curClipboard != app.lastClipboard:
    app.lastClipboard = app.curClipboard
    app.setClipTitle(app.curClipboard)
    if app.curClipboard notin app.clipList:
      app.clipList.insert(app.curClipboard, 0)

proc render(app: var App) = # Called in the main loop
  # Poll and handle events (inputs, window resize, etc.)
  glfwPollEvents() # Use glfwWaitEvents() to only draw on events (more efficient)

  # Start Dear ImGui Frame
  igOpenGL3NewFrame()
  igGlfwNewFrame()
  igNewFrame()

  # Draw application
  app.drawMain()

  # Render
  igRender()

  var displayW, displayH: int32
  let bgColor = igColorConvertU32ToFloat4(uint32 WindowBg)

  app.win.getFramebufferSize(displayW.addr, displayH.addr)
  glViewport(0, 0, displayW, displayH)
  glClearColor(bgColor.x, bgColor.y, bgColor.z, bgColor.w)
  glClear(GL_COLOR_BUFFER_BIT)

  igOpenGL3RenderDrawData(igGetDrawData())  

  app.win.makeContextCurrent()
  app.win.swapBuffers()

proc initWindow(app: var App) = 
  glfwWindowHint(GLFWContextVersionMajor, 3)
  glfwWindowHint(GLFWContextVersionMinor, 3)
  glfwWindowHint(GLFWOpenglForwardCompat, GLFW_TRUE)
  glfwWindowHint(GLFWOpenglProfile, GLFW_OPENGL_CORE_PROFILE)
  glfwWindowHint(GLFWResizable, GLFW_TRUE)

  app.win = glfwCreateWindow(
    int32 app.prefs{"win", "width"}.getInt(), 
    int32 app.prefs{"win", "height"}.getInt(), 
    cstring app.config["name"].getString(), 
    icon = false # Do not use default icon
  )

  if app.win == nil:
    quit(-1)

  # Set the window icon
  var icon = initGLFWImage(app.config["iconPath"].getData().readImageFromMemory())
  app.win.setWindowIcon(1, icon.addr)

  app.win.setWindowSizeLimits(app.config["minSize"][0].getInt().int32, app.config["minSize"][1].getInt().int32, GLFW_DONT_CARE, GLFW_DONT_CARE) # minWidth, minHeight, maxWidth, maxHeight

  # If negative pos, center the window in the first monitor
  if app.prefs{"win", "x"}.getInt() < 0 or app.prefs{"win", "y"}.getInt() < 0:
    var monitorX, monitorY, count: int32
    let monitors = glfwGetMonitors(count.addr)
    let videoMode = monitors[0].getVideoMode()

    monitors[0].getMonitorPos(monitorX.addr, monitorY.addr)
    app.win.setWindowPos(
      monitorX + int32((videoMode.width - int app.prefs{"win", "width"}.getInt()) / 2), 
      monitorY + int32((videoMode.height - int app.prefs{"win", "height"}.getInt()) / 2)
    )
  else:
    app.win.setWindowPos(app.prefs{"win", "x"}.getInt().int32, app.prefs{"win", "y"}.getInt().int32)

proc initPrefs(app: var App) = 
  app.prefs = initPrefs(
    path = (app.getCacheDir() / app.config["name"].getString()).changeFileExt("toml"), 
    default = toToml {
      win: {
        x: -1, # Negative numbers center the window
        y: -1,
        width: 600,
        height: 650
      }, 
      clipList: [], 
      lastClipboard: "", 
    }
  )

proc initApp(config: TomlValueRef): App = 
  result = App(
    config: config, cache: newTTable(), 
    selectedClip: -1, 
  )
  result.initPrefs()
  result.initSettings(result.config["settings"])

  result.lastClipboard = result.prefs["lastClipboard"].getString()

  for clip in result.prefs["clipList"]:
    result.clipList.add(clip.getString())

proc terminate(app: var App) = 
  var x, y, width, height: int32

  app.win.getWindowPos(x.addr, y.addr)
  app.win.getWindowSize(width.addr, height.addr)
  
  app.prefs{"win", "x"} = x
  app.prefs{"win", "y"} = y
  app.prefs{"win", "width"} = width
  app.prefs{"win", "height"} = height

  app.prefs["lastClipboard"] = app.lastClipboard

  app.prefs["clipList"] = newTArray()
  for clip in app.clipList:
    app.prefs["clipList"].add(clip)

  app.prefs.save()

proc main() =
  var app = initApp(Toml.decode(configPath.getData(), TomlValueRef))

  # Setup Window
  doAssert glfwInit()
  app.initWindow()
  app.setClipTitle(app.lastClipboard)

  app.win.makeContextCurrent()
  glfwSwapInterval(1) # Enable vsync

  doAssert glInit()

  # Setup Dear ImGui context
  igCreateContext()
  let io = igGetIO()
  io.iniFilename = nil # Disable .ini config file

  # Setup Dear ImGui style using ImStyle
  setStyleFromToml(Toml.decode(app.config["stylePath"].getData(), TomlValueRef))

  # Setup Platform/Renderer backends
  doAssert igGlfwInitForOpenGL(app.win, true)
  doAssert igOpenGL3Init()

  # Load fonts
  app.font = io.fonts.igAddFontFromMemoryTTF(app.config["fontPath"].getData(), app.config["fontSize"].getFloat())

  # Merge ForkAwesome icon font
  var config = utils.newImFontConfig(mergeMode = true)
  var ranges = [FA_Min.uint16,  FA_Max.uint16]

  io.fonts.igAddFontFromMemoryTTF(app.config["iconFontPath"].getData(), app.config["fontSize"].getFloat(), config.addr, ranges[0].addr)

  # Main loop
  while not app.win.windowShouldClose:
    app.render()

  # Cleanup
  igOpenGL3Shutdown()
  igGlfwShutdown()
  
  igDestroyContext()
  
  app.terminate()
  app.win.destroyWindow()
  glfwTerminate()

when isMainModule:
  main()
