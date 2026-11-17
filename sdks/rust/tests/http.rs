//! `UreqTransport` için gerçek TCP sınaması: yerel dinleyiciye gerçek HTTP isteği gider.
use std::io::{Read, Write};
use std::net::TcpListener;
use std::sync::mpsc;
use std::time::Duration;

use feralin::{Client, Config, Consent, DeliveryError, Event};

const TEST_KEY: &str = "pk_test_rust_0001";

/// Tek bağlantı kabul eder, isteği okur, verilen yanıtı yazar; ham isteği kanala koyar.
fn serve_once(response: &'static str) -> (String, mpsc::Receiver<String>) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let address = format!("http://{}", listener.local_addr().unwrap());
    let (sender, receiver) = mpsc::channel();
    std::thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        stream.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
        let mut raw = Vec::new();
        let mut chunk = [0u8; 4096];
        loop {
            let read = stream.read(&mut chunk).unwrap_or(0);
            if read == 0 {
                break;
            }
            raw.extend_from_slice(&chunk[..read]);
            if request_complete(&raw) {
                break;
            }
        }
        stream.write_all(response.as_bytes()).unwrap();
        sender.send(String::from_utf8_lossy(&raw).into_owned()).unwrap();
    });
    (address, receiver)
}

fn request_complete(raw: &[u8]) -> bool {
    let text = String::from_utf8_lossy(raw);
    let Some(header_end) = text.find("\r\n\r\n") else {
        return false;
    };
    let length = text[..header_end]
        .lines()
        .find_map(|line| line.to_ascii_lowercase().strip_prefix("content-length:").map(|value| value.trim().parse::<usize>().unwrap_or(0)))
        .unwrap_or(0);
    raw.len() >= header_end + 4 + length
}

fn client(address: String) -> Client {
    Client::new(
        Config::new(TEST_KEY, address)
            .consent(Consent { analytics: true, ..Consent::default() })
            .flush_interval(Duration::ZERO)
            .timeout(Duration::from_secs(5)),
    )
    .unwrap()
}

#[test]
fn accepted_response_over_real_http() {
    let (address, requests) = serve_once(
        "HTTP/1.1 202 Accepted\r\nContent-Type: application/json\r\nContent-Length: 51\r\nConnection: close\r\n\r\n{\"accepted\":1,\"rejected\":0,\"batch_id\":\"batch_0001\"}",
    );
    let client = client(address);
    client.track(Event::new("order_completed").property("order_id", "ord_1")).unwrap();
    let result = client.flush().unwrap();
    assert!(result.ok(), "{:?}", result.error);
    assert_eq!(result.status, 202);
    assert_eq!(client.queued(), 0);

    let raw = requests.recv_timeout(Duration::from_secs(5)).unwrap();
    assert!(raw.starts_with("POST /v1/batch HTTP/1.1"), "{raw}");
    let lower = raw.to_ascii_lowercase();
    assert!(lower.contains(&format!("x-feralin-project-key: {TEST_KEY}")));
    assert!(lower.contains("idempotency-key:"));
    assert!(raw.contains("\"event_name\":\"order_completed\""));
}

#[test]
fn server_error_is_response_not_transport_failure() {
    let (address, _requests) =
        serve_once("HTTP/1.1 503 Service Unavailable\r\nRetry-After: 7\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
    let client = client(address);
    client.track(Event::new("e")).unwrap();
    let result = client.flush().unwrap();
    assert!(matches!(result.error, Some(DeliveryError::Temporary { status: 503, .. })));
    assert_eq!(client.queued(), 1);
    assert_eq!(client.status().backoff, Duration::from_secs(7));
    client.set_consent(Consent::default());
}

#[test]
fn rejected_response_carries_problem_summary() {
    let (address, _requests) = serve_once(
        "HTTP/1.1 401 Unauthorized\r\nContent-Type: application/problem+json\r\nContent-Length: 17\r\nConnection: close\r\n\r\n{\"title\":\"Yetki\"}",
    );
    let client = client(address);
    client.track(Event::new("e")).unwrap();
    let result = client.flush().unwrap();
    assert_eq!(result.error, Some(DeliveryError::Rejected { status: 401, detail: "Yetki".to_string() }));
    assert_eq!(client.queued(), 0);
}

#[test]
fn connection_refused_keeps_queue() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let address = format!("http://{}", listener.local_addr().unwrap());
    drop(listener);
    let client = client(address);
    client.track(Event::new("e")).unwrap();
    let result = client.flush().unwrap();
    assert!(matches!(result.error, Some(DeliveryError::Temporary { status: 0, .. })));
    assert_eq!(client.queued(), 1);
    client.set_consent(Consent::default());
}
