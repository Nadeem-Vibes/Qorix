editor.log.info("consent fixture activated")

editor.commands.register({
	id = "griddycode.sensitive.inspect",
	label = "Consent: Inspect",
	handler = function()
		editor.log.info("inspect")
	end,
})
