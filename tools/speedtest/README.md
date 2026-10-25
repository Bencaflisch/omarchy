# Native network speed test

A small Rust client for `speed.omarchy.org`, using the system libcurl and eight independent persistent connections. DNS/TCP/TLS warm-up is excluded from the measurement. Downloads count only payload bytes delivered to this process; uploads count only bytes acknowledged by the server. The final value is the combined payload divided by actual elapsed time, including the last in-flight transfers.

Downloads sample five seconds of continuous body traffic. Uploads keep the connections active for roughly five seconds and confirm delivery to the edge before timing ends. Payload sizes account for fixed request latency. Every direction stays in one process, so terminating it closes all connections. Linux parent-death signalling also stops it when its launcher disappears.

Build on the target architecture with Rust, libcurl headers and pkg-config installed:

```sh
cargo build --release --locked --manifest-path tools/speedtest/Cargo.toml
cargo test --locked --manifest-path tools/speedtest/Cargo.toml
sudo install -Dm755 tools/speedtest/target/release/omarchy-speedtest /usr/lib/omarchy/speedtest
OMARCHY_SPEEDTEST_BINARY="$PWD/tools/speedtest/target/release/omarchy-speedtest" bash test/shell.d/network-speedtest-test.sh
```

The runtime packages install the release binary at `/usr/lib/omarchy/speedtest`; the compiler is needed only to build it. `bin/omarchy-network-speedtest` retains the normal `down|up` CLI and numeric progress protocol used by the panel. The native binary also supports `down --json` or `up --json` for a final record containing bytes, elapsed seconds, Mbps and connection count. `OMARCHY_SPEEDTEST_URL` selects an alternate compatible service for development; the default uses HTTPS with certificate verification. `OMARCHY_SPEEDTEST_BINARY` lets the launcher use a locally built binary during development.

Upload blocks are capped at 8 MiB; `OMARCHY_SPEEDTEST_CONNECTIONS=1..16` allows controlled concurrency comparisons (default eight).

This is a work-in-progress integration checkpoint, not a release-ready change.
