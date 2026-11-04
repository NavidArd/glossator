return {
  { wait = 3, function(api)
      local inkai = api.plugin("inkai")
      local f = io.open(os.getenv("INKAI_SHOTS") .. "/flows.txt", "a")
      f:write(((#inkai.data.groups == 1 and inkai.data.groups[1].note) and "PASS" or "FAIL") .. " restored after restart\n")
      f:write((#inkai.cache.hits == 1 and "PASS" or "FAIL") .. " restored note on page\n")
      f:close()
      api.shot("f3-reopened")
  end },
}
