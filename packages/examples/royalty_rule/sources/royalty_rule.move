// Copyright (c) Mysten Labs, Inc.
// Copyright (c) Unconfirmed Labs, Inc.
// SPDX-License-Identifier: Apache-2.0
//
// Adapted for the Permissioned Asset Standard (PAS) from the MystenLabs/apps kiosk
// `royalty_rule` (https://github.com/MystenLabs/apps). Same basis-points + minimum
// fee model, expressed against PAS's `Policy<T>` / `Request<SendFunds<T>>` instead
// of Kiosk's `TransferPolicy` / `TransferRequest`.

/// A reusable creator-royalty rule for PAS object policies.
///
/// The issuer `add`s the rule to their `Policy<T>`, which makes every transfer
/// require the `Rule` approval witness. That witness is only granted by `pay`, which
/// routes a `amount_bp` (min `min_amount`) cut of the sale to the creator. Without a
/// `pay`, a transfer cannot resolve.
///
/// Note on price: Kiosk records the sale price on the `TransferRequest` (`paid`) and
/// collects the royalty as a separate top-up. PAS transfers carry no price, so this
/// rule treats the supplied `payment` as the gross sale amount and deducts the
/// royalty from it (the remainder is returned to the seller).
module royalty_rule::royalty_rule;

use pas::policy::{Self, Policy, PolicyCap};
use pas::request::Request;
use pas::send_funds::SendFunds;
use sui::coin::Coin;
use sui::sui::SUI;

#[error(code = 0)]
const EIncorrectArgument: vector<u8> = b"amount_bp must be <= 10000 (100%).";

/// Maximum basis points (100%).
const MAX_BPS: u16 = 10_000;

/// Approval witness, granted once the royalty has been paid.
public struct Rule() has drop;

/// Per-type royalty config: `amount_bp` of the sale price (at least `min_amount`)
/// goes to `recipient`. Shared so the payer can reference it. Derived 1:1 from the
/// `Policy<T>` would also be reasonable; kept as its own object for clarity.
public struct Config<phantom T> has key {
    id: UID,
    amount_bp: u16,
    min_amount: u64,
    recipient: address,
}

/// Add the royalty rule to `policy`: require the `Rule` witness for `send_funds` and
/// publish the config. Call from the issuer's policy setup.
public fun add<T>(
    policy: &mut Policy<T>,
    cap: &PolicyCap<T>,
    amount_bp: u16,
    min_amount: u64,
    recipient: address,
    ctx: &mut TxContext,
) {
    assert!(amount_bp <= MAX_BPS, EIncorrectArgument);
    policy.set_required_approval<_, Rule>(cap, b"send_funds".to_string());
    transfer::share_object(Config<T> {
        id: object::new(ctx),
        amount_bp,
        min_amount,
        recipient,
    });
}

/// Pay the royalty and stamp the transfer request so it can resolve.
///
/// `payment`'s value is taken as the sale price: the fee is split off to the
/// creator, and the remainder is returned to the seller (the request's sender).
public fun pay<T: store>(
    config: &Config<T>,
    request: &mut Request<SendFunds<T>>,
    mut payment: Coin<SUI>,
    ctx: &mut TxContext,
) {
    let price = payment.value();
    let mut fee = fee_amount(config, price);
    // The payment *is* the price here, so a `min_amount` on a tiny sale is capped at it.
    if (fee > price) fee = price;

    transfer::public_transfer(payment.split(fee, ctx), config.recipient);
    transfer::public_transfer(payment, request.data().sender());
    request.approve(Rule());
}

/// `fee = max(price * amount_bp / 10000, min_amount)`. Mirrors the kiosk rule's math.
public fun fee_amount<T>(config: &Config<T>, price: u64): u64 {
    let mut amount = ((price as u128) * (config.amount_bp as u128) / (MAX_BPS as u128)) as u64;
    if (amount < config.min_amount) amount = config.min_amount;
    amount
}

public fun amount_bp<T>(config: &Config<T>): u16 { config.amount_bp }

public fun min_amount<T>(config: &Config<T>): u64 { config.min_amount }

public fun recipient<T>(config: &Config<T>): address { config.recipient }
