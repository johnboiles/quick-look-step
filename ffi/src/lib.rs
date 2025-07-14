use std::ffi::CStr;
use std::os::raw::c_char;
use std::panic::{catch_unwind, AssertUnwindSafe};

// Triangulation + STEP parsing crates
use triangulate::triangulate::triangulate;
use step::step_file::StepFile;

// Internal helper to load a STEP file from disk and convert to flat arrays
fn load_step_mesh(path: &str) -> Result<(Vec<f32>, Vec<f32>, Vec<u32>), Box<dyn std::error::Error>> {
    // Read file into memory and parse STEP entities
    let data = std::fs::read(path)?;
    let flat = StepFile::strip_flatten(&data);
    let entities = StepFile::parse(&flat);

    // Triangulate – we only care about the Mesh, ignore the Stats for now.
    let (mesh, _stats) = triangulate(&entities);

    // Convert Mesh { verts, triangles } into separate flat buffers
    let mut vertices = Vec::with_capacity(mesh.verts.len() * 3);
    let mut normals  = Vec::with_capacity(mesh.verts.len() * 3);
    for v in &mesh.verts {
        vertices.push(v.pos.x as f32);
        vertices.push(v.pos.y as f32);
        vertices.push(v.pos.z as f32);

        normals.push(v.norm.x as f32);
        normals.push(v.norm.y as f32);
        normals.push(v.norm.z as f32);
    }

    let mut indices = Vec::with_capacity(mesh.triangles.len() * 3);
    for t in &mesh.triangles {
        for &i in t.verts.iter() {
            indices.push(i);
        }
    }

    Ok((vertices, normals, indices))
}

#[repr(C)]
pub struct MeshSlice<'a> {
    pub verts: *const f32,
    pub normals: *const f32,
    pub tris: *const u32,
    pub vert_count: usize,
    pub tri_count: usize,
    _phantom: std::marker::PhantomData<&'a ()>,
}

#[no_mangle]
pub extern "C" fn foxtrot_load_step(
    path: *const c_char,
    out_mesh: *mut MeshSlice<'_>,
) -> bool {
    // Wrap the whole body in a panic catcher so that Rust panics don't unwind
    // across the FFI boundary (which would abort the process). Any panic or
    // normal error will result in `false` being returned to the caller.
    let result = catch_unwind(AssertUnwindSafe(|| {
        // SAFETY: caller passes a valid, NUL-terminated UTF-8 C string.
        let c_str = unsafe { CStr::from_ptr(path) };
        let Ok(path) = c_str.to_str() else { return false };

        match load_step_mesh(path) {
            Ok((vertices, normals, indices)) => {
                let slice = MeshSlice {
                    verts:       vertices.as_ptr(),
                    normals:     normals.as_ptr(),
                    tris:        indices.as_ptr(),
                    vert_count:  vertices.len() / 3,
                    tri_count:   indices.len()  / 3,
                    _phantom:    std::marker::PhantomData,
                };
                unsafe { *out_mesh = slice };

                // Hand ownership to the caller (SceneKit). Prevent Rust drop.
                std::mem::forget(vertices);
                std::mem::forget(normals);
                std::mem::forget(indices);
                true
            }
            Err(_) => false,
        }
    }));

    match result {
        Ok(v) => v,
        Err(_) => false, // a panic occurred
    }
}

/// Caller must invoke this when the mesh is no longer needed.
#[no_mangle]
pub extern "C" fn foxtrot_free_mesh(slice: MeshSlice<'_>) {
    unsafe {
        drop(Vec::from_raw_parts(
            slice.verts as *mut f32,
            slice.vert_count * 3,
            slice.vert_count * 3,
        ));
        drop(Vec::from_raw_parts(
            slice.normals as *mut f32,
            slice.vert_count * 3,
            slice.vert_count * 3,
        ));
        drop(Vec::from_raw_parts(
            slice.tris as *mut u32,
            slice.tri_count * 3,
            slice.tri_count * 3,
        ));
    }
}
