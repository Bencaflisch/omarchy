use curl::easy::{Easy2, Handler, HttpVersion, List, ReadError, WriteError};
use std::sync::{
  Arc, Condvar, Mutex,
  atomic::{AtomicU64, Ordering},
  mpsc,
};
use std::time::{Duration, Instant};
use std::{env, process, thread};

const DEFAULT_CONNECTIONS: usize = 8;
const WINDOW: Duration = Duration::from_secs(5);
const DRAIN: Duration = Duration::from_secs(3);
const WARMUP: Duration = Duration::from_secs(6);
const SIZES: [u64; 5] = [65536, 1048576, 8388608, 33554432, 67108864];
type Result<T> = std::result::Result<T, String>;
type Start = Arc<(Mutex<Option<Instant>>, Condvar)>;

#[derive(Clone, Copy, PartialEq)]
enum Mode {
  Probe,
  Down,
  Up,
}
enum Event {
  Ready,
  Done(Result<Instant>),
}

struct Payload {
  total: Arc<AtomicU64>,
  mode: Mode,
  measured: bool,
  size: u64,
  sent: u64,
  received: u64,
  reply: Vec<u8>,
  deadline: Instant,
}

impl Handler for Payload {
  fn write(&mut self, data: &[u8]) -> std::result::Result<usize, WriteError> {
    if Instant::now() >= self.deadline {
      return Ok(0);
    }
    self.received += data.len() as u64;
    if self.mode == Mode::Up {
      if self.reply.len() + data.len() > 4096 {
        return Ok(0);
      }
      self.reply.extend_from_slice(data);
    } else if self.measured {
      self.total.fetch_add(data.len() as u64, Ordering::Relaxed);
    }
    Ok(data.len())
  }

  fn read(&mut self, data: &mut [u8]) -> std::result::Result<usize, ReadError> {
    if Instant::now() >= self.deadline {
      return Err(ReadError::Abort);
    }
    let length = (self.size - self.sent).min(data.len() as u64) as usize;
    data[..length].fill(0);
    self.sent += length as u64;
    Ok(length)
  }

  fn progress(&mut self, _: f64, _: f64, _: f64, _: f64) -> bool {
    Instant::now() < self.deadline
  }
}

fn curl<T>(value: std::result::Result<T, curl::Error>) -> Result<T> {
  value.map_err(|error| error.to_string())
}

fn request(
  easy: &mut Easy2<Payload>,
  base: &str,
  mode: Mode,
  size: u64,
  measured: bool,
) -> Result<Duration> {
  {
    let body = easy.get_mut();
    body.mode = mode;
    body.measured = measured;
    body.size = size;
    body.sent = 0;
    body.received = 0;
    body.reply.clear();
  }
  let mut headers = List::new();
  curl(headers.append("Expect:"))?;
  curl(headers.append("Content-Type: application/octet-stream"))?;
  curl(headers.append(if measured {
    "X-Speedtest-Phase: measure"
  } else {
    "X-Speedtest-Phase: warmup"
  }))?;
  curl(easy.http_headers(headers))?;
  let path = match mode {
    Mode::Probe => "/latency".to_owned(),
    Mode::Down => format!("/down?bytes={size}"),
    Mode::Up => "/upload".to_owned(),
  };
  curl(easy.url(&format!("{base}{path}")))?;
  if mode == Mode::Up {
    curl(easy.post(true))?;
    curl(easy.post_field_size(size))?;
  } else {
    curl(easy.get(true))?;
  }
  let remaining = easy
    .get_ref()
    .deadline
    .saturating_duration_since(Instant::now());
  if remaining.is_zero() {
    return Err("Speed test timed out".into());
  }
  curl(easy.timeout(remaining + Duration::from_millis(5)))?;
  let before = Instant::now();
  if let Err(error) = easy.perform() {
    // A download samples actual received body bytes for a fixed window.
    // Stopping a partial final request is expected only at that deadline.
    if mode == Mode::Down
      && measured
      && Instant::now() >= easy.get_ref().deadline
      && (error.is_aborted_by_callback() || error.is_write_error() || error.is_operation_timedout())
    {
      return Ok(before.elapsed());
    }
    return Err(error.to_string());
  }
  let expected = if mode == Mode::Probe { 204 } else { 200 };
  if curl(easy.response_code())? != expected {
    return Err("Unexpected speed test response".into());
  }
  let body = easy.get_ref();
  if mode == Mode::Down && body.received != size {
    return Err("Incomplete test download".into());
  }
  if mode == Mode::Up {
    let reply: serde_json::Value =
      serde_json::from_slice(&body.reply).map_err(|_| "Invalid upload acknowledgement")?;
    let transport = reply.get("acceptedBytes").is_some();
    let uploaded = curl(easy.upload_size())?;
    if uploaded != size as f64
      || reply
        .get("acceptedBytes")
        .or_else(|| reply.get("bytes"))
        .and_then(|bytes| bytes.as_u64())
        != Some(size)
    {
      return Err("Server did not acknowledge the complete upload".into());
    }
    let total = body.total.clone();
    if transport && measured && curl(easy.num_connects())? != 0 {
      return Err("Upload connection changed".into());
    }
    if measured {
      total.fetch_add(uploaded as u64, Ordering::Relaxed);
    }
  }
  Ok(before.elapsed())
}

// Keep fixed request latency out of the payload-size estimate. It remains in
// the final measured elapsed time, so this never inflates the reported rate.
fn choose_size(rate: f64, latency: f64, remaining: f64) -> Option<u64> {
  if SIZES[0] as f64 / rate + latency > remaining {
    return None;
  }
  let budget = rate * (remaining - latency).max(0.0);
  Some(
    SIZES
      .into_iter()
      .rev()
      .find(|size| *size as f64 <= budget)
      .unwrap_or(SIZES[0]),
  )
}

fn worker(
  base: &str,
  mode: Mode,
  total: Arc<AtomicU64>,
  start: Start,
  events: &mpsc::Sender<Event>,
  deadline: Instant,
) -> Result<Instant> {
  let mut easy = Easy2::new(Payload {
    total,
    mode,
    measured: false,
    size: 0,
    sent: 0,
    received: 0,
    reply: Vec::with_capacity(128),
    deadline,
  });
  if mode == Mode::Up {
    curl(easy.http_version(HttpVersion::V11))?;
  }
  curl(easy.useragent("Omarchy-Speedtest/1.0 (+https://omarchy.org)"))?;
  curl(easy.accept_encoding("identity"))?;
  curl(easy.fail_on_error(true))?;
  curl(easy.follow_location(false))?;
  curl(easy.connect_timeout(Duration::from_secs(3)))?;
  curl(easy.progress(true))?;
  curl(easy.tcp_nodelay(true))?;
  curl(easy.buffer_size(65536))?;
  // The first probe establishes DNS/TCP/TLS. The second measures a reused
  // connection; each thread owns a separate persistent connection cache.
  request(&mut easy, base, Mode::Probe, 0, false)?;
  let latency = request(&mut easy, base, Mode::Probe, 0, false)?.as_secs_f64();
  let mut warm_size = SIZES[0];
  let mut warm = request(&mut easy, base, mode, warm_size, false)?;
  for size in [SIZES[1], SIZES[2]] {
    if warm >= Duration::from_millis(250) {
      break;
    }
    warm_size = size;
    warm = request(&mut easy, base, mode, warm_size, false)?;
  }
  if mode == Mode::Up {
    request(&mut easy, base, Mode::Probe, 0, false)?;
    if curl(easy.num_connects())? != 0 {
      return Err("Warm-up confirmation connection changed".into());
    }
  }
  events
    .send(Event::Ready)
    .map_err(|_| "Test controller exited")?;
  let (lock, signal) = &*start;
  let started = {
    let mut gate = lock.lock().unwrap();
    while gate.is_none() {
      gate = signal.wait(gate).unwrap();
    }
    gate.unwrap()
  };
  easy.get_mut().deadline = started
    + if mode == Mode::Down {
      WINDOW
    } else {
      WINDOW + DRAIN
    };
  if mode == Mode::Down {
    // Long streams keep the link busy; only this process's body callbacks
    // are counted. The final partial request ends at the common deadline.
    while Instant::now() < started + WINDOW {
      request(&mut easy, base, mode, *SIZES.last().unwrap(), true)?;
    }
  } else {
    let mut rate = warm_size as f64 / (warm.as_secs_f64() - latency).max(0.001);
    while Instant::now() < started + WINDOW {
      let remaining = (started + WINDOW)
        .saturating_duration_since(Instant::now())
        .as_secs_f64();
      let Some(size) = choose_size(rate, latency, remaining.min(1.0)) else {
        break;
      };
      let size = size.min(8388608);
      let elapsed = request(&mut easy, base, mode, size, true)?.as_secs_f64();
      rate = size as f64 / (elapsed - latency).max(0.001);
    }
    // A same-connection HTTP/1.1 round trip follows all upload bytes. The
    // edge cannot parse this request before draining their framed bodies.
    request(&mut easy, base, Mode::Probe, 0, false)?;
    if curl(easy.num_connects())? != 0 {
      return Err("Upload confirmation connection changed".into());
    }
  }
  Ok(Instant::now())
}

fn emit(total: &AtomicU64, started: Instant, ended: Instant) {
  let rate = total.load(Ordering::Relaxed) as f64 * 8.0
    / ended.duration_since(started).as_secs_f64()
    / 1_000_000.0;
  if rate < 10.0 {
    println!("{rate:.1}");
  } else {
    println!("{rate:.0}");
  }
}

fn run(mode: Mode, json: bool) -> Result<()> {
  let connections = env::var("OMARCHY_SPEEDTEST_CONNECTIONS")
    .map(|value| {
      value
        .parse::<usize>()
        .map_err(|_| "Invalid connection count".to_owned())
    })
    .unwrap_or(Ok(DEFAULT_CONNECTIONS))?;
  if !(1..=16).contains(&connections) {
    return Err("Connection count must be 1..16".into());
  }
  let base =
    env::var("OMARCHY_SPEEDTEST_URL").unwrap_or_else(|_| "https://speed.omarchy.org".into());
  let base = base.trim_end_matches('/');
  if !(base.starts_with("https://") || base.starts_with("http://")) {
    return Err("Invalid speed test URL".into());
  }
  let total = Arc::new(AtomicU64::new(0));
  let start: Start = Arc::new((Mutex::new(None), Condvar::new()));
  let (send, receive) = mpsc::channel();
  let warmup_deadline = Instant::now() + WARMUP;
  for _ in 0..connections {
    let (base, total, start, events) =
      (base.to_owned(), total.clone(), start.clone(), send.clone());
    thread::spawn(move || {
      let result = worker(&base, mode, total, start, &events, warmup_deadline);
      let _ = events.send(Event::Done(result));
    });
  }
  drop(send);
  for _ in 0..connections {
    match receive.recv_timeout(warmup_deadline.saturating_duration_since(Instant::now())) {
      Ok(Event::Ready) => (),
      Ok(Event::Done(Err(error))) => return Err(error),
      _ => return Err("Speed test connection timed out".into()),
    }
  }
  let started = Instant::now();
  *start.0.lock().unwrap() = Some(started);
  start.1.notify_all();
  let mut finished = 0;
  let mut ended = started;
  while finished < connections {
    match receive.recv_timeout(Duration::from_millis(250)) {
      Ok(Event::Done(Ok(time))) => {
        finished += 1;
        ended = ended.max(time);
      }
      Ok(Event::Done(Err(error))) => return Err(error),
      Err(mpsc::RecvTimeoutError::Disconnected) => return Err("Speed test workers exited".into()),
      _ => (),
    }
    if Instant::now() > started + WINDOW + DRAIN + Duration::from_secs(1) {
      return Err("Speed test timed out".into());
    }
    if !json && finished < connections {
      emit(&total, started, Instant::now());
    }
  }
  if json {
    let bytes = total.load(Ordering::Relaxed);
    let seconds = if mode == Mode::Down {
      ended.min(started + WINDOW)
    } else {
      ended
    }
    .duration_since(started)
    .as_secs_f64();
    println!(
      "{}",
      serde_json::json!({"bytes": bytes, "seconds": seconds,
            "mbps": bytes as f64 * 8.0 / seconds / 1_000_000.0,
            "connections": connections})
    );
  } else {
    emit(
      &total,
      started,
      if mode == Mode::Down {
        ended.min(started + WINDOW)
      } else {
        ended
      },
    );
  }
  Ok(())
}

fn main() {
  // Arm parent-death termination before starting any connection or thread.
  // Compare against the Bash launcher's PPID to close the startup race.
  let parent = unsafe { libc::getppid() };
  let expected = env::var("OMARCHY_SPEEDTEST_PARENT_PID")
    .ok()
    .and_then(|value| value.parse().ok())
    .unwrap_or(parent);
  #[cfg(target_os = "linux")]
  if unsafe { libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGTERM) } != 0 {
    process::exit(1);
  }
  if parent == 1 || unsafe { libc::getppid() } != expected {
    process::exit(1);
  }
  let mode = match env::args().nth(1).as_deref() {
    Some("down") => Mode::Down,
    Some("up") => Mode::Up,
    _ => {
      eprintln!("Usage: omarchy-speedtest [down|up]");
      process::exit(2);
    }
  };
  if let Err(error) = run(mode, env::args().nth(2).as_deref() == Some("--json")) {
    eprintln!("Speed test failed: {error}");
    process::exit(1);
  }
}

#[cfg(test)]
mod tests {
  use super::*;
  #[test]
  fn latency_does_not_pin_fast_links_to_small_requests() {
    assert_eq!(choose_size(100_000_000.0, 0.05, 8.0), Some(67108864));
  }
  #[test]
  fn slow_links_stop_before_a_request_that_cannot_finish() {
    assert_eq!(choose_size(65536.0 / 4.5, 0.01, 3.5), None);
    assert_eq!(choose_size(65536.0 / 4.5, 0.01, 8.0), Some(65536));
  }
}
