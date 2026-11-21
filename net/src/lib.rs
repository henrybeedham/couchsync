//! A tiny C interface over iroh, so the Swift app can join a party by invite
//! code with no shared network. An invite code is the iroh endpoint id of the
//! party: every party gets a fresh endpoint with a new random key, so every
//! party has a new code, and the code stops working when the party ends.
//! iroh finds the host through n0's discovery service, punches through both
//! routers when it can, and falls back to n0's public relays when it can't.
//! Traffic is end-to-end encrypted either way.
//!
//! Each connection carries one bidirectional QUIC stream of raw bytes; the app
//! does its own message framing on top. Everything reports back through one
//! callback, called on iroh's threads.

use std::{
    collections::HashMap,
    ffi::{c_char, c_void, CStr},
    str::FromStr,
    sync::{
        atomic::{AtomicU64, Ordering},
        Mutex, OnceLock,
    },
};

use iroh::{
    endpoint::{presets, Connection, QuicTransportConfig, RecvStream, SendStream, VarInt},
    Endpoint, EndpointId, SecretKey,
};
use tokio::{runtime::Runtime, sync::mpsc};

const ALPN: &[u8] = b"couchsync/party/1";

/// Someone connected to us. `data` is their endpoint id.
const EVENT_INCOMING: i32 = 1;
/// A connection we started is ready to use.
const EVENT_READY: i32 = 2;
/// Bytes arrived.
const EVENT_DATA: i32 = 3;
/// The connection ended. `data` says why.
const EVENT_CLOSED: i32 = 4;

pub type EventFn =
    extern "C" fn(ctx: *mut c_void, conn: u64, kind: i32, data: *const u8, len: usize);

struct Callback {
    f: EventFn,
    ctx: usize,
}

enum Command {
    Send(Vec<u8>),
    Close,
}

struct Net {
    rt: Runtime,
    /// For joining parties. It has its own throwaway key and takes no connections.
    guest: tokio::sync::OnceCell<Endpoint>,
    /// The current party's endpoint, while hosting.
    host: Mutex<Option<Endpoint>>,
    /// Bumped on every host start and stop, so a slow bind for a party that
    /// already ended doesn't come back to life.
    host_generation: AtomicU64,
    callback: Callback,
    conns: Mutex<HashMap<u64, mpsc::UnboundedSender<Command>>>,
    next_id: AtomicU64,
}

static NET: OnceLock<Net> = OnceLock::new();

fn net() -> Option<&'static Net> {
    NET.get()
}

async fn bind(secret: SecretKey, alpns: Vec<Vec<u8>>) -> Result<Endpoint, String> {
    // Notice a host that vanished (quit, slept, lost Wi-Fi) in 15 seconds,
    // about as fast as the TCP path. iroh sends keep-alives every 5, so a
    // quiet party isn't mistaken for a dead one.
    let transport = QuicTransportConfig::builder()
        .max_idle_timeout(Some(VarInt::from_u32(15_000).into()))
        .build();
    Endpoint::builder(presets::N0)
        .secret_key(secret)
        .transport_config(transport)
        .alpns(alpns)
        .bind()
        .await
        .map_err(|e| e.to_string())
}

impl Net {
    fn emit(&self, conn: u64, kind: i32, data: &[u8]) {
        (self.callback.f)(self.callback.ctx as *mut c_void, conn, kind, data.as_ptr(), data.len());
    }

    async fn guest(&'static self) -> Result<&'static Endpoint, String> {
        self.guest
            .get_or_try_init(|| bind(SecretKey::generate(), vec![]))
            .await
    }

    async fn host(&'static self, secret: SecretKey, generation: u64) {
        let endpoint = match bind(secret, vec![ALPN.to_vec()]).await {
            Ok(endpoint) => endpoint,
            Err(_) => return,
        };
        {
            let mut slot = self.host.lock().unwrap();
            if self.host_generation.load(Ordering::SeqCst) != generation {
                drop(slot);
                endpoint.close().await;
                return;
            }
            *slot = Some(endpoint.clone());
        }
        while let Some(incoming) = endpoint.accept().await {
            self.rt.spawn(async move {
                let Ok(accepting) = incoming.accept() else { return };
                let Ok(conn) = accepting.await else { return };
                // The guest opens the stream and speaks first.
                let Ok((send, recv)) = conn.accept_bi().await else { return };
                let (id, rx) = self.register();
                self.emit(id, EVENT_INCOMING, conn.remote_id().to_string().as_bytes());
                self.pump(id, conn, send, recv, rx).await;
            });
        }
    }

    fn register(&self) -> (u64, mpsc::UnboundedReceiver<Command>) {
        let id = self.next_id.fetch_add(1, Ordering::SeqCst);
        let (tx, rx) = mpsc::unbounded_channel();
        self.conns.lock().unwrap().insert(id, tx);
        (id, rx)
    }

    async fn connect(&'static self, id: u64, remote: EndpointId, mut rx: mpsc::UnboundedReceiver<Command>) {
        let attempt = async {
            let endpoint = self.guest().await?;
            let conn = endpoint.connect(remote, ALPN).await.map_err(|e| e.to_string())?;
            let (send, recv) = conn.open_bi().await.map_err(|e| e.to_string())?;
            Ok::<_, String>((conn, send, recv))
        };
        // Give up straight away if the app cancels while we're still dialing.
        let cancelled = async {
            while let Some(command) = rx.recv().await {
                if let Command::Close = command {
                    return;
                }
            }
        };
        let result = tokio::select! {
            result = attempt => result,
            _ = cancelled => Err("cancelled".to_string()),
        };
        match result {
            Ok((conn, send, recv)) => {
                self.emit(id, EVENT_READY, &[]);
                self.pump(id, conn, send, recv, rx).await;
            }
            Err(reason) => {
                self.conns.lock().unwrap().remove(&id);
                self.emit(id, EVENT_CLOSED, reason.as_bytes());
            }
        }
    }

    /// Moves bytes both ways until either side stops.
    async fn pump(
        &self,
        id: u64,
        conn: Connection,
        mut send: SendStream,
        mut recv: RecvStream,
        mut rx: mpsc::UnboundedReceiver<Command>,
    ) {
        let reader = async {
            let mut buf = vec![0u8; 64 * 1024];
            loop {
                match recv.read(&mut buf).await {
                    Ok(Some(n)) => self.emit(id, EVENT_DATA, &buf[..n]),
                    Ok(None) => return "the other Mac ended the connection".to_string(),
                    Err(e) => return e.to_string(),
                }
            }
        };
        let writer = async {
            while let Some(command) = rx.recv().await {
                match command {
                    Command::Send(data) => {
                        if let Err(e) = send.write_all(&data).await {
                            return e.to_string();
                        }
                    }
                    Command::Close => break,
                }
            }
            let _ = send.finish();
            "closed".to_string()
        };
        let reason = tokio::select! {
            r = reader => r,
            w = writer => w,
            e = conn.closed() => e.to_string(),
        };
        conn.close(0u32.into(), b"bye");
        self.conns.lock().unwrap().remove(&id);
        self.emit(id, EVENT_CLOSED, reason.as_bytes());
    }
}

/// An invite code: the endpoint id in lowercase base32 (52 letters and digits).
fn code(id: &EndpointId) -> String {
    data_encoding::BASE32_NOPAD.encode(id.as_bytes()).to_ascii_lowercase()
}

fn parse_code(s: &str) -> Option<EndpointId> {
    let cleaned: String = s.chars().filter(|c| c.is_ascii_alphanumeric()).collect();
    EndpointId::from_str(&cleaned.to_ascii_lowercase()).ok()
}

unsafe fn str_arg<'a>(s: *const c_char) -> Option<&'a str> {
    if s.is_null() {
        return None;
    }
    CStr::from_ptr(s).to_str().ok()
}

/// Starts iroh. Call once. Returns false if it was already started or the
/// runtime couldn't start.
#[no_mangle]
pub unsafe extern "C" fn cs_net_start(callback: EventFn, ctx: *mut c_void) -> bool {
    if NET.get().is_some() {
        return false;
    }
    let Ok(rt) = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .thread_name("couchsync-net")
        .enable_all()
        .build()
    else {
        return false;
    };
    let net = Net {
        rt,
        guest: tokio::sync::OnceCell::new(),
        host: Mutex::new(None),
        host_generation: AtomicU64::new(0),
        callback: Callback { f: callback, ctx: ctx as usize },
        conns: Mutex::new(HashMap::new()),
        next_id: AtomicU64::new(1),
    };
    if NET.set(net).is_err() {
        return false;
    }
    // Get the joining endpoint ready now, so joining is quicker.
    let net = NET.get().unwrap();
    net.rt.spawn(async move {
        let _ = net.guest().await;
    });
    true
}

/// Starts taking connections under a brand-new invite code, which it writes to
/// `out` (53 bytes including the NUL). Ends any party already being hosted.
#[no_mangle]
pub unsafe extern "C" fn cs_net_host_start(out: *mut c_char, out_len: usize) -> bool {
    let Some(net) = net() else { return false };
    let secret = SecretKey::generate();
    let code = code(&secret.public());
    if out.is_null() || out_len < code.len() + 1 {
        return false;
    }
    cs_net_host_stop();
    let generation = net.host_generation.fetch_add(1, Ordering::SeqCst) + 1;
    net.rt.spawn(net.host(secret, generation));
    std::ptr::copy_nonoverlapping(code.as_ptr(), out as *mut u8, code.len());
    *out.add(code.len()) = 0;
    true
}

/// Stops hosting. The invite code stops working and everyone connected is dropped.
#[no_mangle]
pub extern "C" fn cs_net_host_stop() {
    let Some(net) = net() else { return };
    net.host_generation.fetch_add(1, Ordering::SeqCst);
    if let Some(endpoint) = net.host.lock().unwrap().take() {
        net.rt.spawn(async move { endpoint.close().await });
    }
}

/// Whether `s` looks like an invite code rather than a hostname or IP.
#[no_mangle]
pub unsafe extern "C" fn cs_net_is_code(s: *const c_char) -> bool {
    str_arg(s).and_then(parse_code).is_some()
}

/// Dials the party with this invite code. Returns a connection id (0 on a bad
/// code); EVENT_READY or EVENT_CLOSED follows.
#[no_mangle]
pub unsafe extern "C" fn cs_net_connect(code: *const c_char) -> u64 {
    let (Some(net), Some(remote)) = (net(), str_arg(code).and_then(parse_code)) else {
        return 0;
    };
    let (id, rx) = net.register();
    net.rt.spawn(net.connect(id, remote, rx));
    id
}

#[no_mangle]
pub unsafe extern "C" fn cs_net_send(conn: u64, data: *const u8, len: usize) {
    let Some(net) = net() else { return };
    if let Some(tx) = net.conns.lock().unwrap().get(&conn) {
        let _ = tx.send(Command::Send(std::slice::from_raw_parts(data, len).to_vec()));
    }
}

#[no_mangle]
pub extern "C" fn cs_net_close(conn: u64) {
    let Some(net) = net() else { return };
    if let Some(tx) = net.conns.lock().unwrap().get(&conn) {
        let _ = tx.send(Command::Close);
    }
}
