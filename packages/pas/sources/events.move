module pas::events;

use sui::event;

public struct FundsSent<phantom T> has copy, drop {
    sender: address,
    recipient: address,
    amount: u64,
}

public struct FundsClawback<phantom T> has copy, drop {
    owner: address,
    amount: u64,
}

public struct FundsUnlocked<phantom T> has copy, drop {
    owner: address,
    amount: u64,
}

public(package) fun emit_funds_sent<T>(sender: address, recipient: address, amount: u64) {
    event::emit(FundsSent<T> { sender, recipient, amount });
}

public(package) fun emit_funds_clawback<T>(owner: address, amount: u64) {
    event::emit(FundsClawback<T> { owner, amount });
}

public(package) fun emit_funds_unlocked<T>(owner: address, amount: u64) {
    event::emit(FundsUnlocked<T> { owner, amount });
}

public struct ObjectSent<phantom T> has copy, drop {
    sender: address,
    recipient: address,
    object_id: ID,
}

public struct ObjectClawback<phantom T> has copy, drop {
    owner: address,
    object_id: ID,
}

public struct ObjectUnlocked<phantom T> has copy, drop {
    owner: address,
    object_id: ID,
}

public(package) fun emit_object_sent<T>(sender: address, recipient: address, object_id: ID) {
    event::emit(ObjectSent<T> { sender, recipient, object_id });
}

public(package) fun emit_object_clawback<T>(owner: address, object_id: ID) {
    event::emit(ObjectClawback<T> { owner, object_id });
}

public(package) fun emit_object_unlocked<T>(owner: address, object_id: ID) {
    event::emit(ObjectUnlocked<T> { owner, object_id });
}
