extends RefCounted

## Offline language detection inspired by GuessLang (https://github.com/yoeo/guesslang).
##
## GuessLang trains a model over character n-grams; shipping a TensorFlow model
## would add hundreds of megabytes to an editor. This is the same idea at a
## smaller scale: every language profile carries a few idiomatic samples. At
## load time each sample becomes a TF-IDF character n-gram vector, then a new
## buffer is scored with cosine similarity. Distinctive syntax (a shebang,
## `<?php`, `package main`) contributes weighted marker evidence on top, and
## extension hints break ties. The result is fully offline, deterministic and
## inspectable, which matters more than beating a large model on 50 languages.
##
## Only plain text/unknown files are auto-detected. A wrong auto-guess must
## never change how a real .py file is highlighted, so RunService still trusts
## the extension first; detection is a safety net, not a replacement.

const Paths = preload("res://src/base/path_utils.gd")

const DEFAULT_PROFILE_PATH := "res://src/features/run/language_profiles.json"

const DEFAULT_SETTINGS := {
	"min_chars": 24,
	"ngram_size": 3,
	"auto_confidence": 0.45,
	"auto_margin": 0.06,
	"max_chars": 16000,
}

# A profile's score is a weighted blend. N-grams carry the most weight because
# they generalise to unseen code; markers are reliable but easy to type by
# accident, and the extension is only a tie-breaker because detection is meant
# for files whose extension is unhelpful in the first place.
const NGRAM_WEIGHT := 0.58
const MARKER_WEIGHT := 0.36
const EXTENSION_WEIGHT := 0.06
const FALLBACK_PENALTY := 0.10

var profile_path: String = DEFAULT_PROFILE_PATH
var settings: Dictionary = DEFAULT_SETTINGS.duplicate(true)
var profiles: Array = []
var errors: Array = []
var loaded: bool = false

var _by_id: Dictionary = {}
var _idf: Dictionary = {}


func _init(p_profile_path: String = "") -> void:
	if !p_profile_path.is_empty():
		profile_path = p_profile_path


# ── PUBLIC API ──────────────────────────────────────────────────────────────

func available() -> bool:
	if !loaded:
		load_profiles()
	return !profiles.is_empty()


## Loads (and re-loads) the profile file. Safe to call repeatedly. Returns a
## summary instead of failing, so a broken profile can never stop the editor.
func load_profiles(path: String = "") -> Dictionary:
	if !path.is_empty():
		profile_path = path

	profiles.clear()
	_by_id.clear()
	_idf.clear()
	errors.clear()
	loaded = false

	var text := FileAccess.get_file_as_string(profile_path)
	if text.strip_edges().is_empty():
		errors.append("Could not read language profiles: %s" % profile_path)
		return _summary()

	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		errors.append("%s is not a valid JSON object." % profile_path.get_file())
		return _summary()

	_read_settings(parsed.get("settings", {}))

	var raw_profiles: Variant = parsed.get("profiles", [])
	if !(raw_profiles is Array):
		errors.append("%s has no profiles array." % profile_path.get_file())
		return _summary()

	var document_frequency: Dictionary = {}
	for raw in raw_profiles:
		if !(raw is Dictionary):
			continue
		var profile := _build_profile(raw)
		if profile.is_empty():
			continue

		profiles.append(profile)
		_by_id[str(profile["id"])] = profile
		var counts: Dictionary = profile.get("_counts", {})
		for gram in counts.keys():
			document_frequency[gram] = int(document_frequency.get(gram, 0)) + 1

	if profiles.is_empty():
		errors.append("%s contains no usable language profiles." % profile_path.get_file())
		return _summary()

	# TF-IDF over profiles rather than documents: a trigram that appears in
	# every language (indentation, `();`, ` = `) should not sway the vote.
	var total := float(profiles.size())
	for profile in profiles:
		var counts: Dictionary = profile.get("_counts", {})
		var weighted: Dictionary = {}
		for gram in counts.keys():
			var frequency := float(counts[gram])
			var inverse := log((total + 1.0) / (float(document_frequency.get(gram, 1)) + 1.0)) + 1.0
			weighted[gram] = (1.0 + log(frequency)) * inverse
		profile["vector"] = _normalized(weighted)
		profile.erase("_counts")

	for gram in document_frequency.keys():
		_idf[gram] = log((total + 1.0) / (float(document_frequency[gram]) + 1.0)) + 1.0

	loaded = true
	return _summary()


## Classifies text. The returned Dictionary is safe to render:
## {ok, language, display, highlight, run_language, confidence, margin, auto,
##  reason, alternatives, evidence, method}.
func detect(text: String, file_path: String = "") -> Dictionary:
	if !loaded:
		load_profiles()

	var clipped := _clip(text)
	var missing := _empty_result("too-short")
	if clipped.strip_edges().length() < min_chars():
		missing["message"] = "This file is too short to identify reliably. Add a few lines and try again."
		return missing

	if profiles.is_empty():
		var broken := _empty_result("unavailable")
		broken["message"] = "Language profiles are unavailable."
		return broken

	var input_vector := _vector_for(clipped)
	if input_vector.is_empty():
		var empty := _empty_result("too-short")
		empty["message"] = "There is not enough distinctive text to identify a language."
		return empty

	var extension := Paths.extension(Paths.normalize(file_path)).to_lower()
	var results: Array = []

	for profile in profiles:
		var cosine := _cosine(input_vector, profile.get("vector", {}))
		var markers := _marker_evidence(profile, clipped)
		var extension_hint := 1.0 if _list_has(profile.get("extensions", []), extension) else 0.0
		var score := NGRAM_WEIGHT * cosine + MARKER_WEIGHT * float(markers["score"]) + EXTENSION_WEIGHT * extension_hint
		if bool(profile.get("fallback", false)):
			score -= FALLBACK_PENALTY

		results.append({
			"language": str(profile["id"]),
			"display": str(profile["display"]),
			"highlight": str(profile["highlight"]),
			"run_language": str(profile["run_language"]),
			"auto_allowed": bool(profile.get("auto", false)),
			"fallback": bool(profile.get("fallback", false)),
			"score": score,
			"cosine": cosine,
			"markers": markers["score"],
			"shebang": markers["shebang"],
			"evidence": markers["labels"],
		})

	results.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a.get("score", 0.0)) > float(b.get("score", 0.0))
	)

	var top: Dictionary = results[0]
	var top_score := float(top.get("score", 0.0))
	var second_score := float(results[1].get("score", 0.0)) if results.size() > 1 else 0.0
	var margin := top_score - second_score

	# Convert the raw scores into a softmax over close candidates. The
	# temperature keeps a one-horse race confident and a tie near 50% instead
	# of pretending either answer is certain. The quality term suppresses
	# confidence when every profile matched poorly (for example prose).
	#
	# The geometric mean of the two terms is deliberately gentler than their
	# product: a clear winner in a short file (a 10-line Python script, say)
	# still has a low absolute score, and multiplying by quality buried it
	# below every sensible auto-detect threshold. Both terms must be healthy
	# for a high confidence, which is what keeps prose and ambiguous two-line
	# snippets from being auto-detected.
	var denominator := 0.0
	for entry in results:
		var delta := (float(entry.get("score", 0.0)) - top_score) / 0.085
		if delta < -8.0:
			continue
		denominator += exp(delta)
	var probability := 1.0 / denominator if denominator > 0.0 else 0.0
	var quality: float = clampf((top_score - 0.16) / 0.34, 0.0, 1.0)
	var confidence: float = _confidence(probability, quality)

	# A shebang names the interpreter explicitly, which is stronger evidence
	# than any n-gram. Extensionless scripts are usually two or three lines, so
	# the quality term would otherwise keep them below the auto-detect bar.
	if bool(top.get("shebang", false)):
		confidence = maxf(confidence, 0.9)

	var alternatives: Array = []
	for index in range(1, mini(results.size(), 4)):
		var entry: Dictionary = results[index]
		var delta := (float(entry.get("score", 0.0)) - top_score) / 0.085
		if delta < -8.0:
			continue
		alternatives.append({
			"language": str(entry.get("language", "")),
			"display": str(entry.get("display", "")),
			"confidence": _confidence(exp(delta) / denominator, quality),
		})

	var language := str(top.get("language", "text"))
	var auto: bool = bool(top.get("auto_allowed", false)) \
		and !bool(top.get("fallback", false)) \
		and confidence >= auto_confidence() \
		and margin >= float(settings.get("auto_margin", 0.06))

	return {
		"ok": true,
		"language": language,
		"display": str(top.get("display", language)),
		"highlight": str(top.get("highlight", "txt")),
		"run_language": str(top.get("run_language", language)),
		"confidence": confidence,
		"margin": margin,
		"score": top_score,
		"auto": auto,
		"reason": _reason(str(top.get("display", language)), confidence),
		"alternatives": alternatives,
		"evidence": top.get("evidence", []),
		"method": "ngram+markers",
	}


func profile_for(language: String) -> Dictionary:
	if !loaded:
		load_profiles()
	var key := _clean_id(language)
	if key.is_empty():
		return {}
	if _by_id.has(key):
		return _by_id[key]
	for profile in profiles:
		if _list_has(profile.get("extensions", []), key):
			return profile
	return {}


## Extensions accepted for a language, canonical first. Save As uses this to
## suggest "Untitled.py" and a matching file-type filter instead of "*.*".
func extensions_for(language: String) -> Array:
	var profile := profile_for(language)
	var out: Array = []
	for extension in profile.get("extensions", []):
		var clean := str(extension).strip_edges().trim_prefix(".")
		if !clean.is_empty() and !out.has(clean):
			out.append(clean)
	return out


func preferred_extension(language: String) -> String:
	var extensions := extensions_for(language)
	return str(extensions[0]) if !extensions.is_empty() else ""


func highlight_for(language: String) -> String:
	var profile := profile_for(language)
	if profile.is_empty():
		return "txt"
	return str(profile.get("highlight", "txt"))


func run_language_for(language: String) -> String:
	var profile := profile_for(language)
	if profile.is_empty():
		return _clean_id(language)
	return str(profile.get("run_language", profile.get("id", "")))


func min_chars() -> int:
	return maxi(8, int(settings.get("min_chars", 24)))


func auto_confidence() -> float:
	return clampf(float(settings.get("auto_confidence", 0.62)), 0.0, 0.99)


func profile_count() -> int:
	return profiles.size()


# ── PROFILE LOADING ─────────────────────────────────────────────────────────

func _read_settings(raw: Variant) -> void:
	settings = DEFAULT_SETTINGS.duplicate(true)
	if !(raw is Dictionary):
		return
	for key in DEFAULT_SETTINGS.keys():
		if raw.has(key):
			settings[key] = raw[key]


func _build_profile(raw: Dictionary) -> Dictionary:
	var id := _clean_id(raw.get("id", ""))
	if id.is_empty():
		errors.append("A language profile has no id.")
		return {}

	var profile := {
		"id": id,
		"display": str(raw.get("display", id.capitalize())),
		"extensions": _clean_list(raw.get("extensions", [])),
		"run_language": _clean_id(raw.get("run_language", id)),
		"highlight": _clean_id(raw.get("highlight", "txt")),
		"auto": bool(raw.get("auto", false)),
		"fallback": bool(raw.get("fallback", false)),
		"markers": [],
		"_counts": {},
	}

	var raw_markers: Variant = raw.get("markers", [])
	if raw_markers is Array:
		for entry in raw_markers:
			if !(entry is Array) or entry.size() < 2:
				continue
			var pattern := "(?m)" + str(entry[0])
			var regex := RegEx.new()
			if regex.compile(pattern) != OK:
				errors.append("%s: marker pattern \"%s\" is invalid." % [id, str(entry[0])])
				continue
			profile["markers"].append({
				"regex": regex,
				"weight": maxf(0.0, float(entry[1])),
				"label": str(entry[2]) if entry.size() > 2 else str(entry[0]),
				# A `#!` line names its interpreter outright. Track it so a
				# two-line script can be trusted without a long n-gram sample.
				"shebang": str(entry[0]).begins_with("^#!"),
			})

	var raw_samples: Variant = raw.get("samples", [])
	if raw_samples is Array:
		for sample in raw_samples:
			_accumulate(profile["_counts"], str(sample))

	return profile


func _summary() -> Dictionary:
	return {
		"ok": errors.is_empty() && !profiles.is_empty(),
		"profiles": profiles.size(),
		"errors": errors.duplicate(),
	}


func _empty_result(reason: String) -> Dictionary:
	return {
		"ok": false,
		"language": "",
		"display": "",
		"highlight": "",
		"run_language": "",
		"confidence": 0.0,
		"margin": 0.0,
		"score": 0.0,
		"auto": false,
		"reason": "",
		"message": "",
		"alternatives": [],
		"evidence": [],
		"method": "ngram+markers",
		"error": reason,
	}


func _reason(display: String, confidence: float) -> String:
	return "%s (%d%% confidence)" % [display, int(round(confidence * 100.0))]


## Combines "how far ahead is the winner" with "how well did anything match"
## without letting either term erase an otherwise usable answer.
static func _confidence(probability: float, quality: float) -> float:
	return clampf(sqrt(maxf(0.0, probability) * maxf(0.0, quality)), 0.0, 0.99)


# ── FEATURES ────────────────────────────────────────────────────────────────

func _vector_for(text: String) -> Dictionary:
	var counts: Dictionary = {}
	_accumulate(counts, text)
	var weighted: Dictionary = {}
	for gram in counts.keys():
		if !_idf.has(gram):
			continue
		weighted[gram] = (1.0 + log(float(counts[gram]))) * float(_idf[gram])
	return _normalized(weighted)


func _accumulate(counts: Dictionary, text: String) -> void:
	var normalized := _normalize(text)
	var size := maxi(1, int(settings.get("ngram_size", 3)))
	if normalized.length() < size:
		return
	for i in range(normalized.length() - size + 1):
		var gram := normalized.substr(i, size)
		counts[gram] = int(counts.get(gram, 0)) + 1


func _marker_evidence(profile: Dictionary, text: String) -> Dictionary:
	var total := 0.0
	var labels: Array = []
	var shebang := false
	for marker in profile.get("markers", []):
		var regex: RegEx = marker.get("regex")
		if regex == null:
			continue
		var matches := regex.search_all(text)
		if matches.is_empty():
			continue
		# Repetition is weak evidence: ten `def` lines are not ten times more
		# Python than one, so growth is logarithmic and capped.
		var count := mini(matches.size(), 8)
		total += float(marker.get("weight", 1.0)) * (1.0 + log(float(count)) / 2.0)
		var label := str(marker.get("label", ""))
		if !label.is_empty() and labels.size() < 4 and !labels.has(label):
			labels.append(label)
		if bool(marker.get("shebang", false)) and matches[0].get_start() == 0:
			shebang = true

	return {
		"score": 1.0 - exp(-total / 7.0),
		"weight": total,
		"labels": labels,
		"shebang": shebang,
	}


func _clip(text: String) -> String:
	var limit := maxi(1000, int(settings.get("max_chars", 16000)))
	if text.length() <= limit:
		return text
	var head := int(float(limit) * 0.75)
	var tail := limit - head
	return text.substr(0, head) + "\n" + text.substr(text.length() - tail)


# ── SMALL HELPERS ───────────────────────────────────────────────────────────

static func _normalize(text: String) -> String:
	return text.replace("\r\n", "\n").replace("\r", "\n").replace("\t", "    ")


static func _normalized(vector: Dictionary) -> Dictionary:
	var length := 0.0
	for value in vector.values():
		length += float(value) * float(value)
	length = sqrt(length)
	if length <= 0.0:
		return {}

	var out: Dictionary = {}
	for key in vector.keys():
		out[key] = float(vector[key]) / length
	return out


static func _cosine(a: Dictionary, b: Dictionary) -> float:
	if a.is_empty() or b.is_empty():
		return 0.0
	var smaller: Dictionary = a
	var larger: Dictionary = b
	if a.size() > b.size():
		smaller = b
		larger = a
	var dot := 0.0
	for key in smaller.keys():
		if larger.has(key):
			dot += float(smaller[key]) * float(larger[key])
	return clampf(dot, 0.0, 1.0)


static func _clean_id(value: Variant) -> String:
	var text := str(value).strip_edges().to_lower().trim_prefix(".")
	var out := ""
	for i in range(text.length()):
		var character := text[i]
		if "abcdefghijklmnopqrstuvwxyz0123456789_+#-".contains(character):
			out += character
	return out


static func _clean_list(value: Variant) -> Array:
	var out: Array = []
	if value is String:
		value = [value]
	if !(value is Array):
		return out
	for item in value:
		var cleaned := _clean_id(item)
		if !cleaned.is_empty() and !out.has(cleaned):
			out.append(cleaned)
	return out


static func _list_has(list: Variant, value: String) -> bool:
	if value.is_empty() or !(list is Array):
		return false
	for item in list:
		if _clean_id(item) == value:
			return true
	return false
