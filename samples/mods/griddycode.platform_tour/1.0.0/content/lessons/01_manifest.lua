return {
  id = "01_manifest",
  title = "Manifest and permissions",
  summary = "Learn permissions.",
  coach = "Permissions gate sensitive APIs.",
  file = "platform_tour/01_manifest.lua",
  exercise = {
    typing = {
      target = "return { permissions = {\"documents.read\", \"documents.write\"} }\n",
      marks = { { id = "perm", text = "permissions" } },
      hints = { { on = "start", text = "Define permissions." }, { on = "complete", text = "Done." } },
    },
    freeform = {
      prompt = "Explain why permissions are needed.",
      hint = "Mention documents.read",
      text = { tests = { { name = "mentions docs", type = "contains", value = "documents.read" } } },
    },
  },
}
