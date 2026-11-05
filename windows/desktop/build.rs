fn main() {
    slint_build::compile_with_config("ui/app.slint", slint_build::CompilerConfiguration::new().with_style("fluent".into())).unwrap();
    #[cfg(windows)]
    { let mut r = winresource::WindowsResource::new(); r.set_icon("../app/icons/icon.ico"); let _ = r.compile(); }
}
