use std::collections::HashMap;
use std::io::{self, Read, Write};
use std::os::fd::{FromRawFd, RawFd};

use log::info;

/// Represents one shell session (one ADB stream)
pub struct ShellSession {
    pub local_id: u32,
    pub remote_id: u32,
    pub v2: bool,
    pub master_fd: RawFd,
    /// Separate stderr pipe read-end (only for v2 single-command mode)
    pub stderr_fd: Option<RawFd>,
    pub child_pid: libc::pid_t,
    pub finished: bool,
}

fn set_nonblocking(fd: RawFd) {
    unsafe {
        let flags = libc::fcntl(fd, libc::F_GETFL);
        libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK);
    }
}

impl ShellSession {
    /// Spawn a new shell session.
    /// If `command` is Some, run that command; otherwise interactive shell.
    pub fn new(
        local_id: u32,
        remote_id: u32,
        v2: bool,
        command: Option<&str>,
    ) -> io::Result<Self> {
        let mut master: RawFd = -1;
        let mut slave: RawFd = -1;

        // openpty
        let ret = unsafe { libc::openpty(&mut master, &mut slave, std::ptr::null_mut(), std::ptr::null_mut(), std::ptr::null_mut()) };
        if ret != 0 {
            return Err(io::Error::last_os_error());
        }

        // For v2 single-command mode, create a separate stderr pipe
        let mut stderr_pipe = [0 as RawFd; 2];
        let has_stderr_pipe = v2 && command.is_some();
        if has_stderr_pipe {
            if unsafe { libc::pipe(stderr_pipe.as_mut_ptr()) } != 0 {
                unsafe { libc::close(master); libc::close(slave); }
                return Err(io::Error::last_os_error());
            }
        }

        let pid = unsafe { libc::fork() };
        if pid < 0 {
            unsafe { libc::close(master); libc::close(slave); }
            return Err(io::Error::last_os_error());
        }

        if pid == 0 {
            // Child process
            unsafe {
                libc::close(master);
                libc::setsid();
                libc::ioctl(slave, libc::TIOCSCTTY as _, 0);

                libc::dup2(slave, 0);
                libc::dup2(slave, 1);

                if has_stderr_pipe {
                    libc::dup2(stderr_pipe[1], 2);
                    libc::close(stderr_pipe[0]);
                    libc::close(stderr_pipe[1]);
                } else {
                    libc::dup2(slave, 2);
                }

                if slave > 2 {
                    libc::close(slave);
                }

                // Set environment
                libc::setenv(b"TERM\0".as_ptr() as _, b"xterm-256color\0".as_ptr() as _, 1);
                libc::setenv(b"HOME\0".as_ptr() as _, b"/root\0".as_ptr() as _, 1);
                libc::setenv(b"PATH\0".as_ptr() as _, b"/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\0".as_ptr() as _, 1);
                libc::setenv(b"SHELL\0".as_ptr() as _, b"/bin/sh\0".as_ptr() as _, 1);
                libc::setenv(b"HOSTNAME\0".as_ptr() as _, b"localhost\0".as_ptr() as _, 1);

                if let Some(cmd) = command {
                    let cmd_c = std::ffi::CString::new(cmd).unwrap();
                    let shell = b"/bin/sh\0".as_ptr() as *const libc::c_char;
                    let dash_c = b"-c\0".as_ptr() as *const libc::c_char;
                    let args = [shell, dash_c, cmd_c.as_ptr(), std::ptr::null()];
                    libc::execv(shell, args.as_ptr());
                } else {
                    let shell = b"/bin/sh\0".as_ptr() as *const libc::c_char;
                    let login_name = b"-sh\0".as_ptr() as *const libc::c_char;
                    let args = [login_name, std::ptr::null()];
                    libc::execv(shell, args.as_ptr());
                }
                libc::_exit(127);
            }
        }

        // Parent
        unsafe {
            libc::close(slave);
            if has_stderr_pipe {
                libc::close(stderr_pipe[1]);
            }
        }

        set_nonblocking(master);
        let stderr_fd = if has_stderr_pipe {
            set_nonblocking(stderr_pipe[0]);
            Some(stderr_pipe[0])
        } else {
            None
        };

        info!(
            "Spawned shell session: local_id={}, remote_id={}, v2={}, pid={}, cmd={:?}",
            local_id, remote_id, v2, pid, command
        );

        Ok(ShellSession {
            local_id,
            remote_id,
            v2,
            master_fd: master,
            stderr_fd,
            child_pid: pid,
            finished: false,
        })
    }

    /// Write data to shell's stdin
    pub fn write_stdin(&self, data: &[u8]) -> io::Result<()> {
        let mut file = unsafe { std::fs::File::from_raw_fd(self.master_fd) };
        let result = file.write_all(data);
        std::mem::forget(file); // Don't close the fd
        result
    }

    /// Read available data from shell's stdout (PTY master)
    pub fn read_stdout(&self) -> io::Result<Option<Vec<u8>>> {
        read_nonblocking(self.master_fd)
    }

    /// Read available data from stderr pipe (only for v2 single-command)
    pub fn read_stderr(&self) -> io::Result<Option<Vec<u8>>> {
        if let Some(fd) = self.stderr_fd {
            read_nonblocking(fd)
        } else {
            Ok(None)
        }
    }

    /// Check if child has exited. Returns exit code if so.
    pub fn try_wait(&mut self) -> Option<u8> {
        if self.finished {
            return Some(0);
        }
        let mut status: libc::c_int = 0;
        let ret = unsafe { libc::waitpid(self.child_pid, &mut status, libc::WNOHANG) };
        if ret == self.child_pid {
            self.finished = true;
            if libc::WIFEXITED(status) {
                Some(libc::WEXITSTATUS(status) as u8)
            } else if libc::WIFSIGNALED(status) {
                Some(128u8.wrapping_add(libc::WTERMSIG(status) as u8))
            } else {
                Some(1)
            }
        } else {
            None
        }
    }

    pub fn cleanup(&mut self) {
        unsafe {
            libc::close(self.master_fd);
            if let Some(fd) = self.stderr_fd.take() {
                libc::close(fd);
            }
            libc::kill(self.child_pid, libc::SIGTERM);
            libc::waitpid(self.child_pid, std::ptr::null_mut(), libc::WNOHANG);
        }
    }
}

fn read_nonblocking(fd: RawFd) -> io::Result<Option<Vec<u8>>> {
    let mut buf = [0u8; 8192];
    let mut file = unsafe { std::fs::File::from_raw_fd(fd) };
    let result = file.read(&mut buf);
    std::mem::forget(file);
    match result {
        Ok(0) => Ok(None),
        Ok(n) => Ok(Some(buf[..n].to_vec())),
        Err(e) if e.kind() == io::ErrorKind::WouldBlock => Ok(None),
        Err(e) => Err(e),
    }
}

impl Drop for ShellSession {
    fn drop(&mut self) {
        self.cleanup();
    }
}

/// Manages all active shell sessions
pub struct SessionManager {
    sessions: HashMap<u32, ShellSession>,
    pub sync_sessions: HashMap<u32, crate::sync::SyncSession>,
    next_local_id: u32,
}

impl SessionManager {
    pub fn new() -> Self {
        Self {
            sessions: HashMap::new(),
            sync_sessions: HashMap::new(),
            next_local_id: 1,
        }
    }

    pub fn alloc_local_id(&mut self) -> u32 {
        let id = self.next_local_id;
        self.next_local_id += 1;
        id
    }

    pub fn insert(&mut self, session: ShellSession) {
        self.sessions.insert(session.local_id, session);
    }

    pub fn get(&self, local_id: u32) -> Option<&ShellSession> {
        self.sessions.get(&local_id)
    }

    pub fn get_mut(&mut self, local_id: u32) -> Option<&mut ShellSession> {
        self.sessions.get_mut(&local_id)
    }

    pub fn remove(&mut self, local_id: u32) -> Option<ShellSession> {
        self.sessions.remove(&local_id)
    }

    /// Get all active session local_ids
    pub fn active_ids(&self) -> Vec<u32> {
        self.sessions.keys().copied().collect()
    }

    pub fn clear(&mut self) {
        self.sessions.clear();
        self.sync_sessions.clear();
        self.next_local_id = 1;
    }
}
