return {
  { wait = 2, function(api) api.tap(900, 100) end },
  { wait = 1.5, function(api) api.shot("k1-bars") end },
  { wait = 0.3, function(api) api.tap(1700 - 160, 50) end },
  { wait = 1, function(api) api.shot("k2-bookmarked") end },
  { wait = 0.3, function(api) api.tap(900, 1200) end },
  { wait = 1, function(api) api.shot("k3-closed") end },
  { wait = 0.3, function(api) api.tap(1500, 1200) end },
  { wait = 1, function(api) api.shot("k4-next") end },
  { wait = 0.3, function(api) api.tap(100, 1200) end },
  { wait = 1, function(api) api.shot("k5-back") end },
}
