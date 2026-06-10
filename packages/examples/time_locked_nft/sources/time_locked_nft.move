/// Example: a **time-locked** Test NFT governed by PAS.
///
/// This is a worked example of a *policy* — the issuer-defined approval logic that
/// every account-to-account transfer must pass. Here the rule is purely time-based:
/// a `TestNft` carries its own `unlock_time_ms`, and the policy's `approve_transfer`
/// resolver reads the on-chain `Clock` and only stamps the request once
/// `Clock.timestamp_ms() >= unlock_time_ms`. Before that, every `sendObject` aborts.
///
/// Because PAS routes the actual object through the request, the policy can inspect
/// the very NFT being moved (`request.data().funds()`) and read its unlock time — no
/// side registry needed.
module time_locked_nft::time_locked_nft;

use pas::account;
use pas::namespace::Namespace;
use pas::policy::{Self, PolicyCap};
use pas::request::Request;
use pas::send_funds::SendFunds;
use pas::templates::{PAS, Templates};
use ptb::ptb;
use std::string::String;
use std::type_name;
use sui::clock::Clock;
use sui::package::{Self, Publisher};

#[error(code = 0)]
const ETransferLocked: vector<u8> =
    b"This NFT is time-locked and cannot be transferred until its unlock time.";

/// One-time witness, used to claim the package `Publisher`.
public struct TIME_LOCKED_NFT has drop {}

/// A test NFT whose account-to-account transfers are locked until `unlock_time_ms`.
public struct TestNft has key, store {
    id: UID,
    name: String,
    /// Epoch milliseconds; transfers are refused by the policy before this time.
    unlock_time_ms: u64,
}

/// Witness stamp authorizing a transfer.
public struct TransferApproval() has drop;

fun init(otw: TIME_LOCKED_NFT, ctx: &mut TxContext) {
    package::claim_and_keep(otw, ctx);
}

/// One-time setup, run by the deployer. Registers the `Policy<TestNft>` and the
/// time-lock approval template, and hands the `PolicyCap` to the deployer.
#[allow(lint(self_transfer))]
public fun setup(
    namespace: &mut Namespace,
    templates: &mut Templates,
    publisher: &Publisher,
    ctx: &mut TxContext,
) {
    let (mut policy, policy_cap) = policy::new_for_object<TestNft>(namespace, publisher, true);
    policy.set_required_approval<_, TransferApproval>(&policy_cap, "send_funds");

    // Template: `approve_transfer(request, clock)`. When the SDK auto-resolves a
    // `sendObject` for this type it injects the `SendFunds` request and the shared
    // Clock (0x6) — `ptb::clock()` is the shorthand for that object argument.
    let type_name = type_name::with_defining_ids<TestNft>();
    let cmd = ptb::move_call(
        type_name.address_string().to_string(),
        b"time_locked_nft".to_string(),
        b"approve_transfer".to_string(),
        vector[ptb::ext_input<PAS>(b"request".to_string()), ptb::clock()],
        vector[],
    );
    templates.set_template_command(internal::permit<TransferApproval>(), cmd);

    policy.share();
    transfer::public_transfer(policy_cap, ctx.sender());
}

/// Mint a time-locked NFT directly into `recipient`'s PAS account. Gated by the
/// `PolicyCap`, so only the issuer can mint.
public fun mint(
    _cap: &PolicyCap<TestNft>,
    namespace: &Namespace,
    recipient: address,
    name: String,
    unlock_time_ms: u64,
    ctx: &mut TxContext,
) {
    account::deposit_object_to_owner(
        namespace,
        recipient,
        TestNft { id: object::new(ctx), name, unlock_time_ms },
    );
}

/// The policy: approve a transfer only once the clock has reached the NFT's unlock
/// time. Reads the unlock time straight off the object carried by the request.
public fun approve_transfer(request: &mut Request<SendFunds<TestNft>>, clock: &Clock) {
    let nft = request.data().funds();
    assert!(clock.timestamp_ms() >= nft.unlock_time_ms, ETransferLocked);
    request.approve(TransferApproval());
}
