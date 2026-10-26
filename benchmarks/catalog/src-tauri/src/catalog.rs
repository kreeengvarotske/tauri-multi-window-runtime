//! The catalog: a deterministic data set, its served form (indexes built
//! once) and a naive reference implementation used only for expected
//! checksums.

use serde::{Deserialize, Serialize};
use std::cmp::Ordering;

/// Number of categories. Category ids are `0..CATEGORIES`.
pub const CATEGORIES: u16 = 32;

/// One catalog record. Strings are ASCII, so the checksum of a record is the
/// same whether it is computed over Rust bytes or JS UTF-16 code units.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Record {
    pub id: u32,
    pub name: String,
    pub category: u16,
    pub price_cents: u32,
    pub created_at: u32,
    pub updated_at: u32,
    pub note: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Sort {
    Name,
    Price,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PageQuery {
    pub sort: Sort,
    pub category: Option<u16>,
    pub offset: u32,
    pub limit: u32,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Page {
    /// Records matching the filter, not just the ones on this page.
    pub total: u32,
    pub rows: Vec<Record>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CategoryTotal {
    pub category: u16,
    pub count: u32,
    pub sum_cents: u64,
}

// ------------------------------------------------------------ generation

const SYLLABLES: [&str; 16] = [
    "ka", "lo", "mi", "ra", "su", "te", "vo", "zen", "bri", "dal", "fen", "gor", "hal", "jun",
    "pex", "qua",
];
const WORDS: [&str; 24] = [
    "steel", "bolt", "cotton", "shirt", "lamp", "desk", "garden", "hose", "paper", "ink", "glass",
    "jar", "cable", "drill", "rope", "tile", "brush", "paint", "valve", "pump", "chair", "board",
    "clock", "frame",
];

/// xorshift64*; deterministic across platforms.
struct Rng(u64);

impl Rng {
    fn new(seed: u64) -> Self {
        Self(seed.wrapping_mul(0x9e37_79b9_7f4a_7c15) | 1)
    }
    fn next(&mut self) -> u64 {
        let mut x = self.0;
        x ^= x >> 12;
        x ^= x << 25;
        x ^= x >> 27;
        self.0 = x;
        x.wrapping_mul(0x2545_f491_4f6c_dd1d)
    }
    fn below(&mut self, n: u64) -> u64 {
        self.next() % n
    }
}

fn record(id: u32, rng: &mut Rng) -> Record {
    let mut name = String::new();
    for _ in 0..2 + rng.below(2) {
        name.push_str(SYLLABLES[rng.below(16) as usize]);
    }
    name.shrink_to_fit();
    let note_len = 40 + rng.below(81) as usize;
    let mut note = String::with_capacity(note_len + 8);
    while note.len() < note_len {
        if !note.is_empty() {
            note.push(' ');
        }
        note.push_str(WORDS[rng.below(24) as usize]);
    }
    note.truncate(note_len);
    note.shrink_to_fit();
    let created_at = 1_600_000_000 + rng.below(100_000_000) as u32;
    Record {
        id,
        name,
        category: rng.below(u64::from(CATEGORIES)) as u16,
        price_cents: 100 + rng.below(999_900) as u32,
        created_at,
        updated_at: created_at + rng.below(10_000_000) as u32,
        note,
    }
}

/// Bytes one record retains in the Rust representation.
pub fn record_bytes(record: &Record) -> usize {
    size_of::<Record>() + record.name.capacity() + record.note.capacity()
}

/// Bytes of the indexes `Catalog::new` builds for `records` records: two
/// sort orders and one price order per category (`u32` positions).
pub const fn index_bytes(records: usize) -> usize {
    3 * records * size_of::<u32>()
}

/// Generates records until the served catalog (records plus indexes) holds
/// at least `target_bytes`. `0` gives an empty catalog. Deterministic for a
/// seed.
pub fn generate(seed: u64, target_bytes: usize) -> Vec<Record> {
    let mut rng = Rng::new(seed);
    let mut records = Vec::new();
    let mut bytes = 0;
    while bytes < target_bytes {
        let record = record(records.len() as u32, &mut rng);
        bytes += record_bytes(&record) + index_bytes(1);
        records.push(record);
    }
    records.shrink_to_fit();
    records
}

/// Bytes the served catalog retains: records (with string capacity) and
/// indexes. This is `RustDataBytes` in the report.
pub fn data_bytes(records: &[Record]) -> usize {
    records.iter().map(record_bytes).sum::<usize>() + index_bytes(records.len())
}

// ------------------------------------------------------------- ordering

fn compare(records: &[Record], sort: Sort, a: u32, b: u32) -> Ordering {
    let (x, y) = (&records[a as usize], &records[b as usize]);
    let primary = match sort {
        Sort::Name => x.name.as_bytes().cmp(y.name.as_bytes()),
        Sort::Price => x.price_cents.cmp(&y.price_cents),
    };
    primary.then(x.id.cmp(&y.id))
}

fn sorted(records: &[Record], sort: Sort, mut positions: Vec<u32>) -> Vec<u32> {
    positions.sort_by(|a, b| compare(records, sort, *a, *b));
    positions
}

// --------------------------------------------------------- served form

/// The catalog as a shared service keeps it: records plus indexes built once,
/// so every view does work proportional to its response.
pub struct Catalog {
    records: Vec<Record>,
    by_name: Vec<u32>,
    by_price: Vec<u32>,
    /// Positions of each category's records, by price. Together they hold
    /// every position once.
    by_category_price: Vec<Vec<u32>>,
    totals: Vec<CategoryTotal>,
}

impl Catalog {
    pub fn new(records: Vec<Record>) -> Self {
        let all: Vec<u32> = (0..records.len() as u32).collect();
        let by_name = sorted(&records, Sort::Name, all.clone());
        let by_price = sorted(&records, Sort::Price, all);
        let mut by_category_price = vec![Vec::new(); usize::from(CATEGORIES)];
        for &position in &by_price {
            by_category_price[usize::from(records[position as usize].category)].push(position);
        }
        for positions in &mut by_category_price {
            positions.shrink_to_fit();
        }
        let totals = reference_aggregate(&records);
        Self {
            records,
            by_name,
            by_price,
            by_category_price,
            totals,
        }
    }

    pub fn len(&self) -> usize {
        self.records.len()
    }

    pub fn is_empty(&self) -> bool {
        self.records.is_empty()
    }

    pub fn data_bytes(&self) -> usize {
        data_bytes(&self.records)
    }

    pub fn page(&self, query: &PageQuery) -> Page {
        let order: &[u32] = match (query.category, query.sort) {
            (Some(category), Sort::Price) => &self.by_category_price[usize::from(category)],
            (None, Sort::Price) => &self.by_price,
            (None, Sort::Name) => &self.by_name,
            // Not used by the workload; correct but proportional to the
            // catalog, so the service refuses it (see `validate_page`).
            (Some(_), Sort::Name) => return reference_page(&self.records, query),
        };
        let rows = order
            .iter()
            .skip(query.offset as usize)
            .take(query.limit as usize)
            .map(|&position| self.records[position as usize].clone())
            .collect();
        Page {
            total: order.len() as u32,
            rows,
        }
    }

    pub fn aggregate(&self) -> Vec<CategoryTotal> {
        self.totals.clone()
    }

    /// Records by id; ids are positions. Unknown ids are skipped.
    pub fn get(&self, ids: &[u32]) -> Vec<Record> {
        ids.iter()
            .filter_map(|&id| self.records.get(id as usize).cloned())
            .collect()
    }
}

// ----------------------------------------------------------- reference

/// Naive page: filter, sort a copy, slice. Used for expected checksums only.
pub fn reference_page(records: &[Record], query: &PageQuery) -> Page {
    let matching: Vec<u32> = (0..records.len() as u32)
        .filter(|&p| {
            query
                .category
                .is_none_or(|c| records[p as usize].category == c)
        })
        .collect();
    let total = matching.len() as u32;
    let rows = sorted(records, query.sort, matching)
        .into_iter()
        .skip(query.offset as usize)
        .take(query.limit as usize)
        .map(|p| records[p as usize].clone())
        .collect();
    Page { total, rows }
}

pub fn reference_aggregate(records: &[Record]) -> Vec<CategoryTotal> {
    let mut totals: Vec<CategoryTotal> = (0..CATEGORIES)
        .map(|category| CategoryTotal {
            category,
            count: 0,
            sum_cents: 0,
        })
        .collect();
    for record in records {
        let total = &mut totals[usize::from(record.category)];
        total.count += 1;
        total.sum_cents += u64::from(record.price_cents);
    }
    totals
}

pub fn reference_get(records: &[Record], ids: &[u32]) -> Vec<Record> {
    ids.iter()
        .filter_map(|&id| records.iter().find(|r| r.id == id).cloned())
        .collect()
}

// ------------------------------------------------------------ checksums

/// FNV-1a, 32 bit, over ASCII text. The frontend computes the same function
/// over the same canonical text.
pub fn fnv1a32(text: &str) -> u32 {
    text.bytes().fold(0x811c_9dc5, |hash, byte| {
        (hash ^ u32::from(byte)).wrapping_mul(0x0100_0193)
    })
}

fn record_line(out: &mut String, r: &Record) {
    use std::fmt::Write;
    let _ = writeln!(
        out,
        "{}|{}|{}|{}|{}|{}|{}",
        r.id, r.name, r.category, r.price_cents, r.created_at, r.updated_at, r.note
    );
}

pub fn page_checksum(page: &Page) -> String {
    let mut text = format!("total={}\n", page.total);
    for row in &page.rows {
        record_line(&mut text, row);
    }
    format!("{:08x}", fnv1a32(&text))
}

pub fn aggregate_checksum(totals: &[CategoryTotal]) -> String {
    let text: String = totals
        .iter()
        .map(|t| format!("{}|{}|{}\n", t.category, t.count, t.sum_cents))
        .collect();
    format!("{:08x}", fnv1a32(&text))
}

pub fn records_checksum(records: &[Record]) -> String {
    let mut text = String::new();
    for record in records {
        record_line(&mut text, record);
    }
    format!("{:08x}", fnv1a32(&text))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn generation_is_deterministic_and_reaches_the_target_size() {
        assert!(generate(1, 0).is_empty());
        let a = generate(7, 1 << 20);
        let b = generate(7, 1 << 20);
        assert_eq!(a, b);
        assert_ne!(a, generate(8, 1 << 20));
        let bytes = data_bytes(&a);
        assert!(bytes >= 1 << 20, "{bytes}");
        // overshoot is at most one record
        assert!(bytes - (1 << 20) < 400, "{bytes}");
        assert!(a.iter().all(|r| r.name.is_ascii() && r.note.is_ascii()));
        assert!(a.iter().enumerate().all(|(i, r)| r.id == i as u32));
    }

    #[test]
    fn served_pages_match_the_reference() {
        let records = generate(3, 256 << 10);
        let catalog = Catalog::new(records.clone());
        for query in [
            PageQuery {
                sort: Sort::Name,
                category: None,
                offset: 0,
                limit: 100,
            },
            PageQuery {
                sort: Sort::Name,
                category: None,
                offset: 700,
                limit: 100,
            },
            PageQuery {
                sort: Sort::Price,
                category: None,
                offset: 50,
                limit: 100,
            },
            PageQuery {
                sort: Sort::Price,
                category: Some(5),
                offset: 0,
                limit: 100,
            },
            PageQuery {
                sort: Sort::Price,
                category: Some(31),
                offset: 10,
                limit: 7,
            },
            PageQuery {
                sort: Sort::Name,
                category: None,
                offset: 1_000_000,
                limit: 100,
            },
        ] {
            assert_eq!(
                catalog.page(&query),
                reference_page(&records, &query),
                "{query:?}"
            );
        }
        assert_eq!(catalog.aggregate(), reference_aggregate(&records));
        let ids = [0, 5, 17, records.len() as u32 - 1];
        assert_eq!(catalog.get(&ids), reference_get(&records, &ids));
    }

    #[test]
    fn name_order_breaks_ties_by_id() {
        let records = generate(5, 512 << 10);
        let catalog = Catalog::new(records.clone());
        let all = catalog.page(&PageQuery {
            sort: Sort::Name,
            category: None,
            offset: 0,
            limit: records.len() as u32,
        });
        let has_tie = all.rows.windows(2).any(|w| w[0].name == w[1].name);
        assert!(has_tie, "the data set should contain equal names");
        assert!(
            all.rows
                .windows(2)
                .all(|w| (w[0].name.as_bytes(), w[0].id) < (w[1].name.as_bytes(), w[1].id))
        );
    }

    #[test]
    fn checksums_pin_the_canonical_text() {
        assert_eq!(fnv1a32(""), 0x811c_9dc5);
        assert_eq!(fnv1a32("a"), 0xe40c_292c);
        let row = Record {
            id: 1,
            name: "kalo".into(),
            category: 2,
            price_cents: 300,
            created_at: 4,
            updated_at: 5,
            note: "steel bolt".into(),
        };
        let page = Page {
            total: 9,
            rows: vec![row.clone()],
        };
        assert_eq!(
            page_checksum(&page),
            format!("{:08x}", fnv1a32("total=9\n1|kalo|2|300|4|5|steel bolt\n"))
        );
        assert_eq!(
            records_checksum(&[row]),
            format!("{:08x}", fnv1a32("1|kalo|2|300|4|5|steel bolt\n"))
        );
        let totals = [CategoryTotal {
            category: 0,
            count: 2,
            sum_cents: 10,
        }];
        assert_eq!(
            aggregate_checksum(&totals),
            format!("{:08x}", fnv1a32("0|2|10\n"))
        );
    }

    #[test]
    fn data_bytes_count_records_strings_and_indexes() {
        let records = generate(1, 64 << 10);
        let expected: usize = records
            .iter()
            .map(|r| size_of::<Record>() + r.name.capacity() + r.note.capacity())
            .sum::<usize>()
            + 12 * records.len();
        assert_eq!(data_bytes(&records), expected);
        assert_eq!(Catalog::new(records.clone()).data_bytes(), expected);
    }
}
