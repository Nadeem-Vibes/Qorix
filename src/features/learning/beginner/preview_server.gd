extends Node

## Tiny loopback web server for the live HTML/Markdown preview.
##
## The server only ever binds to 127.0.0.1, only answers GET/HEAD, and only
## serves files below the workspace root it was started with. Every text page
## gets a small polling script; `/__griddy_version` changes when FileManager
## reports a save, and the page reloads itself.
##
## `build_response()` is static and pure, so the routing, MIME, escaping and
## path-traversal rules can be tested headlessly without opening a socket.

const Markdown = preload("res://src/features/learning/beginner/markdown.gd")
const Paths = preload("res://src/base/path_utils.gd")

const VERSION_PATH := "/__griddy_version"
const MAX_HEADER_BYTES := 16384
const CLIENT_TIMEOUT_MSEC := 5000

const LIVE_RELOAD_SCRIPT := """<script data-griddy-preview>
(function () {
  let known = null;
  async function poll() {
    try {
      const response = await fetch('/__griddy_version', { cache: 'no-store' });
      if (!response.ok) throw new Error('preview server is not ready');
      const data = await response.json();
      if (known === null) {
        known = data.version;
      } else if (data.version !== known) {
        window.location.reload();
        return;
      }
    } catch (error) {
      // The editor may be restarting; keep polling quietly.
    }
    window.setTimeout(poll, 700);
  }
  window.setTimeout(poll, 400);
})();
</script>"""

const MIME_TYPES := {
	"html": "text/html; charset=utf-8",
	"htm": "text/html; charset=utf-8",
	"md": "text/html; charset=utf-8",
	"markdown": "text/html; charset=utf-8",
	"css": "text/css; charset=utf-8",
	"js": "text/javascript; charset=utf-8",
	"mjs": "text/javascript; charset=utf-8",
	"json": "application/json; charset=utf-8",
	"txt": "text/plain; charset=utf-8",
	"xml": "application/xml; charset=utf-8",
	"svg": "image/svg+xml",
	"png": "image/png",
	"jpg": "image/jpeg",
	"jpeg": "image/jpeg",
	"gif": "image/gif",
	"webp": "image/webp",
	"ico": "image/x-icon",
	"woff": "font/woff",
	"woff2": "font/woff2",
	"ttf": "font/ttf",
	"otf": "font/otf",
	"wasm": "application/wasm",
	"map": "application/json; charset=utf-8",
}

var root_path: String = ""
var entry_path: String = ""
var port: int = 0

var _server: TCPServer = null
var _peers: Dictionary = {}
var _version: int = 1


func _ready() -> void:
	set_process(true)


func start(root: String, requested_port: int = 0, entry: String = "") -> Dictionary:
	stop()

	var normalized_root := Paths.normalize(root)
	if normalized_root.is_empty():
		return {"ok": false, "error": "No preview folder was chosen.", "port": 0, "url": "", "root": ""}
	if !DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(normalized_root)):
		return {"ok": false, "error": "The preview folder does not exist: " + normalized_root, "port": 0, "url": "", "root": ""}

	_server = TCPServer.new()
	var error := _server.listen(clampi(requested_port, 0, 65535), "127.0.0.1")
	if error != OK:
		_server = null
		return {
			"ok": false,
			"error": "Could not start the preview server on 127.0.0.1:%d (error %d)." % [requested_port, error],
			"port": 0,
			"url": "",
			"root": "",
		}

	root_path = normalized_root
	port = _server.get_local_port()
	_version += 1
	set_entry(entry)
	return {"ok": true, "error": "", "port": port, "url": base_url(), "root": root_path}


func stop() -> void:
	for peer in _peers.keys():
		if peer != null:
			peer.disconnect_from_host()
	_peers.clear()
	if _server != null:
		_server.stop()
	_server = null
	port = 0


func is_running() -> bool:
	return _server != null and _server.is_listening()


func base_url() -> String:
	if port <= 0:
		return ""
	return "http://127.0.0.1:%d/" % port


## The entry file is what "/" serves. It must live inside the served root.
func set_entry(path: String) -> bool:
	var normalized := Paths.normalize(path)
	if normalized.is_empty():
		entry_path = ""
		return true
	if root_path.is_empty() or !Paths.is_subpath(root_path, normalized):
		entry_path = ""
		return false
	entry_path = normalized
	return true


func entry_url() -> String:
	var base := base_url()
	if base.is_empty():
		return ""
	return base + "?v=%d" % _version


## Starts the server if needed, points it at `path` and opens the browser.
## Returns {ok, error, url, port}.
func open_in_browser(path: String) -> Dictionary:
	var normalized := Paths.normalize(path)
	if normalized.is_empty():
		return {"ok": false, "error": "Open an HTML or Markdown file first.", "url": "", "port": port}

	if !is_running():
		var root := root_path
		if root.is_empty() or !Paths.is_subpath(root, normalized):
			root = normalized.get_base_dir()
		var started := start(root, port, normalized)
		if !bool(started.get("ok", false)):
			return started
	elif !set_entry(normalized):
		return {"ok": false, "error": "That file is outside the preview folder.", "url": "", "port": port}

	_version += 1
	var url := entry_url()
	var shell_error := OS.shell_open(url)
	if shell_error != OK:
		return {
			"ok": false,
			"error": "Could not open the browser (error %d). The preview is running at %s" % [shell_error, url],
			"url": url,
			"port": port,
		}
	return {"ok": true, "error": "", "url": url, "port": port}


## FileManager calls this after a successful save; the next poll reloads.
func notify_changed(path: String = "") -> void:
	_version += 1


func version() -> int:
	return _version


func _process(_delta: float) -> void:
	if _server == null:
		return

	while _server.is_connection_available():
		var peer := _server.take_connection()
		if peer == null:
			continue
		peer.set_no_delay(true)
		_peers[peer] = {"buffer": PackedByteArray(), "started": Time.get_ticks_msec()}

	for peer in _peers.keys():
		if peer == null or !is_instance_valid(peer):
			_peers.erase(peer)
			continue
		if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			_peers.erase(peer)
			continue

		var state: Dictionary = _peers[peer]
		if Time.get_ticks_msec() - int(state.get("started", 0)) > CLIENT_TIMEOUT_MSEC:
			peer.disconnect_from_host()
			_peers.erase(peer)
			continue

		peer.poll()
		var available: int = int(peer.get_available_bytes())
		if available <= 0:
			continue

		var chunk: Array = peer.get_data(available)
		if int(chunk[0]) != OK:
			peer.disconnect_from_host()
			_peers.erase(peer)
			continue

		var buffer: PackedByteArray = state.get("buffer", PackedByteArray())
		buffer.append_array(chunk[1])
		if buffer.size() > MAX_HEADER_BYTES:
			_send(peer, _error_response(431, "Request headers are too large."), false)
			_peers.erase(peer)
			continue
		state["buffer"] = buffer
		_peers[peer] = state

		var header_end := _find_header_end(buffer)
		if header_end < 0:
			continue

		var request_text := buffer.slice(0, header_end).get_string_from_utf8()
		var first_line := request_text.split("\r\n")[0] if request_text.contains("\r\n") else request_text.split("\n")[0]
		var parts := first_line.split(" ")
		var method := str(parts[0]) if parts.size() > 0 else "GET"
		var target := str(parts[1]) if parts.size() > 1 else "/"
		var response := build_response(method, target, root_path, entry_path, _version)
		_send(peer, response, method.to_upper() == "HEAD")
		_peers.erase(peer)


static func build_response(method: String, raw_target: String, root: String, entry: String, version: int = 1) -> Dictionary:
	var verb := method.strip_edges().to_upper()
	if verb != "GET" and verb != "HEAD":
		return _error_response(405, "Only GET and HEAD are supported.")

	var target := raw_target
	var query := target.find("?")
	if query >= 0:
		target = target.substr(0, query)
	var hash := target.find("#")
	if hash >= 0:
		target = target.substr(0, hash)
	target = target.uri_decode()
	if target.is_empty():
		target = "/"
	if !target.begins_with("/"):
		target = "/" + target

	if target == VERSION_PATH:
		return _text_response(200, "application/json; charset=utf-8", JSON.stringify({
			"version": version,
			"entry": _relative_to_root(entry, root),
		}))

	var normalized_root := Paths.normalize(root)
	if normalized_root.is_empty() or !DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(normalized_root)):
		return _error_response(404, "The preview folder is not available.")

	var relative := target.trim_prefix("/")
	if relative.is_empty():
		relative = _relative_to_root(entry, normalized_root)
		if relative.is_empty():
			relative = "index.html"

	var full := Paths.normalize(normalized_root.path_join(relative))
	if !Paths.is_subpath(normalized_root, full):
		return _error_response(403, "That path is outside the preview folder.")
	if !FileAccess.file_exists(full):
		if DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(full)):
			var index_file := full.path_join("index.html")
			if FileAccess.file_exists(index_file):
				full = index_file
			else:
				return _directory_response(normalized_root, full, relative)
		else:
			return _error_response(404, "Not found: " + relative)

	var extension := Paths.extension(full).to_lower()
	var content_type := str(MIME_TYPES.get(extension, "application/octet-stream"))

	if extension == "md" or extension == "markdown":
		var markdown_text := FileAccess.get_file_as_string(full)
		var title := Paths.normalize(full).get_file()
		var html := Markdown.render_document(markdown_text, title, "", LIVE_RELOAD_SCRIPT)
		return _text_response(200, content_type, html)

	var bytes := FileAccess.get_file_as_bytes(full)
	if extension == "html" or extension == "htm":
		var html_text := bytes.get_string_from_utf8()
		html_text = Markdown.inject_live_reload(html_text, LIVE_RELOAD_SCRIPT)
		return _text_response(200, content_type, html_text)

	return {
		"status": 200,
		"reason": "OK",
		"content_type": content_type,
		"body": bytes,
		"error": "",
	}


func _send(peer: StreamPeerTCP, response: Dictionary, head_only: bool) -> void:
	var status := int(response.get("status", 500))
	var reason := str(response.get("reason", "Internal Server Error"))
	var content_type := str(response.get("content_type", "text/html; charset=utf-8"))
	var body: PackedByteArray = response.get("body", PackedByteArray())
	var length := body.size()

	var header := "HTTP/1.1 %d %s\r\n" % [status, reason]
	header += "Content-Type: %s\r\n" % content_type
	header += "Content-Length: %d\r\n" % length
	header += "Cache-Control: no-store\r\n"
	header += "Connection: close\r\n"
	header += "X-Content-Type-Options: nosniff\r\n"
	header += "\r\n"

	peer.put_data(header.to_utf8_buffer())
	if !head_only and length > 0:
		peer.put_data(body)
	peer.disconnect_from_host()


static func _text_response(status: int, content_type: String, text: String) -> Dictionary:
	return {
		"status": status,
		"reason": _reason(status),
		"content_type": content_type,
		"body": text.to_utf8_buffer(),
		"error": "",
	}


static func _error_response(status: int, message: String) -> Dictionary:
	var html := "<!doctype html><html><head><meta charset=\"utf-8\"><title>%d</title>" % status
	html += "<style>body{font:16px system-ui;background:#14171c;color:#d7dce2;padding:48px}code{color:#f0c674}</style>"
	html += "</head><body><h1>%d</h1><p>%s</p></body></html>" % [status, Markdown.escape_html(message)]
	return _text_response(status, "text/html; charset=utf-8", html)


static func _directory_response(root: String, directory: String, relative: String) -> Dictionary:
	var dir := DirAccess.open(ProjectSettings.globalize_path(directory))
	if dir == null:
		return _error_response(404, "That folder cannot be read.")

	var title := relative if !relative.is_empty() else "/"
	var html := "<!doctype html><html><head><meta charset=\"utf-8\"><title>%s</title>" % Markdown.escape_html(title)
	html += "<style>body{font:16px system-ui;background:#14171c;color:#d7dce2;padding:48px}a{color:#8bd5ff}"
	html += "li{margin:6px 0}code{color:#7f848e}</style></head><body><h1>%s</h1><ul>" % Markdown.escape_html(title)

	if !relative.is_empty():
		html += "<li><a href=\"/\">..</a></li>"
	for folder in dir.get_directories():
		var child := relative.path_join(str(folder)).trim_prefix("/")
		html += "<li>📁 <a href=\"/%s\">%s</a></li>" % [_url_path(child), Markdown.escape_html(str(folder))]
	for file_name in dir.get_files():
		var child := relative.path_join(str(file_name)).trim_prefix("/")
		html += "<li>📄 <a href=\"/%s\">%s</a></li>" % [_url_path(child), Markdown.escape_html(str(file_name))]
	html += "</ul></body></html>"
	return _text_response(200, "text/html; charset=utf-8", html)


static func _relative_to_root(path: String, root: String) -> String:
	var normalized_root := Paths.normalize(root)
	var normalized_path := Paths.normalize(path)
	if normalized_root.is_empty() or normalized_path.is_empty():
		return ""
	if !Paths.is_subpath(normalized_root, normalized_path):
		return ""
	if normalized_root == normalized_path:
		return ""
	return normalized_path.substr(normalized_root.length()).trim_prefix("/")


static func _url_path(path: String) -> String:
	return path.replace("\\", "/").uri_encode()


static func _find_header_end(buffer: PackedByteArray) -> int:
	var text := buffer.get_string_from_utf8()
	var index := text.find("\r\n\r\n")
	if index >= 0:
		return index + 2
	index = text.find("\n\n")
	return index + 1 if index >= 0 else -1


static func _reason(status: int) -> String:
	match status:
		200: return "OK"
		403: return "Forbidden"
		404: return "Not Found"
		405: return "Method Not Allowed"
		431: return "Request Header Fields Too Large"
		_: return "Internal Server Error"
