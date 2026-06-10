// Copyright (c) Unconfirmed Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Floor-price rule: a check-only rule that asserts the (post-discount) price is at
/// least `min`. It threads no value — it just inspects and stamps its receipt.
module settlement::floor;

use pas::policy::{Policy, PolicyCap};
use settlement::settlement::{Self, Settlement};

#[error(code = 0)]
const EBelowFloor: vector<u8> = b"Sale price is below the floor.";

public struct Floor() has drop;

public struct Config<phantom T> has key {
    id: UID,
    min: u64,
}

public fun add<T>(policy: &mut Policy<T>, cap: &PolicyCap<T>, min: u64, ctx: &mut TxContext) {
    policy.add_required_approval<_, Floor>(cap, b"send_funds".to_string());
    transfer::share_object(Config<T> { id: object::new(ctx), min });
}

public fun apply<T: store>(mut s: Settlement<T>, config: &Config<T>): Settlement<T> {
    assert!(settlement::price(&s) >= config.min, EBelowFloor);
    settlement::approve(&mut s, Floor());
    s
}
