use std::sync::Mutex;
use std::time::SystemTime;

use crate::time::epoch_millis;

const CROCKFORD: &[u8; 32] = b"0123456789ABCDEFGHJKMNPQRSTVWXYZ";

struct State {
    last_millis: Option<u64>,
    last_random: [u8; 16],
}

/// Monotonik ULID üretimi (26 karakter Crockford base32). Web ve Python SDK'larıyla aynı düzen:
/// 10 karakter zaman (ms) + 16 adet 5 bitlik rastgele basamak (80 bit). İş parçacığı güvenlidir.
pub struct UlidGenerator {
    state: Mutex<State>,
}

impl Default for UlidGenerator {
    fn default() -> Self {
        Self::new()
    }
}

impl UlidGenerator {
    pub fn new() -> Self {
        Self { state: Mutex::new(State { last_millis: None, last_random: [0; 16] }) }
    }

    /// Şimdiki zamanla üretir.
    pub fn generate(&self) -> String {
        self.at(epoch_millis(SystemTime::now()))
    }

    /// Verilen milisaniyeyle üretir. Aynı milisaniyede ya da saat geri gittiğinde son değeri artırarak sıralamayı korur.
    pub fn at(&self, now_millis: u64) -> String {
        let mut state = self.state.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        let previous = state.last_millis;
        let millis = match previous {
            Some(last) if now_millis <= last => {
                if increment(&mut state.last_random) {
                    last
                } else {
                    fill_random(&mut state.last_random);
                    last + 1
                }
            }
            _ => {
                fill_random(&mut state.last_random);
                now_millis
            }
        };
        state.last_millis = Some(millis);

        let mut out = [0u8; 26];
        let mut rest = millis;
        for slot in out[..10].iter_mut().rev() {
            *slot = CROCKFORD[(rest & 31) as usize];
            rest >>= 5;
        }
        for (slot, digit) in out[10..].iter_mut().zip(state.last_random.iter()) {
            *slot = CROCKFORD[*digit as usize];
        }
        out.iter().map(|byte| *byte as char).collect()
    }

    #[cfg(test)]
    fn saturate_random(&self) {
        self.state.lock().unwrap().last_random = [31; 16];
    }
}

fn fill_random(digits: &mut [u8; 16]) {
    let mut buffer = [0u8; 16];
    // İşletim sistemi rastgelesi alınamıyorsa zayıf değerle devam edilmez: event_id tekilliği buna dayanır.
    getrandom::fill(&mut buffer).expect("işletim sistemi rastgele kaynağı okunamadı");
    for (digit, byte) in digits.iter_mut().zip(buffer.iter()) {
        *digit = byte & 31;
    }
}

/// Rastgele kısmı base32 düzeninde bir artırır; tüm basamaklar taşarsa false döner.
fn increment(digits: &mut [u8; 16]) -> bool {
    for digit in digits.iter_mut().rev() {
        if *digit < 31 {
            *digit += 1;
            return true;
        }
        *digit = 0;
    }
    false
}

/// 26 karakterlik Crockford base32 ULID biçim denetimi (ilk karakter en fazla '7').
pub fn is_ulid(value: &str) -> bool {
    let bytes = value.as_bytes();
    bytes.len() == 26 && bytes[0] <= b'7' && bytes.iter().all(|byte| CROCKFORD.contains(byte))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashSet;
    use std::sync::Arc;

    const FIXED_MILLIS: u64 = 1_793_703_600_000;

    #[test]
    fn format_is_valid() {
        let generator = UlidGenerator::new();
        for _ in 0..1000 {
            assert!(is_ulid(&generator.generate()));
        }
        for bad in
            ["", "01ARZ3NDEKTSV4RRFFQ69G5FAV1", "01ARZ3NDEKTSV4RRFFQ69G5FA", "01ARZ3NDEKTSV4RRFFQ69G5FAI", "81ARZ3NDEKTSV4RRFFQ69G5FAV"]
        {
            assert!(!is_ulid(bad), "{bad}");
        }
    }

    #[test]
    fn timestamp_prefix_round_trips() {
        let value = UlidGenerator::new().at(FIXED_MILLIS);
        let mut millis = 0u64;
        for byte in value[..10].bytes() {
            millis = millis * 32 + CROCKFORD.iter().position(|c| *c == byte).unwrap() as u64;
        }
        assert_eq!(millis, FIXED_MILLIS);
    }

    #[test]
    fn monotonic_within_same_millisecond() {
        let generator = UlidGenerator::new();
        let mut previous = generator.at(FIXED_MILLIS);
        for _ in 0..5000 {
            let current = generator.at(FIXED_MILLIS);
            assert!(previous < current);
            assert_eq!(previous[..10], current[..10]);
            previous = current;
        }
    }

    #[test]
    fn monotonic_when_clock_goes_backwards() {
        let generator = UlidGenerator::new();
        let first = generator.at(FIXED_MILLIS);
        assert!(generator.at(FIXED_MILLIS - 10_000) > first);
    }

    #[test]
    fn random_overflow_advances_time() {
        let generator = UlidGenerator::new();
        let first = generator.at(FIXED_MILLIS);
        generator.saturate_random();
        let next = generator.at(FIXED_MILLIS);
        assert!(next > first);
        assert_ne!(next[..10], first[..10]);
    }

    #[test]
    fn concurrent_values_are_unique() {
        let generator = Arc::new(UlidGenerator::new());
        let mut handles = Vec::new();
        for _ in 0..8 {
            let generator = Arc::clone(&generator);
            handles.push(std::thread::spawn(move || (0..500).map(|_| generator.generate()).collect::<Vec<_>>()));
        }
        let mut seen = HashSet::new();
        for handle in handles {
            for value in handle.join().unwrap() {
                assert!(seen.insert(value));
            }
        }
        assert_eq!(seen.len(), 4000);
    }
}
