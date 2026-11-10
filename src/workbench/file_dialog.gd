class_name FileDialogType

extends RichTextLabel

const Paths = preload("res://src/base/path_utils.gd")

@onready var editor: FileManager = $".."

var selected_index: int = 0
var dir: DirAccess
var dirs: Array[String]
var bbcode_dirs: Array[String]
var shortened_dirs: Array[String]
var files: Array[String]

var query: String = ""
var search_limit: int = 1000
var current_dirs_count: int = 0
var handled: bool
var erased: bool
var max_coincidence: Array = []
var coincidence: Array = []

var zoom: Vector2;

var active: bool = false;
signal ui_close

func change_dir(path) -> void:
	query = ""
	# `dir` is reused across calls, so `path` only applies to the first open.
	# A failed open used to fall through to a null method call below.
	if dir == null:
		dir = DirAccess.open(path)
		if dir == null:
			if editor != null and editor.has_method("warn"):
				editor.warn("[color=yellow]WARNING[/color]: Could not open " + str(path) + ". Check the path and your permissions.")
			return
	#dir.include_hidden = true
	# WARNING: this will heavily affect performance if de-commented

	var current_path := Paths.normalize(dir.get_current_dir())
	var current_drive := _drive_root(current_path)
	var at_drive_root := !current_drive.is_empty() and current_path.to_lower() == current_drive.to_lower()

	dirs = [".."];
	dirs.append_array(dir.get_directories())
	dirs.append_array(dir.get_files())

	# Other drives are shortcuts from a drive root only. Showing every drive
	# inside every folder turns the list into noise; ".." still walks up to the
	# root where the shortcuts live.
	if at_drive_root:
		for drive in editor.get_drives():
			if drive.to_lower() == current_drive.to_lower():
				continue
			if dirs.find(drive) == -1:
				dirs.insert(1, drive)

	shortened_dirs = []
	for dir_ in dirs:
		if len(dir_) > 30:
			dir_ = dir_.left(30) + "..." + dir_.right(3)
		shortened_dirs.append(dir_)

	bbcode_dirs = []
	bbcode_dirs.append_array(dirs)

	current_dirs_count = len(dirs)

	files = []
	files.append_array(dir.get_files())

	var view = editor.active_view
	var longest: String = view.get_longest_line(dirs) if view != null else _longest_line(dirs)
	zoom = %Cam.to_zoom(longest.length())

	if active:
		%Cam.focus_on(gp(), zoom)

## "C:/" for a Windows drive path, "/" for the Unix root, "" otherwise.
func _drive_root(path: String) -> String:
	if path.length() >= 2 and path[1] == ":":
		return path.substr(0, 2) + "/"
	return "/" if path == "/" else ""


## Jumps to an absolute directory and redraws the listing. Used by setup and
## when a workspace is opened, so the picker follows the active workspace.
func go_to(path: String) -> void:
	if path.is_empty():
		return
	var next := DirAccess.open(path)
	if next == null:
		return
	dir = next
	change_dir(path)
	update_ui()


func setup() -> void:
	active = false
	var start := editor.current_dir
	if editor.workspace != null and editor.workspace.has_workspace():
		start = editor.workspace.root
	go_to(start)

func _input(event: InputEvent) -> void:
	if !active: return
	if !(event is InputEventKey): return

	var key_event = event as InputEventKey
	bbcode_dirs = []
	bbcode_dirs.append_array(dirs)

	if !(key_event.is_pressed()): return;
	# Holding Enter would otherwise re-open the file / re-descend the folder
	# on every OS key repeat.
	if key_event.echo and key_event.keycode == KEY_ENTER: return;

	handled = true
	if key_event.keycode == KEY_UP:
		selected_index = max(0, selected_index - 1)
	elif key_event.keycode == KEY_DOWN:
		selected_index = min(len(dirs) - 1, selected_index + 1)
	elif key_event.keycode == KEY_ENTER:
		handle_enter_key()
	else:
		handled = false

	erased = false
	if current_dirs_count <= search_limit and !handled:
		if key_event.keycode == KEY_BACKSPACE:
			erased = true
			if len(query) > 0:
				query = query.substr(0, len(query) - 1)
		elif key_event.as_text() == 'Ctrl+Backspace':
			erased = true
			query = ""
		if len(key_event.as_text()) == 1:
			query += key_event.as_text().to_lower()
		elif key_event.keycode == KEY_PERIOD:
			query += "."

	max_coincidence = []

	if len(query) > 0:
		for i in range(1, len(dirs)):
			coincidence = fuzzy_search(shortened_dirs[i].to_lower(), query)
			bbcode_dirs[i] = make_bold(shortened_dirs[i], coincidence)
			if is_closer(max_coincidence, coincidence):
				max_coincidence = coincidence
				if not handled:	selected_index = i

	update_ui()

func update_ui() -> void:
	clear()
	show_items()

func show_items() -> void:
	for i in range(len(bbcode_dirs)):
		show_item(i)

func show_item(index: int) -> void:
	var item = dirs[index]
	var bbcode_item = bbcode_dirs[index]
	if is_selected(item):
		push_bgcolor(LuaSingleton.gui.selection_color)
	else:
		push_bgcolor(Color(0, 0, 0, 0))  # Reset background color if not selected

	var is_dir = dir.get_directories().find(item) != -1 or editor.get_drives().find(item) != -1

	if item == "..":
		push_color(LuaSingleton.gui.font_color)
		add_text("󰕌")
	elif is_dir:
		push_color(LuaSingleton.gui.completion_selected_color)
		add_text("")
	else:
		var extension = item.split(".")[-1]
		var data = Icons.get_icon_data(extension)

		push_color(Color.from_string(data.color, data.color))
		add_text(data.icon)

	pop()

	# The BBCode for a match already contains the full name (bold tags land
	# mid-string), so append it verbatim — splitting on '.' used to drop
	# everything past the second dot ("foo.bar.baz" rendered as "foo.bar").
	append_text(" %s\n" % [bbcode_item])

	if active: %Cam.focus_on(Vector2(gp().x, global_position.y + (selected_index * 23)), zoom)

# i gave up at that point, sorry for what you're about to witness
func is_selected(item: String) -> bool:
	var dir_item = dirs.find(item);

	var is_dir_item = dir_item != -1;
	var is_dir_current = dir_item == selected_index;

	return (is_dir_item and is_dir_current)

func handle_enter_key() -> void:
	if selected_index >= len(dirs): return
	# ^^ this happens when the cursor was at, i.e., pos. 6, but arr is only has 4 entries

	var item = dirs[selected_index];

	var is_file = files.find(item) != -1;

	if is_file:
		editor.current_dir = dir.get_current_dir();
		editor.open_file(editor.current_dir + "/" + item)
		# ^^ open_file handles the extension setup + highlighting now

		get_tree().create_timer(.1).timeout.connect(func():
			editor.editor_host.grab_active_focus()
		)

		ui_close.emit()
	else:
		selected_index = 0;
		dir.change_dir(item)
		change_dir(item)
	update_ui()

func make_bold(string: String, indexes: Array) -> String:
	var new_string: String = ""

	for i in range(len(string)):
		if i in indexes: new_string += "[i][color=yellow]" + string[i] + "[/color][/i]"
		else: new_string += string[i]

	return new_string

func fuzzy_search(string: String, substring: String) -> Array:
	var indexes: Array = []
	var attempts: Array = []
	var pos: int = 0
	var i: int = 0

	while i < string.length():
		if pos < substring.length() and string[i] == substring[pos]:
			indexes.append(i)
			attempts.append(i)
			pos += 1

			if pos == substring.length():
				return indexes
		i += 1

		if i >= string.length() and pos > 0:
			# dead end: undo the last matched character and retry just after it
			if attempts.is_empty():
				return []
			i = attempts.pop_back() + 1
			indexes = []
			pos = 0

	return indexes

# Compares 2 fuzzy Arrays and returns if 'new' Array is closer to query than 'old'
func is_closer(old: Array, new: Array) -> bool:
	if len(old) == 0: return true
	if len(new) == 0: return false

	if old == new: return false

	for i in range(mini(len(old), len(new))):
		if old[i] > new[i]: return true
		elif old[i] < new[i]: return false

	# identical up to the shorter length: the earlier match wins
	return len(new) < len(old)

func _longest_line(lines: Array) -> String:
	var longest := ""
	for line in lines:
		var str_line := str(line)
		if str_line.length() > longest.length():
			longest = str_line
	return longest

# global_position is slightly off, so we customize it a little.
func gp() -> Vector2:
	var vec = global_position;

	vec.x += 100;

	return vec;
