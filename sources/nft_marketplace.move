module marketplace_addr::marketplace {
    use std::signer;
    use aptos_framework::object;
    use aptos_std::smart_vector;
    use aptos_framework::aptos_account;
    use std::error;
    use aptos_framework::coin;
    use std::option;

    #[test_only]
    friend marketplace_addr::test_marketplace;

    const ERR_NO_LISTING: u64 = 0;
    const APP_OBJECT_SEED: vector<u8> = b"MARKETPLACE";

    struct MarketplaceSigner has key {
        extend_ref: object::ExtendRef,
    }

    #[resource_group_member(group = aptos_framework::object::ObjectGroup)]
    struct Listing has key {
        object: object::Object<object::ObjectCore>,
        seller: address,
        delete_ref: object::DeleteRef,
        extend_ref: object::ExtendRef,
    }

    #[resource_group_member(group = aptos_framework::object::ObjectGroup)]
    struct FixedPriceListing<phantom CoinType> has key {
        price: u64,
    }

    struct SellerListings has key {
        listings: smart_vector::SmartVector<address>,
    }

    struct Sellers has key {
        addresses: smart_vector::SmartVector<address>,
    }

    fun init_module(deployer: &signer) {
        let constructor_ref = object::create_named_object(
            deployer,
            APP_OBJECT_SEED,
        );
        let marketplace_signer = &object::generate_signer(&constructor_ref);
        move_to(marketplace_signer, MarketplaceSigner { extend_ref: object::generate_extend_ref(&constructor_ref) });
    }

    fun get_marketplace_signer_addr(): address {
        object::create_object_address(&@marketplace_addr, APP_OBJECT_SEED)
    }

    fun get_marketplace_signer(addr: address): signer acquires MarketplaceSigner {
        object::generate_signer_for_extending(&borrow_global<MarketplaceSigner>(addr).extend_ref)
    }

    public entry fun list_with_fixed_price<CoinType>(
        seller: &signer,
        object: object::Object<object::ObjectCore>,
        price: u64,
    ) acquires MarketplaceSigner, SellerListings, Sellers {
        list_with_fixed_price_internal<CoinType>(seller, object, price);
    }

    public(friend) fun list_with_fixed_price_internal<CoinType>(
        seller: &signer,
        object: object::Object<object::ObjectCore>,
        price: u64,
    ): object::Object<Listing> acquires MarketplaceSigner, SellerListings, Sellers {
        let constructor_ref = object::create_object(signer::address_of(seller));
        let transfer_ref = object::generate_transfer_ref(&constructor_ref);
        object::disable_ungated_transfer(&transfer_ref);
        let listing_signer = object::generate_signer(&constructor_ref);
        let listing = Listing {
            object,
            seller: signer::address_of(seller),
            delete_ref: object::generate_delete_ref(&constructor_ref),
            extend_ref: object::generate_extend_ref(&constructor_ref),
        };
        let fixed_price_listing = FixedPriceListing<CoinType> {
            price,
        };
        move_to(&listing_signer, listing);
        move_to(&listing_signer, fixed_price_listing);

        object::transfer(seller, object, signer::address_of(&listing_signer));

        let listing = object::object_from_constructor_ref(&constructor_ref);

        if(exists<SellerListings>(signer::address_of(seller))){
            let seller_listings = borrow_global_mut<SellerListings>(signer::address_of(seller));
            smart_vector::push_back(&mut seller_listings.listings, object::object_address(&listing));
        } else {
            let seller_listings = SellerListings {
                listings: smart_vector::new()
            };
            smart_vector::push_back(&mut seller_listings.listings, object::object_address(&listing));
            move_to(seller, seller_listings);
        };

        if(exists<Sellers>(get_marketplace_signer_addr())){
            let sellers = borrow_global_mut<Sellers>(get_marketplace_signer_addr());
            if(!smart_vector::contains(&sellers.addresses, &signer::address_of(seller))){
                smart_vector::push_back(&mut sellers.addresses, signer::address_of(seller));
            }
        } else {
            let sellers = Sellers {
                addresses: smart_vector::new()
            };
            smart_vector::push_back(&mut sellers.addresses, signer::address_of(seller));
            move_to(&get_marketplace_signer(get_marketplace_signer_addr()), sellers);
        };

        listing
    }

    public entry fun purchase<CoinType>(
        purchaser: &signer,
        object: object::Object<object::ObjectCore>,
    ) acquires FixedPriceListing, Listing, SellerListings, Sellers {
        let listing_addr = object::object_address(&object);
        assert!(exists<Listing>(listing_addr), error::not_found(ERR_NO_LISTING));
        assert!(exists<FixedPriceListing<CoinType>>(listing_addr), error::not_found(ERR_NO_LISTING));

        let FixedPriceListing {
            price 
        } = move_from<FixedPriceListing<CoinType>>(listing_addr);

        let coins = coin::withdraw<CoinType>(purchaser, price);

        let Listing {
            object,
            seller,
            delete_ref,
            extend_ref
        } = move_from<Listing>(listing_addr);

        let obj_signer = object::generate_signer_for_extending(&extend_ref);
        object::transfer(&obj_signer, object, signer::address_of(purchaser));
        object::delete(delete_ref);

        let seller_listings = borrow_global_mut<SellerListings>(seller);
        let (exist, idx) = smart_vector::index_of(&seller_listings.listings, &listing_addr);
        assert!(exist, error::not_found(ERR_NO_LISTING));
        smart_vector::remove(&mut seller_listings.listings, idx);

        if(smart_vector::length(&seller_listings.listings) == 0) {
            let sellers = borrow_global_mut<Sellers>(get_marketplace_signer_addr());
            let (exist, idx) = smart_vector::index_of(&sellers.addresses, &seller);
            assert!(exist, error::not_found(ERR_NO_LISTING));
            smart_vector::remove(&mut sellers.addresses, idx);
        };
        aptos_account::deposit_coins(seller, coins);
    } 

    #[view]
    public fun get_sellers(): vector<address> acquires Sellers {
        if(exists<Sellers>(get_marketplace_signer_addr())){
            smart_vector::to_vector(&borrow_global<Sellers>(get_marketplace_signer_addr()).addresses)
        } else {
            vector[]
        }
    }

    #[view]
    public fun get_seller_listings(addr: address): vector<address> acquires SellerListings {
        if(exists<SellerListings>(addr)){
            smart_vector::to_vector(&borrow_global<SellerListings>(addr).listings)
        } else {
            vector[]
        }
    }

    #[view]
    public fun listing(object: object::Object<Listing>): (object::Object<object::ObjectCore>, address) acquires Listing {
        let listing = borrow_listing(object);
        (listing.object, listing.seller)
    }

    inline fun borrow_listing(object: object::Object<Listing>): &Listing acquires Listing {
        let obj_addr = object::object_address(&object);
        assert!(exists<Listing>(obj_addr), error::not_found(ERR_NO_LISTING));
        borrow_global<Listing>(obj_addr)
    }

    #[view]
    public fun price<CoinType>(
        object: object::Object<Listing>,
    ): option::Option<u64> acquires FixedPriceListing {
        let listing_addr = object::object_address(&object);
        if(exists<FixedPriceListing<CoinType>>(listing_addr)){
            let fixed_price = borrow_global<FixedPriceListing<CoinType>>(listing_addr).price;
            option::some(fixed_price)
        } else {
            assert!(false, error::not_found(ERR_NO_LISTING));
            option::none()
        }
    }

    #[test_only]
    public fun setup_test(acc: &signer) {
        init_module(acc);
    }
}

#[test_only]
module marketplace_addr::test_marketplace {
    use std::option;
    use aptos_framework::object;
    use aptos_framework::aptos_coin;
    use aptos_framework::coin;
    use aptos_token_objects::token;
    use marketplace_addr::marketplace;
    use marketplace_addr::test_utils;

    // Test fixed price listing can be created and purchased
    #[test(aptos_framework = @0x1, marketplace = @marketplace_addr, seller = @0x222, purchaser = @0x333)]
    fun test_fixed_price(
        aptos_framework: &signer,
        marketplace: &signer,
        seller: &signer,
        purchaser: &signer,
    ) { 
        let (_marketplace_addr, seller_addr, purchaser_addr) = test_utils::setup(
            aptos_framework,
            marketplace,
            seller,
            purchaser
        );
        let (token, listing) = fixed_price_listing(seller, 500);
        let (listing_obj, seller_addr2) = marketplace::listing(listing);
        assert!(listing_obj == object::convert(token), 0);
        assert!(seller_addr2 == seller_addr, 0);
        assert!(marketplace::price<aptos_coin::AptosCoin>(listing) == option::some(500), 0);
        assert!(object::owner(token) == object::object_address(&listing), 0);

        marketplace::purchase<aptos_coin::AptosCoin>(purchaser, object::convert(listing));

        assert!(object::owner(token) == purchaser_addr, 0);
        assert!(coin::balance<aptos_coin::AptosCoin>(seller_addr) == 10500, 0);
        assert!(coin::balance<aptos_coin::AptosCoin>(purchaser_addr) == 9500, 0);
    }

    inline fun fixed_price_listing(
        seller: &signer,
        price: u64
    ): (object::Object<token::Token>, object::Object<marketplace::Listing>) {
        let token = test_utils::mint_tokenv2(seller);
        fixed_price_listing_with_token(seller, token, price)
    }

     inline fun fixed_price_listing_with_token(
        seller: &signer,
        token: object::Object<token::Token>,
        price: u64
    ): (object::Object<token::Token>, object::Object<marketplace::Listing>) {
        let listing = marketplace::list_with_fixed_price_internal<aptos_coin::AptosCoin>(
            seller,
            object::convert(token),
            price
        );
        (token, listing)
    }
} 
