#[test_only, allow(unused_variable, dead_code)]
module settlement::settlement_tests;

use pas::account::{Self, Account};
use pas::namespace::{Self, Namespace};
use pas::policy::{Self, Policy, PolicyCap};
use settlement::discount;
use settlement::floor;
use settlement::royalty;
use settlement::settlement;
use std::unit_test::assert_eq;
use sui::coin::{Self, Coin};
use sui::package;
use sui::sui::SUI;
use sui::test_scenario::{Self as ts, return_shared};

const SELLER: address = @0xA;
const BUYER: address = @0xB;
const CREATOR: address = @0xC;

public struct TEST has drop {}

public struct TestNft has key, store { id: UID }

/// Build a namespace + a `Policy<TestNft>` stacking [discount 20%, royalty 5%, floor 10]
/// and a TestNft sitting in SELLER's account. Leaves everything shared.
fun setup(scenario: &mut ts::Scenario): ID {
    let ctx = scenario.ctx();
    let mut namespace = namespace::create_for_testing(ctx);
    namespace.setup_for_testing();

    let publisher = package::test_claim(TEST {}, ctx);
    let (mut policy, cap) = policy::new_for_object<TestNft>(&mut namespace, &publisher, true);
    discount::add(&mut policy, &cap, 2_000, ctx); // 20%
    royalty::add(&mut policy, &cap, 500, CREATOR, ctx); // 5%
    floor::add(&mut policy, &cap, 10, ctx);

    account::create_and_share(&mut namespace, SELLER);
    let nft = TestNft { id: object::new(ctx) };
    let nft_id = object::id(&nft);
    account::deposit_object_to_owner(&namespace, SELLER, nft);

    std::unit_test::destroy(publisher);
    transfer::public_transfer(cap, SELLER);
    policy.share();
    namespace.share_for_testing();
    nft_id
}

#[test]
fun pipeline_happy_path() {
    let mut scenario = ts::begin(SELLER);
    let nft_id = setup(&mut scenario);

    scenario.next_tx(SELLER);
    {
        let namespace = scenario.take_shared<Namespace>();
        let policy = scenario.take_shared<Policy<TestNft>>();
        let discount_cfg = scenario.take_shared<discount::Config<TestNft>>();
        let royalty_cfg = scenario.take_shared<royalty::Config<TestNft>>();
        let floor_cfg = scenario.take_shared<floor::Config<TestNft>>();
        let mut seller_account = scenario.take_shared_by_id<Account>(namespace
            .account_address(SELLER)
            .to_id());

        let receiving = ts::receiving_ticket_by_id<TestNft>(nft_id);
        let auth = account::new_auth(scenario.ctx());
        let payment = coin::mint_for_testing<SUI>(100, scenario.ctx());

        // send_object → settlement pipeline (maker's order: discount → royalty → floor)
        let request = seller_account.unsafe_send_object<TestNft>(
            &auth,
            BUYER,
            receiving,
            scenario.ctx(),
        );
        let s = settlement::begin(request, payment, BUYER);
        let s = discount::apply(s, &discount_cfg, scenario.ctx());
        let s = royalty::apply(s, &royalty_cfg, scenario.ctx());
        let s = floor::apply(s, &floor_cfg);
        settlement::finalize(s, &policy);

        return_shared(namespace);
        return_shared(policy);
        return_shared(discount_cfg);
        return_shared(royalty_cfg);
        return_shared(floor_cfg);
        return_shared(seller_account);
    };

    // Verify payouts: discount fed the royalty (5% of the *discounted* 80 = 4, not 5).
    scenario.next_tx(SELLER);
    {
        let creator_cut = scenario.take_from_address<Coin<SUI>>(CREATOR);
        assert_eq!(creator_cut.value(), 4); // 5% of 80
        let buyer_refund = scenario.take_from_address<Coin<SUI>>(BUYER);
        assert_eq!(buyer_refund.value(), 20); // 20% discount returned to buyer
        let seller_proceeds = scenario.take_from_address<Coin<SUI>>(SELLER);
        assert_eq!(seller_proceeds.value(), 76); // 100 - 20 - 4

        let namespace = scenario.take_shared<Namespace>();
        // the NFT now lives in the buyer's account
        assert!(
            ts::most_recent_id_for_address<TestNft>(namespace.account_address(BUYER)).is_some(),
        );

        std::unit_test::destroy(creator_cut);
        std::unit_test::destroy(buyer_refund);
        std::unit_test::destroy(seller_proceeds);
        return_shared(namespace);
    };
    scenario.end();
}

#[test, expected_failure(abort_code = ::pas::request::EInvalidNumberOfApprovals)]
fun skipping_a_rule_fails() {
    let mut scenario = ts::begin(SELLER);
    let nft_id = setup(&mut scenario);

    scenario.next_tx(SELLER);
    let namespace = scenario.take_shared<Namespace>();
    let policy = scenario.take_shared<Policy<TestNft>>();
    let discount_cfg = scenario.take_shared<discount::Config<TestNft>>();
    let royalty_cfg = scenario.take_shared<royalty::Config<TestNft>>();
    let mut seller_account = scenario.take_shared_by_id<Account>(namespace
        .account_address(SELLER)
        .to_id());

    let receiving = ts::receiving_ticket_by_id<TestNft>(nft_id);
    let auth = account::new_auth(scenario.ctx());
    let payment = coin::mint_for_testing<SUI>(100, scenario.ctx());

    let request = seller_account.unsafe_send_object<TestNft>(
        &auth,
        BUYER,
        receiving,
        scenario.ctx(),
    );
    let s = settlement::begin(request, payment, BUYER);
    let s = discount::apply(s, &discount_cfg, scenario.ctx());
    let s = royalty::apply(s, &royalty_cfg, scenario.ctx());
    // floor skipped — finalize must abort (a required receipt is missing)
    settlement::finalize(s, &policy);
    abort
}

#[test, expected_failure(abort_code = ::pas::request::EInsufficientApprovals)]
fun wrong_order_fails() {
    let mut scenario = ts::begin(SELLER);
    let nft_id = setup(&mut scenario);

    scenario.next_tx(SELLER);
    let namespace = scenario.take_shared<Namespace>();
    let policy = scenario.take_shared<Policy<TestNft>>();
    let discount_cfg = scenario.take_shared<discount::Config<TestNft>>();
    let royalty_cfg = scenario.take_shared<royalty::Config<TestNft>>();
    let floor_cfg = scenario.take_shared<floor::Config<TestNft>>();
    let mut seller_account = scenario.take_shared_by_id<Account>(namespace
        .account_address(SELLER)
        .to_id());

    let receiving = ts::receiving_ticket_by_id<TestNft>(nft_id);
    let auth = account::new_auth(scenario.ctx());
    let payment = coin::mint_for_testing<SUI>(100, scenario.ctx());

    let request = seller_account.unsafe_send_object<TestNft>(
        &auth,
        BUYER,
        receiving,
        scenario.ctx(),
    );
    let s = settlement::begin(request, payment, BUYER);
    // royalty BEFORE discount — the maker registered discount first, so resolve aborts
    let s = royalty::apply(s, &royalty_cfg, scenario.ctx());
    let s = discount::apply(s, &discount_cfg, scenario.ctx());
    let s = floor::apply(s, &floor_cfg);
    settlement::finalize(s, &policy);
    abort
}
