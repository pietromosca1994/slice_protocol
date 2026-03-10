module mock::mock_usdc {
    use iota::coin::{Self, TreasuryCap};

    public struct MOCK_USDC has drop {}

    fun init(witness: MOCK_USDC, ctx: &mut TxContext) {
        let (treasury, metadata) = coin::create_currency(
            witness,
            6,
            b"USDC",
            b"USD Coin",
            b"Mock USDC for testnet",
            option::none(),
            ctx,
        );
        transfer::public_freeze_object(metadata);
        transfer::public_transfer(treasury, ctx.sender());
    }

    /// Mint `amount` of MOCK_USDC to `recipient`.
    /// The caller must own the TreasuryCap.
    public entry fun mint(
        cap: &mut TreasuryCap<MOCK_USDC>,
        amount: u64,
        recipient: address,
        ctx: &mut TxContext,
    ) {
        coin::mint_and_transfer(cap, amount, recipient, ctx);
    }

    /// Burn coins (optional but good practice).
    public entry fun burn(
        cap: &mut TreasuryCap<MOCK_USDC>,
        coin: coin::Coin<MOCK_USDC>,
    ) {
        coin::burn(cap, coin);
    }
}