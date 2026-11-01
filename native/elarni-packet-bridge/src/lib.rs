mod device;
mod framing;

#[cfg(test)]
mod tests;

use std::ptr;
use std::slice;
use std::sync::atomic::{AtomicU8, AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use device::PacketDevice;
use framing::{FrameAssembler, validate_packet};
use tokio::runtime::Builder;
use tokio::sync::mpsc;
use tun2proxy::{ArgDns, ArgProxy, Args, CancellationToken, ProxyType, VirtualDnsMetrics};

pub const ELARNI_PACKET_ABI_VERSION: u32 = 6;
const STOP_TIMEOUT: Duration = Duration::from_secs(2);
const MIN_PACKET_BYTES: usize = 1280;
const MAX_PACKET_BYTES: usize = 65_535;
const MAX_QUEUE_PACKETS: usize = 4096;

#[repr(C)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ElarniPacketStatus {
    Ok = 0,
    InvalidArgument = 1,
    MalformedPacket = 2,
    QueueOverflow = 3,
    BufferTooSmall = 4,
    Empty = 5,
    Stopped = 6,
    StopTimeout = 7,
    InternalError = 255,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ElarniPacketState {
    Starting = 0,
    Running = 1,
    Stopping = 2,
    Stopped = 3,
    Failed = 4,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct ElarniPacketCounters {
    pub packets_in: u64,
    pub bytes_in: u64,
    pub packets_out: u64,
    pub bytes_out: u64,
    pub malformed: u64,
    pub overflows: u64,
    pub synthetic_dns_answers: u64,
    pub synthetic_mapping_hits: u64,
    pub restored_domain_sessions: u64,
    pub restored_proxy_sessions: u64,
    pub restored_direct_sessions: u64,
    pub restored_block_sessions: u64,
    pub restored_dns_sessions: u64,
    pub synthetic_mapping_evictions: u64,
    pub synthetic_mapping_expirations: u64,
    pub synthetic_allocation_collisions: u64,
    pub active_tcp_sessions: u64,
    pub active_udp_sessions: u64,
    pub dropped_tcp_sessions: u64,
    pub dropped_udp_sessions: u64,
}

#[derive(Default)]
struct Counters {
    packets_in: AtomicU64,
    bytes_in: AtomicU64,
    packets_out: AtomicU64,
    bytes_out: AtomicU64,
    malformed: AtomicU64,
    overflows: AtomicU64,
}

pub struct ElarniPacketBridge {
    input: mpsc::Sender<Vec<u8>>,
    output: Arc<Mutex<FrameAssembler>>,
    output_ready: Arc<Condvar>,
    cancellation: CancellationToken,
    state: Arc<AtomicU8>,
    counters: Arc<Counters>,
    thread: Mutex<Option<JoinHandle<()>>>,
    max_packet_bytes: usize,
    virtual_dns_metrics: Arc<VirtualDnsMetrics>,
    session_metrics: Arc<tun2proxy::SessionMetrics>,
}

#[unsafe(no_mangle)]
pub extern "C" fn elarni_packet_abi_version() -> u32 {
    ELARNI_PACKET_ABI_VERSION
}

#[unsafe(no_mangle)]
pub extern "C" fn elarni_packet_bridge_new(
    socks_port: u16,
    mtu: u16,
    tcp_max_sessions: usize,
    udp_max_sessions: usize,
    queue_packets: usize,
    max_packet_bytes: usize,
) -> *mut ElarniPacketBridge {
    new_bridge(
        ArgProxy {
            proxy_type: ProxyType::Socks5,
            addr: ([127, 0, 0, 1], socks_port).into(),
            credentials: None,
        },
        mtu,
        tcp_max_sessions,
        udp_max_sessions,
        queue_packets,
        max_packet_bytes,
    )
}

/// # Safety
/// Credential pointers must reference their stated readable lengths for this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn elarni_packet_bridge_new_authenticated(
    socks_port: u16,
    mtu: u16,
    tcp_max_sessions: usize,
    udp_max_sessions: usize,
    queue_packets: usize,
    max_packet_bytes: usize,
    username: *const u8,
    username_len: usize,
    password: *const u8,
    password_len: usize,
) -> *mut ElarniPacketBridge {
    if username.is_null()
        || password.is_null()
        || !(1..=255).contains(&username_len)
        || !(1..=255).contains(&password_len)
    {
        return ptr::null_mut();
    }
    let username = unsafe { slice::from_raw_parts(username, username_len) };
    let password = unsafe { slice::from_raw_parts(password, password_len) };
    if std::str::from_utf8(username).is_err() || std::str::from_utf8(password).is_err() {
        return ptr::null_mut();
    }
    let encode = |bytes: &[u8]| {
        bytes
            .iter()
            .map(|byte| format!("%{byte:02X}"))
            .collect::<String>()
    };
    let uri = format!(
        "socks5://{}:{}@127.0.0.1:{socks_port}",
        encode(username),
        encode(password)
    );
    let Ok(proxy) = ArgProxy::try_from(uri.as_str()) else {
        return ptr::null_mut();
    };
    new_bridge(
        proxy,
        mtu,
        tcp_max_sessions,
        udp_max_sessions,
        queue_packets,
        max_packet_bytes,
    )
}

fn new_bridge(
    proxy: ArgProxy,
    mtu: u16,
    tcp_max_sessions: usize,
    udp_max_sessions: usize,
    queue_packets: usize,
    max_packet_bytes: usize,
) -> *mut ElarniPacketBridge {
    if proxy.addr.port() == 0
        || usize::from(mtu) < MIN_PACKET_BYTES
        || tcp_max_sessions == 0
        || udp_max_sessions == 0
        || tcp_max_sessions > 4_096
        || udp_max_sessions > 4_096
        || queue_packets == 0
        || queue_packets > MAX_QUEUE_PACKETS
        || !(MIN_PACKET_BYTES..=MAX_PACKET_BYTES).contains(&max_packet_bytes)
    {
        return ptr::null_mut();
    }

    let (sender, receiver) = mpsc::channel(queue_packets);
    let output = Arc::new(Mutex::new(FrameAssembler::new(
        max_packet_bytes,
        queue_packets,
    )));
    let output_ready = Arc::new(Condvar::new());
    let cancellation = CancellationToken::new();
    let state = Arc::new(AtomicU8::new(ElarniPacketState::Starting as u8));
    let counters = Arc::new(Counters::default());
    let device = PacketDevice::new(receiver, output.clone(), output_ready.clone());
    let thread_cancellation = cancellation.clone();
    let thread_state = state.clone();
    let virtual_dns_metrics = Arc::new(VirtualDnsMetrics::default());
    let session_metrics = Arc::new(tun2proxy::SessionMetrics::default());
    let args = Args {
        proxy,
        setup: false,
        ipv6_enabled: true,
        dns: ArgDns::OverTcp,
        dns_addr: "198.18.0.1".parse().expect("constant DNS listener address"),
        max_sessions: tcp_max_sessions.saturating_add(udp_max_sessions),
        tcp_max_sessions,
        udp_max_sessions,
        session_metrics: Some(session_metrics.clone()),
        mtu,
        virtual_dns_capacity: 256,
        virtual_dns_mapping_ttl: 60,
        virtual_dns_answer_ttl: 5,
        virtual_dns_metrics: Some(virtual_dns_metrics.clone()),
        ..Args::default()
    };

    let worker = thread::Builder::new()
        .name("elarni-packet-bridge".to_owned())
        .spawn(move || {
            let runtime = match Builder::new_multi_thread()
                .worker_threads(2)
                .enable_all()
                .build()
            {
                Ok(runtime) => runtime,
                Err(_) => {
                    thread_state.store(ElarniPacketState::Failed as u8, Ordering::Release);
                    return;
                }
            };
            thread_state.store(ElarniPacketState::Running as u8, Ordering::Release);
            // A panic must report Failed instead of leaving a silent Running bridge.
            let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                runtime.block_on(tun2proxy::run(device, mtu, args, thread_cancellation))
            }));
            let final_state = if matches!(result, Ok(Ok(_))) {
                ElarniPacketState::Stopped
            } else {
                ElarniPacketState::Failed
            };
            drop(runtime);
            let _ = thread_state.fetch_update(Ordering::AcqRel, Ordering::Acquire, |current| {
                (current != ElarniPacketState::Failed as u8).then_some(final_state as u8)
            });
        });
    let Ok(worker) = worker else {
        return ptr::null_mut();
    };

    Box::into_raw(Box::new(ElarniPacketBridge {
        input: sender,
        output,
        output_ready,
        cancellation,
        state,
        counters,
        thread: Mutex::new(Some(worker)),
        max_packet_bytes,
        virtual_dns_metrics,
        session_metrics,
    }))
}

/// # Safety
/// `bridge` must be null or a live pointer returned by `elarni_packet_bridge_new`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn elarni_packet_bridge_free(bridge: *mut ElarniPacketBridge) {
    if bridge.is_null() {
        return;
    }
    let _ = unsafe { elarni_packet_bridge_stop(bridge) };
    drop(unsafe { Box::from_raw(bridge) });
}

/// # Safety
/// `bridge` must be live. `packet` must point to `packet_len` readable bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn elarni_packet_bridge_submit(
    bridge: *mut ElarniPacketBridge,
    packet: *const u8,
    packet_len: usize,
) -> ElarniPacketStatus {
    let Some(bridge) = (unsafe { bridge.as_ref() }) else {
        return ElarniPacketStatus::InvalidArgument;
    };
    if packet.is_null() || packet_len == 0 {
        return ElarniPacketStatus::InvalidArgument;
    }
    if bridge.state.load(Ordering::Acquire) != ElarniPacketState::Running as u8 {
        return ElarniPacketStatus::Stopped;
    }
    let packet = unsafe { slice::from_raw_parts(packet, packet_len) };
    if validate_packet(packet, bridge.max_packet_bytes).is_err() {
        bridge.counters.malformed.fetch_add(1, Ordering::Relaxed);
        return ElarniPacketStatus::MalformedPacket;
    }
    match bridge.input.try_send(packet.to_vec()) {
        Ok(()) => {
            bridge.counters.packets_in.fetch_add(1, Ordering::Relaxed);
            bridge
                .counters
                .bytes_in
                .fetch_add(packet_len as u64, Ordering::Relaxed);
            ElarniPacketStatus::Ok
        }
        Err(mpsc::error::TrySendError::Full(_)) => {
            // Drop this packet like a congested link; the tunnel keeps running.
            bridge.counters.overflows.fetch_add(1, Ordering::Relaxed);
            ElarniPacketStatus::QueueOverflow
        }
        Err(mpsc::error::TrySendError::Closed(_)) => ElarniPacketStatus::Stopped,
    }
}

/// # Safety
/// All pointers must be live and writable for their declared size. `output_capacity` describes
/// the writable bytes at `output`. On `BufferTooSmall`, `written` receives required size.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn elarni_packet_bridge_receive(
    bridge: *mut ElarniPacketBridge,
    output: *mut u8,
    output_capacity: usize,
    written: *mut usize,
) -> ElarniPacketStatus {
    let Some(bridge) = (unsafe { bridge.as_ref() }) else {
        return ElarniPacketStatus::InvalidArgument;
    };
    let Some(written) = (unsafe { written.as_mut() }) else {
        return ElarniPacketStatus::InvalidArgument;
    };
    *written = 0;
    let Ok(mut queue) = bridge.output.lock() else {
        return ElarniPacketStatus::InternalError;
    };
    let Some(packet) = queue.front() else {
        return ElarniPacketStatus::Empty;
    };
    *written = packet.len();
    if output.is_null() || output_capacity < packet.len() {
        return ElarniPacketStatus::BufferTooSmall;
    }
    unsafe { ptr::copy_nonoverlapping(packet.as_ptr(), output, packet.len()) };
    let packet = queue.pop().expect("front existed");
    bridge.counters.packets_out.fetch_add(1, Ordering::Relaxed);
    bridge
        .counters
        .bytes_out
        .fetch_add(packet.len() as u64, Ordering::Relaxed);
    ElarniPacketStatus::Ok
}

/// Sleeps until `receive` has a packet (`Ok`), the bridge stops running (`Stopped`) or
/// `timeout_ms` passes (`Empty`), so an idle caller needs no polling loop.
///
/// # Safety
/// `bridge` must stay live until this call returns: free it only after waiting threads return.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn elarni_packet_bridge_wait(
    bridge: *const ElarniPacketBridge,
    timeout_ms: u32,
) -> ElarniPacketStatus {
    let Some(bridge) = (unsafe { bridge.as_ref() }) else {
        return ElarniPacketStatus::InvalidArgument;
    };
    let running = || bridge.state.load(Ordering::Acquire) == ElarniPacketState::Running as u8;
    let Ok(queue) = bridge.output.lock() else {
        return ElarniPacketStatus::InternalError;
    };
    let Ok((queue, _)) = bridge.output_ready.wait_timeout_while(
        queue,
        Duration::from_millis(timeout_ms.into()),
        |queue| queue.front().is_none() && running(),
    ) else {
        return ElarniPacketStatus::InternalError;
    };
    if queue.front().is_some() {
        ElarniPacketStatus::Ok
    } else if running() {
        ElarniPacketStatus::Empty
    } else {
        ElarniPacketStatus::Stopped
    }
}

/// # Safety
/// `bridge` and `counters` must be live pointers.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn elarni_packet_bridge_counters(
    bridge: *const ElarniPacketBridge,
    counters: *mut ElarniPacketCounters,
) -> ElarniPacketStatus {
    let Some(bridge) = (unsafe { bridge.as_ref() }) else {
        return ElarniPacketStatus::InvalidArgument;
    };
    let Some(counters_out) = (unsafe { counters.as_mut() }) else {
        return ElarniPacketStatus::InvalidArgument;
    };
    let virtual_dns = bridge.virtual_dns_metrics.snapshot();
    *counters_out = ElarniPacketCounters {
        packets_in: bridge.counters.packets_in.load(Ordering::Relaxed),
        bytes_in: bridge.counters.bytes_in.load(Ordering::Relaxed),
        packets_out: bridge.counters.packets_out.load(Ordering::Relaxed),
        bytes_out: bridge.counters.bytes_out.load(Ordering::Relaxed),
        malformed: bridge.counters.malformed.load(Ordering::Relaxed),
        overflows: bridge.counters.overflows.load(Ordering::Relaxed)
            + bridge.output.lock().map_or(0, |output| output.dropped()),
        synthetic_dns_answers: virtual_dns.synthetic_answers,
        synthetic_mapping_hits: virtual_dns.mapping_hits,
        restored_domain_sessions: virtual_dns.restored_domain_sessions,
        restored_proxy_sessions: virtual_dns.restored_proxy_sessions,
        restored_direct_sessions: virtual_dns.restored_direct_sessions,
        restored_block_sessions: virtual_dns.restored_block_sessions,
        restored_dns_sessions: virtual_dns.restored_dns_sessions,
        synthetic_mapping_evictions: virtual_dns.evictions,
        synthetic_mapping_expirations: virtual_dns.expirations,
        synthetic_allocation_collisions: virtual_dns.allocation_collisions,
        active_tcp_sessions: bridge.session_metrics.active_tcp.load(Ordering::Relaxed) as u64,
        active_udp_sessions: bridge.session_metrics.active_udp.load(Ordering::Relaxed) as u64,
        dropped_tcp_sessions: bridge.session_metrics.dropped_tcp.load(Ordering::Relaxed) as u64,
        dropped_udp_sessions: bridge.session_metrics.dropped_udp.load(Ordering::Relaxed) as u64,
    };
    ElarniPacketStatus::Ok
}

/// # Safety
/// `bridge` must be a live pointer.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn elarni_packet_bridge_state(
    bridge: *const ElarniPacketBridge,
) -> ElarniPacketState {
    let Some(bridge) = (unsafe { bridge.as_ref() }) else {
        return ElarniPacketState::Failed;
    };
    match bridge.state.load(Ordering::Acquire) {
        0 => ElarniPacketState::Starting,
        1 => ElarniPacketState::Running,
        2 => ElarniPacketState::Stopping,
        3 => ElarniPacketState::Stopped,
        _ => ElarniPacketState::Failed,
    }
}

/// # Safety
/// `bridge` must be a live pointer. This call is idempotent.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn elarni_packet_bridge_stop(
    bridge: *mut ElarniPacketBridge,
) -> ElarniPacketStatus {
    let Some(bridge) = (unsafe { bridge.as_ref() }) else {
        return ElarniPacketStatus::InvalidArgument;
    };
    let current = bridge.state.load(Ordering::Acquire);
    if current != ElarniPacketState::Failed as u8 && current != ElarniPacketState::Stopped as u8 {
        bridge
            .state
            .store(ElarniPacketState::Stopping as u8, Ordering::Release);
    }
    // Taking the lock orders this wake after a waiter's last look at the state.
    drop(bridge.output.lock());
    bridge.output_ready.notify_all();
    bridge.cancellation.cancel();
    let deadline = Instant::now() + STOP_TIMEOUT;
    loop {
        let finished = bridge
            .thread
            .lock()
            .ok()
            .and_then(|guard| guard.as_ref().map(JoinHandle::is_finished))
            .unwrap_or(true);
        if finished {
            if let Ok(mut guard) = bridge.thread.lock()
                && let Some(worker) = guard.take()
            {
                let _ = worker.join();
            }
            if bridge.state.load(Ordering::Acquire) != ElarniPacketState::Failed as u8 {
                bridge
                    .state
                    .store(ElarniPacketState::Stopped as u8, Ordering::Release);
            }
            return ElarniPacketStatus::Ok;
        }
        if Instant::now() >= deadline {
            bridge
                .state
                .store(ElarniPacketState::Failed as u8, Ordering::Release);
            return ElarniPacketStatus::StopTimeout;
        }
        thread::sleep(Duration::from_millis(5));
    }
}
