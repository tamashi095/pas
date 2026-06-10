// Copyright (c) Unconfirmed Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Royalty rule: routes `bp` basis points of the *current* (possibly discounted)
/// price to the creator.
module settlement::royalty;

use pas::policy::{Policy, PolicyCap};
use settlement::settlement::{Self, Settlement};

public struct Royalty() has drop;

public struct Config<phantom T> has key {
    id: UID,
    bp: u16,
    recipient: address,
}

public fun add<T>(
    policy: &mut Policy<T>,
    cap: &PolicyCap<T>,
    bp: u16,
    recipient: address,
    ctx: &mut TxContext,
) {
    policy.add_required_approval<_, Royalty>(cap, b"send_funds".to_string());
    transfer::share_object(Config<T> { id: object::new(ctx), bp, recipient });
}

public fun apply<T: store>(
    mut s: Settlement<T>,
    config: &Config<T>,
    ctx: &mut TxContext,
): Settlement<T> {
    let fee = ((settlement::price(&s) as u128) * (config.bp as u128) / 10_000) as u64;
    transfer::public_transfer(settlement::take(&mut s, fee, ctx), config.recipient);
    settlement::approve(&mut s, Royalty());
    s
}
