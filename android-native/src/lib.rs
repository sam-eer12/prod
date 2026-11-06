//! Length-checked, panic-contained JNI boundary. Registry IDs prevent stale
//! handles and close/use races from accessing freed native memory.
use jni::{
    JNIEnv,
    objects::{JByteArray, JObject},
    sys::{jbyteArray, jint, jlong},
};
use padlink_protocol::{
    MAX_HANDSHAKE_FRAME_LEN,
    crypto::Transport,
    frame::{Frame, FrameType},
    pairing::{
        DesktopHandshake, PairingMessage,
        net::{DesktopEvent, DesktopPairingClient, PhoneEvent, PhonePairingServer},
        resume::{ResumePath, Resumption, SessionLease},
    },
};
use std::{
    panic::{AssertUnwindSafe, catch_unwind},
    sync::{Mutex, OnceLock},
};
use zeroize::Zeroizing;
#[global_allocator]
static HEAP: padlink_protocol::memory::BudgetedAllocator<std::alloc::System> =
    padlink_protocol::memory::BudgetedAllocator::new(std::alloc::System, 24_000_000);
const MAX_HANDLES: usize = 4;
enum Core {
    Phone(Box<PhonePairingServer>),
    Desktop(Box<DesktopHandshake>),
    Client(Box<DesktopPairingClient>),
    Session(Box<SessionLease>),
    Resume(Box<Resumption>),
    Closed,
}
struct Slot {
    id: i64,
    core: Core,
}
struct Registry {
    next: i64,
    slots: [Option<Slot>; MAX_HANDLES],
}
static REGISTRY: OnceLock<Mutex<Registry>> = OnceLock::new();
fn registry() -> &'static Mutex<Registry> {
    REGISTRY.get_or_init(|| {
        Mutex::new(Registry {
            next: 0,
            slots: std::array::from_fn(|_| None),
        })
    })
}
type Result<T> = std::result::Result<T, String>;
fn string(bytes: &[u8]) -> Result<&str> {
    std::str::from_utf8(bytes).map_err(|_| "invalid UTF-8 core argument".into())
}
fn error<E: std::fmt::Display>(e: E) -> String {
    e.to_string()
}
fn input(env: &JNIEnv, array: &JByteArray) -> Result<Zeroizing<Vec<u8>>> {
    let length = env.get_array_length(array).map_err(error)?;
    if length < 0 || length as usize > MAX_HANDSHAKE_FRAME_LEN {
        return Err("native argument exceeds 4096-byte bound".into());
    }
    Ok(Zeroizing::new(
        env.convert_byte_array(array).map_err(error)?,
    ))
}
fn create(role: i32, bytes: &[u8], now: i64) -> Result<i64> {
    let now = u64::try_from(now).map_err(|_| "invalid monotonic clock")?;
    let mut registry = registry()
        .lock()
        .map_err(|_| "native registry unavailable")?;
    if role == 0
        && registry
            .slots
            .iter()
            .flatten()
            .any(|slot| matches!(slot.core, Core::Phone(_)))
    {
        return Err("one phone core is already active".into());
    }
    let index = registry
        .slots
        .iter()
        .position(Option::is_none)
        .ok_or("native handle limit reached")?;
    let core = match role {
        0 => Core::Phone(Box::new(PhonePairingServer::new(now))),
        1 => Core::Desktop(Box::new(
            DesktopHandshake::new(string(bytes)?).map_err(error)?,
        )),
        2 => {
            let (endpoint, label) = string(bytes)?
                .split_once('\n')
                .ok_or("expected endpoint and label")?;
            Core::Client(Box::new(
                DesktopPairingClient::connect(endpoint.parse().map_err(error)?, label, now)
                    .map_err(error)?,
            ))
        }
        _ => return Err("unknown native role".into()),
    };
    registry.next = registry.next.checked_add(1).ok_or("native IDs exhausted")?;
    let id = registry.next;
    registry.slots[index] = Some(Slot { id, core });
    Ok(id)
}
fn close(id: i64) -> Result<()> {
    let mut registry = registry()
        .lock()
        .map_err(|_| "native registry unavailable")?;
    if let Some(index) = registry
        .slots
        .iter()
        .position(|slot| slot.as_ref().is_some_and(|slot| slot.id == id))
    {
        registry.slots[index] = None;
        Ok(())
    } else {
        Err("native handle is closed".into())
    }
}
fn dispatch(id: i64, op: i32, connection: i64, bytes: &[u8], now: i64) -> Result<Vec<u8>> {
    let now = u64::try_from(now).map_err(|_| "invalid monotonic clock")?;
    let connection = u64::try_from(connection).map_err(|_| "invalid connection ID")?;
    let mut registry = registry()
        .lock()
        .map_err(|_| "native registry unavailable")?;
    let index = registry
        .slots
        .iter()
        .position(|slot| slot.as_ref().is_some_and(|slot| slot.id == id))
        .ok_or("native handle is closed")?;
    if op == 90 {
        let memory = HEAP.metrics();
        return Ok([
            memory.used as u64,
            memory.peak as u64,
            memory.limit as u64,
            memory.rejected as u64,
        ]
        .into_iter()
        .flat_map(u64::to_le_bytes)
        .collect());
    }
    if op == 30 || op == 31 {
        let destination = registry
            .slots
            .iter()
            .position(Option::is_none)
            .ok_or("native handle limit reached")?;
        let next = registry.next.checked_add(1).ok_or("native IDs exhausted")?;
        let lease = match &mut registry.slots[index]
            .as_mut()
            .ok_or("native handle is closed")?
            .core
        {
            Core::Phone(server) if op == 30 => {
                server.detach_session(connection, now).map_err(error)?
            }
            Core::Client(client) if op == 31 => client.detach_session(now).map_err(error)?,
            _ => return Err("invalid session transfer".into()),
        };
        registry.next = next;
        registry.slots[destination] = Some(Slot {
            id: next,
            core: Core::Session(Box::new(lease)),
        });
        return Ok(next.to_le_bytes().to_vec());
    }
    let core = &mut registry
        .slots
        .iter_mut()
        .flatten()
        .find(|slot| slot.id == id)
        .ok_or("native handle is closed")?
        .core;
    if op == 40 {
        let mut fields = string(bytes)?.split('\n');
        let selected = match fields.next() {
            Some("1") => Transport::Udp,
            Some("2") => Transport::Tcp,
            _ => return Err("invalid resume transport".into()),
        };
        let path = ResumePath {
            transport: selected,
            desktop: fields
                .next()
                .ok_or("missing desktop endpoint")?
                .parse()
                .map_err(error)?,
            phone: fields
                .next()
                .ok_or("missing phone endpoint")?
                .parse()
                .map_err(error)?,
        };
        if fields.next().is_some() || !matches!(core, Core::Session(_)) {
            return Err("invalid resume arguments or state".into());
        }
        let Core::Session(lease) = std::mem::replace(core, Core::Closed) else {
            unreachable!()
        };
        *core = Core::Resume(Box::new(lease.resume(path, now).map_err(error)?));
        return Ok(Vec::new());
    }
    if op == 44 {
        if !matches!(core, Core::Resume(_)) {
            return Err("invalid resume state".into());
        }
        let Core::Resume(resume) = std::mem::replace(core, Core::Closed) else {
            unreachable!()
        };
        let (lease, path) = resume.finish(now).map_err(error)?;
        *core = Core::Session(Box::new(lease));
        return Ok(
            format!("{}\n{}\n{}", path.transport as u8, path.desktop, path.phone).into_bytes(),
        );
    }
    match core {
        Core::Phone(server) => match op {
            0 => Ok(vec![server.state() as u8]),
            1 => Ok(server
                .start(string(bytes)?.parse().map_err(error)?)
                .map_err(error)?
                .to_string()
                .into_bytes()),
            2 => {
                server.stop();
                Ok(Vec::new())
            }
            3 => {
                let event = server.poll(now).map_err(error)?;
                let mut out = Vec::new();
                out.try_reserve_exact(256).map_err(error)?;
                match event {
                    PhoneEvent::Pending => out.push(0),
                    PhoneEvent::Consent { id, label, address } => {
                        out.push(1);
                        out.extend_from_slice(&id.to_le_bytes());
                        out.extend_from_slice(&(label.len() as u16).to_le_bytes());
                        out.extend_from_slice(label.as_bytes());
                        out.extend_from_slice(address.to_string().as_bytes());
                    }
                    PhoneEvent::Paired { id } => {
                        out.push(2);
                        out.extend_from_slice(&id.to_le_bytes())
                    }
                    PhoneEvent::Closed { id } => {
                        out.push(3);
                        out.extend_from_slice(&id.to_le_bytes())
                    }
                    PhoneEvent::Frame(frame) => {
                        out.push(4);
                        out.push(frame.frame_type() as u8);
                        out.extend_from_slice(&frame.encode_payload().map_err(error)?);
                    }
                }
                Ok(out)
            }
            4 => {
                server.allow(connection, now).map_err(error)?;
                Ok(Vec::new())
            }
            5 => {
                server.deny(connection, now).map_err(error)?;
                Ok(Vec::new())
            }
            6 => Ok(server
                .code(connection, now)
                .map_err(error)?
                .as_bytes()
                .to_vec()),
            7 => Ok(server.deadline_ms().unwrap_or(0).to_le_bytes().to_vec()),
            8 => {
                server.disconnect(connection).map_err(error)?;
                Ok(Vec::new())
            }
            _ => Err("unknown phone operation".into()),
        },
        Core::Desktop(handshake) => match op {
            10 => handshake.request().encode().map_err(error),
            11 => {
                handshake
                    .accept(&PairingMessage::decode(bytes).map_err(error)?, now)
                    .map_err(error)?;
                Ok(Vec::new())
            }
            12 => handshake
                .start_attempt(string(bytes)?, now)
                .map_err(error)?
                .encode()
                .map_err(error),
            13 => handshake
                .handle_pake_b(&PairingMessage::decode(bytes).map_err(error)?, now)
                .map_err(error)?
                .encode()
                .map_err(error),
            14 => {
                let session = handshake.finish(bytes, now).map_err(error)?;
                *core = Core::Session(Box::new(SessionLease::new(session, now).map_err(error)?));
                Ok(Vec::new())
            }
            _ => Err("unknown desktop operation".into()),
        },
        Core::Session(lease) => {
            match op {
                17 => {
                    lease.check_live(now).map_err(error)?;
                    return Ok(lease.expires_ms().to_le_bytes().to_vec());
                }
                18 => {
                    let sample: [u8; 8] = bytes.try_into().map_err(|_| "expected sample time")?;
                    lease
                        .fresh_input(u64::from_le_bytes(sample), now)
                        .map_err(error)?;
                    return Ok(Vec::new());
                }
                19 => {
                    return Ok(lease
                        .session_mut(now)
                        .map_err(error)?
                        .epoch()
                        .to_le_bytes()
                        .to_vec());
                }
                _ => {}
            }
            if bytes.is_empty() {
                return Err("missing transport".into());
            }
            let selected = match bytes[0] {
                1 => Transport::Udp,
                2 => Transport::Tcp,
                _ => return Err("invalid transport".into()),
            };
            match op {
                15 => {
                    if bytes.len() < 2 {
                        return Err("missing frame type".into());
                    }
                    let frame = Frame::decode_payload(
                        FrameType::try_from(bytes[1]).map_err(error)?,
                        &bytes[2..],
                    )
                    .map_err(error)?;
                    lease
                        .session_mut(now)
                        .map_err(error)?
                        .seal(selected, &frame)
                        .map_err(error)
                }
                16 => {
                    let frame = lease
                        .session_mut(now)
                        .map_err(error)?
                        .open(selected, &bytes[1..])
                        .map_err(error)?
                        .frame;
                    let mut result = vec![frame.frame_type() as u8];
                    result.extend_from_slice(&frame.encode_payload().map_err(error)?);
                    Ok(result)
                }
                _ => Err("unknown session operation".into()),
            }
        }
        Core::Client(client) => match op {
            20 => {
                let mut out = Vec::new();
                match client.poll(now).map_err(error)? {
                    DesktopEvent::Pending => out.push(0),
                    DesktopEvent::EnterCode => out.push(1),
                    DesktopEvent::WrongCode => out.push(2),
                    DesktopEvent::Paired => out.push(3),
                    DesktopEvent::Frame(frame) => {
                        out.push(4);
                        out.push(frame.frame_type() as u8);
                        out.extend_from_slice(&frame.encode_payload().map_err(error)?);
                    }
                }
                Ok(out)
            }
            21 => {
                client.enter_code(string(bytes)?, now).map_err(error)?;
                Ok(Vec::new())
            }
            22 => {
                if bytes.is_empty() {
                    return Err("missing frame type".into());
                }
                let frame = Frame::decode_payload(
                    FrameType::try_from(bytes[0]).map_err(error)?,
                    &bytes[1..],
                )
                .map_err(error)?;
                client.send(&frame, now).map_err(error)?;
                Ok(Vec::new())
            }
            23 => Ok(client
                .code_deadline_ms()
                .unwrap_or(0)
                .to_le_bytes()
                .to_vec()),
            _ => Err("unknown client operation".into()),
        },
        Core::Resume(resume) => match op {
            41 => resume.begin(now).map_err(error),
            42 => {
                if bytes.len() < 2 {
                    return Err("missing resume source".into());
                }
                let length = u16::from_le_bytes([bytes[0], bytes[1]]) as usize;
                if length > 128 || bytes.len() < 2 + length {
                    return Err("invalid resume source length".into());
                }
                let source = string(&bytes[2..2 + length])?.parse().map_err(error)?;
                let output = resume
                    .receive(source, &bytes[2 + length..], now)
                    .map_err(error)?;
                let mut result = Vec::new();
                result.try_reserve_exact(520).map_err(error)?;
                result.push(u8::from(output.ready_to_commit));
                result.push(output.frames.len() as u8);
                for frame in output.frames {
                    result.extend_from_slice(&(frame.len() as u16).to_le_bytes());
                    result.extend_from_slice(&frame);
                }
                Ok(result)
            }
            43 => {
                resume.ready_written(now).map_err(error)?;
                Ok(Vec::new())
            }
            45 => {
                resume.check_live(now).map_err(error)?;
                Ok(resume.deadline_ms().to_le_bytes().to_vec())
            }
            _ => Err("unknown resume operation".into()),
        },
        Core::Closed => Err("native session is closed".into()),
    }
}
fn throw(env: &mut JNIEnv, message: &str) {
    let _ = env.throw_new("java/lang/IllegalStateException", message);
}
/// A contained panic cannot leave poisoned registry slots holding session keys.
fn invalidate_all() {
    let mutex = registry();
    let mut registry = mutex
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    registry.slots.fill_with(|| None);
    mutex.clear_poison();
}
#[unsafe(no_mangle)]
pub extern "system" fn Java_com_padlink_controller_core_NativeCore_create(
    mut env: JNIEnv,
    _object: JObject,
    role: jint,
    data: JByteArray,
    now: jlong,
) -> jlong {
    match catch_unwind(AssertUnwindSafe(|| {
        input(&env, &data).and_then(|bytes| create(role, &bytes, now))
    })) {
        Ok(Ok(id)) => id,
        Ok(Err(message)) => {
            throw(&mut env, &message);
            0
        }
        Err(_) => {
            invalidate_all();
            throw(&mut env, "native core operation failed");
            0
        }
    }
}
#[unsafe(no_mangle)]
pub extern "system" fn Java_com_padlink_controller_core_NativeCore_call(
    mut env: JNIEnv,
    _object: JObject,
    id: jlong,
    op: jint,
    connection: jlong,
    data: JByteArray,
    now: jlong,
) -> jbyteArray {
    match catch_unwind(AssertUnwindSafe(|| {
        input(&env, &data).and_then(|bytes| dispatch(id, op, connection, &bytes, now))
    })) {
        Ok(Ok(bytes)) => {
            let bytes = Zeroizing::new(bytes);
            match env.byte_array_from_slice(&bytes) {
                Ok(array) => array.into_raw(),
                Err(_) => {
                    throw(&mut env, "native result allocation failed");
                    std::ptr::null_mut()
                }
            }
        }
        Ok(Err(message)) => {
            throw(&mut env, &message);
            std::ptr::null_mut()
        }
        Err(_) => {
            invalidate_all();
            throw(&mut env, "native core operation failed");
            std::ptr::null_mut()
        }
    }
}
#[unsafe(no_mangle)]
pub extern "system" fn Java_com_padlink_controller_core_NativeCore_close(
    mut env: JNIEnv,
    _object: JObject,
    id: jlong,
) {
    match catch_unwind(AssertUnwindSafe(|| close(id))) {
        Ok(Ok(())) => {}
        Ok(Err(message)) => throw(&mut env, &message),
        Err(_) => {
            invalidate_all();
            throw(&mut env, "native core close failed");
        }
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn registry_is_bounded_and_stale_handles_are_rejected() {
        let handles: Vec<_> = (0..MAX_HANDLES)
            .map(|_| create(1, b"JNI test", 0).unwrap())
            .collect();
        assert!(create(1, b"Overflow", 0).is_err());
        let id = handles[0];
        close(id).unwrap();
        assert!(dispatch(id, 10, 0, &[], 0).is_err());
        let replacement = create(1, b"Replacement", 0).unwrap();
        assert_ne!(id, replacement);
        for id in handles.into_iter().skip(1) {
            close(id).unwrap();
        }
        close(replacement).unwrap();
        let active = create(1, b"Panic cleanup", 0).unwrap();
        let _ = catch_unwind(|| {
            let _guard = registry().lock().unwrap();
            panic!("contained test panic");
        });
        invalidate_all();
        assert!(dispatch(active, 10, 0, &[], 0).is_err());
        let recovered = create(1, b"Recovered registry", 0).unwrap();
        assert!(recovered > active);
        close(recovered).unwrap();
    }
}
