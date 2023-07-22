module overmind::pay_me_a_river {
    use aptos_std::table::Table;
    use aptos_framework::aptos_coin::AptosCoin;
    use aptos_framework::coin::{Coin};
    use std::signer;
    use aptos_framework::timestamp;
    use aptos_framework::coin;
    use aptos_std::table;
    use aptos_framework::account;
    use std::bcs;

    const ESENDER_CAN_NOT_BE_RECEIVER: u64 = 1;
    const ENUMBER_INVALID: u64 = 2;
    const EPAYMENT_DOES_NOT_EXIST: u64 = 3;
    const ESTREAM_DOES_NOT_EXIST: u64 = 4;
    const ESTREAM_IS_ACTIVE: u64 = 5;
    const ESIGNER_ADDRESS_IS_NOT_SENDER_OR_RECEIVER: u64 = 6;

    struct Stream has store {
        sender: address,
        receiver: address,
        length_in_seconds: u64,
        start_time: u64,
        coins: Coin<AptosCoin>,
    }

    struct Payments has key {
        streams: Table<address, Stream>,
        resource_signer_cap: account::SignerCapability,
    }

    inline fun check_sender_is_not_receiver(sender: address, receiver: address) {
        assert!(sender != receiver, ESENDER_CAN_NOT_BE_RECEIVER)
    }

    inline fun check_number_is_valid(number: u64) {
        assert!(number > 0, ENUMBER_INVALID)
    }

    inline fun check_payment_exists(sender_address: address) {
        assert!(exists<Payments>(sender_address), ESTREAM_DOES_NOT_EXIST);
    }

    inline fun check_stream_exists(payments: &Payments, stream_address: address) {
        assert!(table::contains(&payments.streams, stream_address), ESTREAM_DOES_NOT_EXIST)
    }

    inline fun check_stream_is_not_active(payments: &Payments, stream_address: address) {
        let stream = table::borrow(&payments.streams, stream_address);
        // check that stream is not active...
        assert!(stream.start_time == 0, ESTREAM_IS_ACTIVE)
    }

    inline fun check_signer_address_is_sender_or_receiver(
        signer_address: address,
        sender_address: address,
        receiver_address: address
    ) {
        assert!(signer_address == receiver_address || signer_address == sender_address,
            ESIGNER_ADDRESS_IS_NOT_SENDER_OR_RECEIVER);
    }

    inline fun calculate_stream_claim_amount(total_amount: u64, start_time: u64, length_in_seconds: u64): u64 {

        let now = timestamp::now_seconds();
        let end_time = start_time + length_in_seconds;
        let duration = now - start_time;
        if (now > end_time) {
            total_amount
        } else {
            (duration * total_amount) / length_in_seconds
        }
    }

    public entry fun create_stream(
        signer: &signer,
        receiver_address: address,
        amount: u64,
        length_in_seconds: u64
    ) acquires Payments {
        let payment_address = signer::address_of(signer);
        if (!exists<Payments>(payment_address)) {
            let streams = table::new<address, Stream>();
            let seed = bcs::to_bytes(&receiver_address);
            let (_, resource_signer_cap) = account::create_resource_account(signer, seed);
            move_to(signer, Payments {streams, resource_signer_cap});
        };
        let payments = borrow_global_mut<Payments>(payment_address);

        let resource_signer = account::create_signer_with_capability(&payments.resource_signer_cap);
        let resource_address = signer::address_of(&resource_signer);

        coin::register<AptosCoin>(&resource_signer); // register, so transfer to resource_address works
        if (!table::contains(&mut payments.streams, receiver_address)) {
            let coins = coin::zero<AptosCoin>();
            let stream = Stream {
                sender: payment_address,
                receiver: receiver_address,
                length_in_seconds,
                start_time: timestamp::now_seconds(),
                coins
            };
            table::add(&mut payments.streams, receiver_address, stream);
        } else {
            let stream = table::borrow_mut(&mut payments.streams, receiver_address);
            stream.length_in_seconds = length_in_seconds;
            stream.start_time = timestamp::now_seconds();
        };
        coin::transfer<AptosCoin>(signer, resource_address, amount)
    }

    // accept_stream(sender, sender_address) must fail
    // accept_stream(receiver, sender_address);
    public entry fun accept_stream(signer: &signer, sender_address: address) acquires Payments {
        check_payment_exists(sender_address);
        let payments = borrow_global_mut<Payments>(sender_address);
        let stream_address = signer::address_of(signer);
        check_stream_exists(payments, stream_address);
        check_stream_is_not_active(payments, stream_address);
        check_sender_is_not_receiver(sender_address, stream_address);

        let stream = table::borrow_mut(&mut payments.streams, stream_address);

        stream.start_time = timestamp::now_seconds();
    }

    public entry fun claim_stream(signer: &signer, sender_address: address) acquires Payments {
        check_payment_exists(sender_address);
        let payments = borrow_global_mut<Payments>(sender_address);
        let stream_address = signer::address_of(signer);
        check_stream_exists(payments, stream_address);
        check_sender_is_not_receiver(sender_address, stream_address);

        let resource_signer = account::create_signer_with_capability(&payments.resource_signer_cap);
        let resource_address = signer::address_of(&resource_signer);
        let stream = table::borrow_mut(&mut payments.streams, stream_address);

        let claim_amount = calculate_stream_claim_amount(coin::balance<AptosCoin>(resource_address),
            stream.start_time, stream.length_in_seconds);
        coin::transfer<AptosCoin>(&resource_signer, stream.receiver, claim_amount);
    }

    public entry fun cancel_stream(
        signer: &signer,
        sender_address: address,
        receiver_address: address
    ) acquires Payments {
        check_payment_exists(sender_address);
        let payments = borrow_global<Payments>(sender_address);
        check_stream_exists(payments, receiver_address);
        check_stream_is_not_active(payments, receiver_address);
        check_signer_address_is_sender_or_receiver(signer::address_of(signer), sender_address, receiver_address);

        let payments = borrow_global_mut<Payments>(sender_address);
        let resource_signer = account::create_signer_with_capability(&payments.resource_signer_cap);
        let resource_address = signer::address_of(&resource_signer);
        let stream = table::borrow_mut(&mut payments.streams, receiver_address);
        stream.start_time = 0;
        let amount = coin::balance<AptosCoin>(resource_address);
        coin::transfer<AptosCoin>(&resource_signer, sender_address, amount);
    }

    #[view]
    public fun get_stream(sender_address: address, receiver_address: address): (u64, u64, u64) acquires Payments {
        check_payment_exists(sender_address);
        let payments = borrow_global_mut<Payments>(sender_address);
        check_stream_exists(payments, receiver_address);
        let resource_signer = account::create_signer_with_capability(&payments.resource_signer_cap);
        let resource_address = signer::address_of(&resource_signer);
        let stream = table::borrow_mut(&mut payments.streams, receiver_address);
        let balance = coin::balance<AptosCoin>(resource_address);
        // debug::print(&balance);
        (stream.length_in_seconds, stream.start_time, balance)
    }

}