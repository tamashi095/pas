/// Example: a permissioned **object** (a membership `Badge`) governed by PAS.
///
/// This is the object analog of the `kyc` / `loyalty` currency examples. It shows
/// that a non-fungible `key + store` object can carry the same permissioned
/// guarantees PAS provides for balances:
///
/// - the issuer registers a `Policy<Badge>`, proving authority with the package
///   `Publisher` (there is no `TreasuryCap` for an object type);
/// - badges are minted **directly into PAS accounts** via `deposit_object_to_owner`,
///   never into a bare wallet (a bare `key + store` object would be freely
///   transferable, escaping the policy);
/// - every account-to-account transfer issues a `SendFunds<Badge>` request that the
///   issuer must approve in `approve_transfer` before it resolves;
/// - the issuer can claw a badge back and burn it.
module permissioned_nft::permissioned_nft;

use pas::account;
use pas::clawback_funds::{Self, ClawbackFunds};
use pas::namespace::Namespace;
use pas::policy::{Self, Policy, PolicyCap};
use pas::request::Request;
use pas::send_funds::SendFunds;
use pas::templates::{PAS, Templates};
use ptb::ptb;
use std::type_name;
use sui::package::{Self, Publisher};

#[error(code = 0)]
const ECannotSelfTransfer: vector<u8> = b"Transfers to the same owner are not allowed.";

/// One-time witness, used to claim the package `Publisher`.
public struct PERMISSIONED_NFT has drop {}

/// The permissioned object. It can only ever live inside a PAS account, and only
/// move between accounts with the issuer's approval.
public struct Badge has key, store {
    id: UID,
    tier: u8,
}

/// Witness stamp authorizing a transfer.
public struct TransferApproval() has drop;

/// Witness stamp authorizing a clawback (burn).
public struct ClawbackApproval() has drop;

/// Claim the `Publisher` on publish and keep it with the deployer. `setup` consumes
/// a reference to it to register the `Policy<Badge>`.
fun init(otw: PERMISSIONED_NFT, ctx: &mut TxContext) {
    package::claim_and_keep(otw, ctx);
}

/// One-time setup, run by the deployer after publishing. Registers the object policy
/// and the SDK resolution template, and hands the `PolicyCap` to the deployer.
#[allow(lint(self_transfer))]
public fun setup(
    namespace: &mut Namespace,
    templates: &mut Templates,
    publisher: &Publisher,
    ctx: &mut TxContext,
) {
    // Clawback enabled (so the issuer can recall + burn a badge).
    let (mut policy, policy_cap) = policy::new_for_object<Badge>(namespace, publisher, true);

    policy.set_required_approval<_, TransferApproval>(&policy_cap, "send_funds");
    policy.set_required_approval<_, ClawbackApproval>(&policy_cap, "clawback_funds");

    // Register the template so the SDK can auto-construct the `approve_transfer`
    // call when resolving a `SendFunds<Badge>`. The `Receiving<Badge>` input lives
    // on the user's `send_object` call, not here — so this is identical in shape to
    // the currency examples.
    let type_name = type_name::with_defining_ids<Badge>();
    let cmd = ptb::move_call(
        type_name.address_string().to_string(),
        b"permissioned_nft".to_string(),
        b"approve_transfer".to_string(),
        vector[ptb::ext_input<PAS>(b"request".to_string())],
        vector[],
    );
    templates.set_template_command(internal::permit<TransferApproval>(), cmd);

    policy.share();
    transfer::public_transfer(policy_cap, ctx.sender());
}

/// Mint a badge directly into `recipient`'s PAS account. Works even if the recipient
/// has not created their account yet — the badge waits at the derived account address.
/// Gated by the `PolicyCap`, so only the issuer can mint.
public fun mint(
    _cap: &PolicyCap<Badge>,
    namespace: &Namespace,
    recipient: address,
    tier: u8,
    ctx: &mut TxContext,
) {
    account::deposit_object_to_owner(namespace, recipient, Badge { id: object::new(ctx), tier });
}

/// Resolver for a badge transfer. Demonstrates the policy hook: reject self-transfers,
/// then stamp the request so it can resolve. Arbitrary logic (allowlists, holding
/// periods, price caps read from `request.data().funds()`) would go here.
public fun approve_transfer(request: &mut Request<SendFunds<Badge>>) {
    assert!(request.data().sender() != request.data().recipient(), ECannotSelfTransfer);
    request.approve(TransferApproval());
}

/// Recall a badge via clawback and burn it. Only resolves because the policy was
/// created with clawback enabled.
public fun burn(
    _cap: &PolicyCap<Badge>,
    policy: &Policy<Badge>,
    mut request: Request<ClawbackFunds<Badge>>,
) {
    request.approve(ClawbackApproval());
    let Badge { id, .. } = clawback_funds::resolve(request, policy);
    id.delete();
}
