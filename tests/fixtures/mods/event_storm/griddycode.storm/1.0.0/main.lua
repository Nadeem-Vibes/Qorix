-- 300 events against a 256-entry queue: the bus must drop the oldest and report.

local received = 0

editor.events.on("mod.griddycode.storm.tick", function(payload)
	received = received + 1
end)

for index = 1, 300 do
	editor.events.emit("mod.griddycode.storm.tick", { index = index })
end

editor.log.info("storm emitted")
