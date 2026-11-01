use crate::error::Result;
use hashlink::LruCache;
use hickory_proto::rr::RecordType;
use std::{
    collections::HashMap,
    convert::TryInto,
    net::{IpAddr, Ipv4Addr, Ipv6Addr},
    sync::{
        Arc,
        atomic::{AtomicU64, Ordering},
    },
    time::{Duration, Instant},
};
use tproxy_config::IpCidr;

#[derive(Debug, Default)]
pub struct VirtualDnsMetrics {
    synthetic_answers: AtomicU64,
    mapping_hits: AtomicU64,
    restored_domain_sessions: AtomicU64,
    restored_proxy_sessions: AtomicU64,
    restored_direct_sessions: AtomicU64,
    restored_block_sessions: AtomicU64,
    restored_dns_sessions: AtomicU64,
    evictions: AtomicU64,
    expirations: AtomicU64,
    allocation_collisions: AtomicU64,
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct VirtualDnsMetricsSnapshot {
    pub synthetic_answers: u64,
    pub mapping_hits: u64,
    pub restored_domain_sessions: u64,
    pub restored_proxy_sessions: u64,
    pub restored_direct_sessions: u64,
    pub restored_block_sessions: u64,
    pub restored_dns_sessions: u64,
    pub evictions: u64,
    pub expirations: u64,
    pub allocation_collisions: u64,
}

impl VirtualDnsMetrics {
    pub fn snapshot(&self) -> VirtualDnsMetricsSnapshot {
        VirtualDnsMetricsSnapshot {
            synthetic_answers: self.synthetic_answers.load(Ordering::Relaxed),
            mapping_hits: self.mapping_hits.load(Ordering::Relaxed),
            restored_domain_sessions: self.restored_domain_sessions.load(Ordering::Relaxed),
            restored_proxy_sessions: self.restored_proxy_sessions.load(Ordering::Relaxed),
            restored_direct_sessions: self.restored_direct_sessions.load(Ordering::Relaxed),
            restored_block_sessions: self.restored_block_sessions.load(Ordering::Relaxed),
            restored_dns_sessions: self.restored_dns_sessions.load(Ordering::Relaxed),
            evictions: self.evictions.load(Ordering::Relaxed),
            expirations: self.expirations.load(Ordering::Relaxed),
            allocation_collisions: self.allocation_collisions.load(Ordering::Relaxed),
        }
    }
}

struct NameCacheEntry {
    name: String,
    expiry: Instant,
}

struct AddressPool {
    network: IpAddr,
    last: IpAddr,
    next: IpAddr,
}

impl AddressPool {
    fn new(cidr: IpCidr, ipv6: bool) -> Result<Self> {
        let network = cidr.first_address();
        let last = cidr.last_address();
        if network.is_ipv6() != ipv6 || last.is_ipv6() != ipv6 {
            return Err("Virtual DNS pool address family mismatch".into());
        }
        let next = increment_ip(network)?;
        if next == last {
            return Err("Virtual DNS pool has no usable addresses".into());
        }
        Ok(Self { network, last, next })
    }

    fn take_and_advance(&mut self) -> Result<IpAddr> {
        let value = self.next;
        self.next = increment_ip(self.next)?;
        if self.next == self.last {
            self.next = increment_ip(self.network)?;
        }
        Ok(value)
    }
}

/// Per-run synthetic DNS allocator. It maps A and AAAA names independently,
/// expires idle mappings, bounds live entries, and restores original domains
/// before SOCKS/Xray routing.
pub struct VirtualDns {
    trailing_dot: bool,
    lru_cache: LruCache<IpAddr, NameCacheEntry>,
    name_to_ip: HashMap<(String, bool), IpAddr>,
    ipv4_pool: AddressPool,
    ipv6_pool: AddressPool,
    capacity: usize,
    mapping_ttl: Duration,
    answer_ttl: u32,
    metrics: Arc<VirtualDnsMetrics>,
}

impl VirtualDns {
    pub fn new(
        ipv4_pool: IpCidr,
        ipv6_pool: IpCidr,
        capacity: usize,
        mapping_ttl: Duration,
        answer_ttl: u32,
        metrics: Arc<VirtualDnsMetrics>,
    ) -> Result<Self> {
        if capacity == 0 || capacity > 4096 || mapping_ttl.is_zero() || answer_ttl == 0 {
            return Err("Virtual DNS bounds are invalid".into());
        }
        Ok(Self {
            trailing_dot: false,
            name_to_ip: HashMap::with_capacity(capacity),
            lru_cache: LruCache::new_unbounded(),
            ipv4_pool: AddressPool::new(ipv4_pool, false)?,
            ipv6_pool: AddressPool::new(ipv6_pool, true)?,
            capacity,
            mapping_ttl,
            answer_ttl,
            metrics,
        })
    }

    /// Returns a synthetic A or AAAA response for one app-facing DNS query.
    pub fn generate_query(&mut self, data: &[u8]) -> Result<(Vec<u8>, String, IpAddr)> {
        use crate::dns;
        let message = dns::parse_data_to_dns_message(data, false)?;
        let query = message.queries.first().ok_or("DnsRequest no query body")?;
        let ipv6 = match query.query_type() {
            RecordType::A => false,
            RecordType::AAAA => true,
            _ => return Err("Virtual DNS supports only A and AAAA queries".into()),
        };
        let qname = dns::extract_domain_from_dns_message(&message)?;
        let ip = self.find_or_allocate_ip(qname.clone(), ipv6)?;
        let message = dns::build_dns_response(message, &qname, ip, self.answer_ttl)?;
        self.metrics.synthetic_answers.fetch_add(1, Ordering::Relaxed);
        Ok((message.to_vec()?, qname, ip))
    }

    pub fn touch_ip(&mut self, addr: &IpAddr) {
        let now = Instant::now();
        let expired = self
            .lru_cache
            .get_mut(addr)
            .map(|entry| {
                if now >= entry.expiry {
                    true
                } else {
                    entry.expiry = now + self.mapping_ttl;
                    false
                }
            })
            .unwrap_or(false);
        if expired {
            self.remove(addr, true);
        }
    }

    pub fn resolve_ip(&mut self, addr: &IpAddr) -> Option<String> {
        let now = Instant::now();
        let expired = self.lru_cache.get(addr).map(|entry| now >= entry.expiry).unwrap_or(false);
        if expired {
            self.remove(addr, true);
            return None;
        }
        let name = self.lru_cache.get(addr).map(|entry| entry.name.clone());
        if name.is_some() {
            self.metrics.restored_domain_sessions.fetch_add(1, Ordering::Relaxed);
            match name.as_deref().and_then(proof_role) {
                Some("proxy") => &self.metrics.restored_proxy_sessions,
                Some("direct") => &self.metrics.restored_direct_sessions,
                Some("block") => &self.metrics.restored_block_sessions,
                Some("dns") => &self.metrics.restored_dns_sessions,
                _ => return self.touch_and_return(addr, name),
            }
            .fetch_add(1, Ordering::Relaxed);
            self.touch_ip(addr);
        }
        name
    }

    fn touch_and_return(&mut self, addr: &IpAddr, name: Option<String>) -> Option<String> {
        self.touch_ip(addr);
        name
    }

    fn find_or_allocate_ip(&mut self, name: String, ipv6: bool) -> Result<IpAddr> {
        let name = if name.ends_with('.') && !self.trailing_dot {
            String::from(name.trim_end_matches('.'))
        } else {
            name
        };
        self.prune_expired();
        let key = (name.clone(), ipv6);
        if let Some(ip) = self.name_to_ip.get(&key).copied() {
            self.metrics.mapping_hits.fetch_add(1, Ordering::Relaxed);
            self.touch_ip(&ip);
            return Ok(ip);
        }
        if self.lru_cache.len() >= self.capacity
            && let Some((ip, entry)) = self.lru_cache.remove_lru()
        {
            self.name_to_ip.remove(&(entry.name, ip.is_ipv6()));
            self.metrics.evictions.fetch_add(1, Ordering::Relaxed);
        }

        let pool = if ipv6 { &mut self.ipv6_pool } else { &mut self.ipv4_pool };
        let started_at = pool.next;
        let ip = loop {
            let candidate = pool.take_and_advance()?;
            if !self.lru_cache.contains_key(&candidate) {
                break candidate;
            }
            self.metrics.allocation_collisions.fetch_add(1, Ordering::Relaxed);
            if pool.next == started_at {
                return Err("Virtual IP space for DNS exhausted".into());
            }
        };
        self.lru_cache.insert(
            ip,
            NameCacheEntry {
                name: name.clone(),
                expiry: Instant::now() + self.mapping_ttl,
            },
        );
        self.name_to_ip.insert(key, ip);
        Ok(ip)
    }

    fn prune_expired(&mut self) {
        let now = Instant::now();
        loop {
            let expired_ip = self
                .lru_cache
                .iter()
                .next()
                .and_then(|(ip, entry)| (now >= entry.expiry).then_some(*ip));
            let Some(ip) = expired_ip else { break };
            self.remove(&ip, true);
        }
    }

    fn remove(&mut self, ip: &IpAddr, expired: bool) {
        if let Some(entry) = self.lru_cache.remove(ip) {
            self.name_to_ip.remove(&(entry.name, ip.is_ipv6()));
            if expired {
                self.metrics.expirations.fetch_add(1, Ordering::Relaxed);
            }
        }
    }
}

fn proof_role(domain: &str) -> Option<&str> {
    let labels: Vec<_> = domain.trim_end_matches('.').split('.').collect();
    if labels.len() < 4 || labels[labels.len() - 3..] != ["proof", "elarni", "invalid"] {
        return None;
    }
    Some(labels[labels.len() - 4])
}

fn increment_ip(addr: IpAddr) -> Result<IpAddr> {
    let mut ip_bytes = match addr {
        IpAddr::V4(ip) => Vec::<u8>::from(ip.octets()),
        IpAddr::V6(ip) => Vec::<u8>::from(ip.octets()),
    };
    for index in (0..ip_bytes.len()).rev() {
        if ip_bytes[index] != 255 {
            ip_bytes[index] += 1;
            break;
        }
        ip_bytes[index] = 0;
    }
    if addr.is_ipv4() {
        let bytes: [u8; 4] = ip_bytes.as_slice().try_into()?;
        Ok(IpAddr::V4(Ipv4Addr::from(bytes)))
    } else {
        let bytes: [u8; 16] = ip_bytes.as_slice().try_into()?;
        Ok(IpAddr::V6(Ipv6Addr::from(bytes)))
    }
}
