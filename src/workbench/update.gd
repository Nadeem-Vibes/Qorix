extends Control

## Manual update check against the GitHub releases API.
##
## The repository is named in one place so a fork cannot accidentally keep
## advertising somebody else's releases. The upstream project is only tried as
## a fallback for builds that still tag against it.

const Versions = preload("res://src/base/version_utils.gd")

const RELEASES_REPOS := [
	"Nadeem-vibes/Qorix",  # maintained fork: the builds this updater serves
	"face-hh/griddycode",       # original project, kept as a fallback
]
const API_URL := "https://api.github.com/repos/%s/releases/latest"
const RELEASES_URL := "https://github.com/%s/releases"
const REQUEST_TIMEOUT := 15.0

@onready var info: RichTextLabel = $RichTextLabel2
@onready var current_version: RichTextLabel = $RichTextLabel

var is_requesting = false;

## Which entry of RELEASES_REPOS the current request is asking about.
var _repo_index: int = 0


func _ready():
	current_version.text = "Version: " + LuaSingleton.version
	$HTTPRequest.request_completed.connect(_on_request_completed)
	$HTTPRequest.timeout = REQUEST_TIMEOUT


func _on_button_pressed():
	if is_requesting: return

	is_requesting = true
	_repo_index = 0
	info.show()
	info.text = "Loading..."
	_request_latest()


func _request_latest() -> void:
	var url := API_URL % RELEASES_REPOS[_repo_index]
	if $HTTPRequest.request(url) != OK:
		_fail("Could not reach GitHub. Check your connection and try again.")


## The latest release of the current repository. Returns
## {ok, tag, url, error}. Never indexes a field without checking it first.
func _parse_release(body: PackedByteArray) -> Dictionary:
	var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
	if !(parsed is Dictionary):
		return {"ok": false, "error": "GitHub returned an unexpected response."}

	var release: Dictionary = parsed
	if !release.has("tag_name") and !release.has("name"):
		return {"ok": false, "error": "The latest release has no version."}

	var tag := str(release.get("tag_name", "")).strip_edges()
	if tag.is_empty():
		tag = str(release.get("name", "")).strip_edges()
	if tag.is_empty():
		return {"ok": false, "error": "The latest release has no version."}

	return {
		"ok": true,
		"tag": tag,
		"url": RELEASES_URL % RELEASES_REPOS[_repo_index],
		"error": "",
	}


func _on_request_completed(result, response_code, _headers, body):
	if result != HTTPRequest.RESULT_SUCCESS:
		_next_repo_or_fail("Could not reach GitHub. Check your connection and try again.")
		return
	if int(response_code) != 200:
		# A 404 means this repository has no releases: try the next one. Any
		# other status is a real answer (rate limit, server error, ...).
		if int(response_code) == 404:
			_next_repo_or_fail("GitHub returned HTTP 404.")
		else:
			_fail("GitHub returned HTTP %d." % int(response_code))
		return

	var release := _parse_release(body)
	if !release.get("ok", false):
		_fail(str(release.get("error", "Could not read the latest release.")))
		return

	info.clear()
	var tag := str(release.get("tag", ""))
	var url := str(release.get("url", ""))
	if !is_higher_version(tag):
		info.text = "You're up to date! (latest release: %s)" % tag
	else:
		info.text = "[color=green]%s[/color] is out! [url=%s]GitHub[/url]" % [tag, url]

	info.show()
	is_requesting = false
	get_tree().create_timer(10).timeout.connect(info.hide)


func _next_repo_or_fail(reason: String) -> void:
	_repo_index += 1
	if _repo_index < RELEASES_REPOS.size():
		_request_latest()
		return
	_fail(reason)


func _fail(reason: String) -> void:
	info.clear()
	info.text = "[color=yellow]UPDATE CHECK[/color]: %s" % reason
	info.show()
	is_requesting = false
	get_tree().create_timer(10).timeout.connect(info.hide)


func is_higher_version(new_version: String) -> bool:
	return Versions.is_higher_version(LuaSingleton.version, new_version)
