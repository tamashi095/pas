#[test_only, allow(unused_variable, unused_mut_ref, dead_code)]
module pas::object_e2e;

use pas::{
    account::{Self, Account},
    clawback_funds,
    namespace::{Self, Namespace},
    policy::{Self, Policy, PolicyCap},
    send_funds,
    unlock_funds,
    versioning::breaking_version
};
use std::{type_name, unit_test::assert_eq};
use sui::{
    coin::Coin,
    package::{Self, UpgradeCap},
    sui::SUI,
    test_scenario::{Self as ts, return_shared},
    vec_set
};

/// A managed object type (a `Policy<Obj>` is registered for it).
public struct Obj has key, store { id: UID }

/// A non-managed object type (no policy) — used for unrestricted unlock tests.
public struct FreeObj has key, store { id: UID }

/// One-time-witness used to claim a `Publisher` in tests.
public struct OBJECT_E2E has drop {}

/// Approval witness required by the object policy.
public struct ObjApproval() has drop;

/// Second approval witness, for the multi-approval test.
public struct ObjApproval2() has drop;

#[test]
fun send_object_e2e() {
    test_obj_tx!(@0x1, |namespace, policy, scenario| {
        scenario.next_tx(@0x1);

        let mut from = account::create(namespace, @0x1);
        let to = account::create(namespace, @0x2);

        let obj = Obj { id: object::new(scenario.ctx()) };
        let obj_id = object::id(&obj);
        from.deposit_object(obj);

        from.share();
        to.share();

        scenario.next_tx(@0x1);

        let to_addr = namespace.account_address(@0x2);
        let mut from = scenario.take_shared_by_id<Account>(namespace.account_address(@0x1).to_id());
        let to = scenario.take_shared_by_id<Account>(to_addr.to_id());

        let receiving = ts::receiving_ticket_by_id<Obj>(obj_id);
        let auth = account::new_auth(scenario.ctx());
        let mut request = from.send_object<Obj>(&auth, &to, receiving, scenario.ctx());

        request.approve(ObjApproval());
        send_funds::resolve_object(request, policy);

        return_shared(from);
        return_shared(to);

        // The object now lives at the recipient account address.
        scenario.next_tx(@0x1);
        assert!(ts::most_recent_id_for_address<Obj>(to_addr).is_some());
    });
}

#[test]
fun unsafe_send_object_derives_recipient() {
    test_obj_tx!(@0x1, |namespace, policy, scenario| {
        scenario.next_tx(@0x1);

        let mut from = account::create(namespace, @0x1);
        let obj = Obj { id: object::new(scenario.ctx()) };
        let obj_id = object::id(&obj);
        from.deposit_object(obj);
        from.share();

        scenario.next_tx(@0x1);

        let mut from = scenario.take_shared_by_id<Account>(namespace.account_address(@0x1).to_id());
        let receiving = ts::receiving_ticket_by_id<Obj>(obj_id);
        let auth = account::new_auth(scenario.ctx());

        // Send to @0x2's wallet address — recipient account does not exist yet.
        let request = from.unsafe_send_object<Obj>(&auth, @0x2, receiving, scenario.ctx());

        assert_eq!(request.data().sender(), @0x1);
        assert_eq!(request.data().recipient(), @0x2);
        assert_eq!(request.data().recipient_account_id(), namespace.account_address(@0x2).to_id());
        assert_eq!(object::id(request.data().funds()), obj_id);

        std::unit_test::destroy(request);
        return_shared(from);
    });
}

#[test]
fun unlock_object_managed() {
    test_obj_tx!(@0x1, |namespace, policy, scenario| {
        scenario.next_tx(@0x1);

        let mut account = account::create(namespace, @0x1);
        let obj = Obj { id: object::new(scenario.ctx()) };
        let obj_id = object::id(&obj);
        account.deposit_object(obj);
        account.share();

        scenario.next_tx(@0x1);

        let mut account = scenario.take_shared_by_id<Account>(namespace
            .account_address(@0x1)
            .to_id());
        let receiving = ts::receiving_ticket_by_id<Obj>(obj_id);
        let auth = account::new_auth(scenario.ctx());
        let mut request = account.unlock_object<Obj>(&auth, receiving, scenario.ctx());

        request.approve(ObjApproval());
        let obj = unlock_funds::resolve(request, policy);
        assert_eq!(object::id(&obj), obj_id);

        transfer::public_transfer(obj, @0x1);
        return_shared(account);
    });
}

#[test]
fun unlock_object_unrestricted() {
    test_obj_tx!(@0x1, |namespace, policy, scenario| {
        scenario.next_tx(@0x1);

        let mut account = account::create(namespace, @0x1);
        // FreeObj has no policy, so it can be unlocked without issuer approval.
        let obj = FreeObj { id: object::new(scenario.ctx()) };
        let obj_id = object::id(&obj);
        account.deposit_object(obj);
        account.share();

        scenario.next_tx(@0x1);

        let mut account = scenario.take_shared_by_id<Account>(namespace
            .account_address(@0x1)
            .to_id());
        let receiving = ts::receiving_ticket_by_id<FreeObj>(obj_id);
        let auth = account::new_auth(scenario.ctx());
        let request = account.unlock_object<FreeObj>(&auth, receiving, scenario.ctx());

        let obj = unlock_funds::resolve_unrestricted_object(request, namespace);
        assert_eq!(object::id(&obj), obj_id);

        transfer::public_transfer(obj, @0x1);
        return_shared(account);
    });
}

#[test, expected_failure(abort_code = ::pas::unlock_funds::ECannotResolveManagedAssets)]
fun cannot_unrestricted_unlock_managed_object() {
    test_obj_tx!(@0x1, |namespace, policy, scenario| {
        scenario.next_tx(@0x1);

        let mut account = account::create(namespace, @0x1);
        let obj = Obj { id: object::new(scenario.ctx()) };
        let obj_id = object::id(&obj);
        account.deposit_object(obj);
        account.share();

        scenario.next_tx(@0x1);

        let mut account = scenario.take_shared_by_id<Account>(namespace
            .account_address(@0x1)
            .to_id());
        let receiving = ts::receiving_ticket_by_id<Obj>(obj_id);
        let auth = account::new_auth(scenario.ctx());
        let request = account.unlock_object<Obj>(&auth, receiving, scenario.ctx());

        // Obj is managed — this must abort.
        let obj = unlock_funds::resolve_unrestricted_object(request, namespace);

        abort
    });
}

#[test]
fun clawback_object() {
    test_obj_tx!(@0x1, |namespace, policy, scenario| {
        scenario.next_tx(@0x1);

        let mut account = account::create(namespace, @0x1);
        let obj = Obj { id: object::new(scenario.ctx()) };
        let obj_id = object::id(&obj);
        account.deposit_object(obj);
        account.share();

        scenario.next_tx(@0x1);

        let mut account = scenario.take_shared_by_id<Account>(namespace
            .account_address(@0x1)
            .to_id());
        let receiving = ts::receiving_ticket_by_id<Obj>(obj_id);
        let mut request = account.clawback_object<Obj>(receiving, scenario.ctx());

        request.approve(ObjApproval());
        let obj = clawback_funds::resolve(request, policy);
        assert_eq!(object::id(&obj), obj_id);

        transfer::public_transfer(obj, @0x1);
        return_shared(account);
    });
}

#[test, expected_failure(abort_code = ::pas::clawback_funds::EClawbackNotAllowed)]
fun clawback_object_disallowed() {
    let mut scenario = ts::begin(@0x1);
    namespace::init_for_testing(scenario.ctx());
    scenario.next_tx(@0x1);
    let mut namespace = scenario.take_shared<Namespace>();

    let upgrade_cap = package::test_publish(pkg_id(), scenario.ctx());
    namespace.setup(&upgrade_cap);
    transfer::public_transfer(upgrade_cap, @0x1);

    // Create a policy with clawback DISABLED.
    let publisher = package::test_claim(OBJECT_E2E {}, scenario.ctx());
    let (mut policy, policy_cap) = policy::new_for_object<Obj>(&mut namespace, &publisher, false);
    policy.set_required_approval<_, ObjApproval>(&policy_cap, b"clawback_funds".to_string());
    std::unit_test::destroy(publisher);

    let mut account = account::create(&mut namespace, @0x1);
    let obj = Obj { id: object::new(scenario.ctx()) };
    let obj_id = object::id(&obj);
    account.deposit_object(obj);
    account.share();

    scenario.next_tx(@0x1);

    let mut account = scenario.take_shared_by_id<Account>(namespace.account_address(@0x1).to_id());
    let receiving = ts::receiving_ticket_by_id<Obj>(obj_id);
    let mut request = account.clawback_object<Obj>(receiving, scenario.ctx());
    request.approve(ObjApproval());
    let _obj = clawback_funds::resolve(request, &policy);

    abort
}

#[test, expected_failure(abort_code = ::pas::account::ENotOwner)]
fun wrong_owner_cannot_send_object() {
    test_obj_tx!(@0x1, |namespace, _policy, scenario| {
        scenario.next_tx(@0x1);
        let mut account = account::create(namespace, @0x1);
        let obj = Obj { id: object::new(scenario.ctx()) };
        let obj_id = object::id(&obj);
        account.deposit_object(obj);
        account.share();

        // @0x2 (not the owner) attempts to move @0x1's object.
        scenario.next_tx(@0x2);
        let mut account = scenario.take_shared_by_id<Account>(namespace
            .account_address(@0x1)
            .to_id());
        let receiving = ts::receiving_ticket_by_id<Obj>(obj_id);
        let auth = account::new_auth(scenario.ctx());
        let _request = account.unsafe_send_object<Obj>(&auth, @0x3, receiving, scenario.ctx());

        abort
    });
}

#[test, expected_failure(abort_code = ::pas::account::ENotOwner)]
fun wrong_uid_owner_cannot_unlock_object() {
    test_obj_tx!(@0x1, |namespace, _policy, scenario| {
        scenario.next_tx(@0x1);
        let mut account = account::create(namespace, @0x1);
        let obj = Obj { id: object::new(scenario.ctx()) };
        let obj_id = object::id(&obj);
        account.deposit_object(obj);
        account.share();

        scenario.next_tx(@0x1);
        let mut account = scenario.take_shared_by_id<Account>(namespace
            .account_address(@0x1)
            .to_id());
        // Authenticate as an unrelated UID — not @0x1.
        let mut uid = object::new(scenario.ctx());
        let auth = account::new_auth_as_object(&mut uid);
        let receiving = ts::receiving_ticket_by_id<Obj>(obj_id);
        let _request = account.unlock_object<Obj>(&auth, receiving, scenario.ctx());

        abort
    });
}

#[test]
fun auth_as_object_owner_sends_object() {
    test_obj_tx!(@0x1, |namespace, _policy, scenario| {
        scenario.next_tx(@0x1);
        let mut uid = object::new(scenario.ctx());
        let uid_address = uid.to_inner().to_address();

        let mut account = account::create(namespace, uid_address);
        let obj = Obj { id: object::new(scenario.ctx()) };
        let obj_id = object::id(&obj);
        account.deposit_object(obj);
        account.share();

        scenario.next_tx(@0x1);
        let mut account = scenario.take_shared_by_id<Account>(namespace
            .account_address(uid_address)
            .to_id());
        let auth = account::new_auth_as_object(&mut uid);
        let receiving = ts::receiving_ticket_by_id<Obj>(obj_id);
        let request = account.unsafe_send_object<Obj>(&auth, @0x2, receiving, scenario.ctx());

        assert_eq!(request.data().sender(), uid_address);
        assert_eq!(request.data().recipient(), @0x2);
        assert_eq!(object::id(request.data().funds()), obj_id);

        std::unit_test::destroy(request);
        return_shared(account);
        uid.delete();
    });
}

#[test, expected_failure(abort_code = ::pas::versioning::EInvalidVersion)]
fun blocked_version_aborts_object_unlock() {
    test_obj_tx!(@0x1, |namespace, _policy, scenario| {
        scenario.next_tx(@0x1);
        let mut account = account::create(namespace, @0x1);
        let obj = Obj { id: object::new(scenario.ctx()) };
        let obj_id = object::id(&obj);
        account.deposit_object(obj);
        account.share();

        scenario.next_tx(@0x1);
        let mut account = scenario.take_shared_by_id<Account>(namespace
            .account_address(@0x1)
            .to_id());

        // Block the current version, then sync the account to it.
        let upgrade_cap = scenario.take_from_sender<UpgradeCap>();
        namespace.block_version(&upgrade_cap, breaking_version!());
        account.sync_versioning(namespace);
        scenario.return_to_sender(upgrade_cap);

        let receiving = ts::receiving_ticket_by_id<Obj>(obj_id);
        let auth = account::new_auth(scenario.ctx());
        let _request = account.unlock_object<Obj>(&auth, receiving, scenario.ctx());

        abort
    });
}

#[test]
fun object_send_with_two_approvals() {
    test_obj_tx!(@0x1, |namespace, policy, scenario| {
        scenario.next_tx(@0x1);

        // Require two witnesses for send_funds.
        let policy_cap = scenario.take_from_sender<PolicyCap<Obj>>();
        let mut approvals = vec_set::empty();
        approvals.insert(type_name::with_defining_ids<ObjApproval>());
        approvals.insert(type_name::with_defining_ids<ObjApproval2>());
        policy.set_required_approvals(&policy_cap, b"send_funds".to_string(), approvals);
        scenario.return_to_sender(policy_cap);

        let mut from = account::create(namespace, @0x1);
        let to = account::create(namespace, @0x2);
        let obj = Obj { id: object::new(scenario.ctx()) };
        let obj_id = object::id(&obj);
        from.deposit_object(obj);
        from.share();
        to.share();

        scenario.next_tx(@0x1);
        let mut from = scenario.take_shared_by_id<Account>(namespace.account_address(@0x1).to_id());
        let to = scenario.take_shared_by_id<Account>(namespace.account_address(@0x2).to_id());

        let receiving = ts::receiving_ticket_by_id<Obj>(obj_id);
        let auth = account::new_auth(scenario.ctx());
        let mut request = from.send_object<Obj>(&auth, &to, receiving, scenario.ctx());
        request.approve(ObjApproval());
        request.approve(ObjApproval2());
        send_funds::resolve_object(request, policy);

        return_shared(from);
        return_shared(to);
    });
}

#[test, expected_failure(abort_code = ::pas::policy::ENotAuthorized)]
fun new_for_object_wrong_publisher_aborts() {
    let mut scenario = ts::begin(@0x1);
    namespace::init_for_testing(scenario.ctx());
    scenario.next_tx(@0x1);
    let mut namespace = scenario.take_shared<Namespace>();

    let upgrade_cap = package::test_publish(pkg_id(), scenario.ctx());
    namespace.setup(&upgrade_cap);
    transfer::public_transfer(upgrade_cap, @0x1);

    // Publisher is for the pas test package, but Coin<SUI> is defined in 0x2,
    // so `from_package` fails.
    let publisher = package::test_claim(OBJECT_E2E {}, scenario.ctx());
    let (_policy, _cap) = policy::new_for_object<Coin<SUI>>(&mut namespace, &publisher, true);

    abort
}

#[test, expected_failure(abort_code = ::pas::policy::EPolicyAlreadyExists)]
fun duplicate_object_policy_aborts() {
    test_obj_tx!(@0x1, |namespace, _policy, scenario| {
        scenario.next_tx(@0x1);
        let publisher = package::test_claim(OBJECT_E2E {}, scenario.ctx());
        // A Policy<Obj> already exists (created by the harness).
        let (_p, _c) = policy::new_for_object<Obj>(namespace, &publisher, true);
        abort
    });
}

#[test]
fun lazy_delivery_send_before_account_exists() {
    test_obj_tx!(@0x1, |namespace, policy, scenario| {
        scenario.next_tx(@0x1);
        let mut from = account::create(namespace, @0x1);
        let obj = Obj { id: object::new(scenario.ctx()) };
        let obj_id = object::id(&obj);
        from.deposit_object(obj);
        from.share();

        // @0x1 sends to @0x2, who has no account yet.
        scenario.next_tx(@0x1);
        let mut from = scenario.take_shared_by_id<Account>(namespace.account_address(@0x1).to_id());
        let receiving = ts::receiving_ticket_by_id<Obj>(obj_id);
        let auth = account::new_auth(scenario.ctx());
        let mut request = from.unsafe_send_object<Obj>(&auth, @0x2, receiving, scenario.ctx());
        request.approve(ObjApproval());
        send_funds::resolve_object(request, policy);
        return_shared(from);

        // @0x2 creates their account afterwards and can move the delivered object.
        scenario.next_tx(@0x2);
        account::create_and_share(namespace, @0x2);

        scenario.next_tx(@0x2);
        let mut acc2 = scenario.take_shared_by_id<Account>(namespace.account_address(@0x2).to_id());
        let receiving2 = ts::receiving_ticket_by_id<Obj>(obj_id);
        let auth2 = account::new_auth(scenario.ctx());
        let mut request2 = acc2.unsafe_send_object<Obj>(&auth2, @0x1, receiving2, scenario.ctx());
        request2.approve(ObjApproval());
        send_funds::resolve_object(request2, policy);
        return_shared(acc2);

        scenario.next_tx(@0x1);
        assert!(ts::most_recent_id_for_address<Obj>(namespace.account_address(@0x1)).is_some());
    });
}

#[test]
fun deposit_object_to_owner_mints_into_account() {
    test_obj_tx!(@0x1, |namespace, policy, scenario| {
        scenario.next_tx(@0x1);
        // Mint directly to @0x2, who has no account yet.
        let obj = Obj { id: object::new(scenario.ctx()) };
        let obj_id = object::id(&obj);
        account::deposit_object_to_owner(namespace, @0x2, obj);

        // @0x2 creates their account and can manage the minted object.
        scenario.next_tx(@0x2);
        account::create_and_share(namespace, @0x2);

        scenario.next_tx(@0x2);
        let mut acc2 = scenario.take_shared_by_id<Account>(namespace.account_address(@0x2).to_id());
        let receiving = ts::receiving_ticket_by_id<Obj>(obj_id);
        let auth = account::new_auth(scenario.ctx());
        let mut request = acc2.unlock_object<Obj>(&auth, receiving, scenario.ctx());
        request.approve(ObjApproval());
        let got = unlock_funds::resolve(request, policy);
        assert_eq!(object::id(&got), obj_id);

        transfer::public_transfer(got, @0x2);
        return_shared(acc2);
    });
}

#[test]
fun compose_via_add_required_approval() {
    test_obj_tx!(@0x1, |namespace, policy, scenario| {
        scenario.next_tx(@0x1);
        // The harness set {ObjApproval} for send_funds; stack a second rule's witness.
        let policy_cap = scenario.take_from_sender<PolicyCap<Obj>>();
        policy.add_required_approval<_, ObjApproval2>(&policy_cap, b"send_funds".to_string());
        scenario.return_to_sender(policy_cap);

        let mut from = account::create(namespace, @0x1);
        let to = account::create(namespace, @0x2);
        let obj = Obj { id: object::new(scenario.ctx()) };
        let obj_id = object::id(&obj);
        from.deposit_object(obj);
        from.share();
        to.share();

        scenario.next_tx(@0x1);
        let mut from = scenario.take_shared_by_id<Account>(namespace.account_address(@0x1).to_id());
        let to = scenario.take_shared_by_id<Account>(namespace.account_address(@0x2).to_id());
        let receiving = ts::receiving_ticket_by_id<Obj>(obj_id);
        let auth = account::new_auth(scenario.ctx());
        let mut request = from.send_object<Obj>(&auth, &to, receiving, scenario.ctx());
        // Satisfy in the maker's registration order.
        request.approve(ObjApproval());
        request.approve(ObjApproval2());
        send_funds::resolve_object(request, policy);
        return_shared(from);
        return_shared(to);
    });
}

#[test, expected_failure(abort_code = ::pas::request::EInsufficientApprovals)]
fun compose_wrong_order_fails() {
    test_obj_tx!(@0x1, |namespace, policy, scenario| {
        scenario.next_tx(@0x1);
        let policy_cap = scenario.take_from_sender<PolicyCap<Obj>>();
        policy.add_required_approval<_, ObjApproval2>(&policy_cap, b"send_funds".to_string());
        scenario.return_to_sender(policy_cap);

        let mut from = account::create(namespace, @0x1);
        let to = account::create(namespace, @0x2);
        let obj = Obj { id: object::new(scenario.ctx()) };
        let obj_id = object::id(&obj);
        from.deposit_object(obj);
        from.share();
        to.share();

        scenario.next_tx(@0x1);
        let mut from = scenario.take_shared_by_id<Account>(namespace.account_address(@0x1).to_id());
        let to = scenario.take_shared_by_id<Account>(namespace.account_address(@0x2).to_id());
        let receiving = ts::receiving_ticket_by_id<Obj>(obj_id);
        let auth = account::new_auth(scenario.ctx());
        let mut request = from.send_object<Obj>(&auth, &to, receiving, scenario.ctx());
        // Wrong order — the policy maker registered {ObjApproval, ObjApproval2}.
        request.approve(ObjApproval2());
        request.approve(ObjApproval());
        send_funds::resolve_object(request, policy);
        abort
    });
}

fun pkg_id(): ID {
    sui::address::from_ascii_bytes(std::type_name::with_defining_ids<Namespace>()
        .address_string()
        .as_bytes()).to_id()
}

/// Sets up a namespace and a managed `Policy<Obj>` (clawback enabled, `ObjApproval`
/// required for all actions), then runs the body with `&mut Namespace, &mut Policy<Obj>`.
public macro fun test_obj_tx(
    $admin: address,
    $f: |&mut Namespace, &mut Policy<Obj>, &mut sui::test_scenario::Scenario|,
) {
    let mut scenario = ts::begin($admin);
    namespace::init_for_testing(scenario.ctx());

    scenario.next_tx($admin);
    let mut namespace = scenario.take_shared<Namespace>();

    let upgrade_cap = package::test_publish(pkg_id(), scenario.ctx());
    namespace.setup(&upgrade_cap);
    transfer::public_transfer(upgrade_cap, $admin);

    let publisher = package::test_claim(OBJECT_E2E {}, scenario.ctx());
    let (mut policy, policy_cap) = policy::new_for_object<Obj>(&mut namespace, &publisher, true);
    policy.set_required_approval<_, ObjApproval>(&policy_cap, b"send_funds".to_string());
    policy.set_required_approval<_, ObjApproval>(&policy_cap, b"unlock_funds".to_string());
    policy.set_required_approval<_, ObjApproval>(&policy_cap, b"clawback_funds".to_string());
    transfer::public_transfer(policy_cap, $admin);
    std::unit_test::destroy(publisher);
    policy.share();

    scenario.next_tx($admin);
    let mut policy = scenario.take_shared<Policy<Obj>>();

    $f(&mut namespace, &mut policy, &mut scenario);

    scenario.next_tx($admin);
    return_shared(namespace);
    return_shared(policy);
    scenario.end();
}
