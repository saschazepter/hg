fn main() -> Result<(), Box<dyn std::error::Error>> {
    let fds = protox::compile(["proto/vfs.proto"], ["proto"])?;
    tonic_build::compile_fds(fds)?;
    println!("cargo::rerun-if-changed=proto/vfs.proto");
    Ok(())
}
