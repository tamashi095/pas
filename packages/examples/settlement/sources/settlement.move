// Copyright (c) Unconfirmed Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// A composable "settlement pipeline" for PAS object transfers — an app-layer
/// convention built on the receipt primitive (`policy::add_required_approval` +
/// `request::resolve`), NOT part of the framework.
///
/// A `Settlement` is a hot potato that threads the in-flight transfer request, the
/// buyer's payment, and a working `price` through a chain of rules. Each rule reads
/// the previous rule's output, takes its cut / adjusts the price, and stamps its
/// receipt — so order-dependent economics (a discount feeding a royalty) hold by
/// construction. Because it has no abilities, it cannot be dropped or stored: the
/// pipeline must run to `finalize` in a single transaction.
///
/// The object being moved is read-only and *bound inside the request* — rules read it
/// via `object()`, so there is nothing to substitute.
module settlement::settlement;

use pas::policy::Policy;
use pas::request::Request;
use pas::send_funds::{Self, SendFunds};
use sui::coin::Coin;
use sui::sui::SUI;

/// Threaded through a sale's rules. No `key`/`store`/`drop` → must be `finalize`d.
/// (The `Coin` field is fine here — this is a transient hot potato, never stored.)
#[allow(lint(coin_field))]
public struct Settlement<T: store> {
    request: Request<SendFunds<T>>,
    payment: Coin<SUI>,
    price: u64,
    buyer: address,
    seller: address,
}

/// Begin a settlement around a transfer `request` and the buyer's `payment`.
public fun begin<T: store>(
    request: Request<SendFunds<T>>,
    payment: Coin<SUI>,
    buyer: address,
): Settlement<T> {
    let price = payment.value();
    let seller = request.data().sender();
    Settlement { request, payment, price, buyer, seller }
}

// === Rule-facing API (controlled access to the threaded state) ===

public fun price<T: store>(s: &Settlement<T>): u64 { s.price }

public fun buyer<T: store>(s: &Settlement<T>): address { s.buyer }

public fun seller<T: store>(s: &Settlement<T>): address { s.seller }

/// The object being transferred, read-only — bound in the request, so unswappable.
public fun object<T: store>(s: &Settlement<T>): &T { s.request.data().funds() }

/// Lower the working price downstream rules compute against (e.g. a discount).
public fun reduce_price<T: store>(s: &mut Settlement<T>, by: u64) {
    s.price = if (by >= s.price) 0 else s.price - by;
}

/// Split `amount` out of the payment for a rule to route (royalty cut, refund, …).
public fun take<T: store>(s: &mut Settlement<T>, amount: u64, ctx: &mut TxContext): Coin<SUI> {
    s.payment.split(amount, ctx)
}

/// Stamp a rule's receipt. Only the rule's defining module can construct `W`, so a
/// rule can only ever attest to itself.
public fun approve<T: store, W: drop>(s: &mut Settlement<T>, witness: W) {
    s.request.approve(witness);
}

/// Finalize: the remaining payment goes to the seller, then the request resolves —
/// which checks every required rule's receipt is present, in the maker's order, and
/// delivers the object to the buyer's account.
public fun finalize<T: key + store>(s: Settlement<T>, policy: &Policy<T>) {
    let Settlement { request, payment, seller, .. } = s;
    transfer::public_transfer(payment, seller);
    send_funds::resolve_object(request, policy);
}
