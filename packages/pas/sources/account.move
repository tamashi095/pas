/// Account logic
module pas::account;

use pas::{
    clawback_funds::{Self, ClawbackFunds},
    events,
    keys,
    namespace::{Self, Namespace},
    request::Request,
    send_funds::{Self, SendFunds},
    unlock_funds::{Self, UnlockFunds},
    versioning::Versioning
};
use sui::{balance::{Self, Balance}, derived_object, transfer::Receiving};

use fun balance::withdraw_funds_from_object as UID.withdraw_funds_from_object;
#[error(code = 0)]
const ENotOwner: vector<u8> = b"The owner is not valid for the account.";
#[error(code = 1)]
const EAccountAlreadyExists: vector<u8> = b"The account already exists.";

/// There is only one Account per address (guaranteed by derived objects).
/// - Balances can only be transferred from Account A to Account B.
/// - Accounts are shared by default.
/// - Accounts creation is permission-less
/// - A `UID` (object) can also own a account
public struct Account has key {
    id: UID,
    /// The owner of the account (address or object)
    owner: address,
    /// The ID of the namespace that created this account.
    /// There's ONLY ONE namespace in the system, but this helps us avoid having
    /// `&Namespace` inputs in all functions that need to derive the IDs.
    namespace_id: ID,
    /// Block versions to break backwards compatibility -- only used in case of emergency.
    versioning: Versioning,
}

/// A proof that address has authenticated. This allows for uniform access control between both
/// `UID` and `ctx.sender()` (keeping a single API for both).
public struct Auth(address) has drop;

/// Create a new account for `owner`. This is a permission-less action.
public fun create(namespace: &mut Namespace, owner: address): Account {
    assert!(!namespace.account_exists(owner), EAccountAlreadyExists);

    let versioning = namespace.versioning();
    versioning.assert_is_valid_version();

    Account {
        id: derived_object::claim(namespace.uid_mut(), keys::account_key(owner)),
        owner,
        namespace_id: object::id(namespace),
        versioning,
    }
}

/// The only way to finalize the TX is by sharing the account.
/// All accounts are shared by default.
public fun share(account: Account) {
    transfer::share_object(account);
}

/// Create and share a account in a single step.
public fun create_and_share(namespace: &mut Namespace, owner: address) {
    create(namespace, owner).share()
}

/// Enables a fund unlock flow.
/// This is useful for assets that are not managed by a Policy within the system, or
/// if there's a special case where an issuer allows balances to flow out of the system.
public fun unlock_balance<C>(
    account: &mut Account,
    auth: &Auth,
    amount: u64,
    _ctx: &mut TxContext,
): Request<UnlockFunds<Balance<C>>> {
    auth.assert_is_valid_for_account!(account);
    account.versioning.assert_is_valid_version();
    events::emit_funds_unlocked<Balance<C>>(account.owner, amount);
    unlock_funds::new(account.owner, account.id.to_inner(), account.withdraw_balance<C>(amount))
}

/// Initiate a transfer from account A to account B.
public fun send_balance<C>(
    from: &mut Account,
    auth: &Auth,
    to: &Account,
    amount: u64,
    _ctx: &mut TxContext,
): Request<SendFunds<Balance<C>>> {
    auth.assert_is_valid_for_account!(from);
    from.versioning.assert_is_valid_version();
    from.internal_send_balance<C>(to.owner, amount)
}

/// Initiate a clawback request for an amount of funds.
/// This takes no `Auth`, as it's an admin action.
///
/// This can only ever finalize if clawback is enabled in the policy.
public fun clawback_balance<C>(
    from: &mut Account,
    amount: u64,
    _ctx: &mut TxContext,
): Request<ClawbackFunds<Balance<C>>> {
    from.versioning.assert_is_valid_version();
    events::emit_funds_clawback<Balance<C>>(from.owner, amount);
    clawback_funds::new(from.owner, from.id.to_inner(), from.withdraw_balance<C>(amount))
}

/// Transfer `amount` from account to an address. This unlocks transfers to a account before it has been created.
///
/// It's marked as `unsafe_` as it's easy to accidentally pick the wrong recipient address.
public fun unsafe_send_balance<C>(
    from: &mut Account,
    auth: &Auth,
    // Recipients should always be the wallet or object address, not the account ID.
    // It's recommended to use `transfer` instead for safer transfers.
    recipient_address: address,
    amount: u64,
    _ctx: &mut TxContext,
): Request<SendFunds<Balance<C>>> {
    auth.assert_is_valid_for_account!(from);
    from.versioning.assert_is_valid_version();
    from.internal_send_balance<C>(recipient_address, amount)
}

/// Generate an ownership proof from the sender of the transaction.
public fun new_auth(ctx: &TxContext): Auth {
    Auth(ctx.sender())
}

/// Generate an ownership proof from a `UID` object, to allow objects to own accounts.
/// `&mut UID` is intentional — it serves as proof of ownership over the object.
public fun new_auth_as_object(uid: &mut UID): Auth {
    Auth(uid.to_inner().to_address())
}

public fun owner(account: &Account): address {
    account.owner
}

public fun deposit_balance<C>(account: &Account, balance: Balance<C>) {
    account.versioning.assert_is_valid_version();
    balance::send_funds(balance, object::id(account).to_address());
}

/// Permission-less operation to bring versioning up-to-date with the namespace.
public fun sync_versioning(account: &mut Account, namespace: &Namespace) {
    account.versioning = namespace.versioning();
}

public(package) fun withdraw_balance<C>(account: &mut Account, amount: u64): Balance<C> {
    account.versioning.assert_is_valid_version();
    balance::redeem_funds(account.id.withdraw_funds_from_object(amount))
}

public(package) fun versioning(account: &Account): Versioning {
    account.versioning
}

/// Verify that the ownership proof matches the accounts owner.
macro fun assert_is_valid_for_account($proof: &Auth, $account: &Account) {
    let proof = $proof;
    let account = $account;
    assert!(&proof.0 == &account.owner, ENotOwner);
}

/// The internal implementation for transferring `amount` from Account towards another address.
///
/// INTERNAL WARNING: Callers must verify that `to` is the user address, NOT the account address.
/// Failure to do so can cause assets to move out of the closed loop, breaking the system assurances
fun internal_send_balance<C>(
    from: &mut Account,
    to: address,
    amount: u64,
): Request<SendFunds<Balance<C>>> {
    let funds = from.withdraw_balance<C>(amount);
    let recipient_account_id = namespace::account_address_from_id(from.namespace_id, to);
    events::emit_funds_sent<Balance<C>>(from.owner, to, amount);

    send_funds::new(
        from.owner,
        to,
        from.id.to_inner(),
        recipient_account_id.to_id(),
        funds,
    )
}

// === Generic object support ===
//
// Objects are stored using transfer-to-object: a deposit is a `public_transfer`
// to the account's address, and a withdrawal is a `public_receive` using the
// account's `&mut UID`. This mirrors the balance accumulator flow and keeps the
// "owner == account address" property, so objects are discoverable via RPC the
// same way balances are.
//
// SECURITY: because `T: key + store` objects are freely `public_transfer`-able by
// whoever holds the bare value, the closed loop only holds while the object lives
// at an account address. Issuers must deposit objects directly into accounts and
// avoid releasing them to bare wallets (see the unlock note below).

/// Deposit an object into an account. The object becomes owned by the account's
/// address, exactly like a balance deposit.
public fun deposit_object<T: key + store>(account: &Account, obj: T) {
    account.versioning.assert_is_valid_version();
    transfer::public_transfer(obj, object::id(account).to_address());
}

/// Deposit an object into `owner`'s account by deriving the account address from
/// the namespace. Unlike `deposit_object`, this does NOT require the account to
/// exist yet — the object lands at the derived account address and can be received
/// once the owner creates their account (mirrors how `unsafe_send_*` delivers to
/// not-yet-created accounts).
///
/// This is the safe primitive for minting/airdropping: it keeps the destination
/// derivation inside PAS so issuers can't accidentally send to a bare wallet
/// address (which would put a freely-transferable object outside the closed loop).
public fun deposit_object_to_owner<T: key + store>(namespace: &Namespace, owner: address, obj: T) {
    namespace.versioning().assert_is_valid_version();
    transfer::public_transfer(obj, namespace.account_address(owner));
}

/// Enables an object unlock flow. Mirrors `unlock_balance`.
///
/// This is useful for objects that are not managed by a Policy within the system,
/// or if there's a special case where an issuer allows objects to flow out.
public fun unlock_object<T: key + store>(
    account: &mut Account,
    auth: &Auth,
    receiving: Receiving<T>,
    _ctx: &mut TxContext,
): Request<UnlockFunds<T>> {
    auth.assert_is_valid_for_account!(account);
    account.versioning.assert_is_valid_version();
    let obj = account.withdraw_object<T>(receiving);
    events::emit_object_unlocked<T>(account.owner, object::id(&obj));
    unlock_funds::new(account.owner, account.id.to_inner(), obj)
}

/// Initiate an object transfer from account A to account B. Mirrors `send_balance`.
public fun send_object<T: key + store>(
    from: &mut Account,
    auth: &Auth,
    to: &Account,
    receiving: Receiving<T>,
    _ctx: &mut TxContext,
): Request<SendFunds<T>> {
    auth.assert_is_valid_for_account!(from);
    from.versioning.assert_is_valid_version();
    from.internal_send_object<T>(to.owner, receiving)
}

/// Transfer an object from account to an address. This unlocks transfers to an
/// account before it has been created. Mirrors `unsafe_send_balance`.
///
/// It's marked as `unsafe_` as it's easy to accidentally pick the wrong recipient.
public fun unsafe_send_object<T: key + store>(
    from: &mut Account,
    auth: &Auth,
    // Recipients should always be the wallet or object address, not the account ID.
    recipient_address: address,
    receiving: Receiving<T>,
    _ctx: &mut TxContext,
): Request<SendFunds<T>> {
    auth.assert_is_valid_for_account!(from);
    from.versioning.assert_is_valid_version();
    from.internal_send_object<T>(recipient_address, receiving)
}

/// Initiate a clawback request for an object. Mirrors `clawback_balance`.
/// Takes no `Auth`, as it's an admin action, and can only finalize if clawback is
/// enabled in the policy.
public fun clawback_object<T: key + store>(
    from: &mut Account,
    receiving: Receiving<T>,
    _ctx: &mut TxContext,
): Request<ClawbackFunds<T>> {
    from.versioning.assert_is_valid_version();
    let obj = from.withdraw_object<T>(receiving);
    events::emit_object_clawback<T>(from.owner, object::id(&obj));
    clawback_funds::new(from.owner, from.id.to_inner(), obj)
}

public(package) fun withdraw_object<T: key + store>(
    account: &mut Account,
    receiving: Receiving<T>,
): T {
    account.versioning.assert_is_valid_version();
    transfer::public_receive(&mut account.id, receiving)
}

/// The internal implementation for sending an object towards another address.
///
/// INTERNAL WARNING: Callers must verify that `to` is the user address, NOT the
/// account address. Failure to do so can cause assets to move out of the closed loop.
fun internal_send_object<T: key + store>(
    from: &mut Account,
    to: address,
    receiving: Receiving<T>,
): Request<SendFunds<T>> {
    let obj = from.withdraw_object<T>(receiving);
    let recipient_account_id = namespace::account_address_from_id(from.namespace_id, to);
    events::emit_object_sent<T>(from.owner, to, object::id(&obj));

    send_funds::new(
        from.owner,
        to,
        from.id.to_inner(),
        recipient_account_id.to_id(),
        obj,
    )
}
