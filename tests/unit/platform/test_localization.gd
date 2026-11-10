extends "res://tests/support/test_case.gd"

const LocalizationScript = preload("res://src/platform/localization_service.gd")

var service: Node


func before_each() -> void:
	service = LocalizationScript.new()


func after_each() -> void:
	# TranslationServer is global; leave it in the default language so later
	# suites still see the source strings.
	TranslationServer.set_locale("en")
	if service != null:
		service.free()
	service = null


func test_csv_parser_handles_quotes_commas_and_crlf() -> void:
	var csv := "keys,en,de\r\n\"Save\",\"Save\",\"Speichern\"\r\n\"Say \"\"hi\"\"\",\"Say \"\"hi\"\"\",\"Sag \"\"hi\"\"\"\r\n\"Comma, inside\",\"Comma, inside\",\"Komma, innen\"\r\n"
	var rows: Array = LocalizationScript.parse_csv(csv)

	assert_eq(rows.size(), 4)
	assert_eq(rows[0][0], "keys")
	assert_eq(rows[1][2], "Speichern")
	assert_eq(rows[2][1], "Say \"hi\"")
	assert_eq(rows[3][2], "Komma, innen")


func test_bundled_catalog_installs_three_languages() -> void:
	var result: Dictionary = service.install()
	assert_eq(result.get("ok"), true)
	assert_true(service.has_locale("en"))
	assert_true(service.has_locale("de"))
	assert_true(service.has_locale("es"))

	var codes: Array = []
	for option in service.language_options():
		codes.append(str(option.get("value")))
	assert_true(codes.has("en"))
	assert_true(codes.has("de"))
	assert_true(codes.has("es"))


func test_switching_locale_translates_source_strings() -> void:
	assert_eq(service.install().get("ok"), true)

	assert_true(service.set_locale("de"))
	assert_eq(TranslationServer.translate("Save"), "Speichern")
	assert_eq(TranslationServer.translate("Editor Line Height"), "Editor-Zeilenhöhe")
	assert_eq(TranslationServer.translate("High Contrast"), "Hoher Kontrast")

	assert_true(service.set_locale("es"))
	assert_eq(TranslationServer.translate("New File"), "Archivo nuevo")
	assert_eq(TranslationServer.translate("Interface Language"), "Idioma de la interfaz")


func test_unknown_locale_is_rejected_and_missing_keys_fall_back() -> void:
	assert_eq(service.install().get("ok"), true)
	assert_false(service.set_locale("zz"))

	assert_true(service.set_locale("de"))
	assert_eq(
		TranslationServer.translate("A key nobody translated"),
		"A key nobody translated"
	)
