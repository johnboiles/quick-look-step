.PHONY: foxtrot.h
foxtrot.h:
	cbindgen ffi -o QuickLookStep/foxtrot.h -l c

.PHONY: libfoxtrot_universal.a
libfoxtrot_universal.a:
	cargo build --release --target aarch64-apple-darwin -p foxtrot_ffi
	cargo build --release --target x86_64-apple-darwin -p foxtrot_ffi
	lipo -create \
    target/x86_64-apple-darwin/release/libfoxtrot_ffi.a \
    target/aarch64-apple-darwin/release/libfoxtrot_ffi.a \
    -output QuickLookStep/libfoxtrot_universal.a

.PHONY: test-foxtrot
test-foxtrot:
	cd foxtrot && cargo run --release -- examples/cube_hole.step
