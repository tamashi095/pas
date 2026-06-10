// Copyright (c) Unconfirmed Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Discount rule: lowers the working price by `bp` basis points and refunds that
/// amount to the buyer. Registered before the royalty so the royalty computes off
/// the discounted price — the data dependency that motivates the threaded pipeline.
module settlement::discount;

use pas::policy::{Policy, PolicyCap};
use settlement::settlement::{Self, Settlement};

public struct Discount() has drop;

public struct Config<phantom T> has key {
    id: UID,
    bp: u16,
}

public fun add<T>(policy: &mut Policy<T>, cap: &PolicyCap<T>, bp: u16, ctx: &mut TxContext) {
    policy.add_required_approval<_, Discount>(cap, b"send_funds".to_string());
    transfer::share_object(Config<T> { id: object::new(ctx), bp });
}

public fun apply<T: store>(
    mut s: Settlement<T>,
    config: &Config<T>,
    ctx: &mut TxContext,
): Settlement<T> {
    let off = ((settlement::price(&s) as u128) * (config.bp as u128) / 10_000) as u64;
    settlement::reduce_price(&mut s, off);
    let buyer = settlement::buyer(&s);
    transfer::public_transfer(settlement::take(&mut s, off, ctx), buyer);
    settlement::approve(&mut s, Discount());
    s
}
