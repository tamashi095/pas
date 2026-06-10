// Copyright (c) Unconfirmed Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// A demo NFT that composes `royalty_rule` onto its PAS policy: every
/// account-to-account transfer must route a creator royalty (see `royalty_rule`).
///
/// Because the royalty needs a caller-supplied `Coin<SUI>`, transfers are built as a
/// manual PTB (`send_object` → `royalty_rule::pay` → `resolve_object`) rather than the
/// SDK's one-call `sendObject` — the template system only injects fixed objects.
module royalty_rule::example_nft;

use pas::account;
use pas::namespace::Namespace;
use pas::policy::{Self, PolicyCap};
use royalty_rule::royalty_rule;
use std::string::String;
use sui::package::{Self, Publisher};

/// One-time witness, used to claim the package `Publisher`.
public struct EXAMPLE_NFT has drop {}

/// A simple art NFT governed by a royalty policy.
public struct ArtNft has key, store {
    id: UID,
    name: String,
}

fun init(otw: EXAMPLE_NFT, ctx: &mut TxContext) {
    package::claim_and_keep(otw, ctx);
}

/// Register a `Policy<ArtNft>` with an `amount_bp` / `min_amount` royalty to `recipient`.
#[allow(lint(self_transfer))]
public fun setup(
    namespace: &mut Namespace,
    publisher: &Publisher,
    amount_bp: u16,
    min_amount: u64,
    recipient: address,
    ctx: &mut TxContext,
) {
    let (mut policy, policy_cap) = policy::new_for_object<ArtNft>(namespace, publisher, true);
    royalty_rule::add(&mut policy, &policy_cap, amount_bp, min_amount, recipient, ctx);
    policy.share();
    transfer::public_transfer(policy_cap, ctx.sender());
}

/// Mint an NFT directly into `recipient`'s PAS account.
public fun mint(
    _cap: &PolicyCap<ArtNft>,
    namespace: &Namespace,
    recipient: address,
    name: String,
    ctx: &mut TxContext,
) {
    account::deposit_object_to_owner(namespace, recipient, ArtNft { id: object::new(ctx), name });
}
