/*
Neon-style bloom used for the "Glow" setting.

Replaces Godot's built-in environment glow, which applies to every pixel
(hdr_threshold = 0.0) and washes light themes out to pure white. This shader
only blooms pixels noticeably brighter than the current theme background:
- dark theme  → threshold ~0.4, your text/console colors glow
- light theme → threshold is clamped to 1.3, nothing can glow

ORDER MATTERS here: the threshold is subtracted from EVERY SAMPLE *before*
blurring, not after. Blur-then-threshold makes the blurred average collapse
under the threshold a couple of pixels away from the glyph, so only the glyph
itself lights up ("font got brighter", no halo). Threshold-then-blur makes the
glyph's extracted glow physically spread outward through the blur, producing a
real neon halo that fades across the full radius.

The threshold/intensity are set from LuaSingleton.apply_glow().
*/

shader_type canvas_item;
render_mode blend_add;

uniform sampler2D SCREEN_TEXTURE : hint_screen_texture, filter_linear_mipmap;
uniform float threshold = 0.55;
uniform float intensity = 1.5;
uniform float radius = 7.0; // halo radius in screen pixels

void fragment() {
	vec2 texel = radius / vec2(textureSize(SCREEN_TEXTURE, 0));

	// Wide 4-ring blur. Each ring is sampled on a circle; the whole set is
	// weighted so the glow falls off smoothly (near rings count most).
	float ring_r[4] = float[4](0.3, 0.75, 1.4, 2.2); // ring radius as a fraction of `radius`
	float ring_w[4] = float[4](1.0, 0.8, 0.5, 0.3);  // weight of each ring
	int ring_n[4] = int[4](8, 8, 12, 12);            // taps on each ring

	vec3 acc = vec3(0.0);
	float total = 0.0;

	for (int r = 0; r < 4; r++) {
		int count = ring_n[r];
		// stagger the start angle of each ring so tap patterns don't align
		float a0 = float(r) * 0.7;
		for (int i = 0; i < count; i++) {
			float angle = a0 + 6.28318530718 * float(i) / float(count);
			vec2 offset = vec2(cos(angle), sin(angle)) * texel * ring_r[r];
			vec3 c = texture(SCREEN_TEXTURE, SCREEN_UV + offset).rgb;

			// Extract the glow of this sample BEFORE it is blurred: keep only
			// what sits above the theme threshold, pushed toward its own hue so
			// pastel/neon colors bleed out saturated rather than gray.
			float luma = dot(c, vec3(0.2126, 0.7152, 0.0722));
			vec3 sat = mix(vec3(luma), c, 1.25);
			vec3 glow = max(vec3(0.0), sat - vec3(threshold));

			acc += glow * ring_w[r];
			total += ring_w[r];
		}
	}

	// NOTE: no center tap on purpose. Adding the pixel itself made glyphs
	// double up in brightness ("font just looks brighter"); the halo should
	// come from the surroundings, not from the pixel we're painting over.

	vec3 bloom = acc / total;

	// Lift low bloom values (gamma < 1) for a soft, long tail on the halo
	// instead of a hard ring around each glyph.
	bloom = pow(bloom, vec3(0.8));

	COLOR = vec4(bloom * intensity, 1.0);
}
