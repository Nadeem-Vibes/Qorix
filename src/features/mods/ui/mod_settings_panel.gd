extends PanelContainer

## Mods settings page (Phase 2) with the Phase 6 import review.
##
## Lists installed mods, their state, consent gaps and declared settings. The
## page writes through ModManager so the same validated ModSettings store serves
## both this panel and editor.settings.* from Lua.
##
## Package review is deliberately a separate dialog: opening it validates the
## archive and verifies the signature, but installs nothing until the person has
## seen the publisher, the permission growth and the update/rollback policy and
## pressed Install.

signal closed
signal log_requested(mod_id: String)
signal import_requested

const Permissions = preload("res://src/features/mods/mod_permissions.gd")

var manager = null
var editor = null

var _list: VBoxContainer
var _subtitle: Label
var _status: Label
var _import_dialog: ConfirmationDialog
var _import_body: VBoxContainer
var _import_status: Label
var _import_path: String = ""
var _import_review: Dictionary = {}
var _import_options: Dictionary = {"activate": true}


func _ready() -> void:
	visible = false
	set_anchors_preset(Control.PRESET_CENTER)
	var viewport := get_viewport()
	if is_inside_tree() and viewport != null:
		_fit_to_viewport()
		viewport.size_changed.connect(_fit_to_viewport)
	else:
		_apply_extents(Vector2(1920.0, 1080.0))
	mouse_filter = Control.MOUSE_FILTER_STOP
	add_theme_stylebox_override("panel", _panel_style())

	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 8)
	add_child(outer)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 8)
	outer.add_child(header)

	var title := Label.new()
	title.text = "Mods"
	title.add_theme_font_size_override("font_size", 18)
	title.add_theme_color_override("font_color", _font_color())
	header.add_child(title)

	_subtitle = Label.new()
	_subtitle.text = "Public 1.0 · API 1.0 · installed mods, permissions and settings"
	_subtitle.add_theme_font_size_override("font_size", 12)
	_subtitle.add_theme_color_override("font_color", _muted_color())
	header.add_child(_subtitle)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(spacer)

	var import_button := Button.new()
	import_button.text = "Import package…"
	import_button.tooltip_text = "Review a .gcm or .zip package before anything is installed."
	import_button.pressed.connect(func() -> void: import_requested.emit())
	header.add_child(import_button)

	var reload := Button.new()
	reload.text = "Refresh"
	reload.tooltip_text = "Rescan the installed mods folder and start any mods whose activation is pending, then rebuild this page."
	reload.pressed.connect(_reload_mods)
	header.add_child(reload)

	var close := Button.new()
	close.text = "Close"
	close.pressed.connect(func() -> void:
		visible = false
		closed.emit()
	)
	header.add_child(close)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	outer.add_child(scroll)

	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", 8)
	scroll.add_child(_list)

	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.add_theme_font_size_override("font_size", 12)
	_status.add_theme_color_override("font_color", _muted_color())
	outer.add_child(_status)

	_build_import_dialog()


## PRESET_CENTER keeps the card at its designed size; clamp it back to the
## viewport on small windows so nothing is clipped with no way to reach it.
func _fit_to_viewport() -> void:
	var size := Vector2(1920.0, 1080.0)
	if is_inside_tree():
		var viewport := get_viewport()
		if viewport != null:
			size = viewport.get_visible_rect().size
	_apply_extents(size)

func _apply_extents(size: Vector2) -> void:
	var half_w := minf(470.0, (size.x - 32.0) * 0.5)
	var half_h := minf(330.0, (size.y - 32.0) * 0.5)
	offset_left = -half_w
	offset_right = half_w
	offset_top = -half_h
	offset_bottom = half_h


func setup(manager_ref, editor_ref = null) -> void:
	manager = manager_ref
	editor = editor_ref


func open() -> void:
	refresh()
	visible = true
	move_to_front()


func toggle() -> void:
	if visible:
		visible = false
		closed.emit()
	else:
		open()


## The folder is the install contract, so Refresh must rescan it. Rebuilding only
## from the cached list made a newly copied mod invisible until a restart.
func _reload_mods() -> void:
	if manager != null:
		if manager.has_method("refresh_discovery"):
			manager.refresh_discovery()
		elif manager.has_method("scan_installed"):
			manager.scan_installed()
	refresh()


func refresh() -> void:
	if _list == null:
		return
	for child in _list.get_children():
		_list.remove_child(child)
		child.queue_free()

	_status.text = ""
	_update_subtitle()
	if manager == null:
		_status.text = "The mod manager is not available."
		return

	var installed: Array = manager.installed()
	if installed.is_empty():
		var empty := Label.new()
		empty.text = "No mods are installed. Import a package with the button above, or put a mod under user://mods/<id>/<version>/ and press Refresh."
		empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		empty.add_theme_color_override("font_color", _muted_color())
		_list.add_child(empty)
		_status.text = _mode_note()
		return

	for record in installed:
		_list.add_child(_mod_card(record as Dictionary))

	var health: Dictionary = {}
	if manager.has_method("health_report"):
		health = manager.health_report()
		_list.add_child(_health_card(health))
	if manager.has_method("legacy_content"):
		var legacy: Dictionary = manager.legacy_content()
		_list.add_child(_legacy_card(legacy))

	var pending := int(manager.pending_activations())
	var notes: Array = []
	if pending > 0:
		notes.append("%d mod(s) are still activating in the background." % pending)
	var mode := _mode_note()
	if !mode.is_empty():
		notes.append(mode)
	_status.text = "\n".join(notes)


func _update_subtitle() -> void:
	if _subtitle == null or manager == null or !manager.has_method("status_report"):
		return
	var report: Dictionary = manager.status_report()
	var channel: Dictionary = report.get("channel", {}) if report.get("channel") is Dictionary else {}
	var platform: Dictionary = report.get("platform", {}) if report.get("platform") is Dictionary else {}
	var channel_label := str(channel.get("label", "Mod Platform 1.0"))
	var platform_label := str(platform.get("label", OS.get_name()))
	_subtitle.text = "%s · API 1.0 · %s · %s" % [channel_label, platform_label, "installed mods, permissions and settings"]
	_subtitle.tooltip_text = str(channel.get("note", ""))


func _health_card(report: Dictionary) -> Control:
	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel", _card_style())
	var body := VBoxContainer.new()
	body.add_theme_constant_override("separation", 5)
	card.add_child(body)

	var heading := Label.new()
	heading.text = "Platform health · Gate H"
	heading.add_theme_font_size_override("font_size", 15)
	heading.add_theme_color_override("font_color", _font_color())
	body.add_child(heading)

	if report.is_empty():
		var unavailable := Label.new()
		unavailable.text = "The hardening audit is not available in this build."
		unavailable.add_theme_color_override("font_color", _muted_color())
		body.add_child(unavailable)
		return card

	var channel: Dictionary = report.get("channel", {}) if report.get("channel") is Dictionary else {}
	var platform: Dictionary = report.get("platform", {}) if report.get("platform") is Dictionary else {}
	var runtime: Dictionary = report.get("runtime", {}) if report.get("runtime") is Dictionary else {}
	var counts: Dictionary = report.get("counts", {}) if report.get("counts") is Dictionary else {}

	var summary := Label.new()
	summary.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	summary.text = "%s · %s (%s) · %d pass, %d warn, %d fail, %d manual" % [
		str(channel.get("label", "Mod Platform 1.0")),
		str(platform.get("label", OS.get_name())),
		str(platform.get("status", "unknown")),
		int(counts.get("pass", 0)),
		int(counts.get("warn", 0)),
		int(counts.get("fail", 0)),
		int(counts.get("manual", 0)),
	]
	summary.tooltip_text = str(channel.get("note", ""))
	summary.add_theme_font_size_override("font_size", 12)
	summary.add_theme_color_override("font_color", _muted_color())
	body.add_child(summary)

	var metrics := Label.new()
	metrics.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	metrics.text = "Startup %.1f ms · Lua memory %.1f MB · %d active / %d installed · %d legacy item(s)" % [
		float(int(runtime.get("startup_usec", 0))) / 1000.0,
		float(int(runtime.get("memory_bytes", 0))) / (1024.0 * 1024.0),
		int(runtime.get("active", 0)),
		int(runtime.get("installed", 0)),
		int((report.get("legacy", {}) as Dictionary).get("count", 0)) if report.get("legacy") is Dictionary else 0,
	]
	metrics.add_theme_font_size_override("font_size", 11)
	metrics.add_theme_color_override("font_color", _muted_color())
	body.add_child(metrics)

	for raw in report.get("checks", []):
		if !(raw is Dictionary):
			continue
		var check: Dictionary = raw
		var status := str(check.get("status", "manual"))
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		var chip := Label.new()
		chip.text = status.to_upper()
		chip.custom_minimum_size = Vector2(64, 0)
		chip.add_theme_font_size_override("font_size", 11)
		chip.add_theme_color_override("font_color", _audit_color(status))
		row.add_child(chip)
		var text := Label.new()
		text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		text.text = "%s — %s" % [str(check.get("label", "")), str(check.get("detail", ""))]
		text.add_theme_font_size_override("font_size", 11)
		text.add_theme_color_override("font_color", _muted_color())
		row.add_child(text)
		body.add_child(row)

	return card


func _legacy_card(legacy: Dictionary) -> Control:
	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel", _card_style())
	var body := VBoxContainer.new()
	body.add_theme_constant_override("separation", 4)
	card.add_child(body)

	var heading := Label.new()
	heading.text = "Legacy content · not managed mods"
	heading.add_theme_font_size_override("font_size", 15)
	heading.add_theme_color_override("font_color", _font_color())
	body.add_child(heading)

	var note := Label.new()
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.text = str(legacy.get("note", "Language and theme Lua still loads through the original editor loaders."))
	note.add_theme_font_size_override("font_size", 11)
	note.add_theme_color_override("font_color", _muted_color())
	body.add_child(note)

	var entries: Array = legacy.get("entries", []) if legacy.get("entries") is Array else []
	if entries.is_empty():
		var none := Label.new()
		none.text = "No legacy language or theme files were found in user://langs or user://themes."
		none.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		none.add_theme_font_size_override("font_size", 11)
		none.add_theme_color_override("font_color", _muted_color())
		body.add_child(none)
		return card

	for raw in entries:
		if !(raw is Dictionary):
			continue
		var entry: Dictionary = raw
		var row := Label.new()
		row.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		row.text = "%s · %s · %s" % [
			str(entry.get("label", "Content")),
			str(entry.get("id", "")),
			str(entry.get("path", "")),
		]
		row.tooltip_text = "Legacy content is loaded by the editor, not the mod manager. It has no permissions, consent, sandbox or uninstall action."
		row.add_theme_font_size_override("font_size", 11)
		row.add_theme_color_override("font_color", _muted_color())
		body.add_child(row)

	return card


func _audit_color(status: String) -> Color:
	match status:
		"pass":
			return _state_color("active")
		"warn":
			return Color("#e0af68")
		"fail":
			return Color("#f7768e")
		_:
			return _muted_color()


func _mode_note() -> String:
	if manager == null:
		return ""
	var notes: Array = []
	if _flag("developer_mode"):
		notes.append(
			"Developer mode: hot reload watches user://mods_dev/<id>/<version>/main.lua and lib/*.lua."
		)
	if _flag("preview_build"):
		notes.append("This is the opt-in Developer Preview build. API 1.0 is frozen.")
	return "\n".join(notes)


func _flag(name: String) -> bool:
	var value: Variant = manager.get(name)
	return value is bool and bool(value)


# ── IMPORT REVIEW ───────────────────────────────────────────────────────────

func _build_import_dialog() -> void:
	_import_dialog = ConfirmationDialog.new()
	_import_dialog.title = "Import mod package"
	_import_dialog.ok_button_text = "Install"
	_import_dialog.cancel_button_text = "Cancel"
	_import_dialog.min_size = Vector2i(780, 650)
	_import_dialog.confirmed.connect(_on_import_confirmed)
	_import_dialog.canceled.connect(_on_import_canceled)
	add_child(_import_dialog)

	var outer := VBoxContainer.new()
	outer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	outer.offset_left = 12
	outer.offset_top = 12
	outer.offset_right = -12
	outer.offset_bottom = -54
	outer.add_theme_constant_override("separation", 8)
	_import_dialog.add_child(outer)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	outer.add_child(scroll)

	_import_body = VBoxContainer.new()
	_import_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_import_body.add_theme_constant_override("separation", 6)
	scroll.add_child(_import_body)

	_import_status = Label.new()
	_import_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_import_status.add_theme_font_size_override("font_size", 12)
	_import_status.add_theme_color_override("font_color", _muted_color())
	outer.add_child(_import_status)

	_set_import_can_install(false)


## Called by the file picker after a package is chosen. Everything shown here
## comes from ModInstaller.inspect(); no file has been extracted at this point.
func open_import(package_path: String) -> void:
	if manager == null or _import_dialog == null:
		return
	_import_path = package_path
	_import_review = {}
	_import_options = {"activate": true}
	visible = true
	move_to_front()
	_refresh_import()
	if _import_dialog.is_inside_tree():
		_import_dialog.popup_centered(Vector2i(780, 650))


func _refresh_import() -> void:
	if _import_body == null:
		return
	_clear_import_body()
	if _import_status != null:
		_import_status.text = ""

	if _import_path.is_empty() or manager == null:
		_add_import_line("Choose a .gcm or .zip package to review it.", _muted_color())
		_set_import_can_install(false)
		return

	var inspected: Dictionary = manager.inspect_package(_import_path, _import_options)
	_import_review = {}
	if !inspected.get("ok", false):
		var failure: Dictionary = inspected.get("error", {}) if inspected.get("error") is Dictionary else {}
		_add_import_line("This package cannot be imported.", Color("#f7768e"))
		_add_import_line(str(failure.get("message", "The package could not be read.")), _font_color())
		var details: Variant = failure.get("details", {})
		if details is Dictionary:
			var errors: Variant = (details as Dictionary).get("errors", [])
			if errors is Array:
				for raw in errors:
					if raw is Dictionary:
						_add_import_line("• " + str((raw as Dictionary).get("message", "")), _muted_color(), 11)
		_set_import_can_install(false)
		return

	_import_review = inspected["value"]
	_render_import_review()


func _render_import_review() -> void:
	var review: Dictionary = _import_review
	var name := str(review.get("name", review.get("id", "package")))
	var version := str(review.get("version", ""))
	_import_dialog.title = "Import %s" % name

	_add_import_heading("%s  v%s" % [name, version])
	_add_import_line("id: %s" % str(review.get("id", "")), _muted_color(), 11)
	var author := str(review.get("author", ""))
	if !author.is_empty():
		_add_import_line("Published by %s" % author, _muted_color(), 11)
	var description := str(review.get("description", "")).strip_edges()
	if !description.is_empty():
		_add_import_line(description, _font_color(), 12)

	_render_signature(review)
	_render_update(review)
	_render_permissions(review)
	_render_contents(review)

	var blockers: Array = review.get("blockers", []) if review.get("blockers") is Array else []
	var warnings: Array = review.get("warnings", []) if review.get("warnings") is Array else []
	if !blockers.is_empty():
		_add_import_heading("Must be resolved", 14, Color("#f7768e"))
		for raw in blockers:
			if raw is Dictionary:
				_add_import_line("• " + str((raw as Dictionary).get("message", "")), Color("#f7768e"), 12)
	if !warnings.is_empty():
		_add_import_heading("Warnings", 14, Color("#e0af68"))
		for raw in warnings:
			if raw is Dictionary:
				_add_import_line("• " + str((raw as Dictionary).get("message", "")), Color("#e0af68"), 12)

	_render_policy(review)

	var growth: Dictionary = review.get("permission_growth", {}) if review.get("permission_growth") is Dictionary else {}
	var consent_missing := bool(growth.get("requires_consent", false)) and !bool(_import_options.get("consent", false))
	var can_install := bool(review.get("can_install", false)) and !consent_missing
	_set_import_can_install(can_install)
	if !can_install and bool(review.get("can_install", false)) and consent_missing:
		_import_status.text = "Accept the permissions above to install this package."
		_import_status.add_theme_color_override("font_color", Color("#e0af68"))
	elif can_install:
		_import_status.text = "Nothing has been written yet. Install extracts the validated package into user://mods."
		_import_status.add_theme_color_override("font_color", _muted_color())
	else:
		_import_status.text = "Resolve the items above before installing."
		_import_status.add_theme_color_override("font_color", Color("#f7768e"))


func _render_signature(review: Dictionary) -> void:
	_add_import_heading("Package signature", 14)
	var signature: Dictionary = review.get("signature", {}) if review.get("signature") is Dictionary else {}
	var publisher: Dictionary = review.get("publisher", {}) if review.get("publisher") is Dictionary else {}

	if bool(review.get("unsigned", false)):
		_add_import_line("This package is unsigned. Its author cannot be verified.", Color("#e0af68"))
		_render_unsigned_opt_in()
		return

	var publisher_id := str(signature.get("publisher_id", ""))
	var fingerprint := str(signature.get("fingerprint", ""))
	var display_name := str(signature.get("display_name", "")).strip_edges()
	var status := str(publisher.get("status", "new"))
	var who := display_name if !display_name.is_empty() else publisher_id

	if !bool(signature.get("ok", false)):
		_add_import_line(
			"Signature invalid: " + str(signature.get("error", "the package signature did not verify.")),
			Color("#f7768e"),
		)
	else:
		match status:
			"trusted":
				_add_import_line("Verified signature from %s." % who, _state_color("active"))
			"new":
				_add_import_line("Signature is valid. This publisher is not trusted yet.", Color("#e0af68"))
			"key_changed":
				_add_import_line("The signing key for %s changed." % who, Color("#f7768e"))
			_:
				_add_import_line("Verified signature from %s." % who, _state_color("active"))

	_add_import_line("Publisher id: %s" % publisher_id, _muted_color(), 11)
	if !fingerprint.is_empty():
		_add_import_line("Key fingerprint: %s" % _short_fingerprint(fingerprint), _muted_color(), 11)
		var fingerprint_label := _last_import_line()
		if fingerprint_label != null:
			fingerprint_label.tooltip_text = fingerprint
	var signed_at := int(signature.get("signed_at", 0))
	if signed_at > 0:
		_add_import_line(
			"Signed: %s UTC" % Time.get_datetime_string_from_unix_time(signed_at, true),
			_muted_color(),
			11,
		)

	if status == "key_changed":
		var stored := str(publisher.get("stored_fingerprint", ""))
		if !stored.is_empty():
			_add_import_line("Previously pinned key: %s" % _short_fingerprint(stored), Color("#f7768e"), 11)

	if bool(publisher.get("requires_trust", false)):
		var text := "Trust publisher '%s' and pin this key" % publisher_id
		if status == "key_changed":
			text = "Replace the pinned key for '%s' with this key" % publisher_id
		_add_import_check(
			text,
			"trust_publisher",
			false,
			"Only the exact key fingerprint shown above will be accepted for later packages from this publisher.",
		)


func _render_unsigned_opt_in() -> void:
	_add_import_check(
		"Allow this unsigned package",
		"allow_unsigned",
		false,
		"Unsigned packages can be changed by anyone. Only enable this for a package you built or received from a source you trust.",
	)


func _render_update(review: Dictionary) -> void:
	var update: Dictionary = review.get("update", {}) if review.get("update") is Dictionary else {}
	var kind := str(update.get("kind", "install"))
	var current := str(update.get("current_version", ""))
	var incoming := str(update.get("incoming_version", ""))
	var previous := str(update.get("previous_version", ""))

	_add_import_heading("Installation", 14)
	match kind:
		"update":
			_add_import_line("Update %s → %s." % [current, incoming], _font_color())
		"reinstall":
			_add_import_line("Version %s is already installed and the bytes match." % incoming, _font_color())
		"replace":
			_add_import_line("Version %s is already installed with different bytes." % incoming, _font_color())
		"downgrade":
			_add_import_line("Downgrade %s → %s." % [current, incoming], Color("#e0af68"))
		_:
			_add_import_line("New installation of v%s." % incoming, _font_color())

	if !previous.is_empty() and kind != "install":
		_add_import_line("After this update you can roll back to v%s." % previous, _muted_color(), 11)
	if bool(update.get("can_rollback", false)):
		_add_import_line("A previous version is available for rollback.", _muted_color(), 11)


func _render_permissions(review: Dictionary) -> void:
	var growth: Dictionary = review.get("permission_growth", {}) if review.get("permission_growth") is Dictionary else {}
	var added: Array = growth.get("added", []) if growth.get("added") is Array else []
	var sensitive: Array = growth.get("sensitive", []) if growth.get("sensitive") is Array else []
	var requires_consent := bool(growth.get("requires_consent", false))

	_add_import_heading("Permissions", 14)
	if sensitive.is_empty():
		_add_import_line("No sensitive permissions are declared.", _muted_color())
		return

	if !requires_consent:
		_add_import_line(
			"No new permissions. Declared sensitive permissions: %s." % _permission_summary(sensitive),
			_muted_color(),
			11,
		)
		return

	var first := bool(growth.get("first_consent", false))
	if first:
		_add_import_line(
			"Before this mod can run it needs your consent for %d permission(s)." % added.size(),
			Color("#e0af68"),
		)
	else:
		_add_import_line(
			"This update adds %d permission(s) that were not in the version you already approved." % added.size(),
			Color("#e0af68"),
		)

	var details: Array = growth.get("details", []) if growth.get("details") is Array else []
	for raw in details:
		if !(raw is Dictionary):
			continue
		var detail: Dictionary = raw
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		var permission_label := Label.new()
		permission_label.text = str(detail.get("name", ""))
		permission_label.custom_minimum_size = Vector2(190, 0)
		permission_label.add_theme_font_size_override("font_size", 12)
		permission_label.add_theme_color_override("font_color", _font_color())
		row.add_child(permission_label)
		var risk := str(detail.get("risk", "unknown"))
		var risk_label := Label.new()
		risk_label.text = risk
		risk_label.custom_minimum_size = Vector2(70, 0)
		risk_label.add_theme_font_size_override("font_size", 11)
		risk_label.add_theme_color_override("font_color", _risk_color(risk))
		row.add_child(risk_label)
		var grants := Label.new()
		grants.text = str(detail.get("grants", ""))
		grants.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		grants.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		grants.add_theme_font_size_override("font_size", 11)
		grants.add_theme_color_override("font_color", _muted_color())
		row.add_child(grants)
		_import_body.add_child(row)

	_add_import_check(
		"I accept these permissions and understand what they allow",
		"consent",
		false,
	)

	var removed: Array = growth.get("removed", []) if growth.get("removed") is Array else []
	if !removed.is_empty():
		_add_import_line("This version no longer uses: %s." % ", ".join(removed), _muted_color(), 11)


func _render_contents(review: Dictionary) -> void:
	var counts: Dictionary = review.get("counts", {}) if review.get("counts") is Dictionary else {}
	var sizes: Dictionary = review.get("sizes", {}) if review.get("sizes") is Dictionary else {}
	if counts.is_empty() and sizes.is_empty():
		return
	var file_count := int(counts.get("files", 0))
	var directory_count := int(counts.get("directories", 0))
	var compressed := int(sizes.get("compressed", 0))
	var expanded := int(sizes.get("uncompressed", 0))
	_add_import_heading("Contents", 14)
	_add_import_line(
		"%d file(s), %d folder(s) · %s compressed · %s after extraction" % [
			file_count,
			directory_count,
			_format_bytes(compressed),
			_format_bytes(expanded),
		],
		_muted_color(),
		11,
	)
	var hash := str(review.get("hash", ""))
	if !hash.is_empty():
		var hash_label := _add_import_line("SHA-256: %s" % hash, _muted_color(), 10)
		if hash_label != null:
			hash_label.tooltip_text = hash


func _render_policy(review: Dictionary) -> void:
	var update: Dictionary = review.get("update", {}) if review.get("update") is Dictionary else {}
	var kind := str(update.get("kind", "install"))
	var needs_replace := bool(update.get("target_exists", false)) or kind == "reinstall" or kind == "replace"

	_add_import_heading("Import options", 14)
	if needs_replace:
		_add_import_check(
			"Replace the copy already on disk",
			"replace",
			false,
			"Same-version replacement is not rollbackable. The previous files are removed.",
		)
	if kind == "downgrade":
		_add_import_check(
			"Allow installing an older version",
			"allow_downgrade",
			false,
		)
	_add_import_check("Activate after installing", "activate", true)


func _set_import_can_install(enabled: bool) -> void:
	if _import_dialog == null:
		return
	_import_dialog.get_ok_button().disabled = !enabled


func _on_import_confirmed() -> void:
	if manager == null or _import_path.is_empty():
		return
	_import_status.text = "Installing…"
	_import_status.add_theme_color_override("font_color", _muted_color())
	_set_import_can_install(false)

	var result: Dictionary = manager.import_package(_import_path, _import_options.duplicate(true))
	if !result.get("ok", false):
		var failure: Dictionary = result.get("error", {}) if result.get("error") is Dictionary else {}
		_refresh_import()
		_import_status.text = "Import failed: " + str(failure.get("message", "unknown error"))
		_import_status.add_theme_color_override("font_color", Color("#f7768e"))
		if _import_dialog.is_inside_tree():
			_import_dialog.popup_centered(Vector2i(780, 650))
		return

	var value: Dictionary = result.get("value", {}) if result.get("value") is Dictionary else {}
	var install: Dictionary = value.get("install", {}) if value.get("install") is Dictionary else {}
	var review: Dictionary = value.get("review", {}) if value.get("review") is Dictionary else {}
	var display := str(review.get("name", install.get("id", "The mod")))
	var version := str(install.get("version", ""))

	_import_dialog.hide()
	refresh()

	var notes: Array = ["Installed %s v%s." % [display, version]]
	if bool(value.get("activated", false)):
		notes.append("It is active.")
	else:
		var activation: Dictionary = value.get("activation_error", {}) if value.get("activation_error") is Dictionary else {}
		notes.append("It was installed but not activated: " + str(activation.get("message", "consent is still required.")))
	var update: Dictionary = review.get("update", {}) if review.get("update") is Dictionary else {}
	var kind := str(update.get("kind", "install"))
	if kind == "update":
		var previous := str(install.get("previous_version", ""))
		if !previous.is_empty():
			notes.append("You can roll back to v%s from the mod card." % previous)
	_status.text = "\n".join(notes)
	_import_path = ""
	_import_review = {}
	_import_options = {"activate": true}


func _on_import_canceled() -> void:
	_import_path = ""
	_import_review = {}
	_import_options = {"activate": true}
	_import_status.text = ""
	_import_status.add_theme_color_override("font_color", _muted_color())


# ── MOD CARDS ───────────────────────────────────────────────────────────────

func _mod_card(record: Dictionary) -> Control:
	var mod_id := str(record.get("id", ""))
	var state: Dictionary = manager.state(mod_id)
	var status := str(state.get("status", "unknown"))

	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel", _card_style())
	var body := VBoxContainer.new()
	body.add_theme_constant_override("separation", 6)
	card.add_child(body)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 8)
	body.add_child(header)

	var name_label := Label.new()
	name_label.text = str(record.get("name", mod_id))
	name_label.add_theme_font_size_override("font_size", 15)
	name_label.add_theme_color_override("font_color", _font_color())
	header.add_child(name_label)

	var version := Label.new()
	version.text = "v" + str(record.get("version", ""))
	version.add_theme_font_size_override("font_size", 12)
	version.add_theme_color_override("font_color", _muted_color())
	header.add_child(version)

	if bool(record.get("dev", false)):
		var dev_label := Label.new()
		dev_label.text = "dev · hot reload"
		dev_label.add_theme_font_size_override("font_size", 11)
		dev_label.add_theme_color_override("font_color", _state_color("active"))
		header.add_child(dev_label)

	var state_label := Label.new()
	state_label.text = status
	state_label.add_theme_font_size_override("font_size", 12)
	state_label.add_theme_color_override("font_color", _state_color(status))
	header.add_child(state_label)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(spacer)

	var enabled := status != "disabled"
	var toggle := Button.new()
	toggle.text = "Disable" if enabled else "Enable"
	toggle.pressed.connect(func() -> void:
		manager.set_enabled(mod_id, !enabled, "Changed from the Mods page.")
		refresh()
	)
	header.add_child(toggle)

	var reload := Button.new()
	reload.text = "Reload"
	reload.pressed.connect(func() -> void:
		var result: Dictionary = manager.reload_mod(mod_id)
		refresh()
		if !result.get("ok", false):
			_status.text = "Reload failed: " + _error_message(result)
	)
	header.add_child(reload)

	var log_button := Button.new()
	log_button.text = "Log"
	log_button.pressed.connect(func() -> void: log_requested.emit(mod_id))
	header.add_child(log_button)

	if status == "blocked":
		var missing: Array = state.get("missing_permissions", [])
		var grant := Button.new()
		grant.text = "Grant " + str(missing.size()) + " permission(s)"
		grant.tooltip_text = ", ".join(missing)
		grant.pressed.connect(func() -> void:
			var result: Dictionary = manager.grant_consent(mod_id)
			refresh()
			if !result.get("ok", false):
				_status.text = "Consent failed: " + _error_message(result)
		)
		header.add_child(grant)

		var missing_label := Label.new()
		missing_label.text = "Needs: " + ", ".join(missing)
		missing_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		missing_label.add_theme_font_size_override("font_size", 12)
		missing_label.add_theme_color_override("font_color", _state_color("blocked"))
		body.add_child(missing_label)

	if status == "failed":
		var reason := Label.new()
		reason.text = str(state.get("reason", "The mod stopped."))
		reason.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		reason.add_theme_font_size_override("font_size", 12)
		reason.add_theme_color_override("font_color", _state_color("failed"))
		body.add_child(reason)

	var signature := _signature_summary(record)
	var signature_label := Label.new()
	signature_label.text = str(signature.get("text", ""))
	signature_label.tooltip_text = str(signature.get("tooltip", ""))
	signature_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	signature_label.add_theme_font_size_override("font_size", 12)
	var signature_color: Variant = signature.get("color", _muted_color())
	signature_label.add_theme_color_override("font_color", signature_color if signature_color is Color else _muted_color())
	body.add_child(signature_label)

	var permissions: Dictionary = _permission_risk_summary(mod_id)
	var permissions_label := Label.new()
	permissions_label.text = str(permissions.get("text", ""))
	permissions_label.tooltip_text = str(permissions.get("tooltip", ""))
	permissions_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	permissions_label.add_theme_font_size_override("font_size", 11)
	var permissions_color: Variant = permissions.get("color", _muted_color())
	permissions_label.add_theme_color_override("font_color", permissions_color if permissions_color is Color else _muted_color())
	body.add_child(permissions_label)

	var settings: Dictionary = manager.settings_for(mod_id)
	var definitions: Array = settings.get("definitions", [])
	var values: Dictionary = settings.get("values", {})

	if definitions.is_empty():
		var none := Label.new()
		none.text = "No settings declared."
		none.add_theme_font_size_override("font_size", 12)
		none.add_theme_color_override("font_color", _muted_color())
		body.add_child(none)
	else:
		for definition in definitions:
			body.add_child(_setting_row(mod_id, definition as Dictionary, values))

	if !bool(record.get("dev", false)):
		body.add_child(_card_actions(record))

	return card


func _card_actions(record: Dictionary) -> Control:
	var mod_id := str(record.get("id", ""))
	var display := str(record.get("name", mod_id))
	var previous := str(record.get("previous_version", ""))

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)

	if !previous.is_empty():
		var rollback := Button.new()
		rollback.text = "Roll back to v" + previous
		rollback.tooltip_text = "Switch the active version back to v%s. The current files stay on disk." % previous
		rollback.pressed.connect(func() -> void: _confirm_rollback(mod_id, display, previous))
		row.add_child(rollback)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spacer)

	var uninstall := Button.new()
	uninstall.text = "Uninstall…"
	uninstall.pressed.connect(func() -> void: _confirm_uninstall(mod_id, display))
	row.add_child(uninstall)

	return row


func _confirm_rollback(mod_id: String, display: String, previous: String) -> void:
	var dialog := ConfirmationDialog.new()
	dialog.title = "Roll back %s" % display
	dialog.dialog_text = "Switch back to %s v%s?\n\nThe current version stays on disk; only the active version changes. It is verified against its recorded digest before the switch." % [display, previous]
	dialog.ok_button_text = "Roll back"
	dialog.cancel_button_text = "Cancel"
	dialog.confirmed.connect(func() -> void:
		_run_rollback(mod_id, display, previous)
		dialog.queue_free()
	)
	dialog.canceled.connect(func() -> void: dialog.queue_free())
	add_child(dialog)
	if dialog.is_inside_tree():
		dialog.popup_centered()


func _run_rollback(mod_id: String, display: String, previous: String) -> void:
	var result: Dictionary = manager.rollback_mod(mod_id)
	refresh()
	if !result.get("ok", false):
		_status.text = "Rollback failed: " + _error_message(result)
		return
	var value: Dictionary = result.get("value", {}) if result.get("value") is Dictionary else {}
	var rolled: Dictionary = value.get("rollback", {}) if value.get("rollback") is Dictionary else {}
	var notes: Array = ["Rolled %s back to v%s." % [display, str(rolled.get("version", previous))]]
	if !bool(value.get("activated", false)):
		var activation: Dictionary = value.get("activation_error", {}) if value.get("activation_error") is Dictionary else {}
		notes.append("It was not activated: " + str(activation.get("message", "consent is required.")))
	_status.text = "\n".join(notes)


func _confirm_uninstall(mod_id: String, display: String) -> void:
	var dialog := ConfirmationDialog.new()
	dialog.title = "Uninstall %s" % display
	dialog.dialog_text = "Remove every installed version of %s?\n\nMod data under user://mod_data/%s is kept unless you choose to delete it." % [display, mod_id]
	dialog.ok_button_text = "Uninstall, keep data"
	dialog.cancel_button_text = "Cancel"
	dialog.add_button("Uninstall and delete data", true, "remove_data")
	dialog.confirmed.connect(func() -> void:
		_run_uninstall(mod_id, display, false)
		dialog.queue_free()
	)
	dialog.custom_action.connect(func(action: StringName) -> void:
		if str(action) == "remove_data":
			_run_uninstall(mod_id, display, true)
		dialog.queue_free()
	)
	dialog.canceled.connect(func() -> void: dialog.queue_free())
	add_child(dialog)
	if dialog.is_inside_tree():
		dialog.popup_centered()


func _run_uninstall(mod_id: String, display: String, remove_data: bool) -> void:
	var result: Dictionary = manager.uninstall_mod(mod_id, {"remove_data": remove_data})
	if !result.get("ok", false):
		_status.text = "Uninstall failed: " + _error_message(result)
		return

	var value: Dictionary = result.get("value", {}) if result.get("value") is Dictionary else {}
	refresh()
	var notes: Array = ["Removed %s (%d version folder(s))." % [display, int(value.get("removed_versions", 0))]]
	if bool(value.get("data_removed", false)):
		notes.append("Mod data was deleted.")
	elif bool(value.get("data_kept", false)):
		notes.append("Mod data was kept under user://mod_data/%s." % mod_id)
	_status.text = "\n".join(notes)


# ── SETTINGS ────────────────────────────────────────────────────────────────

func _setting_row(mod_id: String, definition: Dictionary, values: Dictionary) -> Control:
	var key := str(definition.get("key", ""))
	var type := str(definition.get("type", "string"))
	var value: Variant = values.get(key, definition.get("default"))

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)

	var label := Label.new()
	label.text = str(definition.get("label", key))
	label.custom_minimum_size = Vector2(260, 0)
	label.add_theme_color_override("font_color", _font_color())
	row.add_child(label)

	var control: Control = null
	match type:
		"bool":
			var check := CheckBox.new()
			check.button_pressed = bool(value)
			check.toggled.connect(func(pressed: bool) -> void: _write(mod_id, key, pressed))
			control = check
		"int", "float":
			var spin := SpinBox.new()
			spin.min_value = float(definition.get("min", -999999))
			spin.max_value = float(definition.get("max", 999999))
			spin.step = 1 if type == "int" else 0.1
			spin.value = float(value)
			spin.value_changed.connect(func(next: float) -> void:
				_write(mod_id, key, int(round(next)) if type == "int" else next)
			)
			control = spin
		"string":
			if definition.get("options") is Array:
				var option := OptionButton.new()
				var options: Array = definition["options"]
				var selected := 0
				for index in range(options.size()):
					var entry: Variant = options[index]
					# Manifest options are {display, value}; runtime-declared
					# options may use {label, value}. Prefer the human-readable
					# key, fall back to the raw value.
					var text := str(entry.get("display", entry.get("label", entry.get("value", entry))) if entry is Dictionary else entry)
					var entry_value: Variant = (entry as Dictionary).get("value", entry) if entry is Dictionary else entry
					option.add_item(text)
					if str(entry_value) == str(value):
						selected = index
				option.selected = selected
				option.item_selected.connect(func(index: int) -> void:
					var chosen: Variant = options[index]
					_write(mod_id, key, chosen.get("value", chosen) if chosen is Dictionary else chosen)
				)
				control = option
			else:
				var input := LineEdit.new()
				input.text = str(value)
				# Both signals fire on Enter (submit then unfocus); only write
				# when the text actually changed to avoid double settings.json writes.
				var last_written := [str(value)]
				var write_if_changed := func(text: String) -> void:
					if text == last_written[0]:
						return
					last_written[0] = text
					_write(mod_id, key, text)
				input.focus_exited.connect(func() -> void: write_if_changed.call(input.text))
				input.text_submitted.connect(write_if_changed)
				control = input
		_:
			var fallback := Label.new()
			fallback.text = str(value)
			control = fallback

	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(control)
	return row


func _write(mod_id: String, key: String, value: Variant) -> void:
	var result: Dictionary = manager.set_mod_setting(mod_id, key, value)
	if !result.get("ok", false):
		_status.text = "Setting '%s' was not saved: %s" % [key, _error_message(result)]


# ── IMPORT HELPERS ──────────────────────────────────────────────────────────

func _clear_import_body() -> void:
	for child in _import_body.get_children():
		_import_body.remove_child(child)
		child.queue_free()


func _add_import_heading(text: String, font_size: int = 15, color: Color = Color.TRANSPARENT) -> void:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color if color.a > 0.0 else _font_color())
	_import_body.add_child(label)


func _add_import_line(text: String, color: Color, font_size: int = 12) -> Label:
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	_import_body.add_child(label)
	return label


func _last_import_line() -> Label:
	if _import_body.get_child_count() == 0:
		return null
	var child: Node = _import_body.get_child(_import_body.get_child_count() - 1)
	return child as Label


func _add_import_check(
	text: String,
	option: String,
	default_value: bool,
	tooltip: String = "",
) -> CheckBox:
	var check := CheckBox.new()
	check.text = text
	check.button_pressed = bool(_import_options.get(option, default_value))
	if !tooltip.is_empty():
		check.tooltip_text = tooltip
	check.toggled.connect(func(pressed: bool) -> void:
		_import_options[option] = pressed
		if option == "trust_publisher":
			var publisher: Dictionary = _import_review.get("publisher", {}) if _import_review.get("publisher") is Dictionary else {}
			if str(publisher.get("status", "")) == "key_changed":
				_import_options["replace_key"] = pressed
		if option == "activate":
			return
		_refresh_import.call_deferred()
	)
	_import_body.add_child(check)
	return check


func _signature_summary(record: Dictionary) -> Dictionary:
	if bool(record.get("dev", false)):
		return {
			"text": "Development copy · not installed from a package",
			"tooltip": str(record.get("root", "")),
			"color": _state_color("active"),
		}

	var signature: Dictionary = record.get("signature", {}) if record.get("signature") is Dictionary else {}
	var publisher_id := str(record.get("publisher_id", ""))
	var fingerprint := str(record.get("publisher_fingerprint", ""))
	var present := bool(signature.get("present", false))
	var valid := bool(signature.get("ok", false)) and str(signature.get("status", "")) == "valid"

	if !present:
		return {
			"text": "Unsigned package" + (" · installed with an explicit opt-in" if bool(record.get("allow_unsigned", false)) else ""),
			"tooltip": "The package has no signature.json. Its origin cannot be verified.",
			"color": _muted_color(),
		}
	if !valid:
		return {
			"text": "Invalid package signature · this mod will not run",
			"tooltip": str(signature.get("error", "The installed files no longer match the signature.")),
			"color": Color("#f7768e"),
		}

	var publisher: Dictionary = {}
	if manager != null and manager.has_method("publisher_state"):
		publisher = manager.publisher_state(signature)
	var state := str(publisher.get("status", "trusted"))
	var who := str(signature.get("display_name", "")).strip_edges()
	if who.is_empty():
		who = publisher_id
	match state:
		"trusted":
			return {
				"text": "Verified signature · %s · key %s" % [who, _short_fingerprint(fingerprint)],
				"tooltip": "Publisher id: %s\nKey fingerprint: %s" % [publisher_id, fingerprint],
				"color": _state_color("active"),
			}
		"key_changed":
			return {
				"text": "Publisher key changed · %s" % who,
				"tooltip": "The pinned key for %s no longer matches the signature." % publisher_id,
				"color": Color("#f7768e"),
			}
		_:
			return {
				"text": "Valid signature, publisher not trusted · %s · key %s" % [who, _short_fingerprint(fingerprint)],
				"tooltip": "Publisher id: %s\nKey fingerprint: %s" % [publisher_id, fingerprint],
				"color": Color("#e0af68"),
			}


func _permission_risk_summary(mod_id: String) -> Dictionary:
	var permissions: Array = []
	if manager != null and manager.has_method("registry_permissions"):
		permissions = manager.registry_permissions(mod_id)
	var counts := {"critical": 0, "high": 0, "medium": 0, "low": 0}
	var names: Array = []
	for raw in permissions:
		var name := str(raw)
		if name == "core":
			continue
		var info := _permission_info(name)
		var risk := str(info.get("risk", "unknown"))
		if counts.has(risk):
			counts[risk] = int(counts[risk]) + 1
		names.append("%s (%s)" % [name, risk])

	var parts: Array = []
	for risk in ["critical", "high", "medium", "low"]:
		if int(counts[risk]) > 0:
			parts.append("%d %s" % [int(counts[risk]), risk])
	if parts.is_empty():
		return {
			"text": "Permissions: none beyond core",
			"tooltip": ", ".join(names) if !names.is_empty() else "No extra permissions are declared.",
			"color": _muted_color(),
		}

	var color := _muted_color()
	if int(counts["critical"]) > 0:
		color = Color("#f7768e")
	elif int(counts["high"]) > 0:
		color = Color("#e0af68")
	return {
		"text": "Permissions: " + ", ".join(parts),
		"tooltip": ", ".join(names),
		"color": color,
	}


func _permission_summary(permissions: Array) -> String:
	var parts: Array = []
	for raw in permissions:
		var name := str(raw)
		parts.append("%s (%s)" % [name, str(_permission_info(name).get("risk", "unknown"))])
	return ", ".join(parts)


func _permission_info(name: String) -> Dictionary:
	var entry: Variant = Permissions.CATALOGUE.get(name)
	return entry if entry is Dictionary else {}


func _risk_color(risk: String) -> Color:
	match risk:
		"critical":
			return Color("#f7768e")
		"high":
			return Color("#e0af68")
		"medium":
			return _color("selection_color", Color("#89b4fa"))
		_:
			return _muted_color()


func _short_fingerprint(fingerprint: String, length: int = 16) -> String:
	var clean := fingerprint.to_lower()
	if clean.length() <= length:
		return clean
	var head := clean.substr(0, length)
	var chunks: Array = []
	for index in range(0, head.length(), 4):
		chunks.append(head.substr(index, 4))
	return " ".join(chunks)


func _format_bytes(count: int) -> String:
	if count >= 1024 * 1024:
		return "%.1f MB" % (float(count) / (1024.0 * 1024.0))
	if count >= 1024:
		return "%.1f KB" % (float(count) / 1024.0)
	return "%d B" % count


func _error_message(result: Dictionary) -> String:
	var failure: Dictionary = result.get("error", {}) if result.get("error") is Dictionary else {}
	return str(failure.get("message", "unknown error"))


# ── THEME ───────────────────────────────────────────────────────────────────

func _panel_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = _color("background_color", Color("#181825"))
	style.border_color = _color("current_line_color", Color("#313244"))
	style.set_border_width_all(1)
	style.set_corner_radius_all(8)
	style.set_content_margin_all(14)
	return style


func _card_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = _color("current_line_color", Color("#313244"))
	style.bg_color.a = 0.35
	style.set_corner_radius_all(5)
	style.set_content_margin_all(10)
	return style


func _font_color() -> Color:
	return _color("font_color", Color("#cdd6f4"))


func _muted_color() -> Color:
	return Color(_font_color(), 0.65)


func _state_color(status: String) -> Color:
	match status:
		"active":
			return _color("selection_color", Color("#89b4fa"))
		"failed":
			return Color("#f7768e")
		"blocked", "unsupported":
			return Color("#e0af68")
		_:
			return _muted_color()


func _color(property: String, fallback: Color) -> Color:
	var lua = _lua_singleton()
	if lua == null or lua.gui == null:
		return fallback
	var value: Variant = lua.gui.get(property)
	return value if value is Color else fallback


func _lua_singleton():
	var loop := Engine.get_main_loop()
	return loop.root.get_node_or_null("LuaSingleton") if loop != null else null
