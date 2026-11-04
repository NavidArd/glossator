return {
  { wait = 3, function(api)
      local BIM = require("bookinfomanager")
      BIM:saveSetting("filemanager_display_mode", "mosaic_image")
      local FM = require("apps/filemanager/filemanager").instance
      local pt = FM and FM.coverbrowser
      if pt and pt.setupFileManagerDisplayMode then pt:setupFileManagerDisplayMode("mosaic_image") end
  end },
  { wait = 6, function(api) api.shot("l1-library") end },
}
