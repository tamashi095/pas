// Copyright (c) Unconfirmed Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Demo NFT whose policy stacks three rules in a maker-chosen order:
/// discount → royalty → floor. The order is set by the sequence of `add` calls, and
/// `request::resolve` enforces a sale satisfies them in exactly that order.
module settlement::art_nft;

use pas::account;
use pas::namespace::Namespace;
use pas::policy::{Self, PolicyCap};
use settlement::discount;
use settlement::floor;
use settlement::royalty;
use sui::package::{Self, Publisher};

public struct ART_NFT has drop {}

public struct Art has key, store { id: UID }

fun init(otw: ART_NFT, ctx: &mut TxContext) {
    package::claim_and_keep(otw, ctx);
}

#[allow(lint(self_transfer))]
public fun setup(
    namespace: &mut Namespace,
    publisher: &Publisher,
    discount_bp: u16,
    royalty_bp: u16,
    creator: address,
    floor_min: u64,
    ctx: &mut TxContext,
) {
    let (mut policy, cap) = policy::new_for_object<Art>(namespace, publisher, true);
    // Order matters and is the maker's choice: discount first (so it lowers the price),
    // then royalty (off the discounted price), then the floor check.
    discount::add(&mut policy, &cap, discount_bp, ctx);
    royalty::add(&mut policy, &cap, royalty_bp, creator, ctx);
    floor::add(&mut policy, &cap, floor_min, ctx);
    policy.share();
    transfer::public_transfer(cap, ctx.sender());
}

public fun mint(
    _cap: &PolicyCap<Art>,
    namespace: &Namespace,
    recipient: address,
    ctx: &mut TxContext,
) {
    account::deposit_object_to_owner(namespace, recipient, Art { id: object::new(ctx) });
}
