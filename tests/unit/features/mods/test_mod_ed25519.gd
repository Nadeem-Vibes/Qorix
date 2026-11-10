extends TestCase

## Ed25519 known-answer tests (RFC 8032) and SHA-512 padding checks.
##
## The package verifier is pure GDScript, so these vectors are the anchor that
## keeps the arithmetic honest. SHA-512 is checked against independent known
## answers at every padding boundary, because the hand-written padding and
## 64-bit shifts are the easiest part to get subtly wrong.

const Ed25519 = preload("res://src/features/mods/ed25519.gd")

const SHA512_EMPTY := "cf83e1357eefb8bdf1542850d66d8007d620e4050b5715dc83f4a921d36ce9ce47d0d13c5d85f2b0ff8318d2877eec2f63b931bd47417a81a538327af927da3e"
const SHA512_ABC := "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f"
const SHA512_FOX := "07e547d9586f6a73f73fbac0435ed76951218fb7d0c8d788a309d785436bbb642e93a252a954f23912547d1e8a3b5ed6e1bfd7097821233fa0538f3db854fee6"

## L = 2^252 + 27742317777372353535851937790883648493, little-endian.
const SCALAR_L_HEX := "edd3f55c1a631258d69cf7a2def9de1400000000000000000000000000000010"

const VECTORS := [
	{
		"name": "RFC 8032 test 1 (empty message)",
		"seed": "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60",
		"public": "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a",
		"message": "",
		"signature": "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b",
	},
	{
		"name": "RFC 8032 test 2 (single byte)",
		"seed": "4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb",
		"public": "3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c",
		"message": "72",
		"signature": "92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00",
	},
	{
		"name": "RFC 8032 test 3 (two bytes)",
		"seed": "c5aa8df43f9f837bedb7442f31dcb7b166d38535076f094b85ce3a2e0b4458f7",
		"public": "fc51cd8e6218a1a38da47ed00230f0580816ed13ba3303ac5deb911548908025",
		"message": "af82",
		"signature": "6291d657deec24024827e69c3abe01a30ce548a284743a445e3680d7db5ac3ac18ff9b538d16f290ae67f760984dc6594a7c15e9716ed28dc027beceea1ec40a",
	},
]


# ── SHA-512 ─────────────────────────────────────────────────────────────────

func test_sha512_known_answers() -> void:
	assert_eq(Ed25519.bytes_to_hex(Ed25519._sha512(PackedByteArray())), SHA512_EMPTY, "SHA-512 of empty input")
	assert_eq(Ed25519.bytes_to_hex(Ed25519._sha512("abc".to_utf8_buffer())), SHA512_ABC, "SHA-512 of abc")
	assert_eq(
		Ed25519.bytes_to_hex(Ed25519._sha512("The quick brown fox jumps over the lazy dog".to_utf8_buffer())),
		SHA512_FOX,
		"SHA-512 of the quick brown fox"
	)


func test_sha512_at_padding_boundaries() -> void:
	# 112 and 128 are the padding boundaries; 55/56 and 111/112 cross the
	# 64-bit length and 128-byte block edges. Expected values were generated
	# with an independent SHA-512 implementation over the same byte pattern.
	var expected := {
		0: "cf83e1357eefb8bdf1542850d66d8007d620e4050b5715dc83f4a921d36ce9ce47d0d13c5d85f2b0ff8318d2877eec2f63b931bd47417a81a538327af927da3e",
		1: "365d11a1dfe610b60efa996136d37ab8afd2715b8c6bc2850dc5e6005b702bb9f59b0f306ecb2c43ee44c429967d45843524eb2f7c16aab9bde142ee268b51c6",
		55: "330eb5e81b4d722cae1e0efbf883efb180c3e346d2b3b797dafc90409583ed35af65dc2d7974a353f0c21663e196b60d3ee5a2c70c50b7b3bccdb93a5dbce6bf",
		56: "1b5b63bfd5420b2dc480abce3dbdb3e19e5f9d4fabffba7764883937eaae878a55362c938c141712c44c3076c3fabb2c60814c2994c311c33049a8d6de2a8898",
		111: "da780d8338a8a920ceb6892cb4ecbb0cc0c66956269aadd5dd0f48790a00857bd975890f3b2955a317738cc7a770820c29f922ffbc22020f1909d594cc987d1b",
		112: "053182f7fa4e59f8636e415a77ed4fdc650f0a43834c9d35adf899599c3ab9c4153f02ff50bd01888060cd36a6fa12d9db242fc35164c80135613514186d5843",
		127: "a7a75593826fd37d4e60f6101eabb9f8ab1cf4d5319ebc805266d5da8deb5097de1a235fc5d9d3d73c50ac100ffc75089fb454674ab61232091bd19cbdc67396",
		128: "df007a08f3aaae47e0c92ef840ecd43645ae6098c819f2a4a66174ef1cd49e5c6dfccf0616895e570b7564af641de5863dff9f89c752913d30cf0ecf678e1635",
		129: "a10ea769b79831bca33e9efb29fc501ded6e9c88885d079acb76eecaa8ac58d68bdc7e00103053e1519352c0d064c87accc3d553a6039decc2c4f1e7667eef79",
		255: "ac1ecd53106f3dfba66b7b3fcac37652aad2aad2a291c354eaca03928e74853d53c0e8c7f2fa05025efdb262fd4b51103747d3dafd53e1feefc590bf2617b30a",
		1000: "b41d42e106eca6bf57123566b7ed1550c37d33af23afbfa8e302dfd44c988b3003a26b4140ef42f535e66ea424e7c4a31616307269e6d520a6508f726da23d0a",
	}
	for size in expected.keys():
		var message := PackedByteArray()
		message.resize(int(size))
		for index in range(int(size)):
			message[index] = (index * 31 + 7) & 0xFF
		assert_eq(
			Ed25519.bytes_to_hex(Ed25519._sha512(message)),
			str(expected[size]),
			"SHA-512 known answer at %d bytes" % int(size)
		)


# ── RFC 8032 ────────────────────────────────────────────────────────────────

func test_rfc8032_vectors_sign_and_verify() -> void:
	for vector in VECTORS:
		var name := str(vector.get("name", "vector"))
		var seed := Ed25519.hex_to_bytes(str(vector.get("seed", "")))
		var message := Ed25519.hex_to_bytes(str(vector.get("message", "")))
		var expected_public := str(vector.get("public", ""))
		var expected_signature := str(vector.get("signature", ""))

		assert_eq(seed.size(), 32, name + ": seed decodes")
		var public_key := Ed25519.public_key_from_seed(seed)
		assert_eq(Ed25519.bytes_to_hex(public_key), expected_public, name + ": public key")
		var signature := Ed25519.sign(message, seed)
		assert_eq(Ed25519.bytes_to_hex(signature), expected_signature, name + ": signature")
		assert_true(Ed25519.verify(signature, message, public_key), name + ": verifies")


func test_signature_rejects_tampering() -> void:
	var vector: Dictionary = VECTORS[1]
	var seed := Ed25519.hex_to_bytes(str(vector["seed"]))
	var message := Ed25519.hex_to_bytes(str(vector["message"]))
	var public_key := Ed25519.public_key_from_seed(seed)
	var signature := Ed25519.sign(message, seed)
	assert_true(Ed25519.verify(signature, message, public_key), "baseline verifies")

	var other_message := message.duplicate()
	other_message[0] = other_message[0] ^ 0x01
	assert_false(Ed25519.verify(signature, other_message, public_key), "changed message rejected")

	var other_r := signature.duplicate()
	other_r[0] = other_r[0] ^ 0x01
	assert_false(Ed25519.verify(other_r, message, public_key), "changed R rejected")

	var other_s := signature.duplicate()
	other_s[32] = other_s[32] ^ 0x01
	assert_false(Ed25519.verify(other_s, message, public_key), "changed S rejected")

	var other_public := Ed25519.public_key_from_seed(Ed25519.hex_to_bytes(str(VECTORS[0]["seed"])))
	assert_false(Ed25519.verify(signature, message, other_public), "wrong public key rejected")

	assert_false(Ed25519.verify(signature.slice(0, 63), message, public_key), "short signature rejected")
	assert_false(Ed25519.verify(signature, message, public_key.slice(0, 31)), "short public key rejected")


func test_rejects_noncanonical_scalars_and_low_order_keys() -> void:
	var vector: Dictionary = VECTORS[0]
	var signature := Ed25519.hex_to_bytes(str(vector["signature"]))
	var public_key := Ed25519.hex_to_bytes(str(vector["public"]))
	var message := PackedByteArray()
	assert_true(Ed25519.verify(signature, message, public_key), "baseline vector verifies")

	var scalar_l := Ed25519.hex_to_bytes(SCALAR_L_HEX)
	assert_eq(scalar_l.size(), 32, "L decodes")
	var at_l := _with_scalar(signature, scalar_l)
	assert_false(Ed25519.verify(at_l, message, public_key), "S == L is rejected")

	var s_plus_l := _add_little_endian(signature.slice(32, 64), scalar_l)
	var malleable := _with_scalar(signature, s_plus_l)
	assert_false(Ed25519.verify(malleable, message, public_key), "S + L is rejected")

	var zero_key := PackedByteArray()
	zero_key.resize(32)
	assert_false(Ed25519.verify(signature, message, zero_key), "identity-encoding public key rejected")

	var identity_key := PackedByteArray()
	identity_key.resize(32)
	identity_key[0] = 1
	assert_false(Ed25519.verify(signature, message, identity_key), "y = 1 low-order key rejected")

	var noncanonical := PackedByteArray()
	noncanonical.resize(32)
	noncanonical.fill(0xFF)
	noncanonical[31] = 0x7F
	assert_false(Ed25519.verify(signature, message, noncanonical), "y >= p rejected")


# ── HELPERS AND PACKAGE MESSAGE ─────────────────────────────────────────────

func test_hex_and_fingerprint_helpers() -> void:
	var vector: Dictionary = VECTORS[0]
	var seed := Ed25519.hex_to_bytes("  " + str(vector["seed"]).to_upper() + "  ")
	assert_eq(seed.size(), 32, "uppercase and surrounding whitespace accepted")
	assert_eq(Ed25519.bytes_to_hex(seed), str(vector["seed"]), "roundtrip lowercases")
	assert_true(Ed25519.hex_to_bytes("0").is_empty(), "odd-length hex rejected")
	assert_true(Ed25519.hex_to_bytes("zz").is_empty(), "non-hex characters rejected")
	assert_true(Ed25519.hex_to_bytes("0g").is_empty(), "mixed invalid hex rejected")

	var public_key := Ed25519.hex_to_bytes(str(vector["public"]))
	var expected_fingerprint := _native_sha256(public_key)
	assert_eq(Ed25519.fingerprint(public_key), expected_fingerprint, "fingerprint is SHA-256 of the public key")
	assert_eq(Ed25519.fingerprint(public_key).length(), 64, "fingerprint is 64 hex characters")
	assert_eq(Ed25519.fingerprint(public_key.slice(0, 31)), "", "fingerprint needs 32 key bytes")

	var first_seed := Ed25519.generate_seed()
	var second_seed := Ed25519.generate_seed()
	assert_eq(first_seed.size(), 32, "generated seed is 32 bytes")
	assert_ne(Ed25519.bytes_to_hex(first_seed), Ed25519.bytes_to_hex(second_seed), "seeds are not repeated")
	check(Ed25519.hex_to_bytes(Ed25519.bytes_to_hex(first_seed)) == first_seed, "generated seed roundtrips")

	assert_true(Ed25519.sign(PackedByteArray(), PackedByteArray()).is_empty(), "sign rejects a short seed")
	assert_true(Ed25519.public_key_from_seed(PackedByteArray()).is_empty(), "public key rejects a short seed")


func test_package_message_binds_digest_publisher_and_key() -> void:
	var message := Ed25519.package_message("AABB", "Publisher.One", "CCDD")
	var text := message.get_string_from_utf8()
	var lines := text.split("\n")
	assert_eq(lines.size(), 4, "message has four lines")
	assert_eq(str(lines[0]), Ed25519.DOMAIN, "domain separator first")
	assert_eq(str(lines[1]), "aabb", "digest lowercased")
	assert_eq(str(lines[2]), "Publisher.One", "publisher id preserved")
	assert_eq(str(lines[3]), "ccdd", "public key lowercased")

	var first := Ed25519.package_message("aa", "publisher.one", "bb")
	var second := Ed25519.package_message("aa", "publisher.two", "bb")
	assert_ne(Ed25519.bytes_to_hex(first), Ed25519.bytes_to_hex(second), "publisher id is part of the message")


func test_base_point_roundtrip() -> void:
	Ed25519._ensure_tables()
	var encoded := Ed25519.hex_to_bytes(Ed25519.BASE_POINT_BYTES)
	var point := Ed25519._point_decompress(encoded)
	check(!point.is_empty(), "base point decompresses")
	assert_eq(Ed25519.bytes_to_hex(Ed25519._point_compress(point)), Ed25519.BASE_POINT_BYTES, "base point roundtrips")

	var identity := Ed25519._point_identity()
	assert_true(Ed25519._point_is_identity(identity), "identity point detected")
	var identity_bytes := Ed25519._point_compress(identity)
	assert_eq(int(identity_bytes[0]), 1, "identity encodes as y = 1")
	for index in range(1, 32):
		assert_eq(int(identity_bytes[index]), 0, "identity padding byte %d" % index)


func _native_sha256(bytes: PackedByteArray) -> String:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(bytes)
	return context.finish().hex_encode().to_lower()


func _with_scalar(signature: PackedByteArray, scalar: PackedByteArray) -> PackedByteArray:
	var out := signature.duplicate()
	for index in range(32):
		out[32 + index] = scalar[index]
	return out


func _add_little_endian(left: PackedByteArray, right: PackedByteArray) -> PackedByteArray:
	var out := left.duplicate()
	var carry := 0
	for index in range(out.size()):
		var value := int(out[index]) + int(right[index]) + carry
		out[index] = value & 0xFF
		carry = value >> 8
	return out
