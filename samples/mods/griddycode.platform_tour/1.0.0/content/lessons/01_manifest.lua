-- Lesson data is deliberately declarative: lib/tour.lua turns it into a
-- hybrid exercise. The tour teaches the shape of a manifest, not a full Lua
-- application, so the typing target is short enough to finish in a minute.
--
-- content/*.lua is NOT watched by hot reload. The hot reload drill edits
-- lib/build.lua instead; see README.md.

return {
	id = "01_manifest",
	title = "The manifest is the contract",
	summary = "A mod is a folder with a manifest: id, version, API and permissions.",
	coach = "Type the manifest id exactly, then add the permission list.",
	typing = {
		target = 'id = "example.hello"\n',
		display = { scope = "line", chars = 64 },
		marks = {
			{ id = "key", text = "id" },
			{ id = "value", text = '"example.hello"' },
		},
		hints = {
			{ on = "start", text = "Type the line exactly. Ghost text shows the next character." },
			{ on = "mark", mark = "key", text = "Every manifest starts with an id." },
			{ on = "mark", mark = "value", text = "The id is reverse-DNS and must match the folder name." },
			{ on = "mistake", mistake = 2, text = "Keep the quotes and the dot in example.hello." },
			{ on = "complete", text = "The id is right. Now add the permission list." },
		},
	},
	freeform = {
		title = "Permissions",
		prompt = 'Add permissions = { "core", "documents.read" } on the next line.',
		hint = "The permissions table names the capabilities the mod needs. core is automatic; documents.read needs explicit consent.",
		validation = {
			tests = {
				{ name = "permissions table", type = "contains", value = "permissions" },
				{ name = "documents.read", type = "contains", value = "documents.read" },
			},
		},
	},
}
