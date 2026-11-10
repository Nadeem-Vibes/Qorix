extends Node

const ES_SOCIAL_FEEDIA___HEYSON = preload("res://resources/music/ES_Social Feedia - Heyson.wav")

# Resolved in _ready() with null guards: autoload _ready runs before the main
# scene exists (and the headless test runner has no Editor scene at all).
var audio_stream_player: AudioStreamPlayer = null
var timer: Timer = null
var audio_spectrum_analyzer_instance: AudioEffectSpectrumAnalyzerInstance = null
var cam: Camera = null

var music_move_intensity: float = 1;

var enabled: bool = false;
## Static camera / reduced motion switch the beat pulse off without disabling
## the music itself.
var pulse_enabled: bool = true;

# Settings are applied before the deferred _setup() resolves the player, so
# remember the requested volume and apply it once the node exists.
var _volume_db: float = 0.0;

var SONGS = [ES_SOCIAL_FEEDIA___HEYSON];

func _ready():
	# Deferred so the main scene exists even if autoloads are instanced first.
	call_deferred("_setup")

func _setup() -> void:
	audio_stream_player = get_node_or_null("/root/Editor/AudioStreamPlayer")
	timer = get_node_or_null("/root/Editor/AudioTimer")
	cam = get_node_or_null("/root/Editor/Misc/Cam")
	audio_spectrum_analyzer_instance = AudioServer.get_bus_effect_instance(0, 0)

	if audio_stream_player == null or timer == null or cam == null:
		return

	audio_stream_player.volume_db = _volume_db
	audio_stream_player.finished.connect(play_random_song)
	timer.timeout.connect(play_effects)

	# apply_all_settings() may already have enabled music before this runs.
	play_random_song()

func play_random_song() -> void:
	if !enabled or audio_stream_player == null or timer == null: return
	timer.stop()

	var song = SONGS.pick_random()

	audio_stream_player.stream = song
	audio_stream_player.play()
	timer.start()

func find_volume():
	if audio_spectrum_analyzer_instance == null: return 0.0
	var volume = audio_spectrum_analyzer_instance.get_magnitude_for_frequency_range(0.0, 20000, AudioEffectSpectrumAnalyzerInstance.MAGNITUDE_MAX).length()
	return volume

func play_effects() -> void:
	if !enabled:
		if timer != null: timer.stop()
		return
	if cam == null or timer == null or !pulse_enabled: return

	var res = find_volume()

	cam.focus_temp(res * music_move_intensity * 10)

func set_pulse_enabled(value: bool) -> void:
	pulse_enabled = value

func set_volume(value: float) -> void:
	var clampedVolume = clamp(value, 0, 100)
	var decibels = lerp(-100, -30, 1 - (1 - clampedVolume / 100.0) ** 2)
	_volume_db = decibels

	if audio_stream_player == null: return

	audio_stream_player.volume_db = decibels

func set_enabled(value: bool) -> void:
	enabled = value;

	if audio_stream_player == null: return

	if !value:
		audio_stream_player.stop()
	else:
		play_random_song()
