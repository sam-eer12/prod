//! Bounded digital-edge journal and receiver reordering.
//!
//! Analog snapshots alone cannot recover a press and release that both happen
//! between two state ticks. Every button-bitmap change gets a monotonically
//! increasing edge ID. Senders retransmit unacknowledged entries, and receivers
//! apply only the contiguous prefix so a missing transition can never be
//! silently skipped.

use std::collections::{BTreeMap, VecDeque};

use crate::error::ProtocolError;
use crate::frame::{Buttons, Edge, EdgesPayload, MAX_EDGES_PER_FRAME};

/// Maximum unacknowledged transitions retained by either peer.
pub const MAX_EDGE_JOURNAL: usize = 32;

/// Sender-side ordered journal.
#[derive(Debug, Clone)]
pub struct EdgeJournal {
    capacity: usize,
    entries: VecDeque<Edge>,
    next_edge_id: u64,
    highest_issued: u64,
    acknowledged: u64,
}

impl EdgeJournal {
    /// Creates a journal with the protocol limit.
    pub fn new() -> Self {
        Self::with_capacity(MAX_EDGE_JOURNAL)
    }

    /// Creates a journal with a smaller capacity, primarily for tests.
    pub fn with_capacity(capacity: usize) -> Self {
        let capacity = capacity.clamp(1, MAX_EDGE_JOURNAL);
        Self {
            capacity,
            entries: VecDeque::with_capacity(capacity),
            next_edge_id: 1,
            highest_issued: 0,
            acknowledged: 0,
        }
    }

    /// Records one button-bitmap transition.
    pub fn push(&mut self, buttons: Buttons, event_time_us: u64) -> Result<u64, ProtocolError> {
        if self.entries.len() >= self.capacity {
            return Err(ProtocolError::EdgeJournalFull {
                capacity: self.capacity,
            });
        }

        let edge_id = self.next_edge_id;
        self.next_edge_id = self
            .next_edge_id
            .checked_add(1)
            .ok_or(ProtocolError::SequenceExhausted)?;

        self.entries.push_back(Edge {
            edge_id,
            buttons,
            event_time_us,
        });
        self.highest_issued = edge_id;
        Ok(edge_id)
    }

    /// Drops entries covered by a contiguous receiver acknowledgment.
    ///
    /// Acknowledgments are monotonic. An acknowledgment above the highest
    /// issued edge is a protocol error.
    pub fn acknowledge(&mut self, highest_contiguous: u64) -> Result<usize, ProtocolError> {
        if highest_contiguous > self.highest_issued {
            return Err(ProtocolError::InvalidAcknowledgement {
                acknowledged: highest_contiguous,
                highest_issued: self.highest_issued,
            });
        }
        if highest_contiguous <= self.acknowledged {
            return Ok(0);
        }

        self.acknowledged = highest_contiguous;
        let mut removed = 0;
        while self
            .entries
            .front()
            .is_some_and(|edge| edge.edge_id <= highest_contiguous)
        {
            self.entries.pop_front();
            removed += 1;
        }
        Ok(removed)
    }

    /// Up to `limit` unacknowledged entries in ascending order.
    pub fn pending_batch(&self, limit: usize) -> Option<EdgesPayload> {
        let limit = limit.min(MAX_EDGES_PER_FRAME);
        if limit == 0 || self.entries.is_empty() {
            return None;
        }
        Some(EdgesPayload {
            entries: self.entries.iter().take(limit).copied().collect(),
        })
    }

    /// Highest edge ID ever issued.
    pub const fn highest_issued(&self) -> u64 {
        self.highest_issued
    }

    /// Highest acknowledged edge ID.
    pub const fn acknowledged(&self) -> u64 {
        self.acknowledged
    }

    /// Number of unacknowledged entries still retained.
    pub fn len(&self) -> usize {
        self.entries.len()
    }

    /// Returns whether no unacknowledged entries remain.
    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    /// Returns whether the journal cannot accept another transition.
    pub fn is_full(&self) -> bool {
        self.entries.len() >= self.capacity
    }

    /// Removes every entry and starts a fresh edge sequence.
    pub fn reset(&mut self) {
        self.entries.clear();
        self.next_edge_id = 1;
        self.highest_issued = 0;
        self.acknowledged = 0;
    }
}

impl Default for EdgeJournal {
    fn default() -> Self {
        Self::new()
    }
}

/// Receiver-side reordering buffer.
#[derive(Debug, Clone)]
pub struct EdgeReceiver {
    highest_contiguous: u64,
    reorder: BTreeMap<u64, Edge>,
}

impl EdgeReceiver {
    /// Creates an empty receiver with a baseline of zero.
    pub fn new() -> Self {
        Self {
            highest_contiguous: 0,
            reorder: BTreeMap::new(),
        }
    }

    /// Receives a batch and returns the newly contiguous prefix.
    ///
    /// Duplicates are ignored. IDs farther than [`MAX_EDGE_JOURNAL`] ahead of
    /// the current cursor are rejected rather than buffered.
    pub fn receive(&mut self, entries: &[Edge]) -> Result<EdgeDelivery, ProtocolError> {
        // Validate the complete batch before inserting any entry. A rejected
        // batch must not become input through a later receive operation.
        for edge in entries {
            if edge.edge_id <= self.highest_contiguous {
                continue;
            }

            let farthest = self
                .highest_contiguous
                .checked_add(MAX_EDGE_JOURNAL as u64)
                .ok_or(ProtocolError::SequenceExhausted)?;
            if edge.edge_id > farthest {
                return Err(ProtocolError::EdgeOutOfWindow {
                    edge_id: edge.edge_id,
                    highest_contiguous: self.highest_contiguous,
                });
            }
        }
        for edge in entries {
            if edge.edge_id <= self.highest_contiguous {
                continue;
            }
            if self.reorder.contains_key(&edge.edge_id) {
                continue;
            }
            if self.reorder.len() >= MAX_EDGE_JOURNAL {
                return Err(ProtocolError::EdgeJournalFull {
                    capacity: MAX_EDGE_JOURNAL,
                });
            }
            self.reorder.insert(edge.edge_id, *edge);
        }

        let mut applied = Vec::new();
        while let Some(next) = self.highest_contiguous.checked_add(1) {
            let Some(edge) = self.reorder.remove(&next) else {
                break;
            };
            self.highest_contiguous = next;
            applied.push(edge);
        }

        Ok(EdgeDelivery {
            applied,
            highest_contiguous: self.highest_contiguous,
            has_gap: !self.reorder.is_empty(),
        })
    }

    /// Highest edge ID applied in contiguous order.
    pub const fn highest_contiguous(&self) -> u64 {
        self.highest_contiguous
    }

    /// First missing edge ID when a gap exists.
    pub fn missing_from(&self) -> Option<u64> {
        if self.reorder.is_empty() {
            None
        } else {
            self.highest_contiguous.checked_add(1)
        }
    }

    /// Number of buffered transitions waiting on a gap.
    pub fn buffered(&self) -> usize {
        self.reorder.len()
    }

    /// Clears the cursor and every buffered transition.
    pub fn reset(&mut self) {
        self.highest_contiguous = 0;
        self.reorder.clear();
    }
}

impl Default for EdgeReceiver {
    fn default() -> Self {
        Self::new()
    }
}

/// Result of one receive operation.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EdgeDelivery {
    /// Transitions that became contiguous and should be applied in order.
    pub applied: Vec<Edge>,
    /// Cursor after applying the contiguous prefix.
    pub highest_contiguous: u64,
    /// Whether later transitions are still buffered behind a gap.
    pub has_gap: bool,
}

#[cfg(test)]
mod tests {
    use super::*;

    fn edge(edge_id: u64, buttons: Buttons) -> Edge {
        Edge {
            edge_id,
            buttons,
            event_time_us: edge_id * 10,
        }
    }

    #[test]
    fn journal_issues_monotonic_ids_and_acknowledges() {
        let mut journal = EdgeJournal::new();
        assert_eq!(journal.push(Buttons::A, 10).unwrap(), 1);
        assert_eq!(journal.push(Buttons::neutral(), 20).unwrap(), 2);
        assert_eq!(journal.highest_issued(), 2);
        assert_eq!(journal.len(), 2);

        assert_eq!(journal.acknowledge(1).unwrap(), 1);
        assert_eq!(journal.acknowledged(), 1);
        assert_eq!(journal.len(), 1);
        assert_eq!(journal.pending_batch(12).unwrap().entries.len(), 1);

        assert_eq!(journal.acknowledge(2).unwrap(), 1);
        assert!(journal.is_empty());
    }

    #[test]
    fn acknowledgment_cannot_exceed_issued_edges() {
        let mut journal = EdgeJournal::new();
        journal.push(Buttons::A, 10).unwrap();
        assert_eq!(
            journal.acknowledge(2),
            Err(ProtocolError::InvalidAcknowledgement {
                acknowledged: 2,
                highest_issued: 1
            })
        );
        assert_eq!(journal.acknowledge(0).unwrap(), 0);
    }

    #[test]
    fn journal_is_bounded() {
        let mut journal = EdgeJournal::with_capacity(2);
        journal.push(Buttons::A, 1).unwrap();
        journal.push(Buttons::B, 2).unwrap();
        assert!(journal.is_full());
        assert_eq!(
            journal.push(Buttons::X, 3),
            Err(ProtocolError::EdgeJournalFull { capacity: 2 })
        );
    }

    #[test]
    fn short_tap_between_state_ticks_is_recovered() {
        let mut journal = EdgeJournal::new();
        journal.push(Buttons::A, 100).unwrap();
        journal.push(Buttons::neutral(), 110).unwrap();

        let batch = journal.pending_batch(12).unwrap();
        let mut receiver = EdgeReceiver::new();
        let delivery = receiver.receive(&batch.entries).unwrap();

        assert_eq!(delivery.applied.len(), 2);
        assert_eq!(delivery.applied[0].buttons, Buttons::A);
        assert_eq!(delivery.applied[1].buttons, Buttons::neutral());
        assert_eq!(delivery.highest_contiguous, 2);
        assert!(!delivery.has_gap);
    }

    #[test]
    fn receiver_applies_reordered_edges_in_order() {
        let mut receiver = EdgeReceiver::new();
        let first = receiver
            .receive(&[edge(2, Buttons::A), edge(1, Buttons::neutral())])
            .unwrap();
        assert_eq!(first.highest_contiguous, 2);
        assert_eq!(first.applied.len(), 2);
        assert_eq!(first.applied[0].edge_id, 1);
        assert_eq!(first.applied[1].edge_id, 2);
    }

    #[test]
    fn receiver_buffers_a_gap_without_skipping_it() {
        let mut receiver = EdgeReceiver::new();
        let delivery = receiver.receive(&[edge(2, Buttons::A)]).unwrap();
        assert!(delivery.applied.is_empty());
        assert_eq!(delivery.highest_contiguous, 0);
        assert!(delivery.has_gap);
        assert_eq!(receiver.missing_from(), Some(1));
        assert_eq!(receiver.buffered(), 1);

        let delivery = receiver.receive(&[edge(1, Buttons::neutral())]).unwrap();
        assert_eq!(delivery.applied.len(), 2);
        assert_eq!(delivery.highest_contiguous, 2);
        assert_eq!(receiver.missing_from(), None);
    }

    #[test]
    fn receiver_ignores_duplicates() {
        let mut receiver = EdgeReceiver::new();
        let batch = [edge(1, Buttons::A), edge(2, Buttons::neutral())];
        assert_eq!(receiver.receive(&batch).unwrap().applied.len(), 2);
        let duplicate = receiver.receive(&batch).unwrap();
        assert!(duplicate.applied.is_empty());
        assert_eq!(duplicate.highest_contiguous, 2);
    }

    #[test]
    fn receiver_rejects_far_future_edges() {
        let mut receiver = EdgeReceiver::new();
        let far = MAX_EDGE_JOURNAL as u64 + 1;
        assert_eq!(
            receiver.receive(&[edge(far, Buttons::A)]),
            Err(ProtocolError::EdgeOutOfWindow {
                edge_id: far,
                highest_contiguous: 0
            })
        );
    }

    #[test]
    fn receiver_reordering_storage_is_bounded() {
        let mut receiver = EdgeReceiver::new();
        let entries: Vec<Edge> = (2..=MAX_EDGE_JOURNAL as u64)
            .map(|id| edge(id, Buttons::neutral()))
            .collect();
        receiver.receive(&entries).unwrap();
        assert_eq!(receiver.buffered(), MAX_EDGE_JOURNAL - 1);
        assert_eq!(
            receiver.receive(&[edge(MAX_EDGE_JOURNAL as u64 + 1, Buttons::A)]),
            Err(ProtocolError::EdgeOutOfWindow {
                edge_id: MAX_EDGE_JOURNAL as u64 + 1,
                highest_contiguous: 0
            })
        );
    }

    #[test]
    fn reset_starts_a_new_baseline() {
        let mut journal = EdgeJournal::new();
        journal.push(Buttons::A, 1).unwrap();
        journal.acknowledge(1).unwrap();
        journal.reset();
        assert_eq!(journal.highest_issued(), 0);
        assert_eq!(journal.push(Buttons::B, 2).unwrap(), 1);

        let mut receiver = EdgeReceiver::new();
        receiver.receive(&[edge(1, Buttons::A)]).unwrap();
        receiver.reset();
        assert_eq!(receiver.highest_contiguous(), 0);
    }
}
