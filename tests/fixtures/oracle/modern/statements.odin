package modern

Value :: struct {
	slot: i64,
}

read :: proc(v: Value) -> i64 {
	unset: i64 = ---
	kind: typeid = i64
	allocator := context.allocator
	hex := 0xfe - 1
	half := 1.
	_ = kind
	_ = allocator
	_ = unset
	if v.slot > 0 do return v.slot
	return i64(hex) + i64(half)
}
