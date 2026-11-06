//! Combines authenticated state snapshots with the contiguous digital-edge
//! prefix into one gamepad output state.
//!
//! Axes and triggers may advance as soon as a fresh State packet arrives, but
//! the digital button bitmap is applied only when the edge cursor matches the
//! snapshot. A snapshot ahead of the cursor requests retransmission; one behind
//! the cursor cannot roll buttons back.

use crate::edge::{EdgeDelivery, MAX_EDGE_JOURNAL};
use crate::error::ProtocolError;
use crate::frame::{Buttons, StatePayload, Stick};

/// The exact gamepad state a backend should apply.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct OutputState {
    pub buttons: Buttons,
    pub left_trigger: u8,
    pub right_trigger: u8,
    pub left_stick: Stick,
    pub right_stick: Stick,
}

impl OutputState {
    /// Neutral controls: nothing pressed, sticks centered, triggers released.
    pub const fn neutral() -> Self {
        Self {
            buttons: Buttons::neutral(),
            left_trigger: 0,
            right_trigger: 0,
            left_stick: Stick::NEUTRAL,
            right_stick: Stick::NEUTRAL,
        }
    }

    /// Returns whether every control is neutral.
    pub fn is_neutral(&self) -> bool {
        *self == Self::neutral()
    }
}

/// How a State snapshot related to the digital-edge cursor.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StateDisposition {
    /// The snapshot's digital bitmap was applied.
    Applied,
    /// The snapshot is older than already-applied edges; its buttons were ignored.
    SnapshotBehind,
    /// Edges are missing, so axes advanced but buttons were held.
    AwaitingEdges { missing_from: u64 },
}

/// Stateful receiver-side assembler.
#[derive(Debug, Clone)]
pub struct InputAssembler {
    cursor: u64,
    output: OutputState,
}

impl InputAssembler {
    /// Creates an assembler at the neutral baseline.
    pub fn new() -> Self {
        Self {
            cursor: 0,
            output: OutputState::neutral(),
        }
    }

    /// Applies a contiguous edge delivery and returns one backend report for
    /// each transition. A press/release pair must never collapse into one report.
    /// The entire delivery is validated before changing the assembler.
    pub fn apply_edges(
        &mut self,
        delivery: &EdgeDelivery,
    ) -> Result<Vec<OutputState>, ProtocolError> {
        if delivery.applied.len() > MAX_EDGE_JOURNAL {
            return Err(ProtocolError::EdgeJournalFull {
                capacity: MAX_EDGE_JOURNAL,
            });
        }
        let mut cursor = self.cursor;
        for edge in &delivery.applied {
            let expected = cursor
                .checked_add(1)
                .ok_or(ProtocolError::SequenceExhausted)?;
            if edge.edge_id != expected {
                return Err(ProtocolError::EdgeOutOfWindow {
                    edge_id: edge.edge_id,
                    highest_contiguous: cursor,
                });
            }
            cursor = edge.edge_id;
        }
        let mut reports = Vec::new();
        reports
            .try_reserve_exact(delivery.applied.len())
            .map_err(|_| ProtocolError::ResourceExhausted)?;
        for edge in &delivery.applied {
            self.output.buttons = edge.buttons;
            self.cursor = edge.edge_id;
            reports.push(self.output);
        }
        Ok(reports)
    }

    /// Applies one authenticated, fresh State snapshot.
    pub fn apply_state(&mut self, state: &StatePayload) -> StateDisposition {
        // Analog values are safe to update immediately. They have no ordering
        // relationship with the digital-edge journal.
        self.output.left_trigger = state.left_trigger;
        self.output.right_trigger = state.right_trigger;
        self.output.left_stick = state.left_stick;
        self.output.right_stick = state.right_stick;

        if state.latest_edge_id == self.cursor {
            self.output.buttons = state.buttons;
            StateDisposition::Applied
        } else if state.latest_edge_id < self.cursor {
            StateDisposition::SnapshotBehind
        } else {
            StateDisposition::AwaitingEdges {
                missing_from: self.cursor + 1,
            }
        }
    }

    /// Current digital-edge cursor.
    pub const fn cursor(&self) -> u64 {
        self.cursor
    }

    /// Current output state.
    pub const fn output(&self) -> OutputState {
        self.output
    }

    /// Clears controls and accepts the neutral baseline for a fresh epoch.
    pub fn reset_neutral(&mut self) -> Result<(), ProtocolError> {
        self.cursor = 0;
        self.output = OutputState::neutral();
        Ok(())
    }
}

impl Default for InputAssembler {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::frame::Edge as FrameEdge;

    fn state(latest_edge_id: u64, buttons: Buttons) -> StatePayload {
        StatePayload {
            latest_edge_id,
            sample_time_us: 1_000,
            buttons,
            left_trigger: 10,
            right_trigger: 20,
            left_stick: Stick { x: 1, y: 2 },
            right_stick: Stick { x: 3, y: 4 },
        }
    }

    fn delivery(edges: &[(u64, Buttons)]) -> EdgeDelivery {
        let applied = edges
            .iter()
            .map(|(edge_id, buttons)| FrameEdge {
                edge_id: *edge_id,
                buttons: *buttons,
                event_time_us: *edge_id * 10,
            })
            .collect();
        EdgeDelivery {
            applied,
            highest_contiguous: edges.last().map_or(0, |(id, _)| *id),
            has_gap: false,
        }
    }

    #[test]
    fn axes_advance_even_when_edges_are_missing() {
        let mut assembler = InputAssembler::new();
        let disposition = assembler.apply_state(&state(3, Buttons::A));
        assert_eq!(
            disposition,
            StateDisposition::AwaitingEdges { missing_from: 1 }
        );
        assert_eq!(assembler.output().left_trigger, 10);
        assert_eq!(assembler.output().right_trigger, 20);
        assert_eq!(assembler.output().left_stick, Stick { x: 1, y: 2 });
        assert_eq!(assembler.output().buttons, Buttons::neutral());
    }

    #[test]
    fn matching_snapshot_applies_buttons() {
        let mut assembler = InputAssembler::new();
        assembler
            .apply_edges(&delivery(&[(1, Buttons::A)]))
            .unwrap();
        let disposition = assembler.apply_state(&state(1, Buttons::A | Buttons::START));
        assert_eq!(disposition, StateDisposition::Applied);
        assert_eq!(assembler.output().buttons, Buttons::A | Buttons::START);
    }

    #[test]
    fn behind_snapshot_cannot_roll_buttons_back() {
        let mut assembler = InputAssembler::new();
        assembler
            .apply_edges(&delivery(&[(1, Buttons::A), (2, Buttons::neutral())]))
            .unwrap();
        let disposition = assembler.apply_state(&state(1, Buttons::A));
        assert_eq!(disposition, StateDisposition::SnapshotBehind);
        assert_eq!(assembler.output().buttons, Buttons::neutral());
        assert_eq!(assembler.output().left_trigger, 10);
    }

    #[test]
    fn edges_must_be_contiguous() {
        let mut assembler = InputAssembler::new();
        assert_eq!(
            assembler.apply_edges(&delivery(&[(2, Buttons::A)])),
            Err(ProtocolError::EdgeOutOfWindow {
                edge_id: 2,
                highest_contiguous: 0
            })
        );
    }

    #[test]
    fn reset_restores_neutral_baseline() {
        let mut assembler = InputAssembler::new();
        assembler
            .apply_edges(&delivery(&[(1, Buttons::A)]))
            .unwrap();
        assembler.apply_state(&state(1, Buttons::A));
        assembler.reset_neutral().unwrap();
        assert_eq!(assembler.cursor(), 0);
        assert!(assembler.output().is_neutral());
    }
}
