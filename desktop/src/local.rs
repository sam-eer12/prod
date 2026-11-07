//! Owner-only state and file operations shared by the daemon and installer.
use std::{
    fs::{self, File, OpenOptions},
    io,
    path::{Path, PathBuf},
};

pub fn home() -> io::Result<PathBuf> {
    let variable = if cfg!(windows) { "USERPROFILE" } else { "HOME" };
    std::env::var_os(variable)
        .map(PathBuf::from)
        .filter(|p| p.is_absolute())
        .ok_or_else(|| io::Error::other(format!("{variable} must name an absolute home directory")))
}

pub fn state_dir(override_path: Option<PathBuf>) -> io::Result<PathBuf> {
    let path = if let Some(path) = override_path {
        path
    } else if cfg!(windows) {
        PathBuf::from(
            std::env::var_os("LOCALAPPDATA")
                .ok_or_else(|| io::Error::other("LOCALAPPDATA is unavailable"))?,
        )
        .join("PadLink/state")
    } else {
        home()?.join(".local/state/padlink")
    };
    if !path.is_absolute() {
        return Err(io::Error::other("state directory must be absolute"));
    }
    private_dir(&path)?;
    fs::canonicalize(path)
}

pub fn private_dir(path: &Path) -> io::Result<()> {
    match fs::symlink_metadata(path) {
        Ok(metadata) => {
            if !metadata.is_dir() || metadata.file_type().is_symlink() {
                return Err(io::Error::other(format!(
                    "{} must be a real directory",
                    path.display()
                )));
            }
            check_owner(&metadata)?;
        }
        Err(error) if error.kind() == io::ErrorKind::NotFound => {
            if let Some(parent) = path.parent() {
                fs::create_dir_all(parent)?;
            }
            let builder = fs::DirBuilder::new();
            #[cfg(unix)]
            let builder = {
                use std::os::unix::fs::DirBuilderExt;
                let mut builder = builder;
                builder.mode(0o700);
                builder
            };
            match builder.create(path) {
                Ok(()) => {}
                Err(e) if e.kind() == io::ErrorKind::AlreadyExists => {}
                Err(e) => return Err(e),
            }
            return private_dir(path);
        }
        Err(error) => return Err(error),
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(path, fs::Permissions::from_mode(0o700))?;
    }
    #[cfg(windows)]
    secure_windows_dir(path)?;
    Ok(())
}

pub fn check_owner(metadata: &fs::Metadata) -> io::Result<()> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        // SAFETY: geteuid has no arguments and no ownership requirements.
        if metadata.uid() != unsafe { libc::geteuid() } {
            return Err(io::Error::new(
                io::ErrorKind::PermissionDenied,
                "file is owned by another user",
            ));
        }
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        if metadata.file_attributes() & 0x400 != 0 {
            return Err(io::Error::other(
                "reparse points are not allowed for PadLink state",
            ));
        }
    }
    Ok(())
}

pub fn open_private(path: &Path, truncate: bool) -> io::Result<File> {
    if let Ok(metadata) = fs::symlink_metadata(path) {
        if !metadata.is_file() || metadata.file_type().is_symlink() {
            return Err(io::Error::other("refusing a non-regular state file"));
        }
        check_owner(&metadata)?;
    }
    let mut options = OpenOptions::new();
    options
        .read(true)
        .write(true)
        .create(true)
        .truncate(truncate);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600).custom_flags(libc::O_NOFOLLOW);
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::OpenOptionsExt;
        options.custom_flags(0x00200000);
    }
    let file = options.open(path)?;
    check_owner(&file.metadata()?)?;
    Ok(file)
}

pub fn random_suffix() -> io::Result<String> {
    let mut bytes = [0_u8; 12];
    getrandom::fill(&mut bytes).map_err(io::Error::other)?;
    Ok(bytes.iter().map(|b| format!("{b:02x}")).collect())
}

pub fn atomic_write(path: &Path, bytes: &[u8]) -> io::Result<()> {
    let parent = path
        .parent()
        .ok_or_else(|| io::Error::other("missing parent"))?;
    let temporary = parent.join(format!(".padlink-{}", random_suffix()?));
    let result = (|| {
        use std::io::Write;
        let mut file = open_private(&temporary, false)?;
        file.write_all(bytes)?;
        file.sync_all()?;
        replace(&temporary, path)
    })();
    if temporary.exists() {
        let _ = fs::remove_file(&temporary);
    }
    result
}

pub fn replace(source: &Path, destination: &Path) -> io::Result<()> {
    #[cfg(unix)]
    {
        fs::rename(source, destination)
    }
    #[cfg(windows)]
    {
        use std::os::windows::ffi::OsStrExt;
        use windows_sys::Win32::Storage::FileSystem::{
            MOVEFILE_REPLACE_EXISTING, MOVEFILE_WRITE_THROUGH, MoveFileExW,
        };
        let source: Vec<_> = source.as_os_str().encode_wide().chain(Some(0)).collect();
        let destination: Vec<_> = destination
            .as_os_str()
            .encode_wide()
            .chain(Some(0))
            .collect();
        // SAFETY: both pointers refer to live, NUL-terminated strings.
        if unsafe {
            MoveFileExW(
                source.as_ptr(),
                destination.as_ptr(),
                MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH,
            )
        } == 0
        {
            Err(io::Error::last_os_error())
        } else {
            Ok(())
        }
    }
}

#[cfg(windows)]
pub fn user_sid() -> io::Result<String> {
    use windows_sys::Win32::{
        Foundation::{CloseHandle, LocalFree},
        Security::{
            Authorization::ConvertSidToStringSidW, GetTokenInformation, TOKEN_QUERY, TOKEN_USER,
            TokenUser,
        },
        System::Threading::{GetCurrentProcess, OpenProcessToken},
    };
    // SAFETY: all output buffers are live and aligned; handles and allocated SID text are released.
    unsafe {
        let mut token = std::ptr::null_mut();
        if OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut token) == 0 {
            return Err(io::Error::last_os_error());
        }
        let mut buffer = [0_u64; 512];
        let mut length = 0;
        let ok = GetTokenInformation(
            token,
            TokenUser,
            buffer.as_mut_ptr().cast(),
            std::mem::size_of_val(&buffer) as u32,
            &mut length,
        );
        if ok == 0 {
            CloseHandle(token);
            return Err(io::Error::last_os_error());
        }
        let user = &*buffer.as_ptr().cast::<TOKEN_USER>();
        let mut text = std::ptr::null_mut();
        let ok = ConvertSidToStringSidW(user.User.Sid, &mut text);
        CloseHandle(token);
        if ok == 0 {
            return Err(io::Error::last_os_error());
        }
        let mut count = 0;
        while *text.add(count) != 0 {
            count += 1;
        }
        let result = String::from_utf16_lossy(std::slice::from_raw_parts(text, count));
        LocalFree(text.cast());
        Ok(result)
    }
}

#[cfg(windows)]
fn secure_windows_dir(path: &Path) -> io::Result<()> {
    use std::os::windows::ffi::OsStrExt;
    use windows_sys::Win32::{
        Foundation::LocalFree,
        Security::{
            Authorization::ConvertStringSecurityDescriptorToSecurityDescriptorW,
            DACL_SECURITY_INFORMATION, PROTECTED_DACL_SECURITY_INFORMATION, SetFileSecurityW,
        },
    };
    let sid = user_sid()?;
    let path: Vec<_> = path.as_os_str().encode_wide().chain(Some(0)).collect();
    let sddl: Vec<_> = format!("D:P(A;OICI;FA;;;{sid})(A;OICI;FA;;;SY)")
        .encode_utf16()
        .chain(Some(0))
        .collect();
    // SAFETY: strings are live and NUL-terminated; the returned security descriptor is released.
    unsafe {
        let mut descriptor = std::ptr::null_mut();
        if ConvertStringSecurityDescriptorToSecurityDescriptorW(
            sddl.as_ptr(),
            1,
            &mut descriptor,
            std::ptr::null_mut(),
        ) == 0
        {
            return Err(io::Error::last_os_error());
        }
        let result = SetFileSecurityW(
            path.as_ptr(),
            DACL_SECURITY_INFORMATION | PROTECTED_DACL_SECURITY_INFORMATION,
            descriptor,
        );
        let error = io::Error::last_os_error();
        LocalFree(descriptor);
        if result == 0 { Err(error) } else { Ok(()) }
    }
}

#[cfg(windows)]
pub fn process_sid(pid: u32) -> io::Result<String> {
    use windows_sys::Win32::{
        Foundation::{CloseHandle, LocalFree},
        Security::{
            Authorization::ConvertSidToStringSidW, GetTokenInformation, TOKEN_QUERY, TOKEN_USER,
            TokenUser,
        },
        System::Threading::{OpenProcess, OpenProcessToken, PROCESS_QUERY_LIMITED_INFORMATION},
    };
    // SAFETY: handles and SID allocation are released on each branch; the token buffer is aligned.
    unsafe {
        let process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid);
        if process.is_null() {
            return Err(io::Error::last_os_error());
        }
        let mut token = std::ptr::null_mut();
        let opened = OpenProcessToken(process, TOKEN_QUERY, &mut token);
        CloseHandle(process);
        if opened == 0 {
            return Err(io::Error::last_os_error());
        }
        let mut buffer = [0_u64; 512];
        let mut length = 0;
        let ok = GetTokenInformation(
            token,
            TokenUser,
            buffer.as_mut_ptr().cast(),
            std::mem::size_of_val(&buffer) as u32,
            &mut length,
        );
        if ok == 0 {
            CloseHandle(token);
            return Err(io::Error::last_os_error());
        }
        let user = &*buffer.as_ptr().cast::<TOKEN_USER>();
        let mut text = std::ptr::null_mut();
        let ok = ConvertSidToStringSidW(user.User.Sid, &mut text);
        CloseHandle(token);
        if ok == 0 {
            return Err(io::Error::last_os_error());
        }
        let mut count = 0;
        while *text.add(count) != 0 {
            count += 1;
        }
        let result = String::from_utf16_lossy(std::slice::from_raw_parts(text, count));
        LocalFree(text.cast());
        Ok(result)
    }
}
