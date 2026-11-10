shader_type canvas_item;
render_mode blend_mix, unshaded;

// ─────────────────────────────────────────────────────────────────────────────
//  Cursor trail.
//
//  A port of the cursor shaders by sahaj-b (MIT):
//  https://github.com/sahaj-b/cursor-shaders
//  The originals are kept in ThirdParty/cursor-shaders, next to their
//  licence; see the README there for what the port changed.
//
//  The originals are written for Ghostty and Kitty: the terminal hands the
//  shader its whole framebuffer and the shader paints the trail over it.
//  Here the trail is drawn over the code instead, so the shader only ever
//  receives the two caret rectangles and paints the smear between them.
//
//  Three effects are ported:
//    1 = warp  — the Neovide-like smear. Every corner of the caret gets its
//                own easing, so the shape stretches towards the new position
//                and snaps back.
//    2 = sweep — the trail starts at the old caret and shrinks onto the new
//                one.
//    3 = tail  — a comet: the head follows the caret, the tail lags behind.
//
//  All of them are drawn in the quad's own pixels. The driver (Scripts/
//  editor/cursor_effect.gd) positions the quad over the two carets and keeps
//  the rectangles relative to it.
// ─────────────────────────────────────────────────────────────────────────────

uniform int effect : hint_range(0, 3) = 1;
// The caret rectangles, in quad pixels: (x, y, width, height), y = top edge.
uniform vec4 current_cursor = vec4(0.0);
uniform vec4 previous_cursor = vec4(0.0);
// Seconds since the caret last moved, and the length of the animation.
uniform float elapsed = 0.0;
uniform float duration = 0.2;
uniform vec4 trail_color : source_color = vec4(0.4, 0.8, 1.0, 0.55);
uniform float glow_strength = 0.0;
// Width of the soft edge, in quad pixels.
uniform float antialias_size = 1.0;

// warp
uniform float trail_size = 0.8;
uniform float trail_thickness = 1.0;
uniform float trail_thickness_x = 0.9;
uniform float fade_enabled = 0.0;
uniform float fade_exponent = 5.0;

// sweep
uniform float trail_length = 0.5;

// tail
uniform float max_trail_length = 200.0;
uniform float tail_delay = 0.35;

// ── Easing ──────────────────────────────────────────────────────────────────

float ease_out_circ(float x) {
	return sqrt(1.0 - pow(x - 1.0, 2.0));
}

float ease_out_cubic(float x) {
	return 1.0 - pow(1.0 - x, 3.0);
}

// ── Distance fields ─────────────────────────────────────────────────────────

float sdf_rectangle(vec2 p, vec2 center, vec2 half_size) {
	vec2 d = abs(p - center) - half_size;
	return length(max(d, vec2(0.0))) + min(max(d.x, d.y), 0.0);
}

// Distance to a segment. Returns the running minimum distance and the
// winding of the shape, which the caller has to carry along.
// Based on Inigo Quilez's 2D distance functions.
vec2 seg(vec2 p, vec2 a, vec2 b, float s, float d) {
	vec2 e = b - a;
	vec2 w = p - a;
	vec2 proj = a + e * clamp(dot(w, e) / max(dot(e, e), 0.000001), 0.0, 1.0);
	float segd = dot(p - proj, p - proj);
	d = min(d, segd);

	float c0 = step(0.0, p.y - a.y);
	float c1 = 1.0 - step(0.0, p.y - b.y);
	float c2 = 1.0 - step(0.0, e.x * w.y - e.y * w.x);
	float all_cond = c0 * c1 * c2;
	float none_cond = (1.0 - c0) * (1.0 - c1) * (1.0 - c2);
	float flip = mix(1.0, -1.0, step(0.5, all_cond + none_cond));
	s *= flip;
	return vec2(d, s);
}

float sdf_convex_quad(vec2 p, vec2 v1, vec2 v2, vec2 v3, vec2 v4) {
	float s = 1.0;
	float d = dot(p - v1, p - v1);

	vec2 r = seg(p, v1, v2, s, d);
	d = r.x;
	s = r.y;
	r = seg(p, v2, v3, s, d);
	d = r.x;
	s = r.y;
	r = seg(p, v3, v4, s, d);
	d = r.x;
	s = r.y;
	r = seg(p, v4, v1, s, d);
	d = r.x;
	s = r.y;

	return s * sqrt(d);
}

float sdf_parallelogram(vec2 p, vec2 v0, vec2 v1, vec2 v2, vec2 v3) {
	float s = 1.0;
	float d = dot(p - v0, p - v0);

	vec2 r = seg(p, v0, v3, s, d);
	d = r.x;
	s = r.y;
	r = seg(p, v1, v0, s, d);
	d = r.x;
	s = r.y;
	r = seg(p, v2, v1, s, d);
	d = r.x;
	s = r.y;
	r = seg(p, v3, v2, s, d);
	d = r.x;
	s = r.y;

	return s * sqrt(d);
}

// 1 inside the shape, 0 outside, with a soft edge of `edge` pixels.
float shape_mask(float sdf, float edge) {
	return 1.0 - smoothstep(0.0, max(edge, 0.0001), sdf);
}

// Which of the two top corners leads the movement: 1 when the top right one
// does, 0 when the top left one does.
float top_right_leads(vec2 current_corner, vec2 previous_corner) {
	float condition1 = step(previous_corner.x, current_corner.x) * step(current_corner.y, previous_corner.y);
	float condition2 = step(current_corner.x, previous_corner.x) * step(previous_corner.y, current_corner.y);
	return 1.0 - max(condition1, condition2);
}

// ── Effects ─────────────────────────────────────────────────────────────────

// The corners of a caret, with the thickness settings applied.
//
// They come back packed as (left x, right x, top y, bottom y). The names the
// original shader uses are kept in the caller: its "tl" is the corner that
// leads *down* the screen, because the original keeps its cursor rectangle
// anchored at the bottom edge.
vec4 caret_corners(vec4 rect, float thickness, float thickness_x) {
	float half_height = rect.w * 0.5;
	float center_y = rect.y + half_height;
	float new_half_height = half_height * thickness;

	float half_width = rect.z * 0.5;
	float center_x = rect.x + half_width;
	float new_half_width = half_width * thickness_x;

	return vec4(
		center_x - new_half_width,
		center_x + new_half_width,
		center_y - new_half_height,
		center_y + new_half_height
	);
}

// How long a corner takes to reach the new position. `dot_value` is the
// alignment of the corner with the direction of travel: above 0.5 it leads,
// below -0.5 it trails, anything between is a side.
float duration_from_dot(float dot_value, float lead, float side, float trail) {
	float is_lead = step(0.5, dot_value);
	float is_side = step(-0.5, dot_value) * (1.0 - is_lead);

	float result = mix(trail, side, is_side);
	result = mix(result, lead, is_lead);
	return result;
}

float warp_trail(vec2 p, float progress) {
	vec2 cc = current_cursor.xy + current_cursor.zw * 0.5;
	vec2 cp = previous_cursor.xy + previous_cursor.zw * 0.5;

	// The corners of both carets. The original names them after the corner
	// that leads down the screen, so the "tl" of the original is the bottom
	// left corner here.
	vec4 cc_corners = caret_corners(current_cursor, trail_thickness, trail_thickness_x);
	vec4 cp_corners = caret_corners(previous_cursor, trail_thickness, trail_thickness_x);

	vec2 cc_tl = vec2(cc_corners.x, cc_corners.w);
	vec2 cc_tr = vec2(cc_corners.y, cc_corners.w);
	vec2 cc_bl = vec2(cc_corners.x, cc_corners.z);
	vec2 cc_br = vec2(cc_corners.y, cc_corners.z);

	vec2 cp_tl = vec2(cp_corners.x, cp_corners.w);
	vec2 cp_tr = vec2(cp_corners.y, cp_corners.w);
	vec2 cp_bl = vec2(cp_corners.x, cp_corners.z);
	vec2 cp_br = vec2(cp_corners.y, cp_corners.z);

	// The durations are fractions of the animation: the trailing corner takes
	// all of it, the leading one only the leftover.
	float dur_trail = 1.0;
	float dur_lead = 1.0 - trail_size;
	float dur_side = (dur_lead + dur_trail) * 0.5;

	vec2 move_vec = cc - cp;
	vec2 s = sign(move_vec);

	float dot_tl = dot(vec2(-1.0, 1.0), s);
	float dot_tr = dot(vec2(1.0, 1.0), s);
	float dot_bl = dot(vec2(-1.0, -1.0), s);
	float dot_br = dot(vec2(1.0, -1.0), s);

	float d_tl = duration_from_dot(dot_tl, dur_lead, dur_side, dur_trail);
	float d_tr = duration_from_dot(dot_tr, dur_lead, dur_side, dur_trail);
	float d_bl = duration_from_dot(dot_bl, dur_lead, dur_side, dur_trail);
	float d_br = duration_from_dot(dot_br, dur_lead, dur_side, dur_trail);

	// A horizontal move keeps the whole left or the whole right edge together.
	float moving_right = step(0.5, s.x);
	float moving_left = step(0.5, -s.x);

	float dur_right_rail = duration_from_dot((dot_tr + dot_br) * 0.5, dur_lead, dur_side, dur_trail);
	float dur_left_rail = duration_from_dot((dot_tl + dot_bl) * 0.5, dur_lead, dur_side, dur_trail);

	float f_tl = mix(d_tl, dur_left_rail, moving_left);
	float f_bl = mix(d_bl, dur_left_rail, moving_left);
	float f_tr = mix(d_tr, dur_right_rail, moving_right);
	float f_br = mix(d_br, dur_right_rail, moving_right);

	float p_tl = ease_out_circ(clamp(progress / max(f_tl, 0.0001), 0.0, 1.0));
	float p_tr = ease_out_circ(clamp(progress / max(f_tr, 0.0001), 0.0, 1.0));
	float p_bl = ease_out_circ(clamp(progress / max(f_bl, 0.0001), 0.0, 1.0));
	float p_br = ease_out_circ(clamp(progress / max(f_br, 0.0001), 0.0, 1.0));

	vec2 v_tl = mix(cp_tl, cc_tl, p_tl);
	vec2 v_tr = mix(cp_tr, cc_tr, p_tr);
	vec2 v_br = mix(cp_br, cc_br, p_br);
	vec2 v_bl = mix(cp_bl, cc_bl, p_bl);

	float sdf_trail = sdf_convex_quad(p, v_tl, v_tr, v_br, v_bl);

	// The blur of the original is only used on diagonal moves: on a straight
	// move it made the leading edge pulse.
	float edge = antialias_size;
	if (edge < 2.5) {
		float is_diagonal = abs(s.x) * abs(s.y);
		edge = mix(0.0, edge, is_diagonal);
	}

	float mask = shape_mask(sdf_trail, edge);

	if (fade_enabled > 0.5) {
		// Project the fragment onto the movement: 0 at the tail, 1 at the head.
		vec2 frag_vec = p - cp;
		float fade_progress = clamp(dot(frag_vec, move_vec) / (dot(move_vec, move_vec) + 0.000001), 0.0, 1.0);
		mask *= pow(fade_progress, fade_exponent);
	}

	return mask;
}

float sweep_trail(vec2 p, float progress) {
	vec2 cc = current_cursor.xy + current_cursor.zw * 0.5;
	vec2 cp = previous_cursor.xy + previous_cursor.zw * 0.5;

	float shrink = ease_out_cubic(progress);

	// A straight move gets a rectangle, a diagonal one a parallelogram.
	vec2 delta = abs(cc - cp);
	float is_horizontal = step(delta.y, 0.01);
	float is_vertical = step(delta.x, 0.01);
	float is_straight = max(is_horizontal, is_vertical);

	// The bottom left corner of each caret decides which of the top corners
	// leads the movement.
	vec2 cc_corner = vec2(current_cursor.x, current_cursor.y + current_cursor.w);
	vec2 cp_corner = vec2(previous_cursor.x, previous_cursor.y + previous_cursor.w);
	float top_flag = top_right_leads(cc_corner, cp_corner);
	float bottom_flag = 1.0 - top_flag;

	vec2 v0 = vec2(current_cursor.x + current_cursor.z * top_flag, current_cursor.y);
	vec2 v1 = vec2(current_cursor.x + current_cursor.z * bottom_flag, current_cursor.y + current_cursor.w);
	vec2 v2_full = vec2(previous_cursor.x + previous_cursor.z * bottom_flag, previous_cursor.y + previous_cursor.w);
	vec2 v3_full = vec2(previous_cursor.x + previous_cursor.z * top_flag, previous_cursor.y);

	vec2 v2_start = mix(v1, v2_full, trail_length);
	vec2 v3_start = mix(v0, v3_full, trail_length);
	vec2 v2_anim = mix(v2_start, v1, shrink);
	vec2 v3_anim = mix(v3_start, v0, shrink);

	float sdf_diag = sdf_parallelogram(p, v0, v1, v2_anim, v3_anim);

	vec2 min_center = min(cp, cc);
	vec2 max_center = max(cp, cc);
	vec2 box_size_full = (max_center - min_center) + current_cursor.zw;
	vec2 box_center_full = (min_center + max_center) * 0.5;

	vec2 box_size_start = mix(current_cursor.zw, box_size_full, trail_length);
	vec2 box_center_start = mix(cc, box_center_full, trail_length);

	vec2 anim_size = mix(box_size_start, current_cursor.zw, shrink);
	vec2 anim_center = mix(box_center_start, cc, shrink);

	float sdf_rect = sdf_rectangle(p, anim_center, anim_size * 0.5);

	return shape_mask(mix(sdf_diag, sdf_rect, is_straight), antialias_size);
}

float tail_trail(vec2 p, float progress) {
	vec2 cc = current_cursor.xy + current_cursor.zw * 0.5;
	vec2 cp = previous_cursor.xy + previous_cursor.zw * 0.5;

	float travel = distance(cc, cp);
	if (travel < 0.0001) {
		return 0.0;
	}

	// A move longer than the maximum trail length keeps a fixed length: the
	// head jumps to the caret and the tail follows it in. A shorter move is a
	// comet: the head follows the caret and the tail lags behind.
	float is_long_move = step(max_trail_length, travel);

	float head_short = ease_out_circ(progress);
	float tail_short = ease_out_circ(clamp((progress - tail_delay) / max(1.0 - tail_delay, 0.0001), 0.0, 1.0));
	float head_long = 1.0;
	float tail_long = ease_out_circ(progress);

	float head = mix(head_long, head_short, is_long_move);
	float tail = mix(tail_long, tail_short, is_long_move);

	vec2 delta = abs(cc - cp);
	float is_horizontal = step(delta.y, 0.01);
	float is_vertical = step(delta.x, 0.01);
	float is_straight = max(is_horizontal, is_vertical);

	vec2 cc_corner = vec2(current_cursor.x, current_cursor.y + current_cursor.w);
	vec2 cp_corner = vec2(previous_cursor.x, previous_cursor.y + previous_cursor.w);
	float leads = top_right_leads(cc_corner, cp_corner);
	float trails = 1.0 - leads;

	vec2 head_pos = mix(cp_corner, cc_corner, head);
	vec2 tail_pos = mix(cp_corner, cc_corner, tail);

	vec2 v0 = vec2(head_pos.x + current_cursor.z * leads, head_pos.y - current_cursor.w);
	vec2 v1 = vec2(head_pos.x + current_cursor.z * trails, head_pos.y);
	vec2 v2 = vec2(tail_pos.x + current_cursor.z * trails, tail_pos.y);
	vec2 v3 = vec2(tail_pos.x + current_cursor.z * leads, tail_pos.y - previous_cursor.w);

	float sdf_diag = sdf_parallelogram(p, v0, v1, v2, v3);

	vec2 head_center = mix(cp, cc, head);
	vec2 tail_center = mix(cp, cc, tail);
	vec2 min_center = min(head_center, tail_center);
	vec2 max_center = max(head_center, tail_center);
	vec2 box_size = (max_center - min_center) + current_cursor.zw;
	vec2 box_center = (min_center + max_center) * 0.5;

	float sdf_rect = sdf_rectangle(p, box_center, box_size * 0.5);

	return shape_mask(mix(sdf_diag, sdf_rect, is_straight), antialias_size);
}

// ── Fragment ────────────────────────────────────────────────────────────────

// The position of the fragment in the quad's own pixels. It comes from the
// vertex, so it does not depend on the quad carrying a texture.
varying vec2 local_pos;

void vertex() {
	local_pos = VERTEX;
}

void fragment() {
	// The fragment in the quad's own pixels, with the origin at its top left.
	vec2 p = local_pos;

	vec2 cc = current_cursor.xy + current_cursor.zw * 0.5;
	vec2 cp = previous_cursor.xy + previous_cursor.zw * 0.5;

	float progress = clamp(elapsed / max(duration, 0.0001), 0.0, 1.0);

	float mask = 0.0;
	if (effect == 1) {
		mask = warp_trail(p, progress);
	} else if (effect == 2) {
		mask = sweep_trail(p, progress);
	} else if (effect == 3) {
		mask = tail_trail(p, progress);
	}

	if (mask <= 0.0) {
		COLOR = vec4(0.0);
	} else {
		// The live caret stays crisp: the trail never paints over it. The
		// hole is half as soft as the trail's own edge, so it does not eat
		// the head of the smear.
		float sdf_cursor = sdf_rectangle(p, cc, current_cursor.zw * 0.5);
		mask *= smoothstep(-antialias_size * 0.5, antialias_size * 0.5, sdf_cursor);

		float glow = smoothstep(antialias_size * 3.0, 0.0, abs(sdf_cursor));
		float alpha = trail_color.a * max(mask, glow * glow_strength * 0.18);
		COLOR = vec4(trail_color.rgb, alpha);
	}
}
