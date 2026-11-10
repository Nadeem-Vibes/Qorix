extends RefCounted

## Ed25519 signatures (RFC 8032) in pure GDScript.
##
## Publisher signatures need Ed25519, and the pinned Godot build only exposes
## RSA through Crypto. Pulling a second native extension into the trusted
## computing base just for signatures would enlarge the attack surface, so the
## verifier here is deliberately small and auditable:
##
##   * Field elements use ten 26-bit limbs (the top limb holds 21 bits).
##   * Points use extended twisted-Edwards coordinates.
##   * SHA-512 is implemented on 64-bit signed integers with explicit logical
##     shifts; addition wraps exactly like the unsigned algorithm.
##   * Verification is variable-time (inputs are public). Signing exists for the
##     local packaging tool and is not exposed to mods.
##
## This is not a general-purpose crypto library. It implements exactly the
## signature operations the package format needs and is pinned by RFC 8032
## known-answer tests in tests/unit/features/mods/test_mod_ed25519.gd.

const MASK26 := 0x3FFFFFF
const MASK21 := 0x1FFFFF
const DOMAIN := "GRIDDYCODE-MOD-PACKAGE-V1"

## Base point encoding from RFC 8032: y = 4/5, sign bit 0.
const BASE_POINT_BYTES := "5866666666666666666666666666666666666666666666666666666666666666"

static var _d: PackedInt64Array = PackedInt64Array()
static var _sqrt_m1: PackedInt64Array = PackedInt64Array()
static var _base_point: Array = []
static var _base_table: Array = []
static var _sha512_k: Array = []
static var _sha512_h: Array = []


# ── PUBLIC API ──────────────────────────────────────────────────────────────

static func verify(signature: PackedByteArray, message: PackedByteArray, public_key: PackedByteArray) -> bool:
	if signature.size() != 64 or public_key.size() != 32:
		return false
	_ensure_tables()

	var r_bytes := signature.slice(0, 32)
	var s_bytes := signature.slice(32, 64)
	if _scalar_is_above_l(s_bytes):
		return false

	var a := _point_decompress(public_key)
	if a.is_empty():
		return false
	# Reject the low-order public keys that make signatures ambiguous.
	if _point_is_identity(_point_double(_point_double(_point_double(a)))):
		return false

	var r_point := _point_decompress(r_bytes)
	if r_point.is_empty():
		return false

	var h := _sha512(_concat([r_bytes, public_key, message]))
	var h_scalar := _scalar_reduce_wide(h)
	var left := _point_mul(s_bytes, _base_point, _base_table)
	var right := _point_add(r_point, _point_mul(h_scalar, a))
	return _point_eq(left, right)


static func sign(message: PackedByteArray, seed: PackedByteArray) -> PackedByteArray:
	if seed.size() != 32:
		return PackedByteArray()
	_ensure_tables()

	var h := _sha512(seed)
	var a := h.slice(0, 32)
	a[0] = a[0] & 248
	a[31] = a[31] & 127
	a[31] = a[31] | 64
	var prefix := h.slice(32, 64)

	var public_key := _point_compress(_point_mul(a, _base_point, _base_table))
	var r := _scalar_reduce_wide(_sha512(_concat([prefix, message])))
	var r_point := _point_compress(_point_mul(r, _base_point, _base_table))
	var k := _scalar_reduce_wide(_sha512(_concat([r_point, public_key, message])))
	var s := _scalar_add_mod(_scalar_mul(k, a), r)
	return _concat([r_point, s])


static func public_key_from_seed(seed: PackedByteArray) -> PackedByteArray:
	if seed.size() != 32:
		return PackedByteArray()
	_ensure_tables()
	var h := _sha512(seed)
	var a := h.slice(0, 32)
	a[0] = a[0] & 248
	a[31] = a[31] & 127
	a[31] = a[31] | 64
	return _point_compress(_point_mul(a, _base_point, _base_table))


static func generate_seed() -> PackedByteArray:
	return Crypto.new().generate_random_bytes(32)


## Package-signing message. The digest binds the file tree; the publisher id and
## key bind the signature metadata itself, so an attacker cannot swap the
## display name or the key without invalidating the signature.
static func package_message(package_hash_hex: String, publisher_id: String, public_key_hex: String) -> PackedByteArray:
	return ("%s\n%s\n%s\n%s" % [DOMAIN, package_hash_hex.to_lower(), publisher_id, public_key_hex.to_lower()]).to_utf8_buffer()


static func hex_to_bytes(text: String) -> PackedByteArray:
	var clean := text.strip_edges().to_lower()
	if clean.length() % 2 != 0:
		return PackedByteArray()
	var out := PackedByteArray()
	out.resize(clean.length() / 2)
	for index in range(out.size()):
		var hi := _hex_value(clean.unicode_at(index * 2))
		var lo := _hex_value(clean.unicode_at(index * 2 + 1))
		if hi < 0 or lo < 0:
			return PackedByteArray()
		out[index] = (hi << 4) | lo
	return out


static func bytes_to_hex(bytes: PackedByteArray) -> String:
	return bytes.hex_encode().to_lower()


static func fingerprint(public_key: PackedByteArray) -> String:
	if public_key.size() != 32:
		return ""
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(public_key)
	return context.finish().hex_encode().to_lower()


# ── FIELD ARITHMETIC (base 2^26, ten limbs) ─────────────────────────────────

static func _p() -> PackedInt64Array:
	return PackedInt64Array([
		0x3FFFFED, 0x3FFFFFF, 0x3FFFFFF, 0x3FFFFFF, 0x3FFFFFF,
		0x3FFFFFF, 0x3FFFFFF, 0x3FFFFFF, 0x3FFFFFF, 0x1FFFFF,
	])


static func _f_zero() -> PackedInt64Array:
	var out := PackedInt64Array()
	out.resize(10)
	return out


static func _f_one() -> PackedInt64Array:
	var out := _f_zero()
	out[0] = 1
	return out


static func _f_copy(value: PackedInt64Array) -> PackedInt64Array:
	return value.duplicate()


static func _f_normalize(value: PackedInt64Array) -> PackedInt64Array:
	var out := value.duplicate()
	if out.size() < 10:
		out.resize(10)

	var carry := 0
	for index in range(10):
		var v := out[index] + carry
		carry = v >> 26
		out[index] = v & MASK26

	while carry != 0:
		out[0] += carry * 608
		carry = 0
		for index in range(10):
			var v := out[index] + carry
			carry = v >> 26
			out[index] = v & MASK26

	while out[9] >= (1 << 21):
		var top := out[9] >> 21
		out[9] = out[9] & MASK21
		out[0] += top * 19
		carry = 0
		for index in range(10):
			var v := out[index] + carry
			carry = v >> 26
			out[index] = v & MASK26
		out[0] += carry * 608

	if _f_ge_p(out):
		_f_sub_p_inplace(out)
	return out


static func _f_ge_p(value: PackedInt64Array) -> bool:
	var p := _p()
	for index in range(9, -1, -1):
		if value[index] > p[index]:
			return true
		if value[index] < p[index]:
			return false
	return true


static func _f_sub_p_inplace(value: PackedInt64Array) -> void:
	var p := _p()
	var borrow := 0
	for index in range(10):
		var v := value[index] - p[index] - borrow
		if v < 0:
			v += 1 << 26
			borrow = 1
		else:
			borrow = 0
		value[index] = v


static func _f_add(left: PackedInt64Array, right: PackedInt64Array) -> PackedInt64Array:
	var out := _f_zero()
	for index in range(10):
		out[index] = left[index] + right[index]
	return _f_normalize(out)


static func _f_sub(left: PackedInt64Array, right: PackedInt64Array) -> PackedInt64Array:
	# Add 2p limb-wise before normalising. Every limb of left-right is at least
	# -(2^26-1), and every limb of 2p is at least 2(2^26-19) for limb 0, so the
	# sum stays non-negative without any borrow across the 255-bit boundary.
	# (Borrowing across that boundary would add 2^260, which is 608 mod p and
	# would corrupt the result.)
	var out := _f_zero()
	var p := _p()
	var carry := 0
	for index in range(10):
		var v := left[index] - right[index] + (p[index] << 1) + carry
		out[index] = v & MASK26
		carry = v >> 26
	out[0] += carry * 608
	return _f_normalize(out)


static func _f_mul(left: PackedInt64Array, right: PackedInt64Array) -> PackedInt64Array:
	var wide := PackedInt64Array()
	wide.resize(20)

	for i in range(10):
		var ai := left[i]
		if ai == 0:
			continue
		var carry := 0
		for j in range(10):
			var v := wide[i + j] + ai * right[j] + carry
			wide[i + j] = v & MASK26
			carry = v >> 26
		var cursor := i + 10
		while carry != 0 and cursor < 20:
			var v := wide[cursor] + carry
			wide[cursor] = v & MASK26
			carry = v >> 26
			cursor += 1

	# 2^(26*10) = 2^260 = 32 * 2^255 = 32 * 19 (mod p).
	for index in range(10, 20):
		if wide[index] != 0:
			wide[index - 10] += wide[index] * 608
	var folded := PackedInt64Array()
	folded.resize(10)
	for index in range(10):
		folded[index] = wide[index]
	return _f_normalize(folded)


static func _f_sq(value: PackedInt64Array) -> PackedInt64Array:
	return _f_mul(value, value)


static func _f_eq(left: PackedInt64Array, right: PackedInt64Array) -> bool:
	var a := _f_normalize(left)
	var b := _f_normalize(right)
	for index in range(10):
		if a[index] != b[index]:
			return false
	return true


static func _f_is_zero(value: PackedInt64Array) -> bool:
	var normalized := _f_normalize(value)
	for index in range(10):
		if normalized[index] != 0:
			return false
	return true


static func _f_from_int(value: int) -> PackedInt64Array:
	var out := _f_zero()
	var remaining := value
	var index := 0
	while remaining != 0 and index < 10:
		out[index] = remaining & MASK26
		remaining = remaining >> 26
		index += 1
	return out


static func _f_from_bytes(bytes: PackedByteArray) -> PackedInt64Array:
	var out := _f_zero()
	var limit := mini(bytes.size(), 32)
	for index in range(limit):
		var byte := int(bytes[index])
		if byte == 0:
			continue
		var bit_position := index * 8
		var limb := int(bit_position / 26)
		var offset := bit_position % 26
		out[limb] = out[limb] | ((byte << offset) & MASK26)
		if offset > 18 and limb + 1 < 10:
			out[limb + 1] = out[limb + 1] | (byte >> (26 - offset))
	return _f_normalize(out)


static func _f_to_bytes(value: PackedInt64Array) -> PackedByteArray:
	var normalized := _f_normalize(value)
	var out := PackedByteArray()
	out.resize(32)
	var bit_buffer := 0
	var bits := 0
	var out_index := 0
	for index in range(10):
		bit_buffer = bit_buffer | (normalized[index] << bits)
		bits += 26
		while bits >= 8:
			out[out_index] = bit_buffer & 0xFF
			out_index += 1
			bit_buffer = bit_buffer >> 8
			bits -= 8
	if out_index < 32:
		out[out_index] = bit_buffer & 0xFF
	return out


static func _f_pow(base: PackedInt64Array, exponent: PackedByteArray) -> PackedInt64Array:
	var result := _f_one()
	var started := false
	for byte_index in range(exponent.size() - 1, -1, -1):
		var byte := int(exponent[byte_index])
		for bit_index in range(7, -1, -1):
			if started:
				result = _f_sq(result)
				if ((byte >> bit_index) & 1) != 0:
					result = _f_mul(result, base)
			elif ((byte >> bit_index) & 1) != 0:
				result = _f_copy(base)
				started = true
	return result


static func _f_inv(value: PackedInt64Array) -> PackedInt64Array:
	return _f_pow(value, _exp_p_minus_2())


static func _exp_p_minus_2() -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(32)
	out.fill(0xFF)
	out[0] = 0xEB
	out[31] = 0x7F
	return out


static func _exp_sqrt() -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(32)
	out.fill(0xFF)
	out[0] = 0xFE
	out[31] = 0x0F
	return out


static func _exp_sqrt_m1() -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(32)
	out.fill(0xFF)
	out[0] = 0xFB
	out[31] = 0x1F
	return out


# ── POINTS (extended twisted Edwards) ───────────────────────────────────────

static func _point_identity() -> Array:
	return [_f_zero(), _f_one(), _f_one(), _f_zero()]


static func _point_add(left: Array, right: Array) -> Array:
	var a := _f_mul(_f_sub(left[1], left[0]), _f_sub(right[1], right[0]))
	var b := _f_mul(_f_add(left[1], left[0]), _f_add(right[1], right[0]))
	var c := _f_mul(_f_mul(left[3], right[3]), _f_add(_d, _d))
	var d := _f_mul(_f_add(left[2], left[2]), right[2])
	var e := _f_sub(b, a)
	var f := _f_sub(d, c)
	var g := _f_add(d, c)
	var h := _f_add(b, a)
	return [
		_f_mul(e, f),
		_f_mul(g, h),
		_f_mul(f, g),
		_f_mul(e, h),
	]


static func _point_double(point: Array) -> Array:
	var a := _f_sq(point[0])
	var b := _f_sq(point[1])
	var c := _f_add(_f_sq(point[2]), _f_sq(point[2]))
	var d := _f_sub(_f_zero(), a)
	var e := _f_sub(_f_sub(_f_sq(_f_add(point[0], point[1])), a), b)
	var g := _f_add(d, b)
	var f := _f_sub(g, c)
	var h := _f_sub(d, b)
	return [
		_f_mul(e, f),
		_f_mul(g, h),
		_f_mul(f, g),
		_f_mul(e, h),
	]


static func _point_eq(left: Array, right: Array) -> bool:
	var x1z2 := _f_mul(left[0], right[2])
	var x2z1 := _f_mul(right[0], left[2])
	if !_f_eq(x1z2, x2z1):
		return false
	var y1z2 := _f_mul(left[1], right[2])
	var y2z1 := _f_mul(right[1], left[2])
	return _f_eq(y1z2, y2z1)


static func _point_is_identity(point: Array) -> bool:
	return _f_is_zero(point[0]) and _f_eq(point[1], point[2])


static func _point_compress(point: Array) -> PackedByteArray:
	var z_inverse := _f_inv(point[2])
	var x := _f_mul(point[0], z_inverse)
	var y := _f_mul(point[1], z_inverse)
	var out := _f_to_bytes(y)
	if (x[0] & 1) != 0:
		out[31] = out[31] | 0x80
	return out


static func _point_decompress(encoded: PackedByteArray) -> Array:
	if encoded.size() != 32:
		return []
	var sign := (encoded[31] >> 7) & 1
	var y_bytes := encoded.duplicate()
	y_bytes[31] = y_bytes[31] & 0x7F
	var y := _f_from_bytes(y_bytes)
	if _f_ge_p(y):
		return []

	var y_squared := _f_sq(y)
	var u := _f_sub(y_squared, _f_one())
	var v := _f_add(_f_mul(_d, y_squared), _f_one())
	var x := _f_pow(_f_mul(u, _f_inv(v)), _exp_sqrt())
	if !_f_eq(_f_mul(_f_sq(x), v), u):
		x = _f_mul(x, _sqrt_m1)
		if !_f_eq(_f_mul(_f_sq(x), v), u):
			return []

	if _f_is_zero(x):
		if sign != 0:
			return []
	else:
		if (x[0] & 1) != sign:
			x = _f_sub(_f_zero(), x)

	return [x, y, _f_one(), _f_mul(x, y)]


static func _point_table(point: Array) -> Array:
	var table: Array = [_point_identity(), point]
	for index in range(2, 16):
		table.append(_point_add(table[index - 1], point))
	return table


static func _point_mul(scalar: PackedByteArray, point: Array, table: Array = []) -> Array:
	var multiples := table
	if multiples.is_empty():
		multiples = _point_table(point)

	var result := _point_identity()
	for nibble_index in range(63, -1, -1):
		for _round in range(4):
			result = _point_double(result)
		var byte_index := int(nibble_index / 2)
		var shift := 4 if (nibble_index & 1) != 0 else 0
		var nibble := (int(scalar[byte_index]) >> shift) & 0x0F
		if nibble != 0:
			result = _point_add(result, multiples[nibble])
	return result


static func _ensure_tables() -> void:
	if !_base_point.is_empty():
		return

	_d = _f_neg(_f_mul(_f_from_int(121665), _f_inv(_f_from_int(121666))))
	_sqrt_m1 = _f_pow(_f_from_int(2), _exp_sqrt_m1())
	_base_point = _point_decompress(hex_to_bytes(BASE_POINT_BYTES))
	_base_table = _point_table(_base_point)


static func _f_neg(value: PackedInt64Array) -> PackedInt64Array:
	return _f_sub(_f_zero(), value)


# ── SCALARS (base 2^16, sixteen limbs) ──────────────────────────────────────

static func _l_limbs() -> PackedInt64Array:
	return PackedInt64Array([
		0xD3ED, 0x5CF5, 0x631A, 0x5812, 0x9CD6, 0xA2F7, 0xF9DE, 0x14DE,
		0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x1000,
	])


static func _scalar_from_bytes(bytes: PackedByteArray) -> PackedInt64Array:
	var out := PackedInt64Array()
	out.resize(16)
	for index in range(mini(bytes.size(), 32)):
		var byte := int(bytes[index])
		var limb := int(index / 2)
		if (index & 1) == 0:
			out[limb] = out[limb] | byte
		else:
			out[limb] = out[limb] | (byte << 8)
	return out


static func _scalar_to_bytes(scalar: PackedInt64Array) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(32)
	for index in range(16):
		out[index * 2] = scalar[index] & 0xFF
		out[index * 2 + 1] = (scalar[index] >> 8) & 0xFF
	return out


static func _scalar_ge(left: PackedInt64Array, right: PackedInt64Array) -> bool:
	for index in range(15, -1, -1):
		if left[index] > right[index]:
			return true
		if left[index] < right[index]:
			return false
	return true


static func _scalar_sub_inplace(left: PackedInt64Array, right: PackedInt64Array) -> void:
	var borrow := 0
	for index in range(16):
		var value := left[index] - right[index] - borrow
		if value < 0:
			value += 1 << 16
			borrow = 1
		else:
			borrow = 0
		left[index] = value


static func _scalar_reduce_wide(wide: PackedByteArray) -> PackedByteArray:
	var modulus := _l_limbs()
	var remainder := PackedInt64Array()
	remainder.resize(16)

	for bit_index in range(wide.size() * 8 - 1, -1, -1):
		var byte := int(wide[int(bit_index / 8)])
		var bit := (byte >> (bit_index % 8)) & 1
		var carry := bit
		for index in range(16):
			var value := (remainder[index] << 1) | carry
			remainder[index] = value & 0xFFFF
			carry = value >> 16
		if _scalar_ge(remainder, modulus):
			_scalar_sub_inplace(remainder, modulus)

	return _scalar_to_bytes(remainder)


static func _scalar_is_above_l(bytes: PackedByteArray) -> bool:
	return _scalar_ge(_scalar_from_bytes(bytes), _l_limbs())


static func _scalar_mul(left: PackedByteArray, right: PackedByteArray) -> PackedByteArray:
	var a := _scalar_from_bytes(left)
	var b := _scalar_from_bytes(right)
	var wide := PackedInt64Array()
	wide.resize(32)

	for i in range(16):
		var carry := 0
		for j in range(16):
			var value := wide[i + j] + a[i] * b[j] + carry
			wide[i + j] = value & 0xFFFF
			carry = value >> 16
		var cursor := i + 16
		while carry != 0 and cursor < 32:
			var value := wide[cursor] + carry
			wide[cursor] = value & 0xFFFF
			carry = value >> 16
			cursor += 1

	var bytes := PackedByteArray()
	bytes.resize(64)
	for index in range(32):
		bytes[index * 2] = wide[index] & 0xFF
		bytes[index * 2 + 1] = (wide[index] >> 8) & 0xFF
	return _scalar_reduce_wide(bytes)


static func _scalar_add_mod(left: PackedByteArray, right: PackedByteArray) -> PackedByteArray:
	var modulus := _l_limbs()
	var sum := _scalar_from_bytes(left)
	var addend := _scalar_from_bytes(right)
	var carry := 0
	for index in range(16):
		var value := sum[index] + addend[index] + carry
		sum[index] = value & 0xFFFF
		carry = value >> 16
	if carry != 0 or _scalar_ge(sum, modulus):
		_scalar_sub_inplace(sum, modulus)
		# A carry means the true sum was >= 2^256; subtracting L once is still
		# correct because both operands are < L < 2^253.
	return _scalar_to_bytes(sum)


# ── SHA-512 ─────────────────────────────────────────────────────────────────

static func _sha512(message: PackedByteArray) -> PackedByteArray:
	_ensure_sha512()

	var data := message.duplicate()
	var bit_length := data.size() * 8
	data.append(0x80)
	while (data.size() % 128) != 112:
		data.append(0)
	# GDScript masks shift counts modulo 64, so the upper eight length bytes are
	# written explicitly instead of shifting by 64 or more.
	for index in range(15, -1, -1):
		var byte := 0
		if index < 8:
			byte = (bit_length >> (index * 8)) & 0xFF
		data.append(byte)

	var state: Array = _sha512_h.duplicate()
	for block_start in range(0, data.size(), 128):
		var w: Array = []
		w.resize(80)
		for index in range(16):
			var base := block_start + index * 8
			w[index] = _read_u64_be(data, base)
		for index in range(16, 80):
			var s0 := _rotr(w[index - 15], 1) ^ _rotr(w[index - 15], 8) ^ _shr(w[index - 15], 7)
			var s1 := _rotr(w[index - 2], 19) ^ _rotr(w[index - 2], 61) ^ _shr(w[index - 2], 6)
			w[index] = w[index - 16] + s0 + w[index - 7] + s1

		var a: int = state[0]
		var b: int = state[1]
		var c: int = state[2]
		var d: int = state[3]
		var e: int = state[4]
		var f: int = state[5]
		var g: int = state[6]
		var h: int = state[7]

		for index in range(80):
			var s1 := _rotr(e, 14) ^ _rotr(e, 18) ^ _rotr(e, 41)
			var ch := (e & f) ^ ((~e) & g)
			var temp1: int = h + s1 + ch + int(_sha512_k[index]) + int(w[index])
			var s0 := _rotr(a, 28) ^ _rotr(a, 34) ^ _rotr(a, 39)
			var maj := (a & b) ^ (a & c) ^ (b & c)
			var temp2: int = s0 + maj
			h = g
			g = f
			f = e
			e = d + temp1
			d = c
			c = b
			b = a
			a = temp1 + temp2

		state[0] = state[0] + a
		state[1] = state[1] + b
		state[2] = state[2] + c
		state[3] = state[3] + d
		state[4] = state[4] + e
		state[5] = state[5] + f
		state[6] = state[6] + g
		state[7] = state[7] + h

	var out := PackedByteArray()
	out.resize(64)
	for index in range(8):
		_write_u64_be(out, index * 8, state[index])
	return out


static func _shl(word: int, bits: int) -> int:
	if bits <= 0:
		return word
	if bits >= 64:
		return 0
	return word << bits


static func _shr(word: int, bits: int) -> int:
	if bits <= 0:
		return word
	if bits >= 64:
		return 0
	return (word >> bits) & ((1 << (64 - bits)) - 1)


static func _rotr(word: int, bits: int) -> int:
	if bits <= 0:
		return word
	if bits >= 64:
		bits = bits % 64
	return _shr(word, bits) | _shl(word, 64 - bits)


static func _read_u64_be(bytes: PackedByteArray, offset: int) -> int:
	var value := 0
	for index in range(8):
		value = _shl(value, 8) | int(bytes[offset + index])
	return value


static func _write_u64_be(bytes: PackedByteArray, offset: int, value: int) -> void:
	for index in range(7, -1, -1):
		bytes[offset + index] = value & 0xFF
		value = _shr(value, 8)


static func _ensure_sha512() -> void:
	if !_sha512_k.is_empty():
		return
	_sha512_k = [
		(0x428A2F98 << 32) | 0xD728AE22, (0x71374491 << 32) | 0x23EF65CD,
		(0xB5C0FBCF << 32) | 0xEC4D3B2F, (0xE9B5DBA5 << 32) | 0x8189DBBC,
		(0x3956C25B << 32) | 0xF348B538, (0x59F111F1 << 32) | 0xB605D019,
		(0x923F82A4 << 32) | 0xAF194F9B, (0xAB1C5ED5 << 32) | 0xDA6D8118,
		(0xD807AA98 << 32) | 0xA3030242, (0x12835B01 << 32) | 0x45706FBE,
		(0x243185BE << 32) | 0x4EE4B28C, (0x550C7DC3 << 32) | 0xD5FFB4E2,
		(0x72BE5D74 << 32) | 0xF27B896F, (0x80DEB1FE << 32) | 0x3B1696B1,
		(0x9BDC06A7 << 32) | 0x25C71235, (0xC19BF174 << 32) | 0xCF692694,
		(0xE49B69C1 << 32) | 0x9EF14AD2, (0xEFBE4786 << 32) | 0x384F25E3,
		(0x0FC19DC6 << 32) | 0x8B8CD5B5, (0x240CA1CC << 32) | 0x77AC9C65,
		(0x2DE92C6F << 32) | 0x592B0275, (0x4A7484AA << 32) | 0x6EA6E483,
		(0x5CB0A9DC << 32) | 0xBD41FBD4, (0x76F988DA << 32) | 0x831153B5,
		(0x983E5152 << 32) | 0xEE66DFAB, (0xA831C66D << 32) | 0x2DB43210,
		(0xB00327C8 << 32) | 0x98FB213F, (0xBF597FC7 << 32) | 0xBEEF0EE4,
		(0xC6E00BF3 << 32) | 0x3DA88FC2, (0xD5A79147 << 32) | 0x930AA725,
		(0x06CA6351 << 32) | 0xE003826F, (0x14292967 << 32) | 0x0A0E6E70,
		(0x27B70A85 << 32) | 0x46D22FFC, (0x2E1B2138 << 32) | 0x5C26C926,
		(0x4D2C6DFC << 32) | 0x5AC42AED, (0x53380D13 << 32) | 0x9D95B3DF,
		(0x650A7354 << 32) | 0x8BAF63DE, (0x766A0ABB << 32) | 0x3C77B2A8,
		(0x81C2C92E << 32) | 0x47EDAEE6, (0x92722C85 << 32) | 0x1482353B,
		(0xA2BFE8A1 << 32) | 0x4CF10364, (0xA81A664B << 32) | 0xBC423001,
		(0xC24B8B70 << 32) | 0xD0F89791, (0xC76C51A3 << 32) | 0x0654BE30,
		(0xD192E819 << 32) | 0xD6EF5218, (0xD6990624 << 32) | 0x5565A910,
		(0xF40E3585 << 32) | 0x5771202A, (0x106AA070 << 32) | 0x32BBD1B8,
		(0x19A4C116 << 32) | 0xB8D2D0C8, (0x1E376C08 << 32) | 0x5141AB53,
		(0x2748774C << 32) | 0xDF8EEB99, (0x34B0BCB5 << 32) | 0xE19B48A8,
		(0x391C0CB3 << 32) | 0xC5C95A63, (0x4ED8AA4A << 32) | 0xE3418ACB,
		(0x5B9CCA4F << 32) | 0x7763E373, (0x682E6FF3 << 32) | 0xD6B2B8A3,
		(0x748F82EE << 32) | 0x5DEFB2FC, (0x78A5636F << 32) | 0x43172F60,
		(0x84C87814 << 32) | 0xA1F0AB72, (0x8CC70208 << 32) | 0x1A6439EC,
		(0x90BEFFFA << 32) | 0x23631E28, (0xA4506CEB << 32) | 0xDE82BDE9,
		(0xBEF9A3F7 << 32) | 0xB2C67915, (0xC67178F2 << 32) | 0xE372532B,
		(0xCA273ECE << 32) | 0xEA26619C, (0xD186B8C7 << 32) | 0x21C0C207,
		(0xEADA7DD6 << 32) | 0xCDE0EB1E, (0xF57D4F7F << 32) | 0xEE6ED178,
		(0x06F067AA << 32) | 0x72176FBA, (0x0A637DC5 << 32) | 0xA2C898A6,
		(0x113F9804 << 32) | 0xBEF90DAE, (0x1B710B35 << 32) | 0x131C471B,
		(0x28DB77F5 << 32) | 0x23047D84, (0x32CAAB7B << 32) | 0x40C72493,
		(0x3C9EBE0A << 32) | 0x15C9BEBC, (0x431D67C4 << 32) | 0x9C100D4C,
		(0x4CC5D4BE << 32) | 0xCB3E42B6, (0x597F299C << 32) | 0xFC657E2A,
		(0x5FCB6FAB << 32) | 0x3AD6FAEC, (0x6C44198C << 32) | 0x4A475817,
	]
	_sha512_h = [
		(0x6A09E667 << 32) | 0xF3BCC908,
		(0xBB67AE85 << 32) | 0x84CAA73B,
		(0x3C6EF372 << 32) | 0xFE94F82B,
		(0xA54FF53A << 32) | 0x5F1D36F1,
		(0x510E527F << 32) | 0xADE682D1,
		(0x9B05688C << 32) | 0x2B3E6C1F,
		(0x1F83D9AB << 32) | 0xFB41BD6B,
		(0x5BE0CD19 << 32) | 0x137E2179,
	]


# ── SMALL HELPERS ───────────────────────────────────────────────────────────

static func _concat(parts: Array) -> PackedByteArray:
	var out := PackedByteArray()
	for part in parts:
		out.append_array(part as PackedByteArray)
	return out


static func _hex_value(code: int) -> int:
	if code >= 48 and code <= 57:
		return code - 48
	if code >= 97 and code <= 102:
		return code - 87
	if code >= 65 and code <= 70:
		return code - 55
	return -1
