use std::env;
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Seek, SeekFrom, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::os::unix::process::ExitStatusExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, ExitCode, ExitStatus, Stdio};
use std::thread;
use std::time::{Duration, Instant};

// Match harness.py's native_hook socket deadline.
const HOOK_TIMEOUT: Duration = Duration::from_secs(30);
const POLL_INTERVAL: Duration = Duration::from_millis(10);

struct OwnedChild {
    child: Child,
    status: Option<ExitStatus>,
}

impl OwnedChild {
    fn new(child: Child) -> Self {
        Self {
            child,
            status: None,
        }
    }

    fn poll(&mut self) -> io::Result<Option<ExitStatus>> {
        if self.status.is_none() {
            self.status = self.child.try_wait()?;
        }
        Ok(self.status)
    }
}

impl Drop for OwnedChild {
    fn drop(&mut self) {
        if self.status.is_some() {
            return;
        }
        if let Err(error) = self.child.kill() {
            // A child can exit between its last poll and kill; wait still reaps it.
            if error.kind() != io::ErrorKind::InvalidInput {
                eprintln!("harness-launcher: operation=kill-child error={error}");
            }
        }
        if let Err(error) = self.child.wait() {
            eprintln!("harness-launcher: operation=reap-child error={error}");
        }
    }
}

struct Socket {
    listener: UnixListener,
    path: PathBuf,
}

impl Socket {
    fn bind(root: &Path) -> io::Result<Self> {
        let path = root.join(format!("hook-{}.sock", std::process::id()));
        let listener = UnixListener::bind(&path)?;
        let socket = Self { listener, path };
        socket.listener.set_nonblocking(true)?;
        Ok(socket)
    }

    fn cleanup(&self) -> io::Result<()> {
        fs::remove_file(&self.path)
    }
}

impl Drop for Socket {
    fn drop(&mut self) {
        if let Err(error) = self.cleanup() {
            if error.kind() != io::ErrorKind::NotFound {
                eprintln!("harness-launcher: operation=remove-socket error={error}");
            }
        }
    }
}

struct Capture {
    file: File,
    path: PathBuf,
}

impl Capture {
    fn create(root: &Path, name: &str) -> io::Result<Self> {
        let path = root.join(format!("hook-{}.{name}", std::process::id()));
        let file = OpenOptions::new()
            .read(true)
            .write(true)
            .create_new(true)
            .open(&path)?;
        Ok(Self { file, path })
    }

    fn bytes(&mut self) -> io::Result<Vec<u8>> {
        self.file.seek(SeekFrom::Start(0))?;
        let mut bytes = Vec::new();
        self.file.read_to_end(&mut bytes)?;
        Ok(bytes)
    }

    fn cleanup(&self) -> io::Result<()> {
        fs::remove_file(&self.path)
    }
}

impl Drop for Capture {
    fn drop(&mut self) {
        if let Err(error) = self.cleanup() {
            if error.kind() != io::ErrorKind::NotFound {
                eprintln!("harness-launcher: operation=remove-capture error={error}");
            }
        }
    }
}

fn read_u32(stream: &mut UnixStream) -> io::Result<u32> {
    let mut bytes = [0; 4];
    stream.read_exact(&mut bytes)?;
    Ok(u32::from_be_bytes(bytes))
}

fn read_bytes(stream: &mut UnixStream) -> io::Result<Vec<u8>> {
    let len = read_u32(stream)? as usize;
    let mut bytes = vec![0; len];
    stream.read_exact(&mut bytes)?;
    Ok(bytes)
}

fn write_bytes(stream: &mut UnixStream, bytes: &[u8]) -> io::Result<()> {
    let len = u32::try_from(bytes.len())
        .map_err(|_| io::Error::other("callback output exceeds protocol length"))?;
    stream.write_all(&len.to_be_bytes())?;
    stream.write_all(bytes)
}

fn status_code(status: ExitStatus) -> io::Result<i32> {
    match (status.code(), status.signal()) {
        (Some(code), _) => Ok(code),
        (None, Some(signal)) => Ok(128 + signal),
        (None, None) => Err(io::Error::other("child has no exit code or signal")),
    }
}

fn callback(mut stream: UnixStream, root: &Path, simulator: &mut OwnedChild) -> io::Result<()> {
    stream.set_read_timeout(Some(HOOK_TIMEOUT))?;
    stream.set_write_timeout(Some(HOOK_TIMEOUT))?;
    let argc = read_u32(&mut stream)?;
    let mut args = Vec::new();
    for _ in 0..argc {
        let arg = String::from_utf8(read_bytes(&mut stream)?)
            .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;
        args.push(arg);
    }
    let input = read_bytes(&mut stream)?;
    let mut args = args.into_iter();
    let program = args
        .next()
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "callback has no program"))?;

    // Files avoid pipe backpressure and outliving reader threads when a hook fails.
    let mut stdin = Capture::create(root, "stdin")?;
    let mut stdout = Capture::create(root, "stdout")?;
    let mut stderr = Capture::create(root, "stderr")?;
    stdin.file.write_all(&input)?;
    stdin.file.seek(SeekFrom::Start(0))?;
    // The callback must be this native CLI's child, with its cwd, environment and
    // process group: Python is a sibling, never a hook ancestor.
    let mut child = OwnedChild::new(
        Command::new(program)
            .args(args)
            .stdin(Stdio::from(stdin.file.try_clone()?))
            .stdout(Stdio::from(stdout.file.try_clone()?))
            .stderr(Stdio::from(stderr.file.try_clone()?))
            .spawn()?,
    );
    let deadline = Instant::now() + HOOK_TIMEOUT;
    let status = loop {
        if let Some(status) = child.poll()? {
            break status;
        }
        if simulator.poll()?.is_some() {
            return Err(io::Error::other("simulator exited during callback"));
        }
        if Instant::now() >= deadline {
            return Err(io::Error::new(io::ErrorKind::TimedOut, "callback deadline"));
        }
        thread::sleep(POLL_INTERVAL);
    };
    let output = stdout.bytes()?;
    let errors = stderr.bytes()?;
    stdin.cleanup()?;
    stdout.cleanup()?;
    stderr.cleanup()?;
    stream.write_all(&status_code(status)?.to_be_bytes())?;
    write_bytes(&mut stream, &output)?;
    write_bytes(&mut stream, &errors)
}

fn serve(socket: &Socket, root: &Path, simulator: &mut OwnedChild) -> io::Result<ExitStatus> {
    loop {
        if let Some(status) = simulator.poll()? {
            return Ok(status);
        }
        match socket.listener.accept() {
            Ok((stream, _)) => callback(stream, root, simulator)?,
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                thread::sleep(POLL_INTERVAL);
            }
            Err(error) => return Err(error),
        }
    }
}

fn run() -> io::Result<ExitCode> {
    let mut args = env::args_os();
    let executable = args
        .next()
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "missing argv[0]"))?;
    let harness = Path::new(&executable)
        .file_name()
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "missing harness name"))?;

    let root = Path::new(env!("JARVIS_TEST_NATIVE_ROOT"));
    let socket = Socket::bind(root)?;
    // Preserve the caller's environment, terminal streams and process group.
    let mut child = OwnedChild::new(
        Command::new("python3")
            .arg(".fixture-harness.py")
            .args(args)
            .env("JARVIS_TEST_HARNESS", harness)
            .env("JARVIS_TEST_HOOK_SOCKET", &socket.path)
            .spawn()?,
    );
    let code = status_code(serve(&socket, root, &mut child)?)?;
    socket.cleanup()?;
    let code = u8::try_from(code)
        .map_err(|_| io::Error::other("child exit status does not fit an exit code"))?;
    Ok(ExitCode::from(code))
}

fn main() -> ExitCode {
    match run() {
        Ok(code) => code,
        Err(error) => {
            eprintln!("harness-launcher: operation=run error={error}");
            ExitCode::FAILURE
        }
    }
}
